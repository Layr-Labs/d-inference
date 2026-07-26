// Copyright © 2026 Eigen Labs.
//
// ContinuousBatchingV2 (engine v2) factory — v0.7.5 ONE-ENGINE, FAIL-LOUD.
//
// As of v0.7.5 the v2 engine serves EVERY chat request. There is no
// selection gate, no allowlist, and no legacy fallback:
//
//   * The old `DARKBLOOM_ENGINE_V2` / `DARKBLOOM_ENGINE_V2_MODELS` env
//     switches and the `engine_v2` provider-config key are RETIRED. The
//     config key is still parsed (a startup WARN fires when an operator
//     set `engine_v2 = false` — see `RetiredKnobWarnings`), but selection
//     is unconditionally v2. Rollback is release-level (re-point latest
//     to the previous release), not a per-box switch.
//   * Which MODELS can serve is architecture-derived at scan/advertise
//     time (`EngineV2SupportedModels`, the mirror of the
//     `makeProductionEngine` switch) — unsupported families are never
//     advertised, so construction here only sees CBv2-adapted models.
//   * Engine construction failure is a REFUSAL, not a fallback:
//     `makeBridge` throws, an ERROR `engine_health` telemetry event
//     (`operation=engine_v2_refusal`, with a machine-classifiable
//     `reason`) fires, and the caller unloads + 503s so the coordinator
//     reroutes. A provider that cannot serve well refuses loudly; it
//     never degrades silently onto a slower path.

import Foundation
import MLXLMCommon

// MARK: - Retired selection surface

/// Retired v0.7.0–v0.7.4 selection knobs, kept ONLY so startup can warn
/// operators who still set them (`RetiredKnobWarnings`, emitted by
/// `Start.run()` for every serving mode); nothing consults them for
/// selection anymore.
public enum EngineV2Config {
    /// RETIRED master flag (was the per-box kill switch). Ignored.
    public static let environmentFlag = "DARKBLOOM_ENGINE_V2"
    /// RETIRED allowlist override. Ignored.
    public static let environmentAllowlist = "DARKBLOOM_ENGINE_V2_MODELS"

    /// Every env var retired by the one-engine release (v0.7.5 §1.12):
    /// the v2 selection knobs plus the legacy engine's tuning/feature
    /// switches (compiled decode, B=1 fast paths, GPT-OSS KV kernel,
    /// adaptive-prefill cap, checkpoint-capture inflight cap) and the
    /// legacy SSD prefix-cache tier's per-persist threshold. All parse to
    /// nothing; the `DARKBLOOM_PREFIX_CACHE*` tier envs and the memory-cap
    /// envs remain live. NOTE: `DARKBLOOM_PREFIX_CACHE_DISK_GB` and
    /// `DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL` are NOT retired — the
    /// v0.7.5 SSD offload tier re-adopted them with the same semantics
    /// (box-wide disk budget; unsigned-build in-memory-KEK escape hatch).
    public static let retiredEnvironmentKeys: [String] = [
        environmentFlag,
        environmentAllowlist,
        "DARKBLOOM_COMPILED_DECODE",
        "DARKBLOOM_GEMMA_B1_FAST_PATH",
        "DARKBLOOM_B1_GREEDY_FAST_PATH",
        "DARKBLOOM_KV_GPTOSS_KERNEL",
        "DARKBLOOM_ADAPTIVE_PREFILL_ALLOW_8192",
        "DARKBLOOM_KV_CAPTURE_MAX_INFLIGHT",
        "DARKBLOOM_PREFIX_CACHE_MIN_PERSIST_TOKENS",
    ]

    /// Names of retired env vars that are SET in the given environment —
    /// startup emits one WARN per entry so operators notice the knob no
    /// longer does anything.
    public static func retiredEnvironmentKeysSet(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        retiredEnvironmentKeys.filter {
            !(environment[$0] ?? "").isEmpty
        }
    }
}

// MARK: - Refusal reasons

/// Machine-classifiable reason for a v2 engine refusal, carried on the
/// `engine_v2_refusal` telemetry event's allowlisted `reason` field.
public enum EngineV2RefusalReason: String, Sendable {
    /// No KV byte headroom under the unified-memory cap
    /// (`EngineV2ProductionError.noKVHeadroom`).
    case noKVHeadroom = "no_kv_headroom"
    /// The loaded module has no CBv2 adapter
    /// (`EngineV2ProductionError.unsupportedModel`) — should be unreachable
    /// behind the scan-time supported-set gate; kept as loud insurance.
    case unsupportedModel = "unsupported_model"
    /// The Gemma 4 VLM text-model extraction failed (config decode, weight
    /// re-key, verify, or the forward-parity gate).
    case vlmExtractionFailed = "vlm_extraction_failed"
    /// A load-time KV re-slice would push some co-resident slot below the
    /// minimum serviceable grant (`EngineV2KVSizing` floor).
    case resliceFloor = "reslice_floor"
    /// An EXPLICITLY requested paged backend could not be served
    /// (`EngineV2ProductionError.pagedUnavailable`): kernel preflight,
    /// physical-capacity planning, or `PagedKVBackend` construction. Kept
    /// SEPARATE from `engineInitFailed` on purpose — with no canary fleet
    /// this is the aggregate signal that a paged rollout is regressing,
    /// and folding it into the catch-all would make it indistinguishable
    /// from an unrelated bad model load. An `.auto` selection never lands
    /// here; it degrades to contiguous and reports INFO
    /// `engine_v2_kv_backend` with a fallback reason instead.
    case pagedBackendUnavailable = "paged_backend_unavailable"
    /// `DARKBLOOM_CBV2_PAGED_KV_DTYPE` carried a value that is neither
    /// `float16` nor `float32`
    /// (`EngineV2ProductionError.invalidPagedPoolDType`). Kept SEPARATE
    /// from `pagedBackendUnavailable`, which is the paged-rollout
    /// regression signal: this is an operator typo in a measurement knob,
    /// and folding the two together would make a mistyped env var look
    /// like paged infrastructure failing.
    case pagedKVDTypeInvalid = "paged_kv_dtype_invalid"
    /// Any other engine-construction failure.
    case engineInitFailed = "engine_init_failed"

    /// Classify a construction error into its refusal reason.
    public static func classify(_ error: Error) -> EngineV2RefusalReason {
        switch error {
        case EngineV2ProductionError.noKVHeadroom:
            return .noKVHeadroom
        case EngineV2ProductionError.unsupportedModel:
            return .unsupportedModel
        case EngineV2ProductionError.pagedUnavailable:
            return .pagedBackendUnavailable
        case EngineV2ProductionError.invalidPagedPoolDType:
            return .pagedKVDTypeInvalid
        case is EngineV2VLMTextExtractionError:
            return .vlmExtractionFailed
        default:
            return .engineInitFailed
        }
    }
}

// MARK: - Factory (fail loud)

public enum EngineV2Factory {
    /// Build an `EngineV2Bridge` for `modelId` over a freshly-constructed
    /// v2 engine. THROWS on any construction failure after emitting the
    /// ERROR `engine_v2_refusal` telemetry event — there is no legacy
    /// engine to fall back to; the caller maps the throw to a 503 so the
    /// coordinator reroutes (and, for coordinator-pushed loads,
    /// `load_model_status: failed`).
    ///
    /// `makeEngine` is a closure (not a concrete type) so unit tests can
    /// script a `CBv2Engine` without weights; the production body lives in
    /// `EngineV2Factory+Production.makeProductionBuild`. The build result
    /// carries the KV-backend decision: the bridge stores the kind (its
    /// shared-gate accounting, heartbeat clamp, and re-slice policy key
    /// off it) and an INFO `engine_v2_kv_backend` event reports it — with
    /// the fallback reason when a paged selection degraded to contiguous —
    /// so the fleet dashboard can attribute every slot's serving backend.
    public static func makeBridge(
        modelId: String,
        tokenizer: TokenizerHandle,
        eosTokenIds: Set<Int>,
        extraEOSTokens: [String] = [],
        defaultMaxTokens: Int = 4096,
        maxConcurrentRequests: Int = 4,
        kvBytesPerToken: Int = 0,
        kvBudget: GlobalKVCacheBudget? = nil,
        ssdPrefixCache: SSDPrefixCache? = nil,
        prefixCacheStatus: PrefixCacheModelStatus? = nil,
        emitTelemetry: (@Sendable (TelemetryEvent) -> Void)? = nil,
        makeEngine: () throws -> EngineV2Factory.ProductionBuild
    ) throws -> EngineV2Bridge {
        do {
            let build = try makeEngine()
            emitKVBackendTelemetry(
                modelId: modelId,
                kind: build.kvBackendKind,
                fallbackReason: build.kvBackendFallbackReason,
                emitTelemetry: emitTelemetry)
            return EngineV2Bridge(
                engine: build.engine,
                modelId: modelId,
                tokenizer: tokenizer,
                eosTokenIds: eosTokenIds,
                extraEOSTokens: extraEOSTokens,
                defaultMaxTokens: defaultMaxTokens,
                maxConcurrentRequests: maxConcurrentRequests,
                kvBytesPerToken: kvBytesPerToken,
                kvBudget: kvBudget,
                // SSD offload tier handle (v0.7.5): the bridge drives the
                // pre-submit staging hook + release backstops + shutdown
                // over the SAME instance the engine holds as its cache.
                ssdPrefixCache: ssdPrefixCache,
                prefixCacheStatus: prefixCacheStatus,
                kvBackendKind: build.kvBackendKind,
                emitTelemetry: emitTelemetry
            )
        } catch {
            // A failed v2 init must not leak the SSD tier's background
            // tasks/registration (the refusal unloads the slot — there is
            // no engine left to drive the tier's shutdown).
            ssdPrefixCache?.close()
            emitRefusalTelemetry(
                modelId: modelId,
                reason: EngineV2RefusalReason.classify(error),
                error: error,
                emitTelemetry: emitTelemetry
            )
            throw error
        }
    }

    /// ERROR `engine_health` event for a v2 refusal (construction failure
    /// or re-slice floor). Replaces the retired WARN `engine_v2_fallback`:
    /// with no legacy engine left, a refusal is an ERROR the fleet
    /// dashboard must alarm on, not a degradation note. Fields are drawn
    /// from the existing telemetry allowlist (`component`, `operation`,
    /// `backend`, `model`, `reason`, `error_class`, `error`) — no new wire
    /// fields.
    static func emitRefusalTelemetry(
        modelId: String,
        reason: EngineV2RefusalReason,
        error: Error?,
        emitTelemetry: (@Sendable (TelemetryEvent) -> Void)?
    ) {
        var event = TelemetryEvent(
            source: .provider,
            severity: .error,
            kind: .engineHealth,
            message: "engine_v2: refused to serve — \(reason.rawValue)"
        )
        var fields: [String: AnyCodableValue] = [
            "component": .string("engine"),
            "operation": .string("engine_v2_refusal"),
            "backend": .string("engine_v2"),
            "model": .string(modelId),
            "reason": .string(reason.rawValue),
        ]
        if let error {
            fields["error_class"] = .string(String(reflecting: type(of: error)))
            // Human-readable detail ("error" is allowlisted on both sides).
            fields["error"] = .string(String(describing: error))
        }
        event.fields = TelemetryFieldFilter.filter(fields)
        if let emitTelemetry {
            emitTelemetry(event)
        } else {
            TelemetryClient.shared.emit(event)
        }
    }

    /// INFO `engine_health` event reporting which KV backend a slot was
    /// built with (`operation=engine_v2_kv_backend`, `kv_backend=paged |
    /// contiguous`, `reason=paged | contiguous | fallback:<why>`). Emitted
    /// once per engine construction, so it is a NOTIFICATION of a load, not
    /// a fleet inventory — the sink drops on full behind a rate limit. The
    /// recurring per-slot inventory is `engine_v2_slot_posture`
    /// (`EngineV2Bridge+MTP`) plus `BackendSlotCapacity.kv_backend` on every
    /// heartbeat. Allowlisted fields only — no wire changes.
    static func emitKVBackendTelemetry(
        modelId: String,
        kind: EngineV2KVBackendKind,
        fallbackReason: String?,
        emitTelemetry: (@Sendable (TelemetryEvent) -> Void)?
    ) {
        let reason =
            fallbackReason.map { "fallback:\($0)" } ?? kind.rawValue
        var event = TelemetryEvent(
            source: .provider,
            severity: .info,
            kind: .engineHealth,
            message: "engine_v2: serving with \(kind.rawValue) KV backend"
                + (fallbackReason.map { " (fallback: \($0))" } ?? "")
        )
        event.fields = TelemetryFieldFilter.filter([
            "component": .string("engine"),
            "operation": .string("engine_v2_kv_backend"),
            // `backend` is the engine; `kv_backend` is the KV storage kind.
            // The kind was already here, but only inside the free-form
            // `reason` string, where "fallback:kill_switch" hides it from
            // any `group by`. It gets its own key so this event joins the
            // heartbeat and the posture sample on the same value.
            "backend": .string("engine_v2"),
            "kv_backend": .string(kind.rawValue),
            "model": .string(modelId),
            "reason": .string(reason),
        ])
        if let emitTelemetry {
            emitTelemetry(event)
        } else {
            TelemetryClient.shared.emit(event)
        }
    }
}
