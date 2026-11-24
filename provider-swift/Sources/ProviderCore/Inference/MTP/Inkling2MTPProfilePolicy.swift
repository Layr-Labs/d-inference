// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLLM
import MLXLMCommon

/// Operator overrides of Inkling 2's DSpark engine profile
/// (`Inkling2DSparkDrafter.defaultMTPConfig`). Tokens are unaffected: every
/// draft is verified exactly, so a cap changes only how much one round tries.
public enum Inkling2MTPProfilePolicy {
    /// `DARKBLOOM_INKLING_MTP_MAX_DRAFT`: the most drafts one round may
    /// propose. The adaptive depth policy still picks each round's depth at
    /// or below it, down to plain decode.
    public static let maxDraftKey = "DARKBLOOM_INKLING_MTP_MAX_DRAFT"
    /// The drafter's whole block: the shipped cap.
    public static let defaultMaxDraftTokens = 7

    public struct MaxDraft: Equatable, Sendable {
        public let tokens: Int
        /// The raw value when it was not a whole number (the default applies).
        public let unrecognized: String?
    }

    /// Unset or blank: 7. A whole number is clamped to 1...7. Anything else
    /// keeps 7 and is reported.
    public static func maxDraftTokens(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> MaxDraft {
        guard let raw = environment[maxDraftKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        else { return MaxDraft(tokens: defaultMaxDraftTokens, unrecognized: nil) }
        guard let value = Int(raw) else {
            return MaxDraft(tokens: defaultMaxDraftTokens, unrecognized: raw)
        }
        return MaxDraft(tokens: min(max(value, 1), defaultMaxDraftTokens), unrecognized: nil)
    }

    /// `DARKBLOOM_INKLING_MTP_COUPLED`: coupled drafting
    /// (`CBv2MTPConfig.coupledProposals`) for the served Inkling 2 identities.
    /// A sampled row under exact acceptance proposes the keyed race its verify
    /// draw runs instead of the draft's argmax; output is unchanged, only
    /// acceptance can move.
    public static let coupledKey = "DARKBLOOM_INKLING_MTP_COUPLED"
    /// The default when the switch is unset. Changes only on measured data.
    public static let coupledByDefault = false

    /// On for `1`, `true`, `yes` or `on`; off for `0`, `false`, `no` or `off`
    /// (trimmed, any letter case); unset or anything else keeps the default.
    /// Never on for an identity outside `Inkling2ModelIdentity.servedModelIDs`.
    public static func coupledProposals(
        modelID: String, environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard Inkling2ModelIdentity.isServedModelID(modelID) else { return false }
        let raw = environment[coupledKey]?.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch raw {
        case "1", "true", "yes", "on": return true
        case "0", "false", "no", "off": return false
        default: return coupledByDefault
        }
    }

    /// Inkling's engine profile with the operator's cap and coupling, through
    /// the drafter's own profile (`Inkling2DSparkDrafter.defaultMTPConfig`).
    public static func engineConfig(
        maxDraft: MaxDraft, coupled: Bool = false, adaptive: Bool = true,
        maxSpeculativeRows: Int = 8
    ) -> CBv2MTPConfig {
        Inkling2DSparkDrafter.defaultMTPConfig(
            maxDraftTokens: maxDraft.tokens, adaptive: adaptive,
            maxSpeculativeRows: maxSpeculativeRows, coupledProposals: coupled)
    }
}
