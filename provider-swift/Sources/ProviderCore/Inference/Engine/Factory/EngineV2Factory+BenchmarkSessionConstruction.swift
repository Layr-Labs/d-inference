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
        nativeMiMoLoad: MiMoV26ServingLoad? = nil,
        nativeMiMoBudget: GlobalKVCacheBudget? = nil,
        nativeMiMoOperatorReserveBytes: UInt64? = nil,
        nativeMiMoOwnership: MiMoV26BenchmarkOwnership? = nil,
        memorySnapshotForTesting: @escaping @Sendable () -> (physical: UInt64, active: UInt64)
    ) async throws -> EngineV2BenchmarkSession {
        let prepare: @Sendable () async throws -> BenchmarkSessionCandidate = {
            try await prepareBenchmarkSession(
                modelId: modelId, modelDirectory: modelDirectory, isVLM: isVLM,
                container: container, tokenizer: tokenizer, verifiedWeightHash: verifiedWeightHash,
                kvBytesCapacity: kvBytesCapacity, maxConcurrentRequests: maxConcurrentRequests,
                mtpEnabled: mtpEnabled, assistantDirectory: assistantDirectory,
                gemmaMTPVerification: gemmaMTPVerification, useProductionKVGrant: useProductionKVGrant,
                kvBudget: kvBudget, kvBackendConfig: kvBackendConfig, requirePersistentKey: requirePersistentKey,
                persistentTestNamespace: persistentTestNamespace, environment: environment,
                nativeMiMoLoad: nativeMiMoLoad, nativeMiMoBudget: nativeMiMoBudget,
                nativeMiMoOperatorReserveBytes: nativeMiMoOperatorReserveBytes,
                memorySnapshotForTesting: memorySnapshotForTesting)
        }
        if let nativeMiMoLoad {
            guard let ownership = nativeMiMoOwnership,
                nativeMiMoLoad.transaction === ownership.transaction else {
                throw MiMoV26ServingLoadError.nativeOwnerMismatch
            }
            // Track the ENTIRE awaited setup, not just its initial model load.
            // Seal only after that operation has actually unwound; construct
            // the returned session inside the final lifecycle-gated commit.
            let candidate = try await ownership.transaction.performSetup(prepare)
            _ = try await nativeMiMoLoad.sealConstructionForPublication()
            return try nativeMiMoLoad.commitPublication { candidate.makeSession(ownership) }
        }
        guard nativeMiMoOwnership == nil else { throw MiMoV26ServingLoadError.nativeOwnerMismatch }
        let candidate = try await prepare()
        return candidate.makeSession(nil)
    }

    /// The final allocation is synchronous and nonthrowing so the native
    /// transaction can publish it atomically with its lifecycle/permit checks.
    private struct BenchmarkSessionCandidate: Sendable {
        let makeSession: @Sendable (MiMoV26BenchmarkOwnership?) -> EngineV2BenchmarkSession
    }

    private static func prepareBenchmarkSession(
        modelId: String, modelDirectory: URL, isVLM: Bool,
        container: ModelContainer, tokenizer: TokenizerHandle,
        verifiedWeightHash: String, kvBytesCapacity: Int,
        maxConcurrentRequests: Int, mtpEnabled: Bool,
        assistantDirectory: URL?, gemmaMTPVerification: EngineV2BenchmarkMTPVerification?,
        useProductionKVGrant: Bool, kvBudget: GlobalKVCacheBudget?,
        kvBackendConfig: String, requirePersistentKey: Bool,
        persistentTestNamespace: SSDPersistentTestKeyNamespace?, environment: [String: String],
        nativeMiMoLoad: MiMoV26ServingLoad?, nativeMiMoBudget: GlobalKVCacheBudget?,
        nativeMiMoOperatorReserveBytes: UInt64?,
        memorySnapshotForTesting: @Sendable () -> (physical: UInt64, active: UInt64)
    ) async throws -> BenchmarkSessionCandidate {
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
        let servingContainer: ProviderModelContainer
        let preparation: SpecDecPreparation
        if let nativeMiMoLoad {
            guard declaration.modelType == "mimo_v2", !isVLM, nativeMiMoBudget != nil,
                nativeMiMoOperatorReserveBytes != nil,
                useProductionKVGrant, kvBudget == nil, assistantDirectory == nil,
                gemmaMTPVerification == nil, persistentTestNamespace == nil,
                !PrefixCachePolicy.isEnabled(modelId: modelId, environment: effectiveEnvironment),
                !PrefixCachePolicy.isMemoryEnabled(environment: effectiveEnvironment) else {
                throw MiMoV26ServingLoadError.nativeOwnerMismatch
            }
            try nativeMiMoLoad.recheck()
            servingContainer = .nativeMiMo(container, nativeMiMoLoad)
            preparation = try MiMoV26ServingLoad.preparation(mode: mtpEnabled ? .on : .off,
                externalPath: nil, environment: effectiveEnvironment)
        } else {
            guard declaration.modelType != "mimo_v2", nativeMiMoBudget == nil,
                nativeMiMoOperatorReserveBytes == nil else {
                throw MiMoV26ServingLoadError.managedLoadRequired
            }
            servingContainer = .autoregressive(container)
            preparation = try await benchmarkAssistantPreparation(
                modelId: modelId, modelType: declaration.modelType, modelDirectory: modelDirectory,
                enabled: mtpEnabled, assistantDirectory: assistantDirectory, environment: effectiveEnvironment)
        }
        let prepared = try await EngineV2SlotFactory.prepareProductionModel(
            modelId: modelId, isVLM: isVLM, modelDirectory: modelDirectory,
            container: servingContainer, specDecPreparation: preparation)
        // Native preparation is metadata-only. Its actual assistant is created
        // once inside protected slot construction and checked on the bundle.
        guard nativeMiMoLoad != nil || !mtpEnabled || prepared.mtpStatus.active else {
            prepared.assistant?.release()
            throw EngineV2BenchmarkSession.Failure.mtpUnavailable
        }
        let sizing = await servingContainer.sizing(modelPath: modelDirectory, defaultMaxTokens: 8192)
            .replacingAuxiliaryWeightBytes(prepared.assistantBytes)
        let reserve = UnifiedMemoryCap.resolvedActivationReserveBytes(
            env: effectiveEnvironment, modelIDs: [modelId])
        let productionGrant: EngineV2BenchmarkProductionGrant?
        do {
            productionGrant = useProductionKVGrant ? try benchmarkProductionGrant(
                modelId: modelId, sizing: sizing, environment: effectiveEnvironment,
                operatorReserveBytes: nativeMiMoOperatorReserveBytes) : nil
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
        let budget = nativeMiMoBudget ?? kvBudget ?? GlobalKVCacheBudget(
            capFraction: productionGrant?.capFraction, activationReserveBytes: reserve,
            configReserveBytes: productionGrant?.operatorReserveBytes ?? 0)
        let bundle: ProviderEngineBundle
        do {
            bundle = try await EngineV2SlotFactory.makeProductionBundle(
                modelId: modelId, modelType: declaration.modelType, isVLM: isVLM,
                modelDirectory: modelDirectory, container: servingContainer, tokenizer: tokenizer,
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
            let memoryEnabled = PrefixCachePolicy.isMemoryEnabled(environment: effectiveEnvironment)
            let finalHeadroom = postBuildHeadroom
            let assistantIdentity = benchmarkAssistantIdentity(preparation.artifact)
            return BenchmarkSessionCandidate { ownership in
                EngineV2BenchmarkSession(
                    bundle: bundle, engine: engine,
                    backend: backend, fallback: fallback, memoryEnabled: memoryEnabled,
                    activationReserveBytes: reserve, postLoadMaximumKVBytes: maximumKVBytes,
                    budget: budget, assistantIdentity: assistantIdentity,
                    productionGrant: productionGrant, postBuildHeadroomBytes: finalHeadroom,
                    nativeMiMoOwnership: ownership)
            }
        } catch {
            // A native failure is retired by its strong transaction after the
            // encompassing setup task unwinds. Void shutdown is not proof.
            if nativeMiMoLoad == nil {
                await bundle.bridge.shutdown()
                bundle.releaseAssistant()
            }
            throw error
        }
    }
}
