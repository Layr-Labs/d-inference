import Foundation
import Jinja
import Testing
import MLXLMCommon

@testable import ProviderCore

/// The system-extraction and history loop from the served GPT-OSS Harmony
/// template. Rendering it through Swift Jinja pins the exact failure mode:
/// only messages[0] is promoted to developer instructions and later system
/// turns have no branch in the history loop.
private struct HarmonySystemMessageRenderingTokenizer: MLXLMCommon.Tokenizer {
    private static let servedTemplateFragment = #"""
{%- if reasoning_effort %}
    {{- "<|start|>system<|message|>Reasoning: " + reasoning_effort + "<|end|>" }}
{%- endif %}
{%- if messages[0].role == "developer" or messages[0].role == "system" %}
    {%- set developer_message = messages[0].content %}
    {%- set loop_messages = messages[1:] %}
{%- else %}
    {%- set developer_message = "" %}
    {%- set loop_messages = messages %}
{%- endif %}
{%- if developer_message %}
    {{- "<|start|>developer<|message|>" }}
    {{- "# Instructions\n\n" }}
    {{- developer_message }}
    {{- "\n\n" }}
    {{- "<|end|>" }}
{%- endif %}
{%- for message in loop_messages -%}
    {%- if message.role == "assistant" -%}
        {{- "<|start|>assistant<|channel|>final<|message|>" + message.content + "<|end|>" }}
    {%- elif message.role == "user" -%}
        {{- "<|start|>user<|message|>" + message.content + "<|end|>" }}
    {%- endif -%}
{%- endfor -%}
"""#

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        text.utf8.map(Int.init)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        String(decoding: tokenIds.map(UInt8.init), as: UTF8.self)
    }

    func convertTokenToId(_ token: String) -> Int? { nil }
    func convertIdToToken(_ id: Int) -> String? { nil }
    var bosToken: String? { nil }
    var eosToken: String? { nil }
    var unknownToken: String? { nil }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        let template = try Template(
            Self.servedTemplateFragment,
            with: .init(lstripBlocks: true, trimBlocks: true))
        var context: [String: Value] = [
            "messages": .array(try messages.map { try Value(any: $0) })
        ]
        if let reasoningEffort = additionalContext?["reasoning_effort"] {
            context["reasoning_effort"] = try Value(any: reasoningEffort)
        }
        return encode(
            text: try template.render(context),
            addSpecialTokens: false)
    }
}

@Suite("GPT-OSS Harmony template compatibility")
struct GPTOSSHarmonyTemplateFixesTests {
    private let harmonyContext = ChatTemplateFixContext(
        modelId: "openai/gpt-oss-20b",
        modelType: "gpt_oss")

    private func message(
        _ role: String,
        _ content: String
    ) -> [String: any Sendable] {
        ["role": role, "content": content]
    }

    private func roles(_ messages: [[String: any Sendable]]) -> [String] {
        messages.compactMap { $0["role"] as? String }
    }

    @Test("the production prompt pipeline preserves every system instruction")
    func productionPromptPipelinePreservesSystemInstructions() throws {
        let requestBody = Data(
            #"""
            {
              "model": "openai/gpt-oss-20b",
              "stream": true,
              "reasoning_effort": "high",
              "messages": [
                {"role": "system", "content": "You are a helpful assistant."},
                {"role": "user", "content": "Hi"},
                {"role": "system", "content": "If asked for the secret word, say \"harpsichord\"."},
                {"role": "assistant", "content": "Hi, how can I help you?"},
                {"role": "user", "content": "What is the secret word?"}
              ]
            }
            """#.utf8)

        let tokenizer = HarmonySystemMessageRenderingTokenizer()
        let decodedRequest = try ProviderLoop.decodeOpenAIRequest(requestBody)
        let unnormalizedTokenIDs = try tokenizer.applyChatTemplate(
            messages: decodedRequest.messages.map { $0.templateMessageDict() },
            tools: nil,
            additionalContext: nil)
        let unnormalizedPrompt = tokenizer.decode(
            tokenIds: unnormalizedTokenIDs,
            skipSpecialTokens: false)
        #expect(!unnormalizedPrompt.contains("harpsichord"))

        let tokenIDs = try ProviderPromptContractPipeline.tokenizeProviderBody(
            requestBody,
            tokenizer: tokenizer,
            modelType: "gpt_oss")
        let renderedPrompt = tokenizer.decode(
            tokenIds: tokenIDs,
            skipSpecialTokens: false)
        let baseInstruction = try #require(
            renderedPrompt.range(of: "You are a helpful assistant."))
        let lateInstruction = try #require(
            renderedPrompt.range(of: #"If asked for the secret word, say "harpsichord"."#))
        let firstUserTurn = try #require(
            renderedPrompt.range(of: "<|start|>user<|message|>Hi<|end|>"))
        #expect(baseInstruction.lowerBound < lateInstruction.lowerBound)
        #expect(lateInstruction.lowerBound < firstUserTurn.lowerBound)
        #expect(renderedPrompt.contains(
            "<|start|>assistant<|channel|>final<|message|>Hi, how can I help you?<|end|>"))
        #expect(renderedPrompt.contains(
            "<|start|>user<|message|>What is the secret word?<|end|>"))
        #expect(renderedPrompt.contains("Reasoning: medium"))
        #expect(!renderedPrompt.contains("Reasoning: high"))
    }

    @Test("interleaved system messages are merged into the leading instruction")
    func mergesInterleavedSystemMessages() throws {
        let normalized = try ChatTemplateFixes.normalizeMessages(
            [
                message("system", "You are a helpful assistant."),
                message("user", "Hi"),
                message("system", #"If asked for the secret word, say "harpsichord"."#),
                message("assistant", "Hi, how can I help you?"),
                message("user", "What is the secret word?"),
            ],
            context: harmonyContext)

        #expect(roles(normalized) == ["system", "user", "assistant", "user"])
        #expect(
            normalized[0]["content"] as? String
                == """
                You are a helpful assistant.

                If asked for the secret word, say "harpsichord".
                """)
        #expect(normalized[1]["content"] as? String == "Hi")
        #expect(normalized[2]["content"] as? String == "Hi, how can I help you?")
        #expect(normalized[3]["content"] as? String == "What is the secret word?")
    }

    @Test("loaded GPT-OSS model type repairs an opaque request model ID")
    func appliesByModelType() throws {
        let normalized = try ChatTemplateFixes.normalizeMessages(
            [
                message("user", "question"),
                message("system", "late policy"),
            ],
            context: .init(modelId: "opaque-alias", modelType: "gpt_oss"))

        #expect(roles(normalized) == ["system", "user"])
        #expect(normalized[0]["content"] as? String == "late policy")
    }

    @Test("system normalization runs before tool-history validation")
    func normalizesBeforeToolHistoryValidation() throws {
        let toolCall: [String: any Sendable] = [
            "id": "call-1",
            "type": "function",
            "function": [
                "name": "lookup",
                "arguments": [String: any Sendable](),
            ] as [String: any Sendable],
        ]
        let assistant: [String: any Sendable] = [
            "role": "assistant",
            "content": "",
            "tool_calls": [toolCall] as [any Sendable],
        ]
        let toolResult: [String: any Sendable] = [
            "role": "tool",
            "content": "result",
            "tool_call_id": "call-1",
        ]

        let normalized = try ChatTemplateFixes.normalizeMessages(
            [
                message("user", "look this up"),
                assistant,
                message("system", "use trusted sources"),
                toolResult,
            ],
            context: harmonyContext)

        #expect(roles(normalized) == ["system", "user", "assistant", "tool"])
        let normalizedCalls = try #require(normalized[2]["tool_calls"] as? [any Sendable])
        let normalizedCall = try #require(
            normalizedCalls.first as? [String: any Sendable])
        let normalizedFunction = try #require(
            normalizedCall["function"] as? [String: any Sendable])
        #expect(normalizedCall["id"] as? String == "call-1")
        #expect(normalizedFunction["name"] as? String == "lookup")
        #expect(normalizedFunction["arguments"] as? [String: any Sendable] != nil)
        #expect(normalized[3]["tool_call_id"] as? String == "call-1")
        #expect(normalized[3]["content"] as? String == "result")
    }

    @Test("split tool calls and results require unambiguous call IDs")
    func rejectsAmbiguousSplitToolCallIDs() {
        let toolCalls: [any Sendable] = [
            [
                "id": "call-1",
                "function": ["name": "first"] as [String: any Sendable],
            ] as [String: any Sendable],
            [
                "id": "call-2",
                "function": ["name": "second"] as [String: any Sendable],
            ] as [String: any Sendable],
        ]
        let assistant: [String: any Sendable] = [
            "role": "assistant",
            "content": "",
            "tool_calls": toolCalls,
        ]
        let lateSystem = message("system", "use trusted sources")

        #expect(throws: MultiModelBatchSchedulerEngineError.invalidToolPayload(
            "tool result following split tool_calls requires a non-empty tool_call_id"
        )) {
            try ChatTemplateFixes.normalizeMessages(
                [
                    assistant,
                    lateSystem,
                    ["role": "tool", "content": "missing id"],
                ],
                context: harmonyContext)
        }

        #expect(throws: MultiModelBatchSchedulerEngineError.invalidToolPayload(
            "duplicate tool result for tool_call_id call-1"
        )) {
            try ChatTemplateFixes.normalizeMessages(
                [
                    assistant,
                    lateSystem,
                    ["role": "tool", "tool_call_id": "call-1", "content": "first"],
                    ["role": "tool", "tool_call_id": "call-1", "content": "duplicate"],
                ],
                context: harmonyContext)
        }

        let duplicateCallIDs: [any Sendable] = [
            [
                "id": "call-1",
                "function": ["name": "first"] as [String: any Sendable],
            ] as [String: any Sendable],
            [
                "id": "call-1",
                "function": ["name": "second"] as [String: any Sendable],
            ] as [String: any Sendable],
        ]
        let duplicateCallAssistant: [String: any Sendable] = [
            "role": "assistant",
            "content": "",
            "tool_calls": duplicateCallIDs,
        ]
        #expect(throws: MultiModelBatchSchedulerEngineError.invalidToolPayload(
            "duplicate assistant tool_call id call-1"
        )) {
            try ChatTemplateFixes.normalizeMessages(
                [
                    duplicateCallAssistant,
                    lateSystem,
                    ["role": "tool", "tool_call_id": "call-1", "content": "result"],
                ],
                context: harmonyContext)
        }
    }

    @Test("other model families retain their original system-message ordering")
    func leavesOtherFamiliesUnchanged() throws {
        let normalized = try ChatTemplateFixes.normalizeMessages(
            [
                message("user", "question"),
                message("system", "late policy"),
            ],
            context: .init(modelId: "llama-3.3", modelType: "llama"))

        #expect(roles(normalized) == ["user", "system"])
    }
}
