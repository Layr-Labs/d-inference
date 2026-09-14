// Copyright © 2026 Eigen Labs.
import Foundation
import ProviderCoreFoundation

/// Local serving policy for the owned Flash-Next candidate. These defaults
/// neither register a catalog model nor establish artifact/runtime qualification.
/// Architecture support remains separate from automatic paging/cache activation.
enum Qwen4SupportPolicy {
    static let ownedModelID = ModelMediaPolicy.ownedQwen4ModelID
    static let defaultContextTokens = 82_000
    static let contextEnvironmentKey = "DARKBLOOM_QWEN4_LISTING_CONTEXT"
    static let contextRejectionMessage = "advertised_context_exceeded"

    static func isOwnedModelID(_ modelID: String?) -> Bool {
        modelID == ownedModelID
    }

    static func isQwen4ModelType(_ modelType: String?) -> Bool {
        switch modelType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "qwen4_exp", "qwen4_exp_text": return true
        default: return false
        }
    }

    /// Validate this owned artifact's template contract after the existing
    /// boolean/effort precedence has resolved. Other Qwen4 artifacts may ship
    /// different templates, so architecture identity alone is insufficient.
    /// Never coerce an unsupported effort or change disabled-thinking behavior.
    static func validateReasoningContext(
        modelID: String,
        modelType: String?,
        additionalContext: [String: any Sendable]?
    ) throws {
        guard isOwnedModelID(modelID), isQwen4ModelType(modelType),
            additionalContext?["enable_thinking"] as? Bool != false,
            let effort = additionalContext?["reasoning_effort"] as? String
        else { return }
        // The original template defaults to xhigh and accepts these exact
        // spellings. Preserve that behavior rather than inventing aliases.
        guard ["low", "medium", "xhigh"].contains(effort) else {
            throw MultiModelBatchSchedulerEngineError.unsupportedReasoningEffort
        }
    }

    /// A configured limit may only narrow the candidate's serving window.
    /// Missing, zero, negative and malformed values cannot restore the card limit.
    static func configuredContextTokens(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int {
        guard let raw = environment[contextEnvironmentKey],
            let value = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
            value > 0
        else { return defaultContextTokens }
        return min(defaultContextTokens, value)
    }

    static func contextLimit(
        modelID: String,
        modelType: String? = nil,
        nativeContextTokens: Int? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int? {
        guard isOwnedModelID(modelID) || isQwen4ModelType(modelType) else { return nil }
        let limit = configuredContextTokens(environment: environment)
        guard let nativeContextTokens, nativeContextTokens > 0 else { return limit }
        return min(limit, nativeContextTokens)
    }

    /// Keep programmatic/test plumbing bounded as well as the environment path.
    static func boundedContextTokens(_ proposed: Int?) -> Int? {
        guard let proposed else { return nil }
        return proposed > 0 ? min(defaultContextTokens, proposed) : defaultContextTokens
    }
}
