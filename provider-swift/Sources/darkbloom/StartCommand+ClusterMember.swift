import Foundation
import ArgumentParser
import ProviderCore

extension Start {
    /// Shared by the follower-only command and the local leader. Pins the
    /// attested metallib without requireMetal, a container, or the solo device gate.
    func makeClusterMemberLoop(reference: ClusterConfigurationReference, stopOnDisconnect: Bool = false) async throws -> ProviderLoop {
        let prepared = try await Task.detached(priority: .userInitiated) {
            try ClusterMemberPreparation.prepare(reference: reference)
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
        // A setup saved for coordinator pairing yields this Mac's member
        // installation; every other setup yields none and registers no claim.
        let installation = try current.withCurrentReference { _ in
            let installation = try prepared.nativeMemberInstallation(chip: hardware.chipName)
            try prepared.requireUnchanged()
            return installation
        }
        // The unchanged model eligibility gate, with a refusal that says why a
        // pair cannot meet it.
        try DistributedServingEligibility.require(modelID: prepared.model.id, memberCapabilities: capabilities)
        let loopConfig = ProviderLoopConfig(
            coordinatorURL: coordinatorURL ?? config.coordinator.url,
            hardware: hardware, models: [prepared.model], config: config,
            authToken: AuthTokenStore.load(), runtimeHashes: hashes,
            runtimeCapabilities: capabilities,
            modelHashes: prepared.model.weightHash.map { [prepared.model.id: $0] } ?? [:],
            executionRole: .clusterMember, clusterMemberStopsOnDisconnect: stopOnDisconnect)
        let loop = try ProviderLoop(config: loopConfig)
        if let installation {
            do { try await loop.installNativePairMember(installation) } catch {
                throw ClusterConfigurationError.invalid("This Mac cannot register the saved pair approval: it needs its attestation signing key and the approved chip and model")
            }
        }
        return loop
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
        let loop = try await makeClusterMemberLoop(reference: factory.reference)
        heartbeat.attach(loop: loop)
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
