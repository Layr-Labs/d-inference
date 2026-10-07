import Foundation
import MLXLMCommon

/// Resolves the MTP draft acceptance rule for one model slot from the
/// provider configuration.
///
/// Typical acceptance is a per-model opt-in: only
/// `[backend] mtp_acceptance_by_model` for the exact model id selects a rule,
/// and every other model uses `exact`. Typical acceptance is not yet
/// benchmarked, so no default selects it. The retired global
/// `[backend] mtp_acceptance` key selects nothing (`RetiredKnobWarnings`). A
/// value that names no known rule is reported and resolves to `exact`, so a
/// typo can never install a lossy rule. The typical threshold is the engine
/// constant `CBv2MTPAcceptance.defaultTypicalDelta`; it is not a production
/// key. Serving reads no environment variable for this rule; the benchmark
/// harness alone honours `DARKBLOOM_MTP_ACCEPTANCE`.
public enum MTPAcceptancePolicy {
    public struct Resolution: Equatable, Sendable {
        public let acceptance: CBv2MTPAcceptance
        /// The configured value that was ignored because it names no rule.
        public let unrecognized: String?

        /// The operator warning for an ignored value; nil when none was ignored.
        public func unrecognizedWarning(modelID: String) -> String? {
            unrecognized.map {
                "engine_v2: unrecognized mtp_acceptance value \"\($0)\" for \(modelID) — using \"exact\""
            }
        }
    }

    /// Why a slot installs `exact` in place of a configured `typical` rule.
    public enum ExactFallbackReason: String, Equatable, Sendable {
        case mtpOff = "MTP is off for this slot"
        case noTargetPrefixAcceptance = "its MTP drafter does not support target-prefix acceptance"
    }

    /// The rule a slot installs, and why it differs from the configured rule.
    public struct Installation: Equatable, Sendable {
        public let acceptance: CBv2MTPAcceptance
        public let fallback: ExactFallbackReason?

        /// The operator warning for a configured rule the slot cannot honour.
        public func fallbackWarning(modelID: String) -> String? {
            fallback.map {
                "engine_v2: \(modelID) cannot use mtp_acceptance \"typical\" "
                    + "(\($0.rawValue)) — using \"exact\""
            }
        }
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

    public static func resolve(byModel: [String: String], modelID: String) -> Resolution {
        guard let raw = byModel[modelID] else {
            return Resolution(acceptance: .exact, unrecognized: nil)
        }
        guard let parsed = parse(raw) else {
            return Resolution(acceptance: .exact, unrecognized: raw)
        }
        return Resolution(acceptance: parsed, unrecognized: nil)
    }

    /// The rule a slot installs for `requested`. Typical acceptance acts only
    /// on rows that reach target-prefix pre-sampling, which needs an enabled
    /// MTP drafter that declares `supportsTargetPrefixAcceptance`. Without
    /// one, the slot installs `exact` and reports why.
    public static func installation(
        requested: CBv2MTPAcceptance, mtpEnabled: Bool, drafter: (any CBv2MTPDrafter)?
    ) -> Installation {
        guard case .typical = requested else {
            return Installation(acceptance: requested, fallback: nil)
        }
        guard mtpEnabled, let drafter else {
            return Installation(acceptance: .exact, fallback: .mtpOff)
        }
        guard drafter.supportsTargetPrefixAcceptance else {
            return Installation(acceptance: .exact, fallback: .noTargetPrefixAcceptance)
        }
        return Installation(acceptance: requested, fallback: nil)
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
