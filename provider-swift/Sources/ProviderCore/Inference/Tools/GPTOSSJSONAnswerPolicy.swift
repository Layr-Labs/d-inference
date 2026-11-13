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
        guard enabled, modelType == "gpt_oss",
              let format = request.responseFormat, format.requiresJSONOutput,
              request.tools?.isEmpty ?? true, request.toolChoice == nil,
              request.stop?.isEmpty ?? true, !MediaIngest.hasMedia(request) else { return nil }
        let profile = JSONAnswerProfile.gptOSSAnswer
        guard let answer = try? JSONAnswerFormat(format, forbidding: profile.contentMarkers, family: "GPT-OSS") else {
            return declined("schema outside the constrained subset")
        }
        guard let promptTokens, !promptTokens.isEmpty,
              tokenizer.inner.decode(tokenIds: Array(promptTokens.suffix(32)), skipSpecialTokens: false)
                  .hasSuffix(GPTOSSAnswerFraming.promptBoundary) else {
            return declined("unrecognized prompt boundary")
        }
        guard let vocabulary = try? JSONAnswerVocabulary.cached(for: tokenizer, profile: profile,
                                                                 stopTokenIDs: stopTokenIDs) else {
            return declined("tokenizer does not match the pinned vocabulary")
        }
        guard let constraint = try? GPTOSSJSONAnswerConstraint(format: answer, tokenizer: tokenizer.inner,
                                                                vocabulary: vocabulary, profile: profile,
                                                                maxTokens: request.maxTokens ?? defaultMaxTokens) else {
            return declined("no positive output budget or unverified Harmony framing")
        }
        return constraint
    }

    /// Fixed reasons only: never schema text, prompt content or token IDs.
    private static func declined(_ reason: StaticString) -> GPTOSSJSONAnswerConstraint? {
        logger.info("GPT-OSS JSON response_format served prompt-only: \(reason)")
        return nil
    }
}
