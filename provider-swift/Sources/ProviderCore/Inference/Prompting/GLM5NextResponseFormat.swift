// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon
import MLXLMServer

/// GLM-5.3-Flash JSON output contract. GLM's native engine refuses sampler
/// constraints, so this is not constrained decoding: the service's
/// `response_format` instruction steers the model
/// (`OpenAIResponseFormatSupport.preparedRequest`), and the answer is withheld
/// until generation ends, then decoded and validated before any of it is
/// exposed. `json_schema` uses the fail-closed subset the other families
/// compile (`ToolConstraintSchemaCompiler.compileResponseSchema`).
struct GLM5NextResponseFormat: Sendable {
    let format: OpenAIResponseFormat
    /// `nil` for `json_object`, whose root must be an object.
    let schema: ToolValueSchema?

    /// `nil` for other families and non-JSON formats. An unsupported schema
    /// or a format combined with tools is an invalid request.
    static func resolve(
        _ request: OpenAIChatCompletionRequest, modelType: String?
    ) throws -> GLM5NextResponseFormat? {
        guard GLM5NextPromptPolicy.applies(modelType: modelType),
            let format = request.responseFormat, format.requiresJSONOutput
        else { return nil }
        // A withheld answer is one JSON value, never calls; Nemotron Super
        // refuses the same combination.
        guard request.tools?.isEmpty != false else {
            throw invalid("JSON response_format cannot be combined with tools")
        }
        guard format.type == .jsonSchema else { return GLM5NextResponseFormat(format: format, schema: nil) }
        guard let payload = format.jsonSchema else {
            throw invalid("json_schema requires a json_schema payload")
        }
        do {
            return GLM5NextResponseFormat(
                format: format, schema: try ToolConstraintSchemaCompiler.compileResponseSchema(payload.schema))
        } catch ToolConstraintSchemaError.invalid(let message) {
            throw invalid("response_format is invalid: \(message)")
        } catch ToolConstraintSchemaError.unsupported(let message) {
            throw invalid("response_format is unsupported: \(message)")
        }
    }

    /// The answer to expose: the JSON text the instruction asked for, without
    /// markdown fences or surrounding prose, or a typed 422 when no complete
    /// valid value exists. Messages never quote generated content.
    func validatedContent(_ content: String, finishReason: String) throws -> String {
        let mismatch = Self.failure(schema == nil
            ? "GLM content is not a JSON object" : "GLM content does not satisfy the json_schema")
        // The service's candidate extraction (whole text, fenced block, first
        // balanced value) and its own checks; its messages can name generated
        // keys, so they are replaced by fixed ones.
        guard let text = try? OpenAIResponseFormatSupport.normalizedContent(content, for: format),
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
        if let schema, !ToolConstraintValidation.satisfies(value, schema: schema) { throw mismatch }
        return text
    }

    private static func invalid(_ detail: String) -> MultiModelBatchSchedulerEngineError {
        .invalidToolPayload("GLM5: " + detail)
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
        case .toolCall, .toolCallDelta, .info:
            return event
        }
    }

    /// The validated answer as one content event, or a typed 422.
    func validatedAnswer(finishReason: String) throws -> MLXServerGenerationEvent {
        .parsed(.init(content: try format.validatedContent(content, finishReason: finishReason),
            reasoningContent: nil))
    }
}
