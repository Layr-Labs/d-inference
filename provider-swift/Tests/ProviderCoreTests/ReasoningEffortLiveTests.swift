// Live end-to-end coverage for the reasoning_effort + reasoning_tokens
// work, exercised against a REAL gpt-oss model through the same serving
// path ProviderLoop uses (MLXOpenAIService over
// MultiModelBatchSchedulerEngine).
//
// Gated by DARKBLOOM_LIVE_MLX_TESTS=1 and requires
// `mlx-community/gpt-oss-20b-MXFP4-Q8` in the local HuggingFace cache.
// Tests skip cleanly (recorded as a warning) when either precondition is
// unmet, so CI on a model-less runner stays green.

import Foundation
import Testing
import MLX
import MLXLLM
import MLXLMCommon
import MLXLMServer
@testable import ProviderCore

private let gptOssModelID = "mlx-community/gpt-oss-20b-MXFP4-Q8"

// `.serialized`: both tests load the same multi-GB model and race on the
// one-time metallib colocation; running them sequentially avoids that and
// keeps peak memory to a single model.
@Suite("reasoning_effort + reasoning_tokens (live gpt-oss)", .serialized)
struct ReasoningEffortLiveTests {

    /// Fix #1, decisive: the REAL gpt-oss harmony template reads the
    /// `reasoning_effort` value we inject via `additionalContext` and
    /// renders the matching `Reasoning: <effort>` system directive. This
    /// is the exact API path `MultiModelBatchSchedulerEngine` uses.
    @Test(
        "harmony template renders the injected reasoning_effort",
        .enabled(if: LiveInferenceFixtures.liveTestsEnabled)
    )
    func templateHonorsReasoningEffort() async throws {
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

        let messages: [[String: any Sendable]] = [
            ["role": "user", "content": "What is 2+2?"]
        ]

        func renderedPrompt(effort: String?) throws -> String {
            let ctx: [String: any Sendable]? = effort.map { ["reasoning_effort": $0] }
            let tokens = try tokenizer.inner.applyChatTemplate(
                messages: messages, tools: nil, additionalContext: ctx
            )
            return tokenizer.inner.decode(tokenIds: tokens, skipSpecialTokens: false)
        }

        let high = try renderedPrompt(effort: "high")
        let low = try renderedPrompt(effort: "low")
        let defaulted = try renderedPrompt(effort: nil)

        #expect(high.contains("Reasoning: high"))
        #expect(low.contains("Reasoning: low"))
        // No reasoning_effort supplied → template's built-in default.
        #expect(defaulted.contains("Reasoning: medium"))
        // And the value actually changes the prompt.
        #expect(high != low)
    }

    /// Fix #1 + #2, integration: a real generation through the provider
    /// serving path with reasoningEffort set produces analysis-channel
    /// reasoning content, and our token accounting yields a non-zero,
    /// clamped reasoning_tokens that injects cleanly into the usage frame.
    @Test(
        "live generation reports accurate reasoning_tokens",
        .enabled(if: LiveInferenceFixtures.liveTestsEnabled)
    )
    func generationReportsReasoningTokens() async throws {
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

        // Wire the engine exactly as ProviderLoop does, with the
        // reasoning_effort threaded through.
        let engine = MultiModelBatchSchedulerEngine(
            registryProvider: { @Sendable in
                [gptOssModelID: .init(scheduler: scheduler, tokenizer: tokenizer, modelType: "gpt_oss")]
            },
            ensureLoaded: { _ in },
            reserveModel: { _ in },
            releaseModel: { _ in },
            defaultMaxTokens: 256,
            reasoningEffort: "high"
        )
        let service = MLXOpenAIService(engine: engine)

        let request = OpenAIChatCompletionRequest(
            model: gptOssModelID,
            messages: [
                .init(role: .user, content: .text("If a train travels 60 miles in 1.5 hours, what is its average speed? Think briefly."))
            ],
            reasoningParser: .harmony,
            stream: true,
            temperature: 0.0,
            maxTokens: 200,
            streamOptions: .init(includeUsage: true, continuousUsageStats: nil)
        )

        let stream = try await service.streamChatCompletionFrames(request: request)

        // Re-run the exact accounting ProviderLoop performs over the frames.
        var reasoningText = ""
        var contentText = ""
        var completionTokens = 0
        var usageFrame: String?
        for try await frame in stream {
            if frame == ServerSentEventEncoder.done { continue }
            guard let parsed = ProviderLoop.parseStreamChunk(frame) else { continue }
            if let r = parsed.reasoningDelta { reasoningText += r }
            if let c = parsed.contentDelta { contentText += c }
            if let usage = parsed.usage {
                completionTokens = usage.completionTokens
                usageFrame = frame
            }
        }

        // The model actually reasoned (analysis channel was parsed out).
        #expect(!reasoningText.isEmpty)
        #expect(completionTokens > 0)

        let reasoningTokens = min(
            tokenizer.inner.encode(text: reasoningText, addSpecialTokens: false).count,
            max(0, completionTokens)
        )
        #expect(reasoningTokens > 0)
        #expect(reasoningTokens <= completionTokens)

        // The usage frame rewrite carries the detail through to the wire.
        let rewritten = ProviderLoop.injectReasoningTokens(
            into: try #require(usageFrame), reasoningTokens: reasoningTokens
        )
        let payload = try #require(ProviderLoop.joinedDataPayload(rewritten))
        let obj = try #require(
            try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
        )
        let details = try #require(
            (obj["usage"] as? [String: Any])?["completion_tokens_details"] as? [String: Any]
        )
        #expect((details["reasoning_tokens"] as? Int) == reasoningTokens)

        // Surface the real numbers in the test log for the manual record.
        print("[live] reasoning_tokens=\(reasoningTokens) completion_tokens=\(completionTokens) reasoning_chars=\(reasoningText.count) content=\(contentText.prefix(80))")
    }
}
