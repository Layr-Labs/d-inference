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
        let capabilities: Set<ProviderRuntimeCapability> = hardware.chipFamily == .m5 ? [.appleM5] : []
        try current.withCurrentReference { _ in try prepared.requireUnchanged() }
        try ModelRuntimeRequirements.requireEligible(modelID: prepared.model.id, available: capabilities)
        let loopConfig = ProviderLoopConfig(
            coordinatorURL: coordinatorURL ?? config.coordinator.url,
            hardware: hardware, models: [prepared.model], config: config,
            authToken: AuthTokenStore.load(), runtimeHashes: hashes,
            runtimeCapabilities: capabilities,
            modelHashes: prepared.model.weightHash.map { [prepared.model.id: $0] } ?? [:],
            executionRole: .clusterMember, clusterMemberStopsOnDisconnect: stopOnDisconnect)
        let loop = try ProviderLoop(config: loopConfig)
        let installation = try current.withCurrentReference { _ in
            let value = try prepared.nativeMemberInstallation(chip: hardware.chipName)
            try prepared.requireUnchanged()
            return value
        }
        if let installation {
            try await loop.installNativePairMember(installation)
        }
        try Task.checkCancellation()
        try current.withCurrentReference { _ in try prepared.requireUnchanged() }
        return loop
    }

    func runClusterMember() async throws {
        #if NATIVE_PAIR_HARDWARE_EXPERIMENT
        if let path=ProcessInfo.processInfo.environment["DARKBLOOM_PRIVATE_NATIVE_HARDWARE_CONFIG"] {
            guard let pin=ProcessInfo.processInfo.environment["DARKBLOOM_PRIVATE_NATIVE_HARDWARE_SHA256"] else {throw NativeHardwareError.binding}
            try await runNativeHardwareLeader(path:path,pin:pin);return
        }
        #endif
        let path = try configOptions.config.map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
        } ?? ConfigManager.defaultConfigPath()
        let factory = try DistributedStartSessionFactory(providerConfiguration: path)
        try ProcessLifecycle.acquireMediaServingLock()
        ProcessLifecycle.preventSystemSleep()
        defer { ProcessLifecycle.releaseSingleInstanceLock() }
        let loop = try await makeClusterMemberLoop(reference: factory.reference)
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
