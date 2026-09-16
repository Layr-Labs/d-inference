import Foundation
import MLXLMCommon

extension EngineV2SlotFactory {
    struct AttentionPrefixCachePreparation {
        var cache: SSDPrefixCache? = nil
        var capability: CBv2PrefixReuseCapability? = nil
        let status: PrefixCacheConstructionStatus
    }

    /// Build attention-only SSD storage after the backend and complete-checkpoint
    /// path have been resolved. Disabled policy never allocates a cache or emits
    /// construction-failure telemetry; failed construction preserves its reason.
    static func prepareAttentionPrefixCache(
        modelId: String,
        preparedBackend: EngineV2Factory.ProductionBackendPreparation?,
        scriptedEngine: Bool,
        weightHash: String?, promptContractID: String?,
        kvBudget: GlobalKVCacheBudget?, environment: [String: String],
        persistentTestNamespace: SSDPersistentTestKeyNamespace?,
        makePrefixCache: (([CBv2LayerKind], CBv2PrefixReuseCapability) async -> SSDPrefixCache?)?,
        emitTelemetry: (@Sendable (TelemetryEvent) -> Void)?,
        logInfo: @Sendable (String) -> Void,
        logWarning: @Sendable (String) -> Void
    ) async -> AttentionPrefixCachePreparation {
        guard !scriptedEngine else {
            return .init(status: .init(state: .disabled, reason: .unsupportedBackend))
        }
        if let preparedBackend, !preparedBackend.modelCapabilities.supportsPrefixReuse {
            return .init(status: .init(state: .disabled, reason: .unsupportedLayout))
        }
        guard PrefixCachePolicy.isEnabled(modelId: modelId, environment: environment) else {
            return .init(status: .configDisabled)
        }
        guard let preparedBackend else {
            let capability = PrefixCachePolicy.prefixReuseCapability(
                layerKinds: [], backendSelection: .contiguous)
            emitPrefixCacheConstructionFailure(
                modelId: modelId, kvBackendKind: nil, capability: capability,
                failure: .layoutUnavailable, emitTelemetry: emitTelemetry)
            logInfo(
                "engine_v2: SSD prefix cache skipped for \(modelId) — no "
                    + "derivable CBv2 layer kinds (non-adapted family)")
            return .init(capability: capability,
                         status: .init(state: .disabled, reason: .unsupportedLayout))
        }
        let layerKinds = preparedBackend.layerKinds
        let backendKind = preparedBackend.kind
        guard PrefixCachePolicy.adoptionIsExact(onResolvedBackend: backendKind) else {
            // Gate construction on the resolved backend, including kill-switch
            // degradation: no object means no staging, donation, or stats task.
            logInfo(
                "engine_v2: SSD prefix cache skipped for \(modelId) — "
                    + "prefix adoption is not bit-exact on the contiguous "
                    + "KV backend (v0.8.1); paged slots keep the cache")
            return .init(
                capability: PrefixCachePolicy.adoptionDisabledCapability(layerKinds: layerKinds),
                status: .init(state: .disabled, reason: .unsupportedBackend))
        }
        let capability = PrefixCachePolicy.prefixReuseCapability(
            layerKinds: layerKinds,
            backendSelection: backendKind == .paged ? .paged : .contiguous)
        let failed = PrefixCacheConstructionStatus(state: .error, reason: .cacheInitFailed)
        guard let promptContractID else {
            emitPrefixCacheConstructionFailure(
                modelId: modelId, kvBackendKind: backendKind, capability: capability,
                failure: .promptContractUnavailable, emitTelemetry: emitTelemetry)
            logWarning(
                "engine_v2: SSD prefix cache skipped for \(modelId) — "
                    + "prompt contract could not be computed from local artifacts")
            return .init(capability: capability, status: failed)
        }
        let failureStatus = PrefixCacheConstructionStatusBox()
        let cache: SSDPrefixCache?
        if let makePrefixCache {
            cache = await makePrefixCache(layerKinds, capability)
        } else {
            cache = await SSDPrefixCacheFactory.make(
                modelId: modelId, promptContractID: promptContractID, weightHash: weightHash,
                layerKinds: layerKinds, prefixReuseCapability: capability,
                kvBudget: kvBudget, environment: environment,
                persistentTestNamespace: persistentTestNamespace,
                onConstructionFailure: { failure in
                    failureStatus.record(failure: failure, capability: capability)
                    emitPrefixCacheConstructionFailure(
                        modelId: modelId, kvBackendKind: backendKind, capability: capability,
                        failure: failure, emitTelemetry: emitTelemetry)
                })
        }
        return .init(cache: cache, capability: capability,
                     status: cache == nil ? (failureStatus.snapshot ?? failed) : .scanPending)
    }

    private static func emitPrefixCacheConstructionFailure(
        modelId: String,
        kvBackendKind: EngineV2KVBackendKind?,
        capability: CBv2PrefixReuseCapability,
        failure: SSDPrefixCacheConstructionFailure,
        emitTelemetry: (@Sendable (TelemetryEvent) -> Void)?
    ) {
        // `prefix_reuse_backend` keeps its own key alongside the shared
        // `backend` / `kv_backend` pair: it is the finer prefix-reuse ROW
        // identity, and contiguous_quantized vs contiguous_unquantized is a
        // distinction "contiguous" cannot express. Folding any of the three
        // together silently mis-buckets every `group by backend` dashboard.
        //
        // `kv_backend` is nil-ABLE here and that is the whole reason
        // EngineHealthEvent.make takes an optional. ABSENT ⇒ UNKNOWN, the same
        // contract as BackendSlotCapacity.KVBackend (`*string` + omitempty) on
        // the heartbeat wire: a slot whose backend was never resolved omits
        // the key. Do NOT substitute a third vocabulary value such as
        // "unknown" — omission must stay distinguishable from an observation,
        // and any value here would be read as one.
        emitEngineHealth(
            EngineHealthEvent.make(
                severity: .warn,
                message: "engine_v2: SSD prefix cache construction failed",
                operation: "prefix_cache_construction",
                model: modelId,
                kvBackend: kvBackendKind?.rawValue,
                extra: [
                    "prefix_reuse_backend": .string(capability.backend.rawValue),
                    "prefix_reuse_strategy": .string(
                        capability.strategy?.rawValue ?? "none"),
                    "prefix_construction_failure": .string(failure.rawValue),
                    "prefix_cold_fallback": .bool(true),
                ]),
            sink: emitTelemetry)
    }
}
