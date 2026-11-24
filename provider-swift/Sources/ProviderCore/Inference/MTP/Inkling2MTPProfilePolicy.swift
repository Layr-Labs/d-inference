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

    /// Inkling's engine profile with the operator's cap.
    public static func engineConfig(maxDraft: MaxDraft) -> CBv2MTPConfig {
        Inkling2DSparkDrafter.defaultMTPConfig(maxDraftTokens: maxDraft.tokens)
    }
}
