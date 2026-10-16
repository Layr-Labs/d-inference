import Foundation
import ArgumentParser
import ProviderCore

extension Start {
    /// A distributed leader loads only verified tokenizer metadata here. Its
    /// local native owner child acquires the shared device exclusion.
    func runLocalDistributed() async throws {
        // Signals first: a stop that arrives while this rank 0 is still starting (its member loop, its preparation, the
        // wait for its follower) is latched and acted on at once instead of being lost before a handler exists.
        let signals = try DistributedStartSignals()
        defer { signals.close() }
        let configPath = try configOptions.config.map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
        } ?? ConfigManager.defaultConfigPath()
        let factory = try DistributedStartSessionFactory(providerConfiguration: configPath)
        // Before both Macs load anything: a port another program listens on would fail the bind only after the load.
        guard ClusterLocalServing.portIsFree(Int(port)) else {
            throw ValidationError("Port \(port) on this Mac is in use by another program; choose another with --port.")
        }
        try ProcessLifecycle.acquireMediaServingLock()
        ProcessLifecycle.preventSystemSleep()
        defer { ProcessLifecycle.releaseSingleInstanceLock() }
        try signals.requireNotTerminated()
        // Local only by choice (`darkbloom cluster local`, `--no-coordinator`): no coordinator connection is ever
        // built, so nothing can refuse or end it. Otherwise the leader registers as a control-only member first.
        let member: ProviderLoop?
        if noCoordinator { member = nil } else {
            member = try await makeClusterMemberLoop(reference: factory.reference, stopOnDisconnect: true)
        }
        // A session that stops without being asked says so at once: the wait
        // for its workers that follows can be the whole progress limit.
        let announce: @Sendable (DistributedInstalledStopNotice) -> Void = { printError($0.message) }
        try signals.requireNotTerminated()
        let session = try await factory.prepare()
        session.installStopNoticeHandler(announce)
        // A stop first lets a running request end at its next token, then
        // sends shutdown and waits for both workers to end themselves. One that
        // is still inside a collective when its peer went away needs its
        // progress limit to do so; nothing signals it sooner.
        let stopAllowance = session.cooperativeStopAllowanceNanoseconds
        // `darkbloom cluster local`: the pair's one key, whichever Mac the plan makes rank 0.
        let token = try noAuth ? nil : noCoordinator ? LocalEndpoint.loadOrCreateClusterToken() : LocalEndpoint.loadOrCreateToken()
        // From the selected registered model's row, like the stop allowance.
        let budget = try session.firstTokenBudgetPolicy()
        let server = DistributedLocalServer(
            session: session, config: .init(host: bind, port: port, authToken: token),
            firstTokenBudgetPolicy: budget)

        // Keep the existing endpoint/PID and sleep-prevention ownership. The
        // cluster leader never takes the native device gate from its own child.
        // (The signal handler was installed first thing; a stop latched before
        // this point runs as soon as it is attached below.)

        let memberTask = member.map { member in Task { try await member.run() } }
        // Public (registered with the coordinator) or local only: decided once,
        // by the registration wait, before the API opens; at once without a coordinator.
        let scope = DistributedServingScope()
        if member == nil { await scope.decide(.localOnly) }
        let memberExit = Task { () -> Result<Void, Error>? in
            guard let member, let memberTask else { return nil }
            let result = await memberTask.result
            // Serving locally only: the control loop was ended on purpose (or ended
            // by the coordinator's answer); it never advertised this leader.
            if await scope.decided() == .localOnly { return result }
            // A control loop that ended on its own says why before the stop
            // fails a request in flight (otherwise it looks like a pair failure).
            if let reason = await member.memberStopReason { printError("Distributed serving stops: \(reason).") }
            // A terminal control loop cannot leave this leader advertised.
            _ = await server.stop(until: DispatchTime.now().uptimeNanoseconds + stopAllowance)
            return result
        }
        let task = Task {
            if let member, let memberTask {
                do {
                    try await member.waitForClusterMemberRegistration(until: .now.advanced(by: .seconds(30)))
                    await scope.decide(.publicServing)
                } catch where ClusterLocalServing.servesLocally(after: error) && !Task.isCancelled {
                    // The coordinator cannot take the member role (unreachable, or
                    // without the role): serve on the local API only. The member
                    // connection closes, so nothing is advertised; the device lock
                    // and native lease stay held. A refusal of this member is not
                    // caught here and fails the start as before.
                    await scope.decide(.localOnly)
                    memberTask.cancel()
                    printError(error.localizedDescription)
                } catch {
                    await scope.decide(.failed)
                    throw error
                }
            }
            try Task.checkCancellation()
            try await server.start()
            guard let boundPort = await server.status.boundPort else {
                throw DistributedStartRuntimeError.listenerStopped
            }
            print("darkbloom \(ProviderCore.version) (local / distributed)")
            let decided = await scope.decided()
            printError(member == nil ? ClusterLocalServing.localOnlyLogLine
                : decided == .localOnly ? ClusterLocalServing.logLine : ClusterLocalServing.registeredLogLine)
            print("Model: \(session.model.publicModelID)")
            print("Listening on \(bind):\(boundPort); connection details: darkbloom local")
            return await withFanActivityLease(providerVersion: ProviderCore.version) {
                await server.waitUntilStopped()
            }
        }
        let stop: @Sendable () -> Void = {
            Task { await scope.decide(.failed) }
            task.cancel()
            memberTask?.cancel()
            Task { _ = await server.stop(until: DispatchTime.now().uptimeNanoseconds + stopAllowance) }
        }
        signals.attach {
            printError(DistributedInstalledStopNotice.requestedStopMessage(longestWaitNanoseconds: stopAllowance))
            stop()
        }
        let status: DistributedLocalServerStatus
        do {
            status = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { stop() }
        } catch {
            // A separate task keeps cancellation of the command from reducing
            // the bounded cleanup wait to an immediate cancelled sleep.
            let cleanup = Task {
                await server.stop(until: DispatchTime.now().uptimeNanoseconds + stopAllowance)
            }
            let status = await cleanup.value
            memberTask?.cancel()
            _ = await memberExit.value
            if !status.cleanupComplete {
                printError("Distributed cleanup is unresolved. Each owner keeps waiting for its worker and clears its own journal when that worker exits; `darkbloom cluster recover` reports what is left.")
            }
            throw error
        }
        memberTask?.cancel()
        let memberResult = await memberExit.value
        guard status.cleanupComplete else {
            throw DistributedStartRuntimeError.cleanupUnresolved
        }
        if status.failed { throw DistributedStartRuntimeError.sessionFailed }
        // Serving locally only, the control loop's end was the plan, not a failure.
        if await scope.decided() == .localOnly { return }
        if case .failure(let error)? = memberResult, !(error is CancellationError) { throw error }
        // A stop nobody asked for is never a clean exit: a supervisor restarts it.
        if let member, await member.memberStopReason != nil { throw DistributedStartRuntimeError.memberControlEnded }
    }
}

/// How a distributed leader serves this run, decided once by its registration wait: publicly (registered with the
/// coordinator), on its local API only (`ClusterLocalServing`), or not at all (the start failed or was stopped first).
/// The control loop's watcher waits for the decision, so a loop the coordinator's answer ended at the same moment is
/// never mistaken for a lost public registration (which stops the server).
actor DistributedServingScope {
    enum Mode: Equatable { case publicServing, localOnly, failed }
    private var mode: Mode?
    private var waiters: [CheckedContinuation<Mode, Never>] = []

    /// The first decision wins.
    func decide(_ value: Mode) {
        guard mode == nil else { return }
        mode = value
        let resumed = waiters; waiters = []
        for waiter in resumed { waiter.resume(returning: value) }
    }

    func decided() async -> Mode {
        if let mode { return mode }
        return await withCheckedContinuation { waiters.append($0) }
    }
}
