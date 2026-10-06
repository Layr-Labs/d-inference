import Foundation
import MLX
import MLXLMCommon
import ProviderCoreFoundation

extension EngineV2Factory {
    /// Ordinary CLI native MiMo route: one real budget owns loading and the
    /// final session. No bare directory-only native factory or second model.
    @_spi(Benchmarking)
    public static func loadNativeMiMoBenchmarkSession(
        modelID: String, directory: URL, verifiedWeightHash: String,
        operatorReserveBytes: UInt64,
        maxConcurrentRequests: Int = 1, mtpEnabled: Bool = false,
        kvBackend: String = "auto",
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> (container: ModelContainer, session: EngineV2BenchmarkSession) {
        guard ["auto", "contiguous"].contains(kvBackend.lowercased()) else {
            throw MiMoV26ServingLoadError.unsupportedBackend
        }
        guard let load = try MiMoV26ServingLoad.inspect(directory: directory),
            PrefixCachePolicy.checkpointIdentityHash(verifiedWeightHash) != nil else {
            throw MiMoV26ServingLoadError.nativeOwnerMismatch
        }
        let reserve = UnifiedMemoryCap.resolvedActivationReserveBytes(env: environment, modelIDs: [modelID])
        let budget = GlobalKVCacheBudget(
            capFraction: UnifiedMemoryCap.resolvedCapFraction(explicit: nil, env: environment),
            activationReserveBytes: reserve,
            configReserveBytes: operatorReserveBytes)
        let registry = MiMoV26NativeLoadRegistry.shared
        try registry.requireNewNativeWorkAllowed()
        let lifecycle = try registry.openLifecycle()
        do {
            try load.claim(budget: budget, lifecycle: lifecycle, registry: registry)
            guard let transaction = load.transaction else {
                throw MiMoV26ServingLoadError.nativeOwnerMismatch
            }
            let ownership = MiMoV26BenchmarkOwnership(
                registry: registry, lifecycle: lifecycle, transaction: transaction)
            let task = try registry.launchOwnedTask(for: transaction) {
                _ = try GPUEnforcement.requireMetal()
                MLXMemoryGuard.configureOnce()
                let serving = try await ModelContainerLoading.loadServingContainer(
                    from: directory, modelID: modelID, nativeMiMoLoad: load)
                guard let container = serving.autoregressive else {
                    throw MiMoV26ServingLoadError.nativeOwnerMismatch
                }
                guard WeightHasher.computeHash(snapshotDir: directory, modelID: modelID) == verifiedWeightHash else {
                    throw EngineV2BenchmarkSession.Failure.invalidVerifiedWeightHash
                }
                try load.recheck()
                let tokenizer = await container.perform { TokenizerHandle($0.tokenizer) }
                try load.recheck()
                let session = try await makeBenchmarkSession(modelId: modelID, modelDirectory: directory,
                    isVLM: false, container: container, tokenizer: tokenizer,
                    verifiedWeightHash: verifiedWeightHash, kvBytesCapacity: 1 << 30,
                    maxConcurrentRequests: maxConcurrentRequests, mtpEnabled: mtpEnabled,
                    useProductionKVGrant: true, kvBackendConfig: kvBackend,
                    requirePersistentKey: false, environment: environment,
                    nativeMiMoLoad: load, nativeMiMoBudget: budget,
                    nativeMiMoOperatorReserveBytes: operatorReserveBytes,
                    nativeMiMoOwnership: ownership,
                    memorySnapshotForTesting: { (ProcessInfo.processInfo.physicalMemory, UInt64(Memory.activeMemory)) })
                return (container: container, session: session)
            }
            return try await withTaskCancellationHandler {
                let result = try await task.value
                // The caller is outside the stored setup task: join its exact
                // handle before returning or consuming a retirement outcome.
                await registry.joinOwnedTasksFromOutside(transaction)
                try Task.checkCancellation()
                return result
            } onCancel: {
                task.cancel()
                transaction.revoke()
            }
        } catch {
            // Closing/cancelling is not a drain. Join the actual construction
            // task before asking its strongly registered owner to retire. Any
            // pending/faulted result remains retained by that registry.
            _ = try? registry.closeLifecycle(lifecycle)
            load.revoke()
            if let transaction = load.transaction {
                await registry.joinOwnedTasksFromOutside(transaction)
            }
            let retirement = await load.finishFailureAfterUnwind()
            if case .notClaimed = retirement { throw error }
            try EngineV2BenchmarkSession.requireNativeRetirement(retirement)
            throw error
        }
    }

    /// The ordinary benchmark must use the same model-ID-qualified text/vision
    /// factory and external-resource lifetime as a production slot.
    @_spi(Benchmarking)
    public static func loadBenchmarkContainer(
        modelID: String, directory: URL
    ) async throws -> (container: ModelContainer, isVLM: Bool) {
        let selection = ModelContainerLoading.factorySelection(at: directory, modelID: modelID)
        let container = try await ModelContainerLoading.loadContainer(from: directory, modelID: modelID)
        return (container, selection == .vision)
    }

    /// Call only after the benchmark session has drained and shut down.
    @_spi(Benchmarking)
    public static func releaseBenchmarkContainer(_ container: ModelContainer) async {
        await ModelContainerLoading.releaseExternalResources(in: container)
    }
}
