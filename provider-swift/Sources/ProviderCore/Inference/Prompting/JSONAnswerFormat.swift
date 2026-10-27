// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon
import MLXLMServer

/// A compiled JSON `response_format` for a constrained answer: the content
/// grammar plus a second check of the completed content. Exact Flint and
/// constrained Qwen share it; they differ only in the markup the answer may
/// never contain and the family named in content-free messages.
struct JSONAnswerFormat: Sendable {
    let grammar: FlintJSONGrammar
    /// `nil` for `json_object`, whose root must be an object.
    let schema: ToolValueSchema?
    let family: String

    /// Compiles a format whose `requiresJSONOutput` is true: `json_object`, or
    /// a `json_schema` within the shared fail-closed subset.
    init(_ format: OpenAIResponseFormat, forbidding markup: [[UInt8]], family: String) throws {
        self.family = family
        guard format.type == .jsonSchema else {
            grammar = try FlintJSONGrammar(schema: nil, forbidding: markup, owner: family)
            schema = nil
            return
        }
        guard let payload = format.jsonSchema else {
            throw ToolConstraintSchemaError.invalid("json_schema requires a json_schema payload")
        }
        let compiled = try ToolConstraintSchemaCompiler.compileResponseSchema(payload.schema)
        grammar = try FlintJSONGrammar(schema: compiled, forbidding: markup, owner: family)
        schema = compiled
    }

    /// Defense in depth after constrained decoding. A failure, including a
    /// budget that ended before the value completed, is a typed 422 and never
    /// a successful completion. Messages never quote generated content.
    func validate(content: String, finishReason: String) throws {
        let truncated = finishReason == "length"
        guard let value = try? JSONDecoder().decode(MLXLMCommon.JSONValue.self, from: Data(content.utf8)) else {
            throw failure(truncated
                ? "output budget ended before the JSON value was complete"
                : "content is not a single JSON value")
        }
        if truncated {
            // A root number is not self-delimiting: a truncated one still parses.
            switch value {
            case .int, .double:
                throw failure("output budget ended before the JSON value was complete")
            default:
                break
            }
        }
        if let schema {
            guard ToolConstraintValidation.satisfies(value, schema: schema) else {
                throw failure("content does not satisfy the json_schema")
            }
            return
        }
        guard case .object = value else {
            throw failure("json_object content must be a JSON object")
        }
    }

    private func failure(_ message: String) -> MLXOpenAIServiceError {
        .invalidResponseFormatOutput("\(family) \(message)")
    }
}

/// Visible content of one constrained JSON response, retained only until the
/// engine finishes so it can be validated. Never logged or sent to telemetry.
struct JSONAnswerOutput {
    private let format: JSONAnswerFormat
    private var content = ""

    init(_ format: JSONAnswerFormat) { self.format = format }

    mutating func observe(_ event: MLXServerGenerationEvent) {
        switch event {
        case .content(let text): content += text
        case .parsed(let parsed): content += parsed.content
        case .toolCall, .toolCallDelta, .info: break
        }
    }

    func validate(finishReason: String) throws {
        try format.validate(content: content, finishReason: finishReason)
    }
}
