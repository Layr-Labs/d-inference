import Foundation
import MLX
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
        keyLoader: SSDCacheKeyMaterial.PersistentLoader? = nil
    ) async -> CompletePrefixCachePreparation? {
        let historicalCapability = model as? any CBv2HistoricalAttentionCheckpointProviding
        let historicalTarget = historicalCapability?.cbv2SupportsHistoricalAttentionCheckpoint == true
        guard let preparedBackend,
            preparedBackend.modelCapabilities.supportsRecurrentCheckpointReuse || historicalTarget
        else { return nil }
        guard PrefixCachePolicy.isEnabled(modelId: modelId, environment: environment) else {
            return .init(cache: nil, status: .configDisabled)
        }
        guard let storage = completeCheckpointStorage(
            kind: preparedBackend.kind, layerKinds: preparedBackend.layerKinds,
            supportsRecurrent: preparedBackend.modelCapabilities.supportsRecurrentCheckpointReuse,
            supportsHistoricalAttention: historicalTarget,
            modelDTypes: (model as? any CBv2CompleteCheckpointKVTypeProviding)?.cbv2CompleteCheckpointKVDTypes,
            nativeDTypes: preparedBackend.nativeLayerDTypes, pagedConfig: preparedBackend.pagedPoolConfig,
            assistant: CompleteCheckpointAssistant(drafter: mtpDrafter),
            checkpointQuantization: checkpointQuantization)
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
            persistentTestNamespace: persistentTestNamespace,
            persistentLoader: keyLoader)
        return .init(cache: cache, status: cache == nil
            ? .init(state: .error, reason: .cacheInitFailed) : .scanPending,
            checkpointQuantization: cache == nil ? nil : storage.checkpointQuantization)
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
        assistant: CompleteCheckpointAssistant,
        checkpointQuantization: PagedKVQuantizationConfig? = nil
    ) -> CompleteCheckpointStorageIdentity? {
        let layerDTypes: [DType]
        let target: CompleteCheckpointStorageIdentity.Target
        if supportsRecurrent {
            guard !layerKinds.isEmpty, layerKinds.allSatisfy({ layer in
                if case .full = layer.attention { return layer.sharesKVWithLayer == nil }
                return false
            }), let modelDTypes, modelDTypes.count == layerKinds.count,
                nativeDTypes == nil || nativeDTypes == modelDTypes,
                assistant == .none || assistant == .persistentCodec
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
        let effectiveQuantization = CBv2CompleteCheckpointStorageQuantization.resolve(
            checkpointQuantization, layerKinds: layerKinds, layerDTypes: layerDTypes,
            pagedConfig: pagedConfig, hasAssistantState: assistant == .persistentCodec)
        return .init(kind: kind, layerDTypes: layerDTypes, pagedConfig: pagedConfig,
                     target: target, checkpointQuantization: effectiveQuantization)
    }

}
