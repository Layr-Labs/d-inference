// Copyright © 2026 Eigen Labs.
//
// ContinuousBatchingV2 (engine v2) selection + safe-fallback factory.
//
// The v2 engine (`MLXLMCommon.CBv2Engine`, see
// libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/CBv2Contracts.swift)
// ships DEFAULT-ON for the allowlisted models as of v0.7.0:
//
//   * Allowlisted model (default) → `EngineV2Factory.makeBridgeIfSelected`
//                                   builds an `EngineV2Bridge` over the v2
//                                   engine.
//   * Any other model             → legacy `BatchedEngine` path,
//                                   byte-identical to today.
//   * Kill switch / config off    → legacy path for everything.
//   * v2 engine init throws       → legacy path + a WARN `engine_health`
//                                   telemetry event (`engine_v2_fallback`,
//                                   carrying the model id + error) so a
//                                   silent fleet-wide fallback is
//                                   impossible. This fallback is
//                                   load-bearing for the fleet now that v2
//                                   is the default.
//
// Selection sources, in precedence order:
//   1. env `DARKBLOOM_ENGINE_V2` — explicit "0"/"false"/"no"/"off" is the
//      ABSOLUTE per-box kill switch (beats config, no release needed);
//      explicit "1"/"true"/"yes"/"on" force-enables.
//   2. provider config key `engine_v2` under `[backend]` in provider.toml
//      — **default true** (v0.7.0). Rollback = env kill switch or release
//      rollback.
//
// Per-model allowlist: default is the set of coordinator-catalog model ids
// the production fleet actually advertises (these are the registry/heartbeat
// ids, NOT HuggingFace repo ids) — all three were parity/soak-validated on
// real weights. Operators can widen it via env `DARKBLOOM_ENGINE_V2_MODELS`
// (comma-separated patterns, e.g. to stage another checkpoint quantization).

import Foundation
import MLXLMCommon

// MARK: - Selection

public enum EngineV2Config {
    /// Master flag. "0"/"false"/"no"/"off" is the absolute per-box KILL
    /// SWITCH (beats the config key); "1"/"true"/"yes"/"on" force-enables;
    /// absent/other defers to the `engine_v2` provider-config value
    /// (default true as of v0.7.0).
    public static let environmentFlag = "DARKBLOOM_ENGINE_V2"
    /// Optional comma-separated allowlist pattern override
    /// (exact ids or trailing-`*` prefix globs). Empty/absent keeps the
    /// default. Use to widen the default-on scope for staged rollout
    /// (e.g. another checkpoint quantization).
    public static let environmentAllowlist = "DARKBLOOM_ENGINE_V2_MODELS"

    /// The models the v2 engine serves by default: the coordinator-catalog
    /// model ids the production fleet actually advertises (these are the
    /// registry/heartbeat ids, NOT HuggingFace repo ids). All three were
    /// parity/soak-validated on real weights — `gpt-oss-20b` and
    /// `gemma-4-26b-8bit` are the two 8-bit / GPT-OSS production models, and
    /// `gemma-4-26b-qat-4bit` passed strict batch-invariance and benchmarked
    /// faster. Matched case-insensitively against the model id and its last
    /// path component (some ids may be `org/name` shaped). Every other model
    /// — including other gemma-4 / gpt-oss quantizations — keeps the legacy
    /// engine until an operator widens the list via
    /// `DARKBLOOM_ENGINE_V2_MODELS`.
    public static let defaultModelAllowlist = [
        "gpt-oss-20b",
        "gemma-4-26b-8bit",
        "gemma-4-26b-qat-4bit",
    ]

    public enum Selection: String, Sendable, Equatable {
        case legacy
        case v2
    }

    /// Resolve the master flag from env + provider config (`engine_v2`).
    public static func flagEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        configEnabled: Bool
    ) -> Bool {
        if let env = environment[environmentFlag]?
            .trimmingCharacters(in: .whitespaces).lowercased(), !env.isEmpty
        {
            if ["1", "true", "yes", "on"].contains(env) { return true }
            if ["0", "false", "no", "off"].contains(env) { return false }
            // Unrecognized value: fail safe (legacy) rather than guessing.
            return false
        }
        return configEnabled
    }

    /// Resolve the model allowlist patterns (env override or default).
    public static func allowlistPatterns(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        guard let raw = environment[environmentAllowlist] else {
            return defaultModelAllowlist
        }
        let patterns = raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return patterns.isEmpty ? defaultModelAllowlist : patterns
    }

    /// Does `modelId` match any allowlist pattern? Patterns are
    /// case-insensitive; a trailing `*` makes them prefix globs, otherwise
    /// they must match exactly. Both the full id and its last `/` component
    /// are tried on BOTH sides, so an org-qualified id like
    /// `some-org/gpt-oss-20b` still matches the bare pattern `gpt-oss-20b`,
    /// and a bare id matches an org-qualified pattern by last component.
    public static func modelAllowlisted(
        _ modelId: String,
        patterns: [String] = defaultModelAllowlist
    ) -> Bool {
        let id = modelId.trimmingCharacters(in: .whitespaces).lowercased()
        guard !id.isEmpty else { return false }
        let lastComponent = id.split(separator: "/").last.map(String.init) ?? id
        for pattern in patterns {
            let p = pattern.lowercased()
            guard !p.isEmpty else { continue }
            if p.hasSuffix("*") {
                let prefix = String(p.dropLast())
                if id.hasPrefix(prefix) || lastComponent.hasPrefix(prefix) {
                    return true
                }
            } else {
                let pLast = p.split(separator: "/").last.map(String.init) ?? p
                if id == p || lastComponent == p || lastComponent == pLast {
                    return true
                }
            }
        }
        return false
    }

    /// The single selection decision: which engine serves `modelId`.
    public static func selection(
        modelId: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        configEnabled: Bool
    ) -> Selection {
        guard flagEnabled(environment: environment, configEnabled: configEnabled) else {
            return .legacy
        }
        let patterns = allowlistPatterns(environment: environment)
        return modelAllowlisted(modelId, patterns: patterns) ? .v2 : .legacy
    }
}

// MARK: - Factory (selection + safe fallback)

public enum EngineV2Factory {
    /// Build an `EngineV2Bridge` for `modelId` iff the flag + allowlist
    /// select the v2 engine. Returns nil (⇒ caller uses the legacy engine)
    /// when:
    ///   * the flag is off or the model is not allowlisted (silent — this is
    ///     the normal steady state), or
    ///   * `makeEngine` throws — the SAFE FALLBACK path, which additionally
    ///     emits a WARN `engine_health` telemetry event
    ///     (`operation=engine_v2_fallback`, `backend=engine_v2`) so the
    ///     fleet dashboard can see v2 init failures instead of a silent
    ///     downgrade.
    ///
    /// `makeEngine` is a closure (not a concrete type) because the v2 engine
    /// implementation lands via the mlx-swift-lm integration branch; the
    /// bridge codes against the frozen `CBv2Engine` contract only.
    public static func makeBridgeIfSelected(
        modelId: String,
        configEnabled: Bool,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        tokenizer: TokenizerHandle,
        eosTokenIds: Set<Int>,
        extraEOSTokens: [String] = [],
        defaultMaxTokens: Int = 4096,
        maxConcurrentRequests: Int = 4,
        kvBytesPerToken: Int = 0,
        kvBudget: GlobalKVCacheBudget? = nil,
        emitTelemetry: (@Sendable (TelemetryEvent) -> Void)? = nil,
        makeEngine: () throws -> any CBv2Engine
    ) -> EngineV2Bridge? {
        let selection = EngineV2Config.selection(
            modelId: modelId,
            environment: environment,
            configEnabled: configEnabled
        )
        guard selection == .v2 else { return nil }

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
                emitTelemetry: emitTelemetry
            )
        } catch {
            emitFallbackTelemetry(
                modelId: modelId,
                error: error,
                emitTelemetry: emitTelemetry
            )
            return nil
        }
    }

    /// WARN `engine_health` event for a v2-init failure → legacy fallback.
    /// Fields are drawn from the existing telemetry allowlist (`component`,
    /// `operation`, `backend`, `model`, `error_class`) — no new wire fields.
    static func emitFallbackTelemetry(
        modelId: String,
        error: Error,
        emitTelemetry: (@Sendable (TelemetryEvent) -> Void)?
    ) {
        var event = TelemetryEvent(
            source: .provider,
            severity: .warn,
            kind: .engineHealth,
            message: "engine_v2: init failed — falling back to legacy engine"
        )
        // Client-side allowlist filter (same as `TelemetryClient.emit`'s
        // convenience path) — every key here is allowlisted already; the
        // filter keeps that invariant enforced.
        event.fields = TelemetryFieldFilter.filter([
            "component": .string("engine"),
            "operation": .string("engine_v2_fallback"),
            "backend": .string("engine_v2"),
            "model": .string(modelId),
            "error_class": .string(String(reflecting: type(of: error))),
            // Human-readable reason ("error" is allowlisted on both sides).
            // v2 is default-on for the allowlisted models, so this fallback
            // is load-bearing — the dashboard needs model + why, not just
            // the error type.
            "error": .string(String(describing: error)),
        ])
        if let emitTelemetry {
            emitTelemetry(event)
        } else {
            TelemetryClient.shared.emit(event)
        }
    }

    /// WARN `engine_health` event when a model configured for `kv_quant` is
    /// served through engine_v2, which does NOT yet support KV-quant and
    /// silently falls back to fp16 caches (`makeProductionEngine` builds
    /// `CBv2LayerCache`, never a quantized cache). Surfacing this keeps the
    /// operator from assuming the memory savings apply on the v2 path.
    /// Allowlisted fields only.
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
