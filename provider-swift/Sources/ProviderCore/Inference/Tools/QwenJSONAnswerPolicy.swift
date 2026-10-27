// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMServer

/// Grammar-constrained JSON `response_format` answers on the Qwen 3.5/3.6/3.8
/// text path. Eligibility never changes the rendered prompt: the service's
/// format instruction still steers the model, and every request this policy
/// declines keeps that prompt-only behavior without a new refusal.
enum QwenJSONAnswerPolicy {
    private static let modelTypes: Set<String> = ["qwen3_5", "qwen3_5_moe"]

    private static let logger = ProviderLogger(
        subsystem: BuildEnvironment.current.serviceLogSubsystem, category: "json-answer")

    /// The constraint for an eligible request, or nil. Requests with media,
    /// tools or a `tool_choice` are out of scope; an unsupported schema, an
    /// unrecognized prompt boundary, an unverified tokenizer or a nonpositive
    /// budget falls back with a content-free log line.
    static func constraint(
        request: OpenAIChatCompletionRequest,
        tokenizer: TokenizerHandle,
        modelType: String?,
        defaultMaxTokens: Int,
        stopTokenIDs: Set<Int>,
        promptTokens: [Int]?
    ) -> JSONAnswerConstraint? {
        guard let modelType, modelTypes.contains(modelType),
              let format = request.responseFormat, format.requiresJSONOutput,
              request.tools?.isEmpty ?? true, request.toolChoice == nil,
              request.reasoningParser == .qwen3, !MediaIngest.hasMedia(request) else { return nil }
        let profile = JSONAnswerProfile.qwen35
        guard let answer = try? JSONAnswerFormat(format, forbidding: profile.contentMarkers,
                                                 family: profile.family) else {
            return declined("schema outside the constrained subset")
        }
        guard let promptTokens, !promptTokens.isEmpty,
              let phase = profile.initialPhase(promptTail: tokenizer.inner.decode(
                  tokenIds: Array(promptTokens.suffix(ReasoningPromptProbe.tailTokenCount)),
                  skipSpecialTokens: false)) else {
            return declined("unrecognized prompt boundary")
        }
        guard let vocabulary = try? JSONAnswerVocabulary.cached(for: tokenizer, profile: profile,
                                                                 stopTokenIDs: stopTokenIDs) else {
            return declined("tokenizer does not match the pinned vocabulary")
        }
        guard let constraint = try? JSONAnswerConstraint(format: answer, profile: profile, vocabulary: vocabulary,
                                                         initialPhase: phase,
                                                         maxTokens: request.maxTokens ?? defaultMaxTokens) else {
            return declined("no positive output budget")
        }
        return constraint
    }

    /// Fixed reasons only: never schema text, prompt content or token IDs.
    private static func declined(_ reason: StaticString) -> JSONAnswerConstraint? {
        logger.info("Qwen JSON response_format served prompt-only: \(reason)")
        return nil
    }
}
