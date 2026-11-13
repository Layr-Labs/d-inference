// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon
import MLXLMServer

/// What a GLM JSON answer that parses but misses its schema becomes.
/// `refuse` (the default) is the typed 422 of the strict contract. `release`
/// exposes the normalized answer, so the caller's own validator judges it.
/// An answer that is not JSON stays a 422 either way.
/// `DARKBLOOM_GLM_JSON_SCHEMA_MISS=release` selects it; read once at launch.
enum GLM5NextSchemaMiss: String, Sendable {
    case refuse, release

    static let environmentKey = "DARKBLOOM_GLM_JSON_SCHEMA_MISS"
    static let current = parse(ProcessInfo.processInfo.environment[environmentKey])

    static func parse(_ value: String?) -> GLM5NextSchemaMiss {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "release" ? .release : .refuse
    }
}

/// GLM-5.3-Flash JSON output contract. GLM's native engine refuses sampler
/// constraints, so this is not constrained decoding: the service's
/// `response_format` instruction steers the model
/// (`OpenAIResponseFormatSupport.preparedRequest`), and the answer is withheld
/// until generation ends, then decoded and validated before any of it is
/// exposed. Nothing compiles a grammar from the schema, so a `json_schema`
/// outside the subset Flint's grammar needs
/// (`ToolConstraintSchemaCompiler.compileResponseSchema`) is validated against
/// its own JSON Schema, as the other families validate theirs.
struct GLM5NextResponseFormat: Sendable {
    let format: OpenAIResponseFormat
    /// The compiled subset; `nil` for `json_object`, whose root must be an
    /// object, and for a schema the subset does not cover.
    let schema: ToolValueSchema?
    /// The caller's schema when the subset does not cover it.
    let rawSchema: MLXLMCommon.JSONValue?
    let schemaMiss: GLM5NextSchemaMiss

    init(format: OpenAIResponseFormat, schema: ToolValueSchema?, rawSchema: MLXLMCommon.JSONValue? = nil,
         schemaMiss: GLM5NextSchemaMiss = .current) {
        self.format = format
        self.schema = schema
        self.rawSchema = rawSchema
        self.schemaMiss = schemaMiss
    }

    /// `nil` for other families and non-JSON formats.
    static func resolve(
        _ request: OpenAIChatCompletionRequest, modelType: String?
    ) throws -> GLM5NextResponseFormat? {
        guard GLM5NextPromptPolicy.applies(modelType: modelType),
            let format = request.responseFormat, format.requiresJSONOutput
        else { return nil }
        guard format.type == .jsonSchema else { return GLM5NextResponseFormat(format: format, schema: nil) }
        guard let payload = format.jsonSchema else {
            throw invalid("json_schema requires a json_schema payload")
        }
        guard let compiled = try? ToolConstraintSchemaCompiler.compileResponseSchema(payload.schema) else {
            return GLM5NextResponseFormat(format: format, schema: nil, rawSchema: payload.schema)
        }
        return GLM5NextResponseFormat(format: format, schema: compiled)
    }

    /// The answer to expose: the JSON text the instruction asked for, without
    /// markdown fences or surrounding prose, or a typed 422 when no complete
    /// valid value exists. With `release`, a complete value that only misses
    /// its `json_schema` is exposed too, when the model stopped by itself: an
    /// output the token limit cut is judged as with `refuse`. Messages never
    /// quote generated content.
    func validatedContent(_ content: String, finishReason: String) throws -> String {
        let mismatch = Self.failure(format.type == .jsonSchema
            ? "GLM content does not satisfy the json_schema" : "GLM content is not a JSON object")
        let releases = schemaMiss == .release && finishReason != "length"
        // The service's candidate extraction (whole text, fenced block, first
        // balanced value) and its own checks; its messages can name generated
        // keys, so they are replaced by fixed ones.
        let checked = try? OpenAIResponseFormatSupport.normalizedContent(content, for: format)
        guard let text = checked ?? (releases ? releasableCandidate(content) : nil),
            let value = try? JSONDecoder().decode(MLXLMCommon.JSONValue.self, from: Data(text.utf8))
        else { throw mismatch }
        if finishReason == "length" {
            // A root number is not self-delimiting: a truncated one still parses.
            switch value {
            case .int, .double:
                throw Self.failure("GLM output budget ended before the JSON value was complete")
            default:
                break
            }
        }
        if checked == nil || !satisfiesSchema(value) {
            guard releases else { throw mismatch }
            Self.logger.info("GLM JSON response_format answer released past a schema miss")
        }
        return text
    }

    private func satisfiesSchema(_ value: MLXLMCommon.JSONValue) -> Bool {
        if let schema, !ToolConstraintValidation.satisfies(value, schema: schema) { return false }
        if let rawSchema, !ToolConstraintValidation.satisfies(value, jsonSchema: rawSchema) { return false }
        return true
    }

    /// The `json_schema` candidate the service's own schema check rejected:
    /// the same extraction, checked against no schema. This relies on the
    /// service picking its candidate without the schema (the first that
    /// decodes, never another after a schema failure) and on an empty schema
    /// admitting any value.
    private func releasableCandidate(_ content: String) -> String? {
        guard format.type == .jsonSchema else { return nil }
        return try? OpenAIResponseFormatSupport.normalizedContent(content, for: Self.anyJSONValue)
    }

    private static let anyJSONValue = OpenAIResponseFormat(type: .jsonSchema, jsonSchema: .init(schema: .object([:])))

    private static let logger = ProviderLogger(
        subsystem: BuildEnvironment.current.serviceLogSubsystem, category: "json-answer")

    private static func invalid(_ detail: String) -> MultiModelBatchSchedulerEngineError {
        .invalidToolPayload("GLM5: " + detail, refusal: .unsupportedResponseFormat)
    }

    private static func failure(_ message: String) -> MLXOpenAIServiceError {
        .invalidResponseFormatOutput(message)
    }
}

/// The answer of one GLM JSON-format response, retained until the engine
/// finishes so nothing unvalidated reaches the client. Reasoning streams as
/// it is generated. Request-local plaintext; never logged or sent to telemetry.
struct GLM5NextResponseFormatOutput {
    private let format: GLM5NextResponseFormat
    private var content = ""

    init(_ format: GLM5NextResponseFormat) { self.format = format }

    /// The part of `event` that may stream now; answer text is retained.
    mutating func withholding(_ event: MLXServerGenerationEvent) -> MLXServerGenerationEvent? {
        switch event {
        case .content(let text):
            content += text
            return nil
        case .parsed(let parsed):
            content += parsed.content
            guard let reasoning = parsed.reasoningContent, !reasoning.isEmpty else { return nil }
            return .parsed(.init(content: "", reasoningContent: reasoning))
        case .toolCall, .toolCallDelta, .logprobs, .info:
            return event
        }
    }

    /// The answer as one content event at the end of generation. The format
    /// governs an answer, not calls: beside tool calls the retained text
    /// leaves as generated, as the service exposes the other families'
    /// content beside calls; otherwise the validated answer, or a typed 422.
    func finalAnswer(finishReason: String, hasToolCalls: Bool) throws -> MLXServerGenerationEvent? {
        guard !hasToolCalls else {
            return content.isEmpty ? nil : .parsed(.init(content: content, reasoningContent: nil))
        }
        return .parsed(.init(content: try format.validatedContent(content, finishReason: finishReason),
            reasoningContent: nil))
    }
}
