// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore

/// Gemma 4 sometimes writes a string argument without its `<|"|>` marker. As
/// in vLLM, the parameter's schema decides how such a bare value reads: a
/// string parameter keeps the text (`01000`, not 1000), streamed or not, and a
/// `strict` tool accepts the call.
@Suite("Gemma bare argument typing")
struct GemmaArgumentTypingTests {
    private static let tools = """
        [{"type":"function","function":{"name":"set_address","parameters":{"type":"object",
          "properties":{"zip":{"type":"string"},"version":{"type":"string"},"count":{"type":"integer"}},
          "required":["zip"]}}}]
        """
    private static let call = "<|tool_call>call:set_address{zip:01000,version:1.10,count:3}<tool_call|>"
    private static let expected: [String: MLXLMCommon.JSONValue] =
        ["zip": .string("01000"), "version": .string("1.10"), "count": .int(3)]

    private static func request(strict: Bool) throws -> OpenAIChatCompletionRequest {
        var request = OpenAIChatCompletionRequest(
            model: "gemma-4-26b-qat-4bit",
            messages: [.init(role: .user, content: .text("Set the address."))],
            tools: try JSONDecoder().decode([OpenAITool].self, from: Data(tools.utf8)).map { tool in
                var tool = tool
                if strict { tool.function.strict = true }
                return tool
            },
            stream: true, streamOptions: .init(includeUsage: true))
        request.streamToolCallDeltas = true
        return request
    }

    @Test("a streamed call keeps a string parameter's bare text", arguments: [false, true])
    func streamedCallKeepsTheText(strict: Bool) throws {
        let request = try Self.request(strict: strict)
        let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: "gemma4")
        let handler = try ToolStreamPreparation.makeHandler(
            request: request, prepared: prepared, modelType: "gemma4", streamToolCalls: true)
        #expect(handler?.streamsCalls == true)
        var router = NativeToolStreamRouter(handler: handler, requiresToolCall: false, nativePrefix: nil,
            streamedCalls: prepared)
        var events: [MLXServerGenerationEvent] = []
        for character in Self.call { events += try router.process(String(character)) }
        events += try router.finishText()
        events += try router.finishToolCalls(truncated: false)
        let deltas = events.compactMap { if case .toolCallDelta(let delta) = $0 { delta } else { nil } }
        let completed = try #require(deltas.last?.completed)
        #expect(completed.function.arguments == Self.expected)
        // The streamed fragments spell the same arguments.
        let streamed = deltas.map(\.arguments).joined()
        #expect(try JSONDecoder().decode([String: MLXLMCommon.JSONValue].self, from: Data(streamed.utf8))
            == Self.expected)
        try ToolConstraintValidation.validate(router.completedToolCalls, prepared: prepared)
    }

    @Test("a call returned in one piece keeps a string parameter's bare text")
    func completeCallKeepsTheText() throws {
        let request = try Self.request(strict: true)
        let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: "gemma4")
        let handler = try #require(try ToolStreamPreparation.makeHandler(
            request: request, prepared: prepared, modelType: "gemma4", streamToolCalls: false))
        #expect(!handler.streamsCalls)
        _ = handler.processChunk(Self.call)
        let calls = handler.finish()
        #expect(calls.map(\.function.arguments) == [Self.expected])
        try ToolConstraintValidation.validate(calls, prepared: prepared)
    }

    /// The parse reads the schema Gemma is shown, after ingress
    /// `ToolSchemaNormalization`: a property declared without a type (`{}`
    /// or a description only) is shown as STRING, and a union as its first
    /// member's type, so their bare values follow that type. vLLM, reading
    /// the caller's schema, keeps 5, true and 3 there. Each result here is
    /// valid for the caller's schema, and the `strict` validator accepts it.
    @Test("an untyped property or a string-first union reads a bare value as the type Gemma is shown")
    func normalizedSchemasDecideBareValues() throws {
        let body = Data(#"""
            {"model":"gemma-4-26b-qat-4bit","messages":[{"role":"user","content":"Store it."}],"stream":true,
             "tools":[{"type":"function","function":{"name":"store","strict":true,"parameters":{"type":"object",
               "properties":{"any":{},"described":{"description":"Any value"},
                 "either":{"anyOf":[{"type":"string"},{"type":"integer"}]},
                 "number_first":{"anyOf":[{"type":"integer"},{"type":"string"}]},
                 "count":{"type":"integer"}}}}}]}
            """#.utf8)
        let request = try ProviderLoop.decodeOpenAIRequest(body)
        let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: "gemma4")
        let handler = try #require(try ToolStreamPreparation.makeHandler(
            request: request, prepared: prepared, modelType: "gemma4", streamToolCalls: false))
        _ = handler.processChunk(
            "<|tool_call>call:store{any:5,described:true,either:3,number_first:3,count:3}<tool_call|>")
        let calls = handler.finish()
        #expect(calls.map(\.function.arguments) == [[
            "any": .string("5"), "described": .string("true"), "either": .string("3"),
            "number_first": .int(3), "count": .int(3),
        ]])
        try ToolConstraintValidation.validate(calls, prepared: prepared)
    }
}
