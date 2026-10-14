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
        try ProcessLifecycle.acquireMediaServingLock()
        ProcessLifecycle.preventSystemSleep()
        defer { ProcessLifecycle.releaseSingleInstanceLock() }
        try signals.requireNotTerminated()
        let member = try await makeClusterMemberLoop(reference: factory.reference, stopOnDisconnect: true)
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
        let token = try noAuth ? nil : LocalEndpoint.loadOrCreateToken()
        // From the selected registered model's row, like the stop allowance.
        let budget = try session.firstTokenBudgetPolicy()
        let server = DistributedLocalServer(
            session: session, config: .init(host: bind, port: port, authToken: token),
            firstTokenBudgetPolicy: budget)

        // Keep the existing endpoint/PID and sleep-prevention ownership. The
        // cluster leader never takes the native device gate from its own child.
        // (The signal handler was installed first thing; a stop latched before
        // this point runs as soon as it is attached below.)

        let memberTask = Task { try await member.run() }
        let memberExit = Task {
            let result = await memberTask.result
            // A control loop that ended on its own says why before the stop
            // fails a request in flight (otherwise it looks like a pair failure).
            if let reason = await member.memberStopReason { printError("Distributed serving stops: \(reason).") }
            // A terminal control loop cannot leave this leader advertised.
            _ = await server.stop(until: DispatchTime.now().uptimeNanoseconds + stopAllowance)
            return result
        }
        let task = Task {
            try await member.waitForClusterMemberRegistration(until: .now.advanced(by: .seconds(30)))
            try Task.checkCancellation()
            try await server.start()
            guard let boundPort = await server.status.boundPort else {
                throw DistributedStartRuntimeError.listenerStopped
            }
            print("darkbloom \(ProviderCore.version) (local / distributed)")
            print("Model: \(session.model.publicModelID)")
            print("Listening on \(bind):\(boundPort); connection details: darkbloom local")
            return await withFanActivityLease(providerVersion: ProviderCore.version) {
                await server.waitUntilStopped()
            }
        }
        let stop: @Sendable () -> Void = {
            task.cancel()
            memberTask.cancel()
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
            memberTask.cancel()
            _ = await memberExit.value
            if !status.cleanupComplete {
                printError("Distributed cleanup is unresolved. Each owner keeps waiting for its worker and clears its own journal when that worker exits; `darkbloom cluster recover` reports what is left.")
            }
            throw error
        }
        memberTask.cancel()
        let memberResult = await memberExit.value
        guard status.cleanupComplete else {
            throw DistributedStartRuntimeError.cleanupUnresolved
        }
        if status.failed { throw DistributedStartRuntimeError.sessionFailed }
        if case .failure(let error) = memberResult, !(error is CancellationError) { throw error }
        // A stop nobody asked for is never a clean exit: a supervisor restarts it.
        if await member.memberStopReason != nil { throw DistributedStartRuntimeError.memberControlEnded }
    }
}
