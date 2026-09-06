import Foundation
import MLX
import MLXLMCommon

extension EngineV2SlotFactory {
    struct CompletePrefixCachePreparation {
        let cache: SSDHybridCheckpointStore?
        let status: PrefixCacheConstructionStatus
    }

    /// Loaded native capability selects either recurrent full state or exact
    /// historical attention state. Both use the complete encrypted SSD format;
    /// ordinary attention block/replay eligibility remains separate.
    static func prepareCompletePrefixCache(
        modelId: String, model: any LanguageModel,
        preparedBackend: EngineV2Factory.ProductionBackendPreparation?,
        weightHash: String?, promptContractID: String?,
        mtpDrafter: (any CBv2MTPDrafter)?, mtpConfig: CBv2MTPConfig,
        kvBudget: GlobalKVCacheBudget?, environment: [String: String],
        persistentTestNamespace: SSDPersistentTestKeyNamespace? = nil,
        identityOverride: CBv2CompleteCheckpointIdentity? = nil
    ) async -> CompletePrefixCachePreparation? {
        let historicalCapability = model as? any CBv2HistoricalAttentionCheckpointProviding
        let historicalTarget = historicalCapability?.cbv2SupportsHistoricalAttentionCheckpoint == true
        guard let preparedBackend,
            preparedBackend.modelCapabilities.supportsRecurrentCheckpointReuse || historicalTarget
        else { return nil }
        guard PrefixCachePolicy.isEnabled(environment: environment) else {
            return .init(cache: nil, status: .configDisabled)
        }
        guard let storage = completeCheckpointStorage(
            kind: preparedBackend.kind, layerKinds: preparedBackend.layerKinds,
            supportsRecurrent: preparedBackend.modelCapabilities.supportsRecurrentCheckpointReuse,
            supportsHistoricalAttention: historicalTarget,
            modelDTypes: (model as? any CBv2CompleteCheckpointKVTypeProviding)?.cbv2CompleteCheckpointKVDTypes,
            nativeDTypes: preparedBackend.pagedLayerDTypes, pagedConfig: preparedBackend.pagedPoolConfig,
            assistant: CompleteCheckpointAssistant(drafter: mtpDrafter))
        else {
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
            mtpConfig: mtpConfig,
            assistantCodecID: (mtpDrafter as? any CBv2MTPPrefixCheckpointCoding)?.prefixCheckpointCodecID,
            environment: environment, processEnvironment: ProcessInfo.processInfo.environment,
            storage: storage)
        guard let identity,
            identity.modelAggregateHash == weightHash,
            identity.promptContractID == promptContractID
        else {
            return .init(cache: nil, status: .init(state: .disabled, reason: .runtimeIdentityUnavailable))
        }
        let cache = await SSDHybridCheckpointStoreFactory.make(
            modelId: modelId, identity: identity, backendLayout: storage.backendLayout,
            kvBudget: kvBudget, environment: environment,
            persistentTestNamespace: persistentTestNamespace)
        return .init(cache: cache, status: cache == nil
            ? .init(state: .error, reason: .cacheInitFailed) : .scanPending)
    }

    enum CompleteCheckpointAssistant: Equatable {
        case none, stateless, persistentCodec, unsupportedPersistent

        init(drafter: (any CBv2MTPDrafter)?) {
            if drafter == nil { self = .none }
            else if drafter is any CBv2MTPPrefixCheckpointCoding { self = .persistentCodec }
            else if drafter is any CBv2MTPRequestStatefulDrafter { self = .unsupportedPersistent }
            else { self = .stateless }
        }
    }

    /// Pure loaded-capability gate, shared with construction tests. The caller
    /// forwards the effective serving model and actual prepared storage facts.
    /// It never changes the supplied assistant configuration or verification.
    static func completeCheckpointStorage(
        kind: EngineV2KVBackendKind, layerKinds: [CBv2LayerKind],
        supportsRecurrent: Bool, supportsHistoricalAttention: Bool,
        modelDTypes: [DType]?, nativeDTypes: [DType]?, pagedConfig: PagedKVPoolConfig?,
        assistant: CompleteCheckpointAssistant
    ) -> CompleteCheckpointStorageIdentity? {
        if supportsRecurrent {
            guard !layerKinds.isEmpty, layerKinds.allSatisfy({ layer in
                if case .full = layer.attention { return layer.sharesKVWithLayer == nil }
                return false
            }), let modelDTypes, modelDTypes.count == layerKinds.count,
                nativeDTypes == nil || nativeDTypes == modelDTypes,
                assistant == .none || assistant == .persistentCodec
            else { return nil }
            return .init(kind: kind, layerDTypes: nativeDTypes ?? modelDTypes, pagedConfig: pagedConfig)
        }
        guard supportsHistoricalAttention, kind == .paged, let nativeDTypes,
              assistant == .none || assistant == .stateless else { return nil }
        // Gemma's stateless per-round drafter remains configured normally. It
        // rebuilds from restored target rows; no persistent assistant payload
        // or model-declared attention dtype is fabricated here.
        return .init(kind: kind, layerDTypes: nativeDTypes, pagedConfig: pagedConfig,
                     target: .historicalAttention(layerKinds))
    }

}
