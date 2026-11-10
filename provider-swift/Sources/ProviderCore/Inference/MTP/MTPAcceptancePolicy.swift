import Foundation
import MLXLMCommon

/// Resolves the MTP draft acceptance rule for one model slot from the
/// provider configuration.
///
/// Precedence: `[backend] mtp_acceptance_by_model` for the exact model id,
/// then `[backend] mtp_acceptance`, then the built-in rule (exact for the
/// private Bonsai 9B candidate, the catalog Qwen3.5-9B and Gemma 4 26B QAT,
/// typical for the other profiles). A value that names no known rule is reported and
/// resolves to `exact`, so a typo can never install a lossy rule. The
/// typical threshold is the engine constant
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

    public static func resolve(
        global: String?, byModel: [String: String], modelID: String
    ) -> Resolution {
        let raw = byModel[modelID] ?? global
        guard let raw else {
            return Resolution(
                acceptance: builtInIsExact(modelID: modelID) ? .exact
                    : .typical(delta: CBv2MTPAcceptance.defaultTypicalDelta),
                unrecognized: nil)
        }
        guard let parsed = parse(raw) else {
            return Resolution(acceptance: .exact, unrecognized: raw)
        }
        return Resolution(acceptance: parsed, unrecognized: nil)
    }

    /// The built-in rule is exact for the owned Bonsai 9B candidate, for the
    /// catalog Qwen3.5-9B (with no default presence penalty its rows
    /// speculate, and at temperature 1 typical acceptance made them loop to
    /// `max_tokens` where exact acceptance did not) and for the catalog
    /// Gemma 4 26B QAT, whose assistant drafts most of its rows: on
    /// OpenRouter's GPQA run of 10-31 every answer drafted under typical
    /// acceptance and 30 % ended at the 32,768-token output cap. Exact keeps
    /// each model's output distribution (not bit-identical to MTP off).
    static func builtInIsExact(modelID: String) -> Bool {
        Bonsai9BModelPolicy.matchesModelID(modelID)
            || modelID == EngineV2SamplingDefaults.qwen35NineBModelID
            || modelID == gemmaQATModelID
    }

    /// The catalog Gemma 4 26B QAT build (its 8-bit siblings draft only with
    /// `mtp_mode = "on"` and keep typical).
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
