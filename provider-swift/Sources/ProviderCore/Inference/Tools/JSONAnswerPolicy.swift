// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMServer

/// Grammar-constrained JSON `response_format` answers on the text path of the
/// families with a pinned answer contract (`JSONAnswerProfile`): Qwen 3.5, 3.6
/// and 3.8, the PrismML Bonsai 2 builds, and Nemotron 3.5 Lightning.
/// Eligibility never changes the rendered prompt: the service's format
/// instruction still steers the model, and every request this policy declines
/// keeps that prompt-only behavior without a new refusal.
enum JSONAnswerPolicy {
    /// `DARKBLOOM_JSON_ANSWER_GRAMMAR=qwen` keeps the grammar to the Qwen 3.5,
    /// 3.6 and 3.8 types, as before Bonsai and Lightning were admitted; unset
    /// or any other value admits every family below. Read at launch.
    static let familiesEnvironmentKey = "DARKBLOOM_JSON_ANSWER_GRAMMAR"

    enum Families: Equatable, Sendable {
        case all
        case qwenOnly

        static let current = Families(environmentValue: ProcessInfo.processInfo.environment[familiesEnvironmentKey])

        init(environmentValue: String?) {
            self = environmentValue?.trimmingCharacters(in: .whitespaces).lowercased() == "qwen" ? .qwenOnly : .all
        }
    }

    private static let logger = ProviderLogger(
        subsystem: BuildEnvironment.current.serviceLogSubsystem, category: "json-answer")

    /// The answer contract of an admitted model, or nil. Admission is per
    /// family and, where a `model_type` is shared, per listed build: Bonsai's
    /// type is PrismML's alone, and Lightning shares `nemotron_h` with Nano.
    static func profile(modelID: String?, modelType: String?, families: Families = .current)
        -> JSONAnswerProfile?
    {
        switch modelType {
        case "qwen3_5", "qwen3_5_moe":
            return .qwen35
        default:
            return nil
        }
    }

    /// The constraint for an eligible request, or nil. Requests with media,
    /// tools or a `tool_choice` are out of scope; an unsupported schema, an
    /// unrecognized prompt boundary, an unverified tokenizer or a nonpositive
    /// budget falls back with a content-free log line.
    static func constraint(
        request: OpenAIChatCompletionRequest,
        tokenizer: TokenizerHandle,
        modelID: String?,
        modelType: String?,
        defaultMaxTokens: Int,
        stopTokenIDs: Set<Int>,
        promptTokens: [Int]?,
        families: Families = .current
    ) -> JSONAnswerConstraint? {
        guard let profile = profile(modelID: modelID, modelType: modelType, families: families),
              let format = request.responseFormat, format.requiresJSONOutput,
              request.tools?.isEmpty ?? true, request.toolChoice == nil,
              request.reasoningParser == .qwen3, !MediaIngest.hasMedia(request) else { return nil }
        guard let answer = try? JSONAnswerFormat(format, forbidding: profile.contentMarkers,
                                                 family: profile.family) else {
            return declined(profile, "schema outside the constrained subset")
        }
        guard let promptTokens, !promptTokens.isEmpty,
              let phase = profile.initialPhase(promptTail: tokenizer.inner.decode(
                  tokenIds: Array(promptTokens.suffix(ReasoningPromptProbe.tailTokenCount)),
                  skipSpecialTokens: false)) else {
            return declined(profile, "unrecognized prompt boundary")
        }
        guard let vocabulary = try? JSONAnswerVocabulary.cached(for: tokenizer, profile: profile,
                                                                 stopTokenIDs: stopTokenIDs) else {
            return declined(profile, "tokenizer does not match the pinned vocabulary")
        }
        guard let constraint = try? JSONAnswerConstraint(format: answer, profile: profile, vocabulary: vocabulary,
                                                         initialPhase: phase,
                                                         maxTokens: request.maxTokens ?? defaultMaxTokens) else {
            return declined(profile, "no positive output budget")
        }
        return constraint
    }

    /// Fixed reasons only: never schema text, prompt content or token IDs.
    private static func declined(_ profile: JSONAnswerProfile, _ reason: StaticString) -> JSONAnswerConstraint? {
        logger.info("\(profile.family) JSON response_format served prompt-only: \(reason)")
        return nil
    }
}
