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
//     set `engine_v2 = false` — see `ProviderLoop.run()`), but selection
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
/// operators who still set them (`ProviderLoop.run()`); nothing consults
/// them for selection anymore.
public enum EngineV2Config {
    /// RETIRED master flag (was the per-box kill switch). Ignored.
    public static let environmentFlag = "DARKBLOOM_ENGINE_V2"
    /// RETIRED allowlist override. Ignored.
    public static let environmentAllowlist = "DARKBLOOM_ENGINE_V2_MODELS"

    /// Names of retired engine-selection env vars that are SET in the given
    /// environment — startup emits one WARN per entry so operators notice
    /// the knob no longer does anything.
    public static func retiredEnvironmentKeysSet(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        [environmentFlag, environmentAllowlist].filter {
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
    /// Any other engine-construction failure.
    case engineInitFailed = "engine_init_failed"

    /// Classify a construction error into its refusal reason.
    public static func classify(_ error: Error) -> EngineV2RefusalReason {
        switch error {
        case EngineV2ProductionError.noKVHeadroom:
            return .noKVHeadroom
        case EngineV2ProductionError.unsupportedModel:
            return .unsupportedModel
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
    /// `EngineV2Factory+Production.makeProductionEngine`.
    public static func makeBridge(
        modelId: String,
        tokenizer: TokenizerHandle,
        eosTokenIds: Set<Int>,
        extraEOSTokens: [String] = [],
        defaultMaxTokens: Int = 4096,
        maxConcurrentRequests: Int = 4,
        kvBytesPerToken: Int = 0,
        kvBudget: GlobalKVCacheBudget? = nil,
        prefixCacheBudgetBytes: Int = 0,
        emitTelemetry: (@Sendable (TelemetryEvent) -> Void)? = nil,
        makeEngine: () throws -> any CBv2Engine
    ) throws -> EngineV2Bridge {
        do {
            let engine = try makeEngine()
            return EngineV2Bridge(
                engine: engine,
                modelId: modelId,
                tokenizer: tokenizer,
                eosTokenIds: eosTokenIds,
                extraEOSTokens: extraEOSTokens,
                defaultMaxTokens: defaultMaxTokens,
                maxConcurrentRequests: maxConcurrentRequests,
                kvBytesPerToken: kvBytesPerToken,
                kvBudget: kvBudget,
                // Fleet-sizing bookkeeping only (the cache itself was carved
                // out of the engine's kvBytesCapacity by the caller): the
                // bridge exposes it via `slotKVBytesClaim()` so later loads
                // subtract the cache's bytes too (T-041 budget accounting).
                prefixCacheBudgetBytes: prefixCacheBudgetBytes,
                emitTelemetry: emitTelemetry
            )
        } catch {
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

    /// WARN `engine_health` event when a model configured for `kv_quant` is
    /// served through engine_v2, which does NOT support KV-quant and uses
    /// fp16 caches (`makeProductionEngine` builds `CBv2LayerCache`, never a
    /// quantized cache). Surfacing this keeps the operator from assuming
    /// the memory savings apply. Allowlisted fields only.
    static func emitKVQuantUnsupportedTelemetry(
        modelId: String,
        emitTelemetry: (@Sendable (TelemetryEvent) -> Void)?
    ) {
        var event = TelemetryEvent(
            source: .provider,
            severity: .warn,
            kind: .engineHealth,
            message: "engine_v2: kv_quant not supported — using fp16 caches"
        )
        event.fields = TelemetryFieldFilter.filter([
            "component": .string("engine"),
            "operation": .string("engine_v2_kv_quant_unsupported"),
            "backend": .string("engine_v2"),
            "model": .string(modelId),
        ])
        if let emitTelemetry {
            emitTelemetry(event)
        } else {
            TelemetryClient.shared.emit(event)
        }
    }
}
