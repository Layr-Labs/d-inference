// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon
import MLXLMServer

/// Grammar-constrained JSON `response_format` answers on Gemma 4. Eligibility
/// never changes the rendered prompt: the service's format instruction still
/// steers the model, and every request this policy declines keeps today's
/// prompt-only behavior without a new refusal.
enum GemmaJSONAnswerPolicy {
    /// `off`, `0`, `false` or `no` restores prompt-only Gemma JSON answers.
    /// Read once at launch.
    static let environmentKey = "DARKBLOOM_GEMMA_JSON_ANSWERS"
    static let enabled = isEnabled(ProcessInfo.processInfo.environment[environmentKey])

    private static let modelTypes: Set<String> = ["gemma4", "gemma4_text"]
    /// The pinned template's generation prompt: thinking on leaves the model
    /// at its turn, thinking off adds an empty, closed thought.
    private static let turnBoundary = "<|turn>model\n"
    private static let closedThoughtBoundary = turnBoundary + "<|channel>thought\n<channel|>"

    private static let logger = ProviderLogger(
        subsystem: BuildEnvironment.current.serviceLogSubsystem, category: "json-answer")

    static func isEnabled(_ value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else { return true }
        return !["off", "0", "false", "no"].contains(value)
    }

    /// The constraint for an eligible request, or nil. Requests with media,
    /// tools, a `tool_choice` other than a tool-free `auto`, or client stop
    /// sequences are out of scope. A schema outside the constrained subset is
    /// held to a JSON object when its root is one, else prompt-only; an
    /// unpinned template or tokenizer, an unrecognized prompt end or a
    /// nonpositive budget falls back with a content-free log line.
    static func constraint(
        request: OpenAIChatCompletionRequest,
        tokenizer: TokenizerHandle,
        modelType: String?,
        defaultMaxTokens: Int,
        stopTokenIDs: Set<Int>,
        promptTokens: [Int]?,
        enabled: Bool = enabled
    ) -> GemmaJSONAnswerConstraint? {
        guard enabled, let modelType, modelTypes.contains(modelType),
              let format = request.responseFormat, format.requiresJSONOutput,
              request.tools?.isEmpty ?? true, request.toolChoice == nil || request.toolChoice == .mode(.auto),
              request.stop?.isEmpty ?? true, request.reasoningParser == .gemma4,
              !MediaIngest.hasMedia(request) else { return nil }
        guard tokenizer.toolConstraintContractVerified else {
            return declined("unpinned Gemma 4 chat template")
        }
        guard case let (answer, heldToObject)? = answerFormat(format) else {
            return declined("schema outside the constrained subset and not an object")
        }
        guard let promptTokens, !promptTokens.isEmpty,
              let phase = initialPhase(promptTail: tokenizer.inner.decode(
                  tokenIds: Array(promptTokens.suffix(ReasoningPromptProbe.tailTokenCount)),
                  skipSpecialTokens: false)) else {
            return declined("unrecognized prompt boundary")
        }
        guard let vocabulary = try? GemmaAnswerPieces.cachedVocabulary(for: tokenizer,
                                                                       stopTokenIDs: stopTokenIDs) else {
            return declined("tokenizer does not match the pinned vocabulary")
        }
        guard let constraint = try? GemmaJSONAnswerConstraint(format: answer, vocabulary: vocabulary,
            initialPhase: phase, maxTokens: request.maxTokens ?? defaultMaxTokens) else {
            return declined("no positive output budget")
        }
        if heldToObject { logger.info("Gemma json_schema outside the constrained subset: held to a JSON object") }
        return constraint
    }

    /// Where output starts after the rendered prompt, or nil for any other
    /// prompt end (an assistant prefill, another template).
    static func initialPhase(promptTail tail: String) -> GemmaJSONAnswerBoundary.Phase? {
        if tail.hasSuffix(closedThoughtBoundary) { return .answer }
        if tail.hasSuffix(turnBoundary) { return .opening }
        return nil
    }

    /// The request's format (a `json_schema` rewritten into the shared subset
    /// where that is exact, `ResponseSchemaRewrite`), or a JSON-object answer
    /// (`heldToObject`) for a `json_schema` outside it whose root is an object.
    static func answerFormat(_ format: OpenAIResponseFormat) -> (format: JSONAnswerFormat, heldToObject: Bool)? {
        let profile = JSONAnswerProfile.gemma4
        if let exact = try? JSONAnswerFormat(format, forbidding: profile.contentMarkers, family: profile.family) {
            return (exact, false)
        }
        if format.type == .jsonSchema, var payload = format.jsonSchema,
           let rewritten = ResponseSchemaRewrite.subset(payload.schema) {
            payload.schema = rewritten
            if let exact = try? JSONAnswerFormat(.jsonSchema(payload), forbidding: profile.contentMarkers,
                                                 family: profile.family) {
                return (exact, false)
            }
        }
        guard format.type == .jsonSchema, let schema = format.jsonSchema?.schema, rootIsObject(schema),
              let object = try? JSONAnswerFormat(.jsonObject(), forbidding: profile.contentMarkers,
                                                 family: profile.family) else { return nil }
        return (object, true)
    }

    /// A schema whose every instance is an object: `type` is exactly
    /// `"object"`, which every other keyword narrows, except a draft-7 `$ref`
    /// that would replace it.
    private static func rootIsObject(_ schema: MLXLMCommon.JSONValue) -> Bool {
        guard case .object(let object) = schema else { return false }
        return object["type"] == .string("object") && object["$ref"] == nil
    }

    /// Fixed reasons only: never schema text, prompt content or token IDs.
    private static func declined(_ reason: StaticString) -> GemmaJSONAnswerConstraint? {
        logger.info("Gemma JSON response_format served prompt-only: \(reason)")
        return nil
    }
}

extension EngineV2Bridge {
    /// A Gemma JSON answer's grammar is best effort. An engine that runs no
    /// token constraint (a cluster pair, a native-tracked engine) refuses one,
    /// so there the request is submitted unconstrained, as before.
    static func admittedConstraint(_ constraint: (any CBv2TokenConstraint)?, servesDistributedPair: Bool,
                                   tracksNativeShutdown: Bool) -> (any CBv2TokenConstraint)? {
        guard constraint is GemmaJSONAnswerConstraint, servesDistributedPair || tracksNativeShutdown else {
            return constraint
        }
        return nil
    }
}
