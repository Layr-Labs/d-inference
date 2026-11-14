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
        identityOverride: CBv2CompleteCheckpointIdentity? = nil
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
                modelDTypes: (model as? any CBv2CompleteCheckpointKVTypeProviding)?.cbv2CompleteCheckpointKVDTypes,
                nativeDTypes: preparedBackend.nativeLayerDTypes, pagedConfig: preparedBackend.pagedPoolConfig,
                assistant: CompleteCheckpointAssistant(drafter: mtpDrafter, acceptance: mtpConfig.acceptance),
                checkpointQuantization: checkpointQuantization)
        }
        guard let storage else {
            return .init(cache: nil, status: .init(state: .disabled, reason: .unsupportedLayout))
        }
        guard PrefixCachePolicy.checkpointIdentityHash(weightHash) != nil else {
            return .init(cache: nil, status: .init(state: .disabled, reason: .weightHashUnavailable))
        }
        guard let additionalNumerics = completeCheckpointNumerics(model: model) else {
            return .init(cache: nil, status: .init(state: .disabled, reason: .runtimeIdentityUnavailable))
        }
        let identity = identityOverride ?? PrefixCachePolicy.completeCheckpointIdentity(
            modelAggregateHash: weightHash, promptContractID: promptContractID,
            binaryHash: PrefixCachePolicy.checkpointBinaryHash,
            loadedMetallibHash: metallibHash(),
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            mtpConfig: effectiveMTPConfig,
            assistantCodecID: (mtpDrafter as? any CBv2MTPPrefixCheckpointCoding)?.prefixCheckpointCodecID,
            environment: environment, processEnvironment: ProcessInfo.processInfo.environment,
            storage: storage, additionalNumerics: additionalNumerics)
        guard let identity,
            identity.modelAggregateHash == weightHash,
            identity.promptContractID == promptContractID
        else {
            return .init(cache: nil, status: .init(state: .disabled, reason: .runtimeIdentityUnavailable))
        }
        switch await SSDHybridCheckpointStoreFactory.build(
            modelId: modelId, identity: identity, backendLayout: storage.backendLayout,
            kvBudget: kvBudget, environment: environment,
            persistentTestNamespace: persistentTestNamespace) {
        case .success(let cache):
            return .init(cache: cache, status: .scanPending,
                checkpointQuantization: storage.checkpointQuantization)
        case .failure(let failure):
            return .init(cache: nil, status: .init(refusal: failure.reason))
        }
    }

    /// Model numerics the generic fingerprint cannot see, under `native.`.
    /// Muse Glimmer's decode bytes change with exact verify windows, so its
    /// profile is part of the identity, and a tower without the serving
    /// profile gets no store (nil) rather than checkpoints that could mix.
    /// Every other model adds nothing.
    static func completeCheckpointNumerics(model: any LanguageModel) -> [String: String]? {
        guard let glimmer = model as? MuseGlimmerTextModel else { return [:] }
        let profile = glimmer.numericsProfile
        guard glimmer.verifiesWindowsExactly, profile == MuseGlimmerServingLoad.exactWindowsProfile else {
            return nil
        }
        return ["museGlimmer.numericsProfile": profile]
    }

    enum CompleteCheckpointAssistant: Equatable {
        /// `persistentExactHistory`: a persistent codec whose history stays
        /// exact beside lossy older target rows
        /// (`CBv2MTPExactHistoryPrefixCheckpointCoding`).
        /// `advisory`: request state that only decides what is proposed
        /// (`CBv2MTPAdvisoryHistoryDrafter`) under exact acceptance. The SDK
        /// keeps generic historical checkpoints for it with no assistant
        /// state (`checkpointsRequireAssistantHistory` is false), exactly as
        /// without a drafter; a restored request starts a new, empty state.
        case none, stateless, advisory, persistentCodec, persistentExactHistory, unsupportedPersistent

        /// `acceptance` is the engine's: typical acceptance makes emitted
        /// tokens depend on the drafter, so its state is never advisory and
        /// the drafter keeps the older classification (no checkpoints for a
        /// request-stateful one).
        init(drafter: (any CBv2MTPDrafter)?, acceptance: CBv2MTPAcceptance = .exact) {
            if drafter == nil { self = .none }
            else if acceptance == .exact,
                (drafter as? any CBv2MTPAdvisoryHistoryDrafter)?.requestStateIsAdvisory == true {
                self = .advisory
            } else if drafter is any CBv2MTPExactHistoryPrefixCheckpointCoding {
                self = .persistentExactHistory
            } else if drafter is any CBv2MTPPrefixCheckpointCoding { self = .persistentCodec }
            else if drafter is any CBv2MTPRequestStatefulDrafter { self = .unsupportedPersistent }
            else { self = .stateless }
        }

        /// Whether its state keeps the target's checkpoint rows native. An
        /// exact-history codec permits lossy rows only beside a paged
        /// recurrent target, the SDK's rule
        /// (`CBv2CompleteCheckpointStorageQuantization.permitsLossyTarget`).
        func keepsNativeStorage(pagedRecurrent: Bool) -> Bool {
            switch self {
            case .none, .stateless, .advisory: false
            case .persistentExactHistory: !pagedRecurrent
            case .persistentCodec, .unsupportedPersistent: true
            }
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
                [.none, .persistentCodec, .persistentExactHistory].contains(assistant)
            else { return nil }
            layerDTypes = nativeDTypes ?? modelDTypes
            target = .recurrentFull
        } else {
            guard supportsHistoricalAttention, let nativeDTypes,
                  [.none, .stateless, .advisory].contains(assistant) else { return nil }
            if kind == .contiguous {
                guard modelDTypes == nil || modelDTypes == nativeDTypes,
                      nativeDTypes.count == layerKinds.count else { return nil }
            }
            // A stateless or advisory drafter rebuilds from target rows; its
            // live policy is independent of whether those rows were compressed
            // on disk, and no emitted token depends on it.
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
