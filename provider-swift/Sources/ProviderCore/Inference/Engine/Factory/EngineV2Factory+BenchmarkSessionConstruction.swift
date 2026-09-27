import Foundation
import MLX
import MLXLMCommon

extension EngineV2Factory {
    /// Benchmark construction uses the normal slot factory and its identity,
    /// assistant and cache gates. The caller must compute fresh equal weight
    /// hashes before/after loading the container; passing the verified digest
    /// here avoids a redundant third model read. An explicit Gemma verifier
    /// control changes only that benchmark's verification mode.
    @_spi(Benchmarking)
    public static func makeBenchmarkSession(
        modelId: String, modelDirectory: URL, isVLM: Bool,
        container: ModelContainer, tokenizer: TokenizerHandle,
        verifiedWeightHash: String, kvBytesCapacity: Int,
        maxConcurrentRequests: Int = 1, mtpEnabled: Bool,
        assistantDirectory: URL? = nil,
        gemmaMTPVerification: EngineV2BenchmarkMTPVerification? = nil,
        useProductionKVGrant: Bool = false,
        kvBudget: GlobalKVCacheBudget? = nil,
        kvBackendConfig: String = "auto",
        requirePersistentKey: Bool = true,
        persistentTestNamespace: SSDPersistentTestKeyNamespace? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> EngineV2BenchmarkSession {
        try await makeBenchmarkSession(
            modelId: modelId, modelDirectory: modelDirectory, isVLM: isVLM,
            container: container, tokenizer: tokenizer, verifiedWeightHash: verifiedWeightHash,
            kvBytesCapacity: kvBytesCapacity, maxConcurrentRequests: maxConcurrentRequests,
            mtpEnabled: mtpEnabled, assistantDirectory: assistantDirectory,
            gemmaMTPVerification: gemmaMTPVerification, useProductionKVGrant: useProductionKVGrant,
            kvBudget: kvBudget, kvBackendConfig: kvBackendConfig, requirePersistentKey: requirePersistentKey,
            persistentTestNamespace: persistentTestNamespace, environment: environment,
            memorySnapshotForTesting: {
                (ProcessInfo.processInfo.physicalMemory, UInt64(Memory.activeMemory))
            })
    }

    // Keep the production allocator observation at the original point after
    // model preparation. Scripted fixtures can supply a deterministic machine
    // without weakening the public benchmark's memory guard.
    static func makeBenchmarkSession(
        modelId: String, modelDirectory: URL, isVLM: Bool,
        container: ModelContainer, tokenizer: TokenizerHandle,
        verifiedWeightHash: String, kvBytesCapacity: Int,
        maxConcurrentRequests: Int = 1, mtpEnabled: Bool,
        assistantDirectory: URL? = nil,
        gemmaMTPVerification: EngineV2BenchmarkMTPVerification? = nil,
        useProductionKVGrant: Bool = false,
        kvBudget: GlobalKVCacheBudget? = nil,
        kvBackendConfig: String = "auto",
        requirePersistentKey: Bool = true,
        persistentTestNamespace: SSDPersistentTestKeyNamespace? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        memorySnapshotForTesting: @Sendable () -> (physical: UInt64, active: UInt64)
    ) async throws -> EngineV2BenchmarkSession {
        try gemmaMTPVerification?.validateScope(
            mtpEnabled: mtpEnabled, concurrency: maxConcurrentRequests,
            productionGrant: useProductionKVGrant, backend: kvBackendConfig, environment: environment)
        // Reject a partial persistent-test selection before config reads,
        // assistant/slot preparation, native allocations or cache-root IO.
        try persistentTestNamespace?.validate(
            environment: environment, requirePersistentKey: requirePersistentKey)
        guard PrefixCachePolicy.checkpointIdentityHash(verifiedWeightHash) != nil else {
            throw EngineV2BenchmarkSession.Failure.invalidVerifiedWeightHash
        }
        guard kvBytesCapacity > 0, maxConcurrentRequests > 0,
            !useProductionKVGrant || kvBudget == nil else {
            throw EngineV2BenchmarkSession.Failure.invalidCapacity
        }
        var effectiveEnvironment = environment
        if requirePersistentKey,
            let testRoot = environment["DARKBLOOM_PREFIX_CACHE_TEST_ROOT"], !testRoot.isEmpty
        {
            // Keep the isolated payload directory while exercising the normal
            // persistent KEK path. Verify the actual key mode below.
            effectiveEnvironment["DARKBLOOM_PREFIX_CACHE_TEST_PERSISTENT_KEY"] = "1"
        }
        struct Declaration: Decodable {
            let modelType: String?
            enum CodingKeys: String, CodingKey { case modelType = "model_type" }
        }
        let declaration = try JSONDecoder().decode(Declaration.self,
            from: Data(contentsOf: modelDirectory.appendingPathComponent("config.json")))
        let preparation = try await benchmarkAssistantPreparation(
            modelId: modelId, modelType: declaration.modelType, modelDirectory: modelDirectory,
            enabled: mtpEnabled, assistantDirectory: assistantDirectory, environment: effectiveEnvironment)
        let prepared = try await EngineV2SlotFactory.prepareProductionModel(
            modelId: modelId, isVLM: isVLM, modelDirectory: modelDirectory,
            container: container, specDecPreparation: preparation)
        guard !mtpEnabled || prepared.mtpStatus.active else {
            prepared.assistant?.release()
            throw EngineV2BenchmarkSession.Failure.mtpUnavailable
        }
        let sizing = await SlotSizingSnapshot.build(
            container: container, modelPath: modelDirectory, fallbackDefaultMaxTokens: 8192)
            .replacingAuxiliaryWeightBytes(prepared.assistantBytes)
        let reserve = UnifiedMemoryCap.resolvedActivationReserveBytes(
            env: effectiveEnvironment, modelIDs: [modelId])
        let productionGrant: EngineV2BenchmarkProductionGrant?
        do {
            productionGrant = useProductionKVGrant ? try benchmarkProductionGrant(
                modelId: modelId, sizing: sizing, environment: effectiveEnvironment) : nil
        } catch {
            prepared.assistant?.release()
            throw error
        }
        let selectedGrant = productionGrant?.grantBytes ?? kvBytesCapacity
        // Retain the explicit-mode allocator guard and its diagnostic value.
        // Production logical grants use loaded parameters; current active bytes
        // do not redefine them. A separate live post-build gate runs below.
        let memory = memorySnapshotForTesting()
        let maximumKVBytes = UnifiedMemoryCap.kvBudgetBytes(
            physicalBytes: memory.physical,
            residentWeightBytes: memory.active, activationReserveBytes: reserve,
            configReserveBytes: productionGrant?.operatorReserveBytes ?? 0,
            capFraction: productionGrant?.capFraction)
        guard useProductionKVGrant || UInt64(selectedGrant) <= maximumKVBytes else {
            prepared.assistant?.release()
            throw EngineV2BenchmarkSession.Failure.invalidCapacity
        }
        // The default authority belongs to this isolated single session. Explicit
        // multi-session callers inject the complete serving-set policy authority.
        let budget = kvBudget ?? GlobalKVCacheBudget(
            capFraction: productionGrant?.capFraction, activationReserveBytes: reserve,
            configReserveBytes: productionGrant?.operatorReserveBytes ?? 0)
        let bundle: ProviderEngineBundle
        do {
            bundle = try await EngineV2SlotFactory.makeProductionBundle(
                modelId: modelId, modelType: declaration.modelType, isVLM: isVLM,
                modelDirectory: modelDirectory, container: container, tokenizer: tokenizer,
                sizing: sizing, kvBytesCapacity: selectedGrant,
                maxConcurrentRequests: maxConcurrentRequests, kvBudget: budget,
                activationReserveBytes: reserve, kvBackendConfig: kvBackendConfig,
                weightHash: verifiedWeightHash, specDecPreparation: preparation,
                preparedModel: prepared,
                assemblyOverrides: .init(gemmaMTPVerification: gemmaMTPVerification),
                environment: effectiveEnvironment,
                persistentTestNamespace: persistentTestNamespace)
        } catch {
            prepared.assistant?.release()
            throw error
        }
        // Bundle ownership transfers only after every benchmark gate passes.
        // All post-build refusals drain the engine before releasing the assistant.
        do {
            guard let engine = await bundle.bridge.ownedEngine as? EngineV2 else {
                throw EngineV2BenchmarkSession.Failure.unexpectedEngine
            }
            guard !mtpEnabled || (bundle.mtpStatus.active && engine.mtpMetricsSnapshot() != nil) else {
                throw EngineV2BenchmarkSession.Failure.mtpUnavailable
            }
            try gemmaMTPVerification?.validateObservedMetrics(engine.mtpMetricsSnapshot())
            guard !PrefixCachePolicy.isMemoryEnabled(environment: effectiveEnvironment),
                engine.hybridPrefixCache == nil else {
                throw EngineV2BenchmarkSession.Failure.unexpectedResidentCache
            }
            if PrefixCachePolicy.isEnabled(modelId: modelId, environment: effectiveEnvironment) {
                let cacheStatus = bundle.bridge.prefixCacheModelStatus()
                let hasEvidenceSource = bundle.bridge.durablePrefixCacheEvidenceSource != nil
                guard hasEvidenceSource, cacheStatus.state == .ready else {
                    throw EngineV2BenchmarkSession.Failure.ssdUnavailable(
                        status: cacheStatus, hasEvidenceSource: hasEvidenceSource)
                }
            }
            if requirePersistentKey, bundle.bridge.ssdHybridCheckpointStore?.usesEphemeralKey == true {
                throw EngineV2BenchmarkSession.Failure.persistentKeyUnavailable
            }
            var postBuildHeadroom: UInt64?
            if useProductionKVGrant {
                // The ordinary post-load guard clears reclaimable load buffers and
                // requires minimum live OS/activation headroom. It is a refusal gate,
                // not a second, smaller logical grant derived from Memory.active.
                Memory.clearCache()
                let sample = budget.memoryHeadroomSnapshot()
                postBuildHeadroom = sample.runtimeRemainingBytes
                let kind = await bundle.bridge.kvBackendKind
                let ceiling = await bundle.bridge.kvBackendPoolBytes()
                guard KVHeadroomProbe.postBuildServeable(kvBackendKind: kind, pagedPoolBytes: ceiling,
                    activationReserveBytes: reserve, measuredHeadroomBytes: sample.runtimeRemainingBytes) else {
                    throw EngineV2BenchmarkSession.Failure.unservablePostLoad(
                        headroomBytes: sample.runtimeRemainingBytes,
                        requiredBytes: UnifiedMemoryCap.minimumLoadKVBytes)
                }
            }
            let backend = await bundle.bridge.kvBackendKind.rawValue
            let fallback = await bundle.bridge.kvBackendFallbackReason
            return EngineV2BenchmarkSession(
                bundle: bundle, engine: engine,
                backend: backend, fallback: fallback,
                memoryEnabled: PrefixCachePolicy.isMemoryEnabled(environment: effectiveEnvironment),
                activationReserveBytes: reserve, postLoadMaximumKVBytes: maximumKVBytes,
                budget: budget, assistantIdentity: benchmarkAssistantIdentity(preparation.artifact),
                productionGrant: productionGrant, postBuildHeadroomBytes: postBuildHeadroom)
        } catch {
            await bundle.bridge.shutdown()
            bundle.releaseAssistant()
            throw error
        }
    }
}
