// Copyright © 2026 Eigen Labs Inc.

import Foundation
import MLXLMServer
import Testing

@testable import ProviderCore

/// Regression tests for #249: `templateMessageDict()` must hand the chat
/// template a tool-call `arguments` mapping, not a JSON string.
struct ToolCallTemplateArgumentsTests {
    private func assistantWithToolCall(arguments: String) -> OpenAIChatMessage {
        OpenAIChatMessage(
            role: .assistant,
            content: .text(""),
            toolCalls: [
                OpenAIToolCall(
                    id: "call_1",
                    function: .init(name: "run_terminal", arguments: arguments)
                )
            ]
        )
    }

    private func renderedArguments(_ message: OpenAIChatMessage) throws -> any Sendable {
        let dict = message.templateMessageDict()
        let toolCalls = try #require(dict["tool_calls"] as? [[String: any Sendable]])
        let function = try #require(toolCalls.first?["function"] as? [String: any Sendable])
        return try #require(function["arguments"])
    }

    @Test("templateMessageDict decodes JSON-string arguments into a mapping")
    func decodesArgumentsIntoMapping() throws {
        let arguments = try renderedArguments(
            assistantWithToolCall(arguments: #"{"command":"ls -la"}"#))
        let mapping = try #require(arguments as? [String: any Sendable])
        #expect(mapping["command"] as? String == "ls -la")
        #expect(!(arguments is String))
    }

    @Test("templateMessageDict keeps non-JSON arguments as a string")
    func keepsNonJSONArgumentsAsString() throws {
        let arguments = try renderedArguments(
            assistantWithToolCall(arguments: "not json"))
        #expect(arguments as? String == "not json")
    }
}
