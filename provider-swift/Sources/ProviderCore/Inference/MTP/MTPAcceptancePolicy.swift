import Foundation
import MLXLMCommon

/// Resolves the MTP draft acceptance rule for one model slot from the
/// provider configuration.
///
/// Precedence: `[backend] mtp_acceptance_by_model` for the exact model id,
/// then `[backend] mtp_acceptance`, then the built-in rule, which is exact for
/// every model: typical acceptance is used only where configured. A value that
/// names no known rule is reported and resolves to `exact`, so a typo can never
/// install a lossy rule. The typical threshold is the engine constant
/// `CBv2MTPAcceptance.defaultTypicalDelta`; it is not a production key.
/// Serving reads no environment variable for this rule; the benchmark
/// harness alone honours `DARKBLOOM_MTP_ACCEPTANCE`.
public enum MTPAcceptancePolicy {
    public struct Resolution: Equatable, Sendable {
        public let acceptance: CBv2MTPAcceptance
        /// The configured value that was ignored because it names no rule.
        public let unrecognized: String?
    }

    /// `"exact"` or `"typical"` (case-insensitive, surrounding whitespace
    /// ignored). nil for anything else.
    public static func parse(_ raw: String) -> CBv2MTPAcceptance? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "exact": return .exact
        case "typical": return .typical(delta: CBv2MTPAcceptance.defaultTypicalDelta)
        default: return nil
        }
    }

    /// Without a configured value the rule is exact for every model. Exact
    /// keeps each model's output distribution (not bit-identical to MTP off).
    /// Typical acceptance kept greedy-leaning drafts often enough to loop
    /// sampled answers on every family measured:
    /// - Qwen3.5-9B: a row at temperature 1 looped to `max_tokens` under
    ///   typical acceptance where exact acceptance did not;
    /// - Gemma 4 26B QAT: on OpenRouter's GPQA run of 10-31 every answer
    ///   drafted under typical acceptance and 30 % ended at the 32,768-token
    ///   output cap;
    /// - Inkling 2 Mini: on OpenRouter's GPQA shape at temperature 0.5 none of
    ///   8 drafter-on samples answered under typical acceptance (they repeated
    ///   until the 32,768-token cap or the loop guard); with exact acceptance
    ///   the same questions answered, token for token as with the drafter off.
    /// Greedy rows accept exactly under either rule.
    public static func resolve(
        global: String?, byModel: [String: String], modelID: String
    ) -> Resolution {
        let raw = byModel[modelID] ?? global
        guard let raw else { return Resolution(acceptance: .exact, unrecognized: nil) }
        guard let parsed = parse(raw) else {
            return Resolution(acceptance: .exact, unrecognized: raw)
        }
        return Resolution(acceptance: parsed, unrecognized: nil)
    }

    /// The catalog Qwen 3.5/3.6 MoE builds with an MTP head.
    static let qwen35CatalogMoEModelIDs: Set<String> = [
        "qwen3.5-35b-a3b", "qwen3.6-35b-a3b-vl-mtp-mxfp8",
    ]

    /// The catalog Gemma 4 26B QAT build (its 8-bit siblings draft only with
    /// `mtp_mode = "on"`).
    static let gemmaQATModelID = "gemma-4-26b-qat-4bit"

    /// Benchmark-only override: `DARKBLOOM_MTP_ACCEPTANCE=exact|typical[:<delta>]`.
    /// nil when the variable is absent or names no rule. A `typical` delta
    /// must be a finite positive number; otherwise the default applies.
    public static func benchmarkOverride(environment: [String: String]) -> CBv2MTPAcceptance? {
        guard let raw = environment["DARKBLOOM_MTP_ACCEPTANCE"] else { return nil }
        let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
        guard let first = parts.first, let mode = parse(first) else { return nil }
        if case .typical = mode, parts.count == 2,
            let delta = Float(parts[1].trimmingCharacters(in: .whitespaces)),
            delta.isFinite, delta > 0
        {
            return .typical(delta: delta)
        }
        return mode
    }
}

/// On the builds in `SDKFeatureDefaults.penaltyRowBuilds` (the catalog Qwen
/// 3.5/3.6 builds, card default presence 1.5, Gemma 4 26B QAT and Inkling 2
/// Mini), rows with a presence or
/// frequency penalty speculate: the engine re-derives the penalties at each
/// verify position, always with exact acceptance. The SDK reads the switch
/// once per process (`CBv2MTPConfig.envPenaltySpeculation`); the LaunchAgent
/// forwards it. `0`, `false`, `no` or `off` keeps such rows target-only.
public enum MTPPenaltyRows {
    public static let environmentKey = "DARKBLOOM_MTP_PENALTY_ROWS"
}

/// On the builds in `SDKFeatureDefaults.stopStringRowBuilds` (the catalog
/// Gemma 4 26B QAT build and Inkling 2 Mini), rows with `stop` strings speculate; the round's
/// finalize ends the row at the first match. The SDK reads the switch once
/// per process (`CBv2MTPConfig.envStopStringSpeculation`); the LaunchAgent
/// forwards it. `0`, `false`, `no` or `off` keeps such rows target-only.
public enum MTPStopStringRows {
    public static let environmentKey = "DARKBLOOM_MTP_STOP_STRING_ROWS"
}
