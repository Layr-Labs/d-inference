import Foundation
import MLX
import MLXLLM
import MLXLMCommon

extension EngineV2SlotFactory {
    struct CompletePrefixCachePreparation {
        let cache: SSDHybridCheckpointStore?
        let status: PrefixCacheConstructionStatus
        var checkpointQuantization: PagedKVQuantizationConfig? = nil
    }

    /// Loaded native capability selects either recurrent full state or complete
    /// historical attention state. Both use the complete encrypted SSD format;
    /// ordinary attention block/replay eligibility remains separate.
    static func prepareCompletePrefixCache(
        modelId: String, model: any LanguageModel,
        preparedBackend: EngineV2Factory.ProductionBackendPreparation?,
        checkpointQuantization: PagedKVQuantizationConfig? = nil,
        weightHash: String?, promptContractID: String?,
        mtpDrafter: (any CBv2MTPDrafter)?, mtpConfig: CBv2MTPConfig,
        kvBudget: GlobalKVCacheBudget?, environment: [String: String],
        persistentTestNamespace: SSDPersistentTestKeyNamespace? = nil,
        identityOverride: CBv2CompleteCheckpointIdentity? = nil,
        allowsMemoryOnlyTier: Bool = true
    ) async -> CompletePrefixCachePreparation? {
        let historicalCapability = model as? any CBv2HistoricalAttentionCheckpointProviding
        let historicalTarget = historicalCapability?.cbv2SupportsHistoricalAttentionCheckpoint == true
        guard let preparedBackend,
            preparedBackend.modelCapabilities.supportsRecurrentCheckpointReuse || historicalTarget
        else { return nil }
        guard PrefixCachePolicy.isEnabled(modelId: modelId, environment: environment) else {
            return .init(cache: nil, status: .configDisabled)
        }
        let storage: CompleteCheckpointStorageIdentity?
        let effectiveMTPConfig: CBv2MTPConfig
        if let glm = model as? GLM5NextProtectedModel {
            guard preparedBackend.glm5NextModel === glm,
                let resolved = try? glm.resolvedMTPConfiguration(mtpConfig, drafter: mtpDrafter) else {
                return .init(cache: nil, status: .init(state: .disabled, reason: .unsupportedLayout))
            }
            effectiveMTPConfig = resolved
            // A GLM checkpoint includes KDA state and raw latent/index payloads,
            // not generic full-attention K/V. A profile codes only its older
            // latent rows; everything else stays exact.
            storage = CompleteCheckpointStorageIdentity(kind: preparedBackend.kind,
                layerDTypes: preparedBackend.nativeLayerDTypes,
                pagedConfig: preparedBackend.pagedPoolConfig,
                target: .glm5Next(preparedBackend.layerKinds),
                checkpointQuantization: CBv2CompleteCheckpointStorageQuantization.resolveGLM5Next(
                    checkpointQuantization, layerKinds: preparedBackend.layerKinds,
                    pagedConfig: preparedBackend.pagedPoolConfig, assistant: mtpDrafter))
        } else {
            effectiveMTPConfig = mtpConfig
            storage = completeCheckpointStorage(
                kind: preparedBackend.kind, layerKinds: preparedBackend.layerKinds,
                supportsRecurrent: preparedBackend.modelCapabilities.supportsRecurrentCheckpointReuse,
                supportsHistoricalAttention: historicalTarget,
                isInkling2: EngineV2Factory.isInkling2(model),
                modelDTypes: (model as? any CBv2CompleteCheckpointKVTypeProviding)?.cbv2CompleteCheckpointKVDTypes,
                nativeDTypes: preparedBackend.nativeLayerDTypes, pagedConfig: preparedBackend.pagedPoolConfig,
                assistant: CompleteCheckpointAssistant(drafter: mtpDrafter),
                assistantKeepsHistory: CompleteCheckpointAssistant.keepsHistory(mtpConfig),
                checkpointQuantization: checkpointQuantization)
        }
        guard let storage else {
            return .init(cache: nil, status: .init(state: .disabled, reason: .unsupportedLayout))
        }
        guard PrefixCachePolicy.checkpointIdentityHash(weightHash) != nil else {
            return .init(cache: nil, status: .init(state: .disabled, reason: .weightHashUnavailable))
        }
        let identity = identityOverride ?? PrefixCachePolicy.completeCheckpointIdentity(
            modelAggregateHash: weightHash, promptContractID: promptContractID,
            binaryHash: PrefixCachePolicy.checkpointBinaryHash,
            loadedMetallibHash: metallibHash(),
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            mtpConfig: effectiveMTPConfig,
            assistantCodecID: (mtpDrafter as? any CBv2MTPPrefixCheckpointCoding)?.prefixCheckpointCodecID,
            environment: environment, processEnvironment: ProcessInfo.processInfo.environment,
            storage: storage)
        guard let identity,
            identity.modelAggregateHash == weightHash,
            identity.promptContractID == promptContractID
        else {
            return .init(cache: nil, status: .init(state: .disabled, reason: .runtimeIdentityUnavailable))
        }
        let attachesMemoryOnlyTier = MemoryOnlyPrefixCachePolicy.attachesTier(
            excludedModel: !allowsMemoryOnlyTier || model is GLM5NextProtectedModel, environment: environment)
        switch await SSDHybridCheckpointStoreFactory.build(
            modelId: modelId, identity: identity, backendLayout: storage.backendLayout,
            kvBudget: kvBudget, environment: environment,
            persistentTestNamespace: persistentTestNamespace, attachesMemoryOnlyTier: attachesMemoryOnlyTier) {
        case .success(let cache):
            return .init(cache: cache, status: .scanPending,
                checkpointQuantization: storage.checkpointQuantization)
        case .failure(let failure):
            return .init(cache: nil, status: .init(refusal: failure.reason))
        }
    }

    enum CompleteCheckpointAssistant: Equatable {
        /// `persistentExactHistory`: a persistent codec whose history stays
        /// exact beside lossy older target rows
        /// (`CBv2MTPExactHistoryPrefixCheckpointCoding`).
        /// `persistentHistorical`: a persistent codec that exports its own
        /// complete prefix history beside a historical (windowed) recurrent
        /// target, the SDK's `CBv2HistoricalMTPPrefixCheckpointCoding`. That
        /// protocol is package-scoped, so the provider names its one
        /// conformer, Inkling 2's DSpark drafter.
        case none, stateless, persistentCodec, persistentExactHistory, persistentHistorical,
            unsupportedPersistent

        init(drafter: (any CBv2MTPDrafter)?) {
            if drafter == nil { self = .none }
            else if drafter is any CBv2MTPExactHistoryPrefixCheckpointCoding {
                self = .persistentExactHistory
            } else if drafter is Inkling2DSparkDrafter { self = .persistentHistorical }
            else if drafter is any CBv2MTPPrefixCheckpointCoding { self = .persistentCodec }
            else if drafter is any CBv2MTPRequestStatefulDrafter { self = .unsupportedPersistent }
            else { self = .stateless }
        }

        /// Whether its state keeps the target's checkpoint rows native. An
        /// exact-history codec permits lossy rows only beside a paged
        /// recurrent target, the SDK's rule
        /// (`CBv2CompleteCheckpointStorageQuantization.permitsLossyTarget`).
        func keepsNativeStorage(pagedRecurrent: Bool) -> Bool {
            switch self {
            case .none, .stateless: false
            case .persistentExactHistory: !pagedRecurrent
            case .persistentCodec, .persistentHistorical, .unsupportedPersistent: true
            }
        }

        /// Whether the engine's round driver keeps a persistent assistant's
        /// history, so its checkpoints carry that history (the SDK's
        /// `tracksPersistentHistory` with MTP effectively on). A configured
        /// but inactive drafter writes target-only checkpoints.
        static func keepsHistory(_ config: CBv2MTPConfig) -> Bool {
            config.effectiveEnabled && config.maxDraftTokens > 0 && config.fixedDraftTokens != 0
        }
    }

    /// Pure loaded-capability gate, shared with construction tests. The caller
    /// forwards the effective serving model and actual prepared storage facts.
    /// It never changes the supplied assistant configuration or verification.
    /// `isInkling2`: the serving model is Inkling 2 (`EngineV2Factory.isInkling2`),
    /// the one model reviewed on the historical recurrent codec.
    static func completeCheckpointStorage(
        kind: EngineV2KVBackendKind, layerKinds: [CBv2LayerKind],
        supportsRecurrent: Bool, supportsHistoricalAttention: Bool,
        isInkling2: Bool = false,
        modelDTypes: [DType]?, nativeDTypes: [DType]?, pagedConfig: PagedKVPoolConfig?,
        assistant: CompleteCheckpointAssistant,
        assistantKeepsHistory: Bool = true,
        checkpointQuantization: PagedKVQuantizationConfig? = nil
    ) -> CompleteCheckpointStorageIdentity? {
        let layerDTypes: [DType]
        let target: CompleteCheckpointStorageIdentity.Target
        if isInkling2, supportsRecurrent, kind == .paged, layerKinds.contains(where: { layer in
            if case .slidingWindow = layer.attention { return true }
            return false
        }) {
            // Inkling 2's sliding windows beside recurrent state: the SDK's
            // historical recurrent codec, with an assistant only when it
            // exports its own history (its DSpark drafter). Another model of
            // this shape was not reviewed on it: it takes the branch below,
            // which refuses a sliding window beside recurrent state. It stores
            // exact native rows only, so a requested checkpoint profile (the
            // fleet default is lossy) keeps native storage here, as an
            // unsupported encoding does elsewhere; the identity records `native`.
            guard let nativeDTypes,
                nativeDTypes.count == layerKinds.count,
                modelDTypes == nil || modelDTypes == nativeDTypes,
                [.none, .persistentHistorical].contains(assistant)
            else { return nil }
            return .init(kind: kind, layerDTypes: nativeDTypes, pagedConfig: pagedConfig,
                         target: .historicalRecurrent(layerKinds),
                         assistantHistory: assistant == .persistentHistorical && assistantKeepsHistory)
        }
        if supportsRecurrent {
            guard !layerKinds.isEmpty, layerKinds.allSatisfy({ layer in
                if case .full = layer.attention { return layer.sharesKVWithLayer == nil }
                return false
            }), let modelDTypes, modelDTypes.count == layerKinds.count,
                nativeDTypes == nil || nativeDTypes == modelDTypes,
                [.none, .persistentCodec, .persistentExactHistory].contains(assistant)
            else { return nil }
            layerDTypes = nativeDTypes ?? modelDTypes
            target = .recurrentFull
        } else {
            guard supportsHistoricalAttention, let nativeDTypes,
                  assistant == .none || assistant == .stateless else { return nil }
            if kind == .contiguous {
                guard modelDTypes == nil || modelDTypes == nativeDTypes,
                      nativeDTypes.count == layerKinds.count else { return nil }
            }
            // A stateless drafter rebuilds from target rows; its live policy is
            // independent of whether those rows were compressed on disk.
            layerDTypes = nativeDTypes
            target = .historicalAttention(layerKinds)
        }
        let pagedRecurrent = supportsRecurrent && kind == .paged
        let effectiveQuantization = CBv2CompleteCheckpointStorageQuantization.resolve(
            checkpointQuantization, layerKinds: layerKinds, layerDTypes: layerDTypes,
            pagedConfig: pagedConfig,
            hasAssistantState: assistant.keepsNativeStorage(pagedRecurrent: pagedRecurrent))
        return .init(kind: kind, layerDTypes: layerDTypes, pagedConfig: pagedConfig,
                     target: target, checkpointQuantization: effectiveQuantization,
                     assistantHistory: pagedRecurrent && assistant == .persistentExactHistory)
    }

}
