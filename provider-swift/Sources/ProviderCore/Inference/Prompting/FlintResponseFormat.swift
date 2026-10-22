// Copyright © 2026 Eigen Labs.
//
// Recursive's Flint serving guide (RecursiveSI/flint sglang/README.md at
// 2a247be0c0aec895ccb0ac7ca92229ec6df37288): `response_format` constrains
// `content`; Flint may first reason in <think>…</think>, and the constraint
// applies to the answer after it. A request with both tools and a response
// format gets only the response format.

import Foundation
import MLXLMCommon
import MLXLMServer

/// Exact-Flint JSON output contract: compiled once per request, enforced by
/// the native constraint and checked again on the completed content.
struct FlintResponseFormat: Sendable {
    let grammar: FlintJSONGrammar
    /// `nil` for `json_object`, whose root must be an object.
    let schema: ToolValueSchema?

    /// `nil` for other families and non-JSON formats. A schema outside the
    /// shared compiled subset fails closed as an invalid request.
    static func resolve(
        _ request: OpenAIChatCompletionRequest, modelType: String?
    ) throws -> FlintResponseFormat? {
        guard modelType == "flint", let format = request.responseFormat, format.requiresJSONOutput else {
            return nil
        }
        do {
            guard format.type == .jsonSchema else {
                return FlintResponseFormat(grammar: try FlintJSONGrammar(schema: nil), schema: nil)
            }
            guard let payload = format.jsonSchema else {
                throw ToolConstraintSchemaError.invalid("json_schema requires a json_schema payload")
            }
            let schema = try ToolConstraintSchemaCompiler.compileResponseSchema(payload.schema)
            try requireExplicitTypes(payload.schema, path: "json_schema.schema")
            return FlintResponseFormat(grammar: try FlintJSONGrammar(schema: schema), schema: schema)
        } catch let error as ToolConstraintSchemaError {
            let detail: String
            switch error {
            case .invalid(let message): detail = "invalid: \(message)"
            case .unsupported(let message): detail = "unsupported: \(message)"
            }
            throw MultiModelBatchSchedulerEngineError.invalidToolPayload("Flint response_format is \(detail)")
        }
    }

    /// The shared compiler infers `string` for an untyped leaf, which is the
    /// right render type for a tool argument but would silently narrow an
    /// untyped (accept-anything) output schema. Run after compilation, which
    /// already bounded the depth and validated these subschema positions.
    private static func requireExplicitTypes(_ raw: MLXLMCommon.JSONValue, path: String) throws {
        guard case .object(let object) = raw else { return }
        let typed = (object["type"].map { $0 != .null } ?? false)
            || ["properties", "additionalProperties", "items", "enum", "const"].contains { object[$0] != nil }
        guard typed else {
            throw ToolConstraintSchemaError.unsupported("\(path) has no type and would accept any JSON value")
        }
        if case .object(let properties)? = object["properties"] {
            for (name, child) in properties.sorted(by: { $0.key < $1.key }) {
                try requireExplicitTypes(child, path: "\(path).properties.\(name)")
            }
        }
        if let items = object["items"] { try requireExplicitTypes(items, path: "\(path).items") }
    }

    /// Defense in depth after constrained decoding. A failure, including a
    /// budget that ended before the value completed, is a typed 422 and never
    /// a successful completion. Messages never quote generated content.
    func validate(content: String, finishReason: String) throws {
        let truncated = finishReason == "length"
        guard let value = try? JSONDecoder().decode(MLXLMCommon.JSONValue.self, from: Data(content.utf8)) else {
            throw Self.failure(truncated
                ? "Flint output budget ended before the JSON value was complete"
                : "Flint content is not a single JSON value")
        }
        if truncated {
            // A root number is not self-delimiting: a truncated one still parses.
            switch value {
            case .int, .double:
                throw Self.failure("Flint output budget ended before the JSON value was complete")
            default:
                break
            }
        }
        if let schema {
            guard ToolConstraintValidation.satisfies(value, schema: schema) else {
                throw Self.failure("Flint content does not satisfy the json_schema")
            }
            return
        }
        guard case .object = value else {
            throw Self.failure("Flint json_object content must be a JSON object")
        }
    }

    private static func failure(_ message: String) -> MLXOpenAIServiceError {
        .invalidResponseFormatOutput(message)
    }
}

/// Visible content of one formatted Flint response, retained only until the
/// engine finishes so it can be validated. Never logged or sent to telemetry.
struct FlintResponseFormatOutput {
    private let format: FlintResponseFormat
    private var content = ""

    init(_ format: FlintResponseFormat) { self.format = format }

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
