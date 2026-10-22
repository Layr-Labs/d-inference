// Copyright © 2026 Eigen Labs.

import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore

/// Exact Flint installs its native sampler constraint for every request, so
/// required/named prompts keep the caller's turns instead of the generic
/// tool-only instruction. Selection is by verified artifact type, never ID.
@Suite("Flint native tool prompt ownership")
struct FlintToolChoicePromptPolicyTests {
    private static let forcingFragment = "Your entire response must"

    @Test(arguments: ["RecursiveSI/flint-int4", "catalog-alias"])
    func requiredAndNamedPreserveMessagesAndEnforcement(modelID: String) throws {
        for choice in [OpenAIToolChoice.mode(.required), .function(name: "second")] {
            for parallel: Bool? in [nil, false, true] {
                var input = request(choice)
                input.model = modelID
                input.parallelToolCalls = parallel
                let native = try ToolChoicePromptPolicy.prepare(input, modelType: "flint")
                let legacy = try ToolChoicePromptPolicy.prepare(input)
                #expect(native.messages == input.messages)
                #expect(legacy.messages != input.messages)
                #expect(native.requiresToolCall)
                #expect(native.mode == legacy.mode)
                #expect(native.tools == legacy.tools)
                #expect(native.allowedToolNames == legacy.allowedToolNames)
                #expect(native.compiledTools?.count == legacy.compiledTools?.count)
                #expect(native.allowsParallelCalls == (parallel ?? true))
            }
        }
        let named = try ToolChoicePromptPolicy.prepare(request(.function(name: "second")), modelType: "flint")
        #expect(named.tools?.map(\.function.name) == ["second"])
        #expect(named.allowedToolNames == ["second"])
        let required = try ToolChoicePromptPolicy.prepare(request(.mode(.required)), modelType: "flint")
        #expect(required.tools?.map(\.function.name) == ["first", "second"])
        #expect(required.allowedToolNames == ["first", "second"])
    }

    @Test(arguments: [nil, "Flint", " flint ", "flint_mtp", "qwen4_exp", "llama"] as [String?])
    func nearMissTypesRetainLegacyPrompt(modelType: String?) throws {
        for choice in [OpenAIToolChoice.mode(.required), .function(name: "second")] {
            let input = request(choice)
            let legacy = try ToolChoicePromptPolicy.prepare(input)
            let actual = try ToolChoicePromptPolicy.prepare(input, modelType: modelType)
            #expect(actual.messages == legacy.messages)
            #expect(actual.messages != input.messages)
            #expect(actual.tools == legacy.tools)
        }
    }

    @Test func autoNoneAndInvalidChoicesRetainTheirContracts() throws {
        for choice in [OpenAIToolChoice.mode(.auto), .mode(.none)] {
            let input = request(choice)
            let legacy = try ToolChoicePromptPolicy.prepare(input)
            let actual = try ToolChoicePromptPolicy.prepare(input, modelType: "flint")
            #expect(actual.messages == legacy.messages)
            #expect(actual.tools == legacy.tools)
            #expect(actual.mode == legacy.mode)
        }
        var invalid: [OpenAIChatCompletionRequest] = [request(.function(name: "missing"))]
        for tools in [nil, [], [OpenAITool(function: .init(name: "bad name"))],
            [OpenAITool(function: .init(name: "first")), OpenAITool(function: .init(name: "first"))],
            [OpenAITool(function: .init(name: "first", parameters: .object(["type": .string("string")])))],
        ] as [[OpenAITool]?] {
            var input = request(.mode(.required))
            input.tools = tools
            invalid.append(input)
        }
        for input in invalid {
            #expect(throws: MultiModelBatchSchedulerEngineError.self) {
                try ToolChoicePromptPolicy.prepare(input, modelType: "flint")
            }
        }
    }

    @Test func renderedNamedPromptKeepsOriginalTurnsAndSelectedDeclaration() throws {
        let template = FlintTemplateReplayTests()
        var input = request(.function(name: "second"))
        input.parallelToolCalls = false
        let prompt = try template.render(input, modelType: "flint")
        #expect(!prompt.contains(Self.forcingFragment))
        #expect(prompt.hasPrefix("<|system|>Keep the original policy.<|system|>\n# Tools"))
        // The pinned template strips reasoning tags from caller text.
        #expect(prompt.hasSuffix("<|user|>Copy literal data and backslash \\ exactly.<|assistant|>"))
        #expect(prompt.contains(#""name":"second""#))
        #expect(!prompt.contains(#""name":"first""#))
        #expect(try template.render(input, modelType: nil).contains(Self.forcingFragment))
    }

    private func request(_ choice: OpenAIToolChoice) -> OpenAIChatCompletionRequest {
        OpenAIChatCompletionRequest(model: "RecursiveSI/flint-int4",
            messages: [.init(role: .system, content: .text("Keep the original policy.")),
                .init(role: .user, content: .text("Copy literal <think>data</think> and backslash \\ exactly."))],
            tools: ["first", "second"].map { OpenAITool(function: .init(name: $0)) }, toolChoice: choice)
    }
}
