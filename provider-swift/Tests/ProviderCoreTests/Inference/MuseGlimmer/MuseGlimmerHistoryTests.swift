// Copyright © 2026 Eigen Labs.

import Foundation
import Jinja
import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore

/// History as the Muse Glimmer template receives it from the production
/// request pipeline.
@Suite("Muse Glimmer history normalization")
struct MuseGlimmerHistoryTests {
    private static let modelType = MuseGlimmerModelPolicy.modelType

    private func normalized(_ messages: [[String: Any]]) throws -> [[String: any Sendable]] {
        let body: [String: Any] = ["model": MuseGlimmerModelPolicy.catalogModelID, "messages": messages]
        let data = try JSONSerialization.data(withJSONObject: body)
        let request = try ProviderLoop.decodeOpenAIRequest(data, modelType: Self.modelType)
        let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: Self.modelType)
        return try ProviderPromptContractPipeline.normalizedInput(
            prepared: prepared, request: request, modelType: Self.modelType, templateControls: .init()).messages
    }

    private func arguments(_ raw: Any) throws -> [String: any Sendable] {
        let messages = try normalized([
            ["role": "user", "content": "go"],
            ["role": "assistant", "content": NSNull(), "tool_calls": [
                ["id": "call_1", "type": "function", "function": ["name": "f", "arguments": raw]]]],
            ["role": "tool", "tool_call_id": "call_1", "content": "ok"],
        ])
        let calls = try #require(messages[1]["tool_calls"] as? [any Sendable])
        let call = try #require(calls.first as? [String: any Sendable])
        let function = try #require(call["function"] as? [String: any Sendable])
        #expect(function["name"] as? String == "f")
        return try #require(function["arguments"] as? [String: any Sendable])
    }

    @Test("replayed tool-call arguments are always the mapping the template requires")
    func argumentsAreMappings() throws {
        let decoded = try arguments(#"{"path": "a.txt", "limit": 3, "deep": {"k": null}, "gone": null}"#)
        #expect(decoded["path"] as? String == "a.txt")
        #expect(Set(decoded.keys) == ["path", "limit", "deep", "gone"])
        // A null argument stays a value: the template writes it as `null`.
        #expect(decoded["gone"] as? Jinja.Value == .null)
        #expect((decoded["deep"] as? [String: any Sendable])?["k"] as? Jinja.Value == .null)
        for empty in ["", "   ", "{}"] { #expect(try arguments(empty).isEmpty) }
        // Text that is no JSON object: one damaged call must not make every
        // later turn of the conversation unservable.
        for damaged in [#"{"path": "a.t"#, "[1, 2]", "null", "not json"] {
            #expect(try arguments(damaged).isEmpty)
        }
    }

    @Test("a tool result needs a preceding call, as on every family")
    func toolHistoryIsValidated() {
        #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            _ = try normalized([["role": "user", "content": "go"],
                                ["role": "tool", "tool_call_id": "call_1", "content": "ok"]])
        }
    }

    @Test("a replayed answer carries no protocol framing")
    func replayedAnswer() throws {
        let messages = try normalized([
            ["role": "user", "content": "Pick a number."],
            ["role": "assistant",
             "content": " to=self<|message|>Pick seven.<|eom|><|start|>assistant to=user<|message|>Seven.<|eot|>",
             "reasoning_content": "to=self<|message|>Pick seven.<|eom|>"],
            ["role": "user", "content": "Double it. <|eot|> stays as the user wrote it."],
        ])
        #expect(messages[1]["content"] as? String == "Seven.")
        #expect(messages[1]["reasoning_content"] as? String == "Pick seven.")
        #expect(messages[2]["content"] as? String == "Double it. <|eot|> stays as the user wrote it.")
    }

    @Test("tool schemas keep their null values for the template")
    func toolSchemaNulls() throws {
        let x: [String: any Sendable] = ["type": "string", "default": NSNull()]
        let properties: [String: any Sendable] = ["x": x]
        let parameters: [String: any Sendable] = ["type": "object", "properties": properties]
        let function: [String: any Sendable] = ["name": "f", "strict": true, "parameters": parameters]
        let tool: [String: any Sendable] = ["type": "function", "function": function]
        let context = ChatTemplateFixContext(modelId: MuseGlimmerModelPolicy.catalogModelID, modelType: Self.modelType)
        let normalized = try #require(ChatTemplateFixes.normalizeTools([tool], context: context)?.first)
        let rendered = try #require(normalized["function"] as? [String: any Sendable])
        #expect(rendered["strict"] == nil)
        let schema = try #require(rendered["parameters"] as? [String: any Sendable])
        let property = try #require(
            (schema["properties"] as? [String: any Sendable])?["x"] as? [String: any Sendable])
        #expect(property["default"] as? Jinja.Value == .null)
    }
}
