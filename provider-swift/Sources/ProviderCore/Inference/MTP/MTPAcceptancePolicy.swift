import Foundation
import MLXLMCommon

/// Resolves the MTP draft acceptance rule for one model slot from the
/// provider configuration.
///
/// Precedence: `[backend] mtp_acceptance_by_model` for the exact model id,
/// then `[backend] mtp_acceptance`, then the built-in `exact`. A value that
/// names no known rule is reported and resolves to `exact`, so a typo can
/// never install a lossy rule. The typical threshold is the engine constant
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
        guard let raw else { return Resolution(acceptance: .exact, unrecognized: nil) }
        guard let parsed = parse(raw) else {
            return Resolution(acceptance: .exact, unrecognized: raw)
        }
        return Resolution(acceptance: parsed, unrecognized: nil)
    }

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
