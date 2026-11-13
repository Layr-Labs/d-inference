// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMServer

/// Grammar-constrained JSON `response_format` answers on the text path of the
/// families with a pinned answer contract (`JSONAnswerProfile`): Qwen 3.5, 3.6
/// and 3.8, PrismML Bonsai 2 27B, Nemotron 3.5 Lightning and, behind its own
/// switch, GLM-5.3-Flash.
/// Eligibility never changes the rendered prompt: the service's format
/// instruction still steers the model, and every request this policy declines
/// keeps that prompt-only behavior without a new refusal.
enum JSONAnswerPolicy {
    /// `DARKBLOOM_JSON_ANSWER_GRAMMAR=qwen` (or `0`, `off`, `false`, `no`,
    /// `none`) keeps the grammar to the Qwen 3.5, 3.6 and 3.8 types, as before
    /// Bonsai and Lightning were admitted; unset or any other value admits
    /// every family below. Read once per process.
    static let familiesEnvironmentKey = "DARKBLOOM_JSON_ANSWER_GRAMMAR"

    enum Families: Equatable, Sendable {
        case all
        case qwenOnly

        static let current = Families(environmentValue: ProcessInfo.processInfo.environment[familiesEnvironmentKey])

        init(environmentValue: String?) {
            let value = environmentValue?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            self = ["qwen", "0", "off", "false", "no", "none"].contains(value) ? .qwenOnly : .all
        }
    }

    /// `DARKBLOOM_GLM_JSON_ANSWERS`: GLM-5.3-Flash JSON answers are
    /// constrained only with `1`, `on`, `true` or `yes`; unset or any other
    /// value keeps them prompt-steered and checked after generation
    /// (`GLM5NextResponseFormat`). Read once per process.
    static let glmEnvironmentKey = "DARKBLOOM_GLM_JSON_ANSWERS"
    static let glmEnabled = glmEnabled(environmentValue: ProcessInfo.processInfo.environment[glmEnvironmentKey])

    static func glmEnabled(environmentValue: String?) -> Bool {
        let value = environmentValue?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        return ["1", "on", "true", "yes"].contains(value)
    }

    private static let logger = ProviderLogger(
        subsystem: BuildEnvironment.current.serviceLogSubsystem, category: "json-answer")

    /// The answer contract of an admitted model, or nil. The Qwen types are
    /// admitted by `model_type` alone; `prism_hadamard_qwen35` and
    /// `nemotron_h`, which Lightning shares with Nano, only for a listed
    /// build, and only on a single Mac: a cluster pair refuses any token
    /// constraint before reserving (`constrainedDecodingUnsupported`), so their
    /// pairs keep today's prompt-only service instead of gaining that refusal.
    /// A Qwen pair's refusal predates them and is failed over upstream. The
    /// Bonsai 2 9B is not admitted: it drafts, and its JSON rows (thinking off
    /// by default) would stop its whole decode cohort from speculating.
    /// GLM-5.3-Flash is admitted only where its engine accepts token
    /// constraints (`EngineV2.acceptsTokenConstraints`: the native page-bank
    /// profiles, never a cluster pair), with `glm` on.
    static func profile(modelID: String?, modelType: String?, families: Families = .current,
                        servesDistributedPair: Bool = false, acceptsTokenConstraints: Bool = false,
                        glm: Bool = glmEnabled) -> JSONAnswerProfile?
    {
        switch modelType {
        case "qwen3_5", "qwen3_5_moe":
            return .qwen35
        case "prism_hadamard_qwen35" where families == .all && !servesDistributedPair:
            return EngineV2SupportedModels.isBonsai2ListingModelID(modelID) ? .bonsai2 : nil
        case "nemotron_h" where families == .all && !servesDistributedPair:
            return EngineV2SupportedModels.isNemotron35ListingModelID(modelID) ? .nemotron35 : nil
        case "glm5_next" where glm && acceptsTokenConstraints:
            return .glm5Next
        default:
            return nil
        }
    }

    /// The constraint for an eligible request, or nil. Requests with media,
    /// tools or a `tool_choice` are out of scope, and so is a prompt that
    /// opens a thought on a family admitted for its answers alone (Lightning's
    /// default). On Qwen a schema outside the subset is widened first
    /// (`QwenJSONSchemaRewrite`). An unsupported schema, an unrecognized prompt
    /// boundary, an unverified tokenizer or a nonpositive budget falls back
    /// with a content-free log line.
    static func constraint(
        request: OpenAIChatCompletionRequest,
        tokenizer: TokenizerHandle,
        modelID: String?,
        modelType: String?,
        defaultMaxTokens: Int,
        stopTokenIDs: Set<Int>,
        promptTokens: [Int]?,
        servesDistributedPair: Bool,
        acceptsTokenConstraints: Bool = false,
        families: Families = .current,
        glm: Bool = glmEnabled,
        widensSchemas: Bool = QwenJSONSchemaRewrite.enabled
    ) -> JSONAnswerConstraint? {
        guard let profile = profile(modelID: modelID, modelType: modelType, families: families,
                                    servesDistributedPair: servesDistributedPair,
                                    acceptsTokenConstraints: acceptsTokenConstraints, glm: glm),
              let format = request.responseFormat, format.requiresJSONOutput,
              request.tools?.isEmpty ?? true, request.toolChoice == nil,
              request.reasoningParser == .qwen3, !MediaIngest.hasMedia(request) else { return nil }
        let phase = promptTokens.flatMap { tokens in
            tokens.isEmpty ? nil : profile.initialPhase(promptTail: tokenizer.inner.decode(
                tokenIds: Array(tokens.suffix(ReasoningPromptProbe.tailTokenCount)), skipSpecialTokens: false))
        }
        if phase == .reasoning, !profile.constrainsReasoning { return nil }
        guard case let (answer, widening)? = QwenJSONSchemaRewrite.answerFormat(format, profile: profile,
                  widens: widensSchemas) else {
            return declined(profile, "schema outside the constrained subset")
        }
        guard let phase else {
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
        if let widening { logger.info("\(profile.family) json_schema outside the constrained subset: \(widening.note)") }
        return constraint
    }

    /// Fixed reasons only: never schema text, prompt content or token IDs.
    private static func declined(_ profile: JSONAnswerProfile, _ reason: StaticString) -> JSONAnswerConstraint? {
        logger.info("\(profile.family) JSON response_format served prompt-only: \(reason)")
        return nil
    }
}
