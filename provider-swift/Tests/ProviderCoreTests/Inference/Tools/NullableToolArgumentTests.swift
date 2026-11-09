import Foundation
import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore

/// A client's nullable tool parameter (`"type": ["integer", "null"]`) reaches
/// the SDK as OpenAPI 3.0's `{"type": "integer", "nullable": true}`
/// (`ToolSchemaNormalization`). A Qwen 3.5 XML call that passes `null` for it
/// must come out as JSON null and pass validation, not as the string "null",
/// which fails the parameter's type. Production decode, parser and validator
/// over a scripted model frame.
@Suite("Nullable tool arguments")
struct NullableToolArgumentTests {
    private static let modelID = "Qwen3.5-9B"
    private static let modelType = "qwen3_5"

    /// Client schemas for the probe's `p` parameter, as OpenAI clients send
    /// them, with a non-null value of the same parameter.
    private static var shapes: [(label: String, schema: [String: Any], value: String, parsed: MLXLMCommon.JSONValue)] {
        [
            ("integer", ["type": ["integer", "null"]], "42", .int(42)),
            ("integer, anyOf", ["anyOf": [["type": "integer"], ["type": "null"]]], "42", .int(42)),
            ("boolean", ["type": ["boolean", "null"]], "false", .bool(false)),
            ("object", ["type": ["object", "null"], "properties": ["n": ["type": "integer"]]],
             #"{"n":3}"#, .object(["n": .int(3)])),
        ]
    }

    private func request(_ schema: [String: Any]) throws -> OpenAIChatCompletionRequest {
        let body: [String: Any] = [
            "model": Self.modelID,
            "messages": [["role": "user", "content": "Probe it."]],
            "tools": [["type": "function", "function": [
                "name": "probe",
                "parameters": ["type": "object", "properties": ["p": schema]] as [String: Any],
            ] as [String: Any]]],
            "tool_choice": "auto",
        ]
        return try ProviderLoop.decodeOpenAIRequest(
            JSONSerialization.data(withJSONObject: body), modelType: Self.modelType)
    }

    /// The validated arguments of the one call in `text`, a Qwen 3.5 frame.
    private func serve(_ schema: [String: Any], argument text: String) throws -> [String: MLXLMCommon.JSONValue] {
        let request = try request(schema)
        let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: Self.modelType)
        let handler = try #require(try ToolStreamPreparation.makeHandler(
            request: request, prepared: prepared, modelType: Self.modelType, streamToolCalls: false))
        let frame = "<tool_call>\n<function=probe>\n<parameter=p>\n\(text)\n</parameter>\n</function>\n</tool_call>"
        _ = handler.processChunk(frame)
        let calls = handler.finish()
        try ToolConstraintValidation.validate(calls, prepared: prepared)
        return try #require(calls.first?.function.arguments)
    }

    @Test(arguments: shapes.map { $0.label })
    func xmlNullForANullableParameterIsJSONNull(_ label: String) throws {
        let shape = try #require(Self.shapes.first { $0.label == label })
        #expect(try serve(shape.schema, argument: "null")["p"] == .null, "\(label)")
    }

    @Test(arguments: shapes.map { $0.label })
    func aValueForANullableParameterKeepsItsType(_ label: String) throws {
        let shape = try #require(Self.shapes.first { $0.label == label })
        #expect(try serve(shape.schema, argument: shape.value)["p"] == shape.parsed, "\(label)")
    }

    @Test func xmlNullForANonNullableParameterStaysRefused() throws {
        #expect(throws: MultiModelBatchSchedulerEngineError.toolChoiceViolation(
            "tool call arguments do not satisfy the declared schema")) {
            _ = try serve(["type": "integer"], argument: "null")
        }
    }
}
