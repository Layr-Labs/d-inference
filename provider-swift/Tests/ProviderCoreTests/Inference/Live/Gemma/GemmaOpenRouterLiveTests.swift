// Copyright © 2026 Eigen Labs.

import Foundation
import MLX
import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore

@Suite("Gemma OpenRouter tool compatibility (live)", .serialized)
struct GemmaOpenRouterLiveTests {
    @Test(
        "reasoning and tool_choice matrix",
        .enabled(if: LiveInferenceFixtures.gemmaTestsEnabled)
    )
    func toolChoiceMatrix() async throws {
        let loaded: LiveInferenceFixtures.LoadedBridge
        let maxTokens = 768
        do {
            loaded = try await LiveInferenceFixtures.loadBridge(
                modelID: LiveInferenceFixtures.gemmaModelID,
                maxConcurrentRequests: 1,
                memoryBudgetBytes: 64 * 1024 * 1024 * 1024,
                defaultMaxTokens: maxTokens)
        } catch let skip as LiveFixtureSkip {
            Issue.record("skipping: \(skip)")
            return
        }
        let bridge = loaded.bridge
        defer {
            Task {
                await bridge.shutdown()
                MLX.Memory.clearCache()
            }
        }
        let tokenizer: TokenizerHandle = await loaded.container.perform { context in
            TokenizerHandle(context.tokenizer)
        }
        let engine = MultiModelBatchSchedulerEngine(
            registryProvider: { @Sendable in
                [LiveInferenceFixtures.gemmaModelID: .init(
                    tokenizer: tokenizer,
                    modelType: "gemma4",
                    engineV2Bridge: bridge)]
            },
            defaultMaxTokens: maxTokens)
        let service = MLXOpenAIService(engine: engine, defaultReasoningParser: .gemma4)

        for reasoningEnabled in [false, true] {
            for scenario in scenarios(reasoningEnabled: reasoningEnabled) {
                try await assertScenario(scenario, reasoningEnabled: reasoningEnabled, service: service)
            }
        }
    }

    private func assertScenario(
        _ scenario: Scenario,
        reasoningEnabled: Bool,
        service: MLXOpenAIService
    ) async throws {
        var calls: [OpenAIToolCall] = []
        var content = ""
        var reasoning = ""
        var finishReason = ""
        let frames = try await service.streamChatCompletionFrames(request: scenario.request)
        for try await frame in frames {
            guard let parsed = ProviderLoop.parseStreamChunk(frame) else { continue }
            if let delta = parsed.contentDelta { content += delta }
            if let delta = parsed.reasoningDelta { reasoning += delta }
            if let delta = parsed.toolCallsDelta { calls.append(contentsOf: delta) }
            if let reason = parsed.finishReason { finishReason = reason }
        }

        print(
            "[openrouter-live] \(scenario.name) reasoning=\(reasoningEnabled) "
                + "calls=\(calls.map(\.function.name)) finish=\(finishReason) "
                + "reasoning_chars=\(reasoning.count) content=\(content.prefix(100))")

        guard let expectedTool = scenario.expectedTool else {
            #expect(calls.isEmpty)
            #expect(finishReason == "stop" || finishReason == "length")
            return
        }

        let call = try #require(
            calls.first,
            "\(scenario.name) reasoning=\(reasoningEnabled) did not emit a tool call")
        #expect(calls.count == 1)
        #expect(call.function.name == expectedTool)
        #expect(finishReason == "tool_calls")
        let arguments = try #require(
            try JSONSerialization.jsonObject(
                with: Data(call.function.arguments.utf8)) as? [String: Any])
        if expectedTool == "get_current_weather" {
            #expect(arguments["location"] as? String == "Boston, MA")
            #expect(arguments["unit"] as? String == "fahrenheit")
        } else {
            #expect((arguments["expression"] as? String)?.isEmpty == false)
        }
    }

    private struct Scenario {
        let name: String
        let request: OpenAIChatCompletionRequest
        let expectedTool: String?
    }

    private func scenarios(reasoningEnabled: Bool) -> [Scenario] {
        let weatherPrompt = "What is the weather like in Boston, MA in fahrenheit?"
        let weatherTool = OpenAITool(
            function: OpenAIFunctionDefinition(
                name: "get_current_weather",
                description: "Get the current weather in a given location",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "location": .object([
                            "type": .string("string"),
                            "description": .string("The city and state, e.g. San Francisco, CA"),
                        ]),
                        "unit": .object([
                            "type": .string("string"),
                            "enum": .array([.string("celsius"), .string("fahrenheit")]),
                        ]),
                    ]),
                    "additionalProperties": .bool(false),
                    "required": .array([.string("location"), .string("unit")]),
                ])))
        let calculateTool = OpenAITool(
            function: OpenAIFunctionDefinition(
                name: "calculate",
                description: "Perform a mathematical calculation",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "expression": .object([
                            "type": .string("string"),
                            "description": .string("The mathematical expression to evaluate, e.g. 2 + 2"),
                        ])
                    ]),
                    "additionalProperties": .bool(false),
                    "required": .array([.string("expression")]),
                ])))

        func request(
            prompt: String,
            tools: [OpenAITool],
            choice: OpenAIToolChoice?
        ) -> OpenAIChatCompletionRequest {
            OpenAIChatCompletionRequest(
                model: LiveInferenceFixtures.gemmaModelID,
                messages: [.init(role: .user, content: .text(prompt))],
                tools: tools,
                toolChoice: choice,
                reasoningParser: .gemma4,
                reasoning: .init(enabled: reasoningEnabled),
                stream: true,
                maxTokens: reasoningEnabled ? 768 : 192)
        }

        return [
            Scenario(
                name: "implicit",
                request: request(prompt: weatherPrompt, tools: [weatherTool], choice: nil),
                expectedTool: "get_current_weather"),
            Scenario(
                name: "auto",
                request: request(
                    prompt: weatherPrompt, tools: [weatherTool], choice: .mode(.auto)),
                expectedTool: "get_current_weather"),
            Scenario(
                name: "none",
                request: request(
                    prompt: weatherPrompt, tools: [weatherTool], choice: .mode(.none)),
                expectedTool: nil),
            Scenario(
                name: "required",
                request: request(
                    prompt: "Hi, how are you?", tools: [calculateTool], choice: .mode(.required)),
                expectedTool: "calculate"),
            Scenario(
                name: "named",
                request: request(
                    prompt: weatherPrompt,
                    tools: [weatherTool, calculateTool],
                    choice: .function(name: "calculate")),
                expectedTool: "calculate"),
        ]
    }
}
