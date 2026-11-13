// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMServer

/// Grammar-constrained JSON `response_format` answers on GPT-OSS. Eligibility
/// never changes the rendered prompt: the service's format instruction still
/// steers the model, and every request this policy declines keeps today's
/// prompt-only behavior without a new refusal.
enum GPTOSSJSONAnswerPolicy {
    /// `off`, `0`, `false` or `no` restores prompt-only GPT-OSS JSON answers.
    /// Read once at launch.
    static let environmentKey = "DARKBLOOM_GPTOSS_JSON_ANSWERS"
    static let enabled = isEnabled(ProcessInfo.processInfo.environment[environmentKey])

    private static let logger = ProviderLogger(
        subsystem: BuildEnvironment.current.serviceLogSubsystem, category: "json-answer")

    static func isEnabled(_ value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else { return true }
        return !["off", "0", "false", "no"].contains(value)
    }

    /// The constraint for an eligible request, or nil. Requests with media,
    /// tools, a `tool_choice` or client stop sequences are out of scope; an
    /// unsupported schema, an unrecognized prompt boundary, an unverified
    /// tokenizer or a nonpositive budget falls back with a content-free log line.
    static func constraint(
        request: OpenAIChatCompletionRequest,
        tokenizer: TokenizerHandle,
        modelType: String?,
        defaultMaxTokens: Int,
        stopTokenIDs: Set<Int>,
        promptTokens: [Int]?,
        enabled: Bool = enabled
    ) -> GPTOSSJSONAnswerConstraint? {
        nil
    }

    /// Fixed reasons only: never schema text, prompt content or token IDs.
    private static func declined(_ reason: StaticString) -> GPTOSSJSONAnswerConstraint? {
        logger.info("GPT-OSS JSON response_format served prompt-only: \(reason)")
        return nil
    }
}
