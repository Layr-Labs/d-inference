// Copyright © 2026 Eigen Labs.
import Foundation
import MLXLMServer
import Testing

@testable import ProviderCore

@Suite("Native Qwen4 tool prompt ownership")
struct Qwen4ToolChoicePromptPolicyTests {
    @Test func requiredAndNamedPreserveMessagesAndEnforcement() throws {
        for choice in [OpenAIToolChoice.mode(.required), .function(name: "second")] {
            for parallel: Bool? in [nil, false, true] {
                for thinking in [false, true] {
                    var input = request(choice)
                    input.parallelToolCalls = parallel
                    input.reasoning = .init(enabled: thinking)
                    let native = try ToolChoicePromptPolicy.prepare(input, modelType: "qwen4_exp")
                    let legacy = try ToolChoicePromptPolicy.prepare(input)
                    #expect(native.messages == input.messages)
                    #expect(native.messages != legacy.messages)
                    #expect(native.requiresToolCall)
                    #expect(native.mode == legacy.mode)
                    #expect(native.tools == legacy.tools)
                    #expect(native.allowedToolNames == legacy.allowedToolNames)
                    #expect(native.compiledTools?.count == legacy.compiledTools?.count)
                    #expect(native.allowsParallelCalls == (parallel ?? true))
                }
            }
        }
    }

    @Test func otherIdentitiesAndMediaRetainLegacyPrompt() throws {
        for (model, type) in [
            (Qwen4SupportPolicy.ownedModelID, nil),
            (Qwen4SupportPolicy.ownedModelID, "qwen3_5"),
            (Qwen4SupportPolicy.ownedModelID, "qwen4_exp_text"),
            ("other-qwen4", "qwen4_exp"), ("gemma-4", "gemma4"), ("nemotron", "nemotron_h"),
        ] as [(String, String?)] {
            var input = request(.mode(.required))
            input.model = model
            let legacy = try ToolChoicePromptPolicy.prepare(input)
            let actual = try ToolChoicePromptPolicy.prepare(input, modelType: type)
            #expect(actual.messages == legacy.messages)
            #expect(actual.tools == legacy.tools)
        }
        for kind in ["image_url", "video_url"] {
            let body: [String: Any] = ["model": Qwen4SupportPolicy.ownedModelID,
                "messages": [["role": "user", "content": [["type": kind, kind: ["url": "data:image/png;base64,AA=="]]]]],
                "tools": [["type": "function", "function": ["name": "describe"]]], "tool_choice": "required"]
            let input = try ProviderLoop.decodeOpenAIRequest(JSONSerialization.data(withJSONObject: body))
            #expect(MediaIngest.hasMedia(input))
            let legacy = try ToolChoicePromptPolicy.prepare(input)
            let actual = try ToolChoicePromptPolicy.prepare(input, modelType: "qwen4_exp")
            #expect(actual.messages == legacy.messages)
        }
    }

    @Test func autoNoneAndInvalidChoicesRetainTheirContracts() throws {
        for choice in [OpenAIToolChoice.mode(.auto), .mode(.none)] {
            let input = request(choice)
            let legacy = try ToolChoicePromptPolicy.prepare(input)
            let actual = try ToolChoicePromptPolicy.prepare(input, modelType: "qwen4_exp")
            #expect(actual.messages == legacy.messages)
            #expect(actual.tools == legacy.tools)
            #expect(actual.mode == legacy.mode)
        }
        #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            try ToolChoicePromptPolicy.prepare(request(.function(name: "missing")), modelType: "qwen4_exp")
        }
        var missing = request(.mode(.required))
        missing.tools = nil
        #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            try ToolChoicePromptPolicy.prepare(missing, modelType: "qwen4_exp")
        }
    }

    private func request(_ choice: OpenAIToolChoice) -> OpenAIChatCompletionRequest {
        OpenAIChatCompletionRequest(model: Qwen4SupportPolicy.ownedModelID,
            messages: [.init(role: .system, content: .text("Keep the original policy.")),
                .init(role: .user, content: .text("Copy literal <think>data</think> and backslash \\ exactly."))],
            tools: ["first", "second"].map { OpenAITool(function: .init(name: $0)) }, toolChoice: choice)
    }
}
