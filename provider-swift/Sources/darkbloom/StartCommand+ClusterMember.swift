import Foundation
import ArgumentParser
import ProviderCore

extension Start {
    /// Shared by the follower-only command and the local leader. Pins the
    /// attested metallib without requireMetal, a container, or the solo device gate.
    func makeClusterMemberLoop(reference: ClusterConfigurationReference, stopOnDisconnect: Bool = false) async throws -> ProviderLoop {
        try await makeClusterMemberLoopAndPreparation(reference: reference, stopOnDisconnect: stopOnDisconnect).loop
    }

    /// `offered`: the saved setup carries an approval this Mac installed, so its member registers a membership and
    /// the coordinator may form a pair with it. `answersUpdateDrain`: the coordinator-paired part, which drains for
    /// the pair's coordinated update (`ProviderLoopConfig.clusterMemberAnswersUpdateDrain`).
    func makeClusterMemberLoopAndPreparation(reference: ClusterConfigurationReference, stopOnDisconnect: Bool = false,
                                             answersUpdateDrain: Bool = false)
        async throws -> (loop: ProviderLoop, prepared: ClusterMemberPreparation, offered: Bool) {
        // The model's pair-serving grant for the rank this Mac runs, with this
        // Mac's own chip class (any Apple silicon; owner 2026-10-14), is decided inside the
        // preparation, before the weights are read. The single-Mac
        // requirements of the model are for solo serving and are not applied.
        let prepared = try await Task.detached(priority: .userInitiated) {
            try ClusterMemberPreparation.prepare(reference: reference, localChipClass: ClusterChipClass.local())
        }.value
        try Task.checkCancellation()
        let path = try configOptions.config.map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
        } ?? ConfigManager.defaultConfigPath()
        let current = try DistributedStartSessionFactory(providerConfiguration: path)
        guard current.reference == reference else {
            throw ClusterMemberControlError.incompatibleConfiguration
        }
        let hardware = try HardwareDetector.detect()
        let config = try ConfigManager.load(from: path)
        // The existing binder copies/hashes an anonymous read-only snapshot
        // and sets MLX's path string only; it performs no GPU initialization.
        // Without it metallibHash() is nil and fresh release attestation fails.
        guard bindRuntimeMetallibForMLX(from: nil) != nil else {
            throw ClusterMemberControlError.incompatibleConfiguration
        }
        let hashes = (try? RuntimeHashReporter().report().coordinatorRuntimeHashes)
        // Hardware-only capabilities are honest here. Native/kernel capability
        // proof belongs to the selected installed adapter, not a solo GPU probe.
        let capabilities = DistributedServingEligibility.memberCapabilities(chipFamily: hardware.chipFamily)
        let coordinator = coordinatorURL ?? config.coordinator.url
        let endpoint = Self.clusterMemberLocalEndpoint(requested: localEndpoint, hostsPairSlot: prepared.hostsPairSlot,
                                                       bind: bind, port: port, local: config.local, settingsFile: path,
                                                       coordinatorURL: coordinator)
        // A setup saved for coordinator pairing yields this Mac's member
        // installation; every other setup yields none and registers no claim.
        let installation = try current.withCurrentReference { _ in
            let installation = try prepared.nativeMemberInstallation(chip: hardware.chipName) { metallib in
                try ClusterMemberDeviceProfile.current(chipName: hardware.chipName, gpuCores: hardware.gpuCores,
                    metallibSHA256: metallib)
            }
            try prepared.requireUnchanged()
            return installation
        }
        let loopConfig = ProviderLoopConfig(
            coordinatorURL: coordinator,
            hardware: hardware, models: [prepared.model], config: config,
            authToken: AuthTokenStore.load(), runtimeHashes: hashes,
            runtimeCapabilities: capabilities,
            modelHashes: prepared.model.weightHash.map { [prepared.model.id: $0] } ?? [:],
            localEndpoint: endpoint,
            executionRole: .clusterMember, clusterMemberStopsOnDisconnect: stopOnDisconnect,
            clusterMemberAnswersUpdateDrain: answersUpdateDrain,
            pairServingGrantedModelIDs: [prepared.model.id])
        let loop = try ProviderLoop(config: loopConfig)
        if let installation {
            do { try await loop.installNativePairMember(installation) } catch {
                // The roster names this Mac by the key that paired (S17); another key means this Mac must pair again.
                if await loop.nativePairRosterNamesAnotherKey(installation) {
                    throw ClusterConfigurationError.invalid("This Mac cannot register the saved roster: \(ClusterPairingRosterCheck.Refusal.identityChanged)")
                }
                throw ClusterConfigurationError.invalid("This Mac cannot register the saved pair approval: it needs its attestation signing key and the approved chip and model")
            }
        }
        return (loop, prepared, installation != nil)
    }

    /// The pair's local API beside Darkbloom (Both, me first), on the address and port the cluster service chose, with
    /// the local router, for which this Mac's engine is the pair. Without `--local-endpoint` the member is today's.
    ///
    /// Only the slot's host runs it, checked three times: the service passes `--local-endpoint` to rank 0's part only
    /// (`ClusterLocalServing.memberArguments`); here, any other member runs none and says so in one line; and the loop
    /// refuses an endpoint on a member without the slot (`admitsClusterPairLocalAPI`), which would end the part.
    /// Never without a key: always the pair's (`cluster local`'s); `validate` refuses `--no-auth`, the loop refuses a
    /// keyless endpoint, and a key that can't be read here leaves the pair serving Darkbloom without the API, never
    /// with an open one.
    static func clusterMemberLocalEndpoint(requested: Bool, hostsPairSlot: Bool, bind: String, port: UInt16,
                                           local: LocalSettings?, settingsFile: URL? = nil, coordinatorURL: String?,
                                           loadToken: () throws -> String = { try LocalEndpoint.loadOrCreateClusterToken() },
                                           say: (String) -> Void = printError) -> LocalInferenceHTTPConfig? {
        guard requested else { return nil }
        guard hostsPairSlot else {
            say("This Mac's part runs no local API: the pair's API is on the Mac that runs rank 0.")
            return nil
        }
        guard let token = try? loadToken(), !token.isEmpty else {
            say("The pair's local API key could not be read or created, so this part serves Darkbloom without the local API.")
            return nil
        }
        return LocalInferenceHTTPConfig(host: bind, port: port, authToken: token,
            router: .host(local: local, settingsFile: nil, coordinatorURL: coordinatorURL, takesCoordinatorWork: true))
    }

    /// What a member's start that failed with `error` ends with. Refused because another Darkbloom app holds this Mac's
    /// GPU, or production serves here, it is a wait, never a failure: it says the refusal's `Error:` line (an `ExitCode`
    /// prints nothing, and the cluster service waits on that line) and ends with the exit code reserved for it, which
    /// the always-on supervisor waits on without spending its restart budget (`ClusterMemberPreparation.gpuHoldRefusal`).
    /// Any other error is thrown as it is.
    static func memberStartFailure(_ error: any Error, say: (String) -> Void = printError) -> any Error {
        guard let refusal = ClusterMemberPreparation.gpuHoldRefusal(error) else { return error }
        say(refusal.line)
        return ExitCode(refusal.exitCode)
    }

    func runClusterMember() async throws {
        let path = try configOptions.config.map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
        } ?? ConfigManager.defaultConfigPath()
        let factory = try DistributedStartSessionFactory(providerConfiguration: path)
        try ProcessLifecycle.acquireMediaServingLock()
        ProcessLifecycle.preventSystemSleep()
        defer { ProcessLifecycle.releaseSingleInstanceLock() }
        // Heartbeats for a supervisor (S18) and the launchd watchdog.
        let heartbeat = ClusterMemberHeartbeat()
        heartbeat.startEarly()
        defer { heartbeat.stop() }
        // Nothing of a dead session may be left when this member starts, and
        // nothing of this one when it ends: the orphan sweep (owners and
        // workers whose parent is gone, a stranded device journal, stale
        // bootstrap directories), reported in this member's log.
        Self.sweepOrphans(phase: "start", waitForContract: true)
        defer { Self.sweepOrphans(phase: "end", waitForContract: true) }
        let made: (loop: ProviderLoop, prepared: ClusterMemberPreparation, offered: Bool)
        do {
            made = try await makeClusterMemberLoopAndPreparation(reference: factory.reference, answersUpdateDrain: true)
        } catch {
            throw Self.memberStartFailure(error)
        }
        let (loop, prepared, offered) = made
        heartbeat.attach(loop: loop)
        // A setup saved for coordinator pairing over the link serves the
        // pair's committed starts (S10): the leader hosts the link listener
        // and publishes the pair slot, the follower serves its rank over it.
        let pairLink = try await prepared.installPairServing(on: loop) { line in
            let stamp = ISO8601DateFormatter().string(from: Date())
            FileHandle.standardOutput.write(Data("\(stamp) cluster-member follower: \(line)\n".utf8))
        }
        defer { pairLink?.stop() }
        let stamp = ISO8601DateFormatter().string(from: Date())
        print("\(stamp) cluster-member pair serving: \(pairLink?.role ?? "none")")
        let signals = try DistributedStartSignals()
        defer { signals.close() }
        let task = Task { try await loop.run() }
        signals.attach { task.cancel() }
        do {
            // A foreground command fails fast so the operator sees why. A
            // supervised member keeps reconnecting like a solo provider: a
            // coordinator still unreachable at boot (network not up yet) or
            // restarting is not a crash, and must not spend the restart budget.
            let wait: Duration = heartbeat.isSupervised ? .seconds(365 * 86_400) : .seconds(30)
            try await loop.waitForClusterMemberRegistration(until: .now.advanced(by: wait))
            print("darkbloom \(ProviderCore.version) (registered cluster member; solo inference disabled)")
            // The cluster service reads its part's latest notice line (unbuffered stderr): this part is offered.
            if offered {
                printError(ClusterLocalServing.offeredLogLine)
                // Owner-only by the coordinator's rule: the screens and status show it instead of ✓ once it serves.
                if let reason = prepared.ownerOnlyReason() { printError(ClusterLocalServing.logPrefix + reason) }
                let url = coordinatorURL ?? (try? ConfigManager.load(from: path))?.coordinator.url
                if let url { Self.sayCatalogRefusal(modelID: prepared.model.id, coordinatorURL: url) }
            }
            try await withTaskCancellationHandler { try await task.value }
                onCancel: { task.cancel() }
        } catch {
            task.cancel()
            // Bounded: a loop that does not finish after its cancellation must
            // not keep this process (and its SIGTERM) waiting forever (S09
            // finding 3); the process exits and its supervisor decides.
            await Self.awaitFinished(task, atMostSeconds: 30)
            throw error
        }
    }

    /// Reads the coordinator's public model catalog once, without holding up the part, and writes the refusal notice
    /// when it does not list `modelID` (`ClusterLocalServing.catalogRefusal`). A catalog that can't be read says nothing.
    static func sayCatalogRefusal(modelID: String, coordinatorURL: String) {
        Task.detached {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 20
            let client = ModelCatalogClient(coordinatorURL: coordinatorURL, urlSession: URLSession(configuration: configuration))
            guard let catalog = try? await client.fetchCatalog(),
                  let refusal = ClusterLocalServing.catalogRefusal(modelID: modelID, catalogIDs: Set(catalog.map(\.id)))
            else { return }
            printError(ClusterLocalServing.logPrefix + refusal)
        }
    }

    /// The orphan sweep at a member's start and end. Its outcome is one log
    /// line when it found something; a sweep that cannot run (no home) is
    /// noted and never fails the member.
    static func sweepOrphans(phase: String, waitForContract: Bool) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        do {
            let report = try ClusterOrphanSweep.reap(waitForContract: waitForContract)
            if let line = ClusterOrphanSweep.summary(report) {
                FileHandle.standardOutput.write(Data("\(stamp) cluster-member \(phase): \(line)\n".utf8))
            }
        } catch {
            FileHandle.standardOutput.write(Data("\(stamp) cluster-member \(phase): orphan sweep skipped: \(error)\n".utf8))
        }
    }

    /// Waits for `task` to finish, at most `seconds`; never cancels or kills it.
    static func awaitFinished(_ task: Task<Void, Error>, atMostSeconds seconds: Double) async {
        let finished = ClusterMemberFlag()
        Task.detached { _ = try? await task.value; finished.set() }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int(seconds * 1000)))
        while !finished.value, ContinuousClock.now < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }
}

final class ClusterMemberFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    var value: Bool { lock.withLock { raised } }
    func set() { lock.withLock { raised = true } }
}
