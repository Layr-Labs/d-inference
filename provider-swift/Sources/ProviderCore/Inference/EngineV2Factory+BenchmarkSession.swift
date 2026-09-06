import Foundation
import MLX
import MLXLMCommon

/// Offline measurement access to a real production slot. Raw events preserve
/// token IDs; HTTP framing and bridge admission timing are intentionally absent.
@_spi(Benchmarking)
public actor EngineV2BenchmarkSession {
    public struct Submission: Sendable {
        public let receiptID: CBv2RequestID
        public let events: AsyncStream<CBv2Event>
        public let stageMilliseconds: Double
        public let stageDisposition: String
    }

    public struct CacheSnapshot: Sendable {
        public let durableMode: String?
        public let keyMode: String?
        public let status: PrefixCacheModelStatus
        public let memoryEnabled: Bool
        public let recurrentBankBudgetBytes: Int
        public let engineKVCapacityBytes: Int
        public let physicalMemoryBytes: UInt64
        public let activationReserveBytes: UInt64
        public let postLoadMaximumKVBytes: UInt64
        public let checkpoints: SSDHybridCheckpointStats?
        public let attention: SSDPrefixCacheStats?
        public let processMemory: ProcessMemoryTelemetry?
        public let assistantIdentity: [String: String]
        public let productionGrant: EngineV2BenchmarkProductionGrant?
        public let postBuildHeadroomBytes: UInt64?
    }

    public enum Failure: Error {
        case invalidVerifiedWeightHash, invalidCapacity, mtpUnavailable
        case unexpectedEngine, unexpectedResidentCache, persistentKeyUnavailable
        case ssdUnavailable(status: PrefixCacheModelStatus, hasEvidenceSource: Bool)
        case unservablePostLoad(headroomBytes: UInt64, requiredBytes: UInt64)
        case closed, requestAlreadyActive, receiptIDsExhausted
    }

    /// Metric/cancellation access, plus explicit teacher forcing on an idle,
    /// cache-disabled diagnostic session. Submit ordinary requests through this
    /// session so checkpoint receipt and staging lifetimes remain paired.
    public nonisolated let rawEngine: EngineV2
    public nonisolated let backend: String
    public nonisolated let backendFallback: String?
    private let bundle: ProviderEngineBundle
    private let budget: GlobalKVCacheBudget
    private let assistantIdentity: [String: String]
    private var memorySampler = ProcessMemoryTelemetrySampler()
    private let memoryEnabled: Bool
    private let activationReserveBytes: UInt64
    private let postLoadMaximumKVBytes: UInt64
    private let productionGrant: EngineV2BenchmarkProductionGrant?
    private let postBuildHeadroomBytes: UInt64?
    private var nextReceipt: UInt64 = 1
    private var active: [CBv2RequestID: CBv2RequestID] = [:]
    private var closed = false

    fileprivate init(
        bundle: ProviderEngineBundle, engine: EngineV2,
        backend: String, fallback: String?, memoryEnabled: Bool,
        activationReserveBytes: UInt64, postLoadMaximumKVBytes: UInt64,
        budget: GlobalKVCacheBudget, assistantIdentity: [String: String],
        productionGrant: EngineV2BenchmarkProductionGrant?, postBuildHeadroomBytes: UInt64?
    ) {
        self.bundle = bundle
        self.budget = budget
        self.assistantIdentity = assistantIdentity
        self.productionGrant = productionGrant
        self.postBuildHeadroomBytes = postBuildHeadroomBytes
        self.rawEngine = engine
        self.backend = backend
        self.backendFallback = fallback
        self.memoryEnabled = memoryEnabled
        self.activationReserveBytes = activationReserveBytes
        self.postLoadMaximumKVBytes = postLoadMaximumKVBytes
    }

    public func cacheSnapshot() -> CacheSnapshot {
        CacheSnapshot(
            durableMode: bundle.bridge.ssdHybridCheckpointStore != nil ? "ssd_complete"
                : bundle.bridge.ssdPrefixCache != nil ? "ssd_attention" : nil,
            keyMode: bundle.bridge.ssdHybridCheckpointStore.map { $0.usesEphemeralKey ? "ephemeral" : "persistent" },
            status: bundle.bridge.prefixCacheModelStatus(),
            memoryEnabled: memoryEnabled,
            recurrentBankBudgetBytes: rawEngine.hybridPrefixCache?.config.maximumBytes ?? 0,
            engineKVCapacityBytes: rawEngine.capacity().kvBytesCapacity,
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            activationReserveBytes: activationReserveBytes,
            postLoadMaximumKVBytes: postLoadMaximumKVBytes,
            checkpoints: bundle.bridge.ssdHybridCheckpointStore?.stats(),
            attention: bundle.bridge.ssdPrefixCache?.stats(),
            processMemory: memorySnapshot(), assistantIdentity: assistantIdentity,
            productionGrant: productionGrant, postBuildHeadroomBytes: postBuildHeadroomBytes)
    }

    /// Read the same coherent shared ledger used by this production slot.
    /// This benchmark-only capture never inspects mutable native pool state.
    public func memorySnapshot() -> ProcessMemoryTelemetry? {
        memorySampler.capture(budget.memoryHeadroomSnapshot())
    }

    /// Start the caller's TTFT clock BEFORE awaiting this method. It returns
    /// the engine's original stream after production SSD staging, without a
    /// relay task. Call complete(receiptID:) after fully draining that stream.
    public func submit(_ input: CBv2Request) async throws -> Submission {
        guard !closed else { throw Failure.closed }
        guard !active.values.contains(input.id) else { throw Failure.requestAlreadyActive }
        guard nextReceipt < UInt64.max else { throw Failure.receiptIDsExhausted }
        // Separate identity domain from deterministic sampling IDs. The maps
        // never treat a reused engine ID as ownership of an older submission.
        let receiptID = CBv2RequestID(nextReceipt)
        nextReceipt += 1
        active[receiptID] = input.id
        var request = input
        request.prefixCacheReceiptID = receiptID
        do {
            var stage: SSDPrefixCacheStageResult?
            if input.prefixCacheEnabled, input.multimodal == nil, input.positionState == nil {
                if let store = bundle.bridge.ssdHybridCheckpointStore {
                    let importRequest = request
                    stage = await store.stage(
                        requestID: receiptID, request: importRequest,
                        reserveReadScratch: { [rawEngine] in try rawEngine.reserveCompleteCheckpointReadScratch() }
                    ) { [rawEngine] in
                        try rawEngine.planCompleteCheckpointImport(manifest: $0, request: importRequest)
                    }
                } else if let store = bundle.bridge.ssdPrefixCache {
                    let resident = rawEngine.residentPrefixCandidate(for: request)
                    if resident == nil || store.estimatedPrefillTokensSaved(
                        promptTokens: input.promptTokens, cacheScope: input.cacheSalt ?? "")
                        > (resident?.prefillTokensSaved ?? 0) {
                        stage = await store.stage(
                            requestID: receiptID, promptTokens: input.promptTokens,
                            cacheScope: input.cacheSalt ?? "")
                    }
                }
            }
            try Task.checkCancellation()
            guard !closed else { throw Failure.closed }
            let events = try rawEngine.submit(request)
            return Submission(
                receiptID: receiptID, events: events,
                stageMilliseconds: stage?.stageMs ?? 0,
                stageDisposition: stage.map { Self.describe($0.disposition) } ?? "not_attempted")
        } catch {
            active.removeValue(forKey: receiptID)
            await retireStage(receiptID)
            throw error
        }
    }

    /// Caller drains the raw terminal first; this is the idempotent store
    /// backstop used by the production bridge's terminal pump as well.
    public func complete(receiptID: CBv2RequestID) async {
        guard active.removeValue(forKey: receiptID) != nil else { return }
        await retireStage(receiptID)
        // After a serial row, include the final actor-based refund in idle
        // metrics. An active concurrent row must not wait for another's stage.
        if active.isEmpty {
            await bundle.bridge.ssdHybridCheckpointStore?.activity.waitUntilDrained()
        }
    }

    private func retireStage(_ receiptID: CBv2RequestID) async {
        await bundle.bridge.ssdHybridCheckpointStore?.abandonStaging(requestID: receiptID)
        bundle.bridge.ssdHybridCheckpointStore?.discardReadyReceipt(requestID: receiptID)
        await bundle.bridge.ssdPrefixCache?.abandonStaging(requestID: receiptID)
        bundle.bridge.ssdPrefixCache?.discardReadyReceipt(requestID: receiptID)
    }

    public func shutdown() async {
        guard !closed else { return }
        closed = true
        await bundle.bridge.shutdown()
        active.removeAll()
        bundle.releaseAssistant()
    }

    private static func describe(_ disposition: SSDPrefixCacheStageDisposition) -> String {
        switch disposition {
        case .staged: "staged"
        case .missAbsent: "miss_absent"
        case .missCorrupt: "miss_corrupt"
        case .skippedCapacity: "skipped_capacity"
        case .skippedCost: "skipped_cost"
        case .skippedPolicy: "skipped_policy"
        }
    }
}

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
        let maximumKVBytes = UnifiedMemoryCap.kvBudgetBytes(
            residentWeightBytes: UInt64(Memory.activeMemory), activationReserveBytes: reserve,
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
        guard let engine = await bundle.bridge.ownedEngine as? EngineV2 else {
            await bundle.bridge.shutdown()
            bundle.releaseAssistant()
            throw EngineV2BenchmarkSession.Failure.unexpectedEngine
        }
        guard !mtpEnabled || (bundle.mtpStatus.active && engine.mtpMetricsSnapshot() != nil) else {
            await bundle.bridge.shutdown()
            bundle.releaseAssistant()
            throw EngineV2BenchmarkSession.Failure.mtpUnavailable
        }
        do {
            try gemmaMTPVerification?.validateObservedMetrics(engine.mtpMetricsSnapshot())
        } catch {
            await bundle.bridge.shutdown()
            bundle.releaseAssistant()
            throw error
        }
        guard !PrefixCachePolicy.isMemoryEnabled(environment: effectiveEnvironment),
            engine.hybridPrefixCache == nil else {
            await bundle.bridge.shutdown()
            bundle.releaseAssistant()
            throw EngineV2BenchmarkSession.Failure.unexpectedResidentCache
        }
        if PrefixCachePolicy.isEnabled(environment: effectiveEnvironment) {
            let cacheStatus = bundle.bridge.prefixCacheModelStatus()
            let hasEvidenceSource = bundle.bridge.durablePrefixCacheEvidenceSource != nil
            guard hasEvidenceSource, cacheStatus.state == .ready else {
                await bundle.bridge.shutdown()
                bundle.releaseAssistant()
                throw EngineV2BenchmarkSession.Failure.ssdUnavailable(
                    status: cacheStatus, hasEvidenceSource: hasEvidenceSource)
            }
        }
        if requirePersistentKey, bundle.bridge.ssdHybridCheckpointStore?.usesEphemeralKey == true {
            await bundle.bridge.shutdown()
            bundle.releaseAssistant()
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
                await bundle.bridge.shutdown()
                bundle.releaseAssistant()
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
    }
}
