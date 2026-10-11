import Foundation
import ArgumentParser
import ProviderCore

extension Start {
    /// Shared by the follower-only command and the local leader. Pins the
    /// attested metallib without requireMetal, a container, or the solo device gate.
    func makeClusterMemberLoop(reference: ClusterConfigurationReference, stopOnDisconnect: Bool = false) async throws -> ProviderLoop {
        try await makeClusterMemberLoopAndPreparation(reference: reference, stopOnDisconnect: stopOnDisconnect).loop
    }

    func makeClusterMemberLoopAndPreparation(reference: ClusterConfigurationReference, stopOnDisconnect: Bool = false)
        async throws -> (loop: ProviderLoop, prepared: ClusterMemberPreparation) {
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
            let installation = try prepared.nativeMemberInstallation(chip: hardware.chipName) { metallib in
                try ClusterMemberDeviceProfile.current(chipName: hardware.chipName, gpuCores: hardware.gpuCores,
                    metallibSHA256: metallib)
            }
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
        return (loop, prepared)
    }

    func runClusterMember() async throws {
        let path = try configOptions.config.map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
        } ?? ConfigManager.defaultConfigPath()
        let factory = try DistributedStartSessionFactory(providerConfiguration: path)
        try ProcessLifecycle.acquireMediaServingLock()
        ProcessLifecycle.preventSystemSleep()
        defer { ProcessLifecycle.releaseSingleInstanceLock() }
        let (loop, prepared) = try await makeClusterMemberLoopAndPreparation(reference: factory.reference)
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
            try await loop.waitForClusterMemberRegistration(until: .now.advanced(by: .seconds(30)))
            print("darkbloom \(ProviderCore.version) (registered cluster member; solo inference disabled)")
            try await withTaskCancellationHandler { try await task.value }
                onCancel: { task.cancel() }
        } catch {
            task.cancel(); _ = try? await task.value
            throw error
        }
    }
}
