// Live end-to-end coverage for the Jinja null/Optional sanitizer, exercised
// against a REAL gpt-oss model through the same serving path ProviderLoop uses
// (MLXOpenAIService over MultiModelBatchSchedulerEngine, where the sanitizer is
// applied before applyChatTemplate).
//
// gpt-oss / Harmony is the model the fix targets: its template routinely renders
// tools + tool-call history, which is where un-normalized JSON null leaves used
// to throw "Cannot convert value of type … to Jinja Value" (a hard 500). This
// proves (a) a normal request still infers and (b) a request carrying null leaves
// in both a tool schema and an assistant tool-call's arguments now renders,
// generates, and completes instead of crashing.
//
// Gated by DARKBLOOM_LIVE_MLX_TESTS=1 and requires
// `mlx-community/gpt-oss-20b-MXFP4-Q8` in the local HuggingFace cache. Skips
// cleanly (recorded as a warning) when either precondition is unmet.

import Foundation
import Testing
import MLX
import MLXLLM
import MLXLMCommon
import MLXLMServer
@testable import ProviderCore

private let gptOssModelID = "mlx-community/gpt-oss-20b-MXFP4-Q8"

@Suite("Jinja null sanitizer (live gpt-oss)", .serialized)
struct JinjaSanitizationLiveTests {

    /// Drain a stream into (content, reasoning, completionTokens, errorFrame).
    private func drain(
        _ stream: AsyncThrowingStream<String, Error>
    ) async throws -> (content: String, completionTokens: Int) {
        var content = ""
        var completionTokens = 0
        for try await frame in stream {
            if frame == ServerSentEventEncoder.done { continue }
            guard let parsed = ProviderLoop.parseStreamChunk(frame) else { continue }
            if let c = parsed.contentDelta { content += c }
            if let usage = parsed.usage { completionTokens = usage.completionTokens }
        }
        return (content, completionTokens)
    }

    @Test(
        "normal + null-bearing tool requests both infer end-to-end",
        .enabled(if: LiveInferenceFixtures.liveTestsEnabled)
    )
    func nullBearingToolRequestInfers() async throws {
        let loaded: (scheduler: BatchScheduler, container: ModelContainer, modelDirectory: URL)
        do {
            loaded = try await LiveInferenceFixtures.loadScheduler(
                modelID: gptOssModelID,
                maxConcurrentRequests: 1,
                memoryBudgetBytes: 24 * 1024 * 1024 * 1024
            )
        } catch let skip as LiveFixtureSkip {
            withKnownIssue("skipped: \(skip)") { Issue.record("\(skip)") }
            return
        }
        let scheduler = loaded.scheduler
        defer { Task { await scheduler.unloadModel() } }
        let tokenizer: TokenizerHandle = await loaded.container.perform { ctx in
            TokenizerHandle(ctx.tokenizer)
        }

        // Wire the engine exactly as ProviderLoop does.
        let engine = MultiModelBatchSchedulerEngine(
            registryProvider: { @Sendable in
                [gptOssModelID: .init(scheduler: scheduler, tokenizer: tokenizer, modelType: "gpt_oss")]
            },
            ensureLoaded: { _ in },
            reserveModel: { _ in },
            releaseModel: { _ in },
            defaultMaxTokens: 256
        )
        let service = MLXOpenAIService(engine: engine)

        // (a) Non-regression: a plain request with no tools / nulls still infers.
        let plain = OpenAIChatCompletionRequest(
            model: gptOssModelID,
            messages: [.init(role: .user, content: .text("Reply with the single word: pong."))],
            reasoningParser: .harmony,
            stream: true,
            temperature: 0.0,
            maxTokens: 64,
            streamOptions: .init(includeUsage: true, continuousUsageStats: nil)
        )
        let plainResult = try await drain(try await service.streamChatCompletionFrames(request: plain))
        #expect(plainResult.completionTokens > 0)
        print("[live] plain: completion_tokens=\(plainResult.completionTokens) content=\(plainResult.content.prefix(60))")

        // (b) The fix: a tool schema with null leaves (null enum element + null
        // default) AND an assistant tool-call message whose decoded arguments
        // carry a JSON null. Pre-fix this threw at applyChatTemplate (500);
        // post-fix the nulls are stripped and the request renders + generates.
        let tools: [OpenAITool] = [
            OpenAITool(
                type: "function",
                function: OpenAIFunctionDefinition(
                    name: "get_weather",
                    description: "Get the weather for a city",
                    parameters: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "city": .object(["type": .string("string")]),
                            "unit": .object([
                                "type": .string("string"),
                                "enum": .array([.string("celsius"), .string("fahrenheit"), .null]),
                                "default": .null,
                            ]),
                        ]),
                        "required": .array([.string("city")]),
                    ])
                )
            )
        ]
        let toolMessages: [OpenAIChatMessage] = [
            .init(role: .user, content: .text("What's the weather in SF?")),
            .init(
                role: .assistant,
                content: .null,
                toolCalls: [
                    OpenAIToolCall(
                        id: "call_0001",
                        type: "function",
                        function: .init(name: "get_weather", arguments: #"{"city":"SF","unit":null}"#)
                    )
                ]
            ),
        ]
        let toolReq = OpenAIChatCompletionRequest(
            model: gptOssModelID,
            messages: toolMessages,
            tools: tools,
            reasoningParser: .harmony,
            stream: true,
            temperature: 0.0,
            maxTokens: 128,
            streamOptions: .init(includeUsage: true, continuousUsageStats: nil)
        )

        // The decisive assertion: this does NOT throw (pre-fix it threw the
        // Jinja conversion error) and the model actually produces tokens.
        let toolResult = try await drain(try await service.streamChatCompletionFrames(request: toolReq))
        #expect(toolResult.completionTokens > 0)
        print("[live] null-tool: completion_tokens=\(toolResult.completionTokens) content=\(toolResult.content.prefix(80))")
    }
}
