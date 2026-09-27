// Copyright © 2026 Eigen Labs.
//
// The startup preload SELF-TEST decode (1-token greedy through
// `MultiModelBatchSchedulerEngine` via `MLXOpenAIService`, see
// `ProviderLoop.runStartupSelfTestDecode`) must leave the serving engine
// reusable: the next REAL routed request has to stream content instead of
// faulting against residue the tiny warmup decode left behind.
//
// Lineage: this suite originally pinned the v0.6.31 CI failure, where the
// self-test decode left residual state in the legacy BatchScheduler for a
// hybrid (SSM + attention) Qwen3.5 checkpoint and every subsequent request
// died in an MLX broadcast fatal. v0.7.5 one-engine deleted the legacy
// scheduler, and Qwen has no CBv2 adapter, so that exact checkpoint is
// unservable — but the invariant is engine-agnostic. These tests now drive
// the EXACT v2 serving path the production self-test and a routed request
// share — `MultiModelBatchSchedulerEngine` over the slot's `EngineV2Bridge`
// via `MLXOpenAIService.streamChatCompletionFrames` — on gpt-oss (the
// smallest production CBv2 checkpoint): first the self-test-shaped request
// (tiny prompt, maxTokens=1, greedy), then a normal longer request, and
// assert the second one streams content instead of dying.
//
// Weight-gated like the other live tests: enabled only when
// DARKBLOOM_LIVE_MLX_TESTS is set and the model is in the local HF cache.

import Foundation
import MLX
import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore

@Suite("startup self-test decode leaves the engine reusable", .serialized)
struct StartupSelfTestDecodeLiveTests {

    /// Smallest production CBv2 checkpoint (v0.7.5 one-engine: only
    /// CBv2-adapted families — gpt-oss, gemma4 — can serve). Same model
    /// the reasoning-effort and Jinja live suites use.
    static let modelID = "mlx-community/gpt-oss-20b-MXFP4-Q8"
    static let modelType = "gpt_oss"

    /// Load the model's PRODUCTION v2 bridge through the shared fixture —
    /// the same `EngineV2SlotFactory.makeProductionBridge` construction
    /// every serving slot uses.
    private func loadBridge() async throws -> LiveInferenceFixtures.LoadedBridge {
        try await LiveInferenceFixtures.loadBridge(
            modelID: Self.modelID,
            maxConcurrentRequests: 4,
            memoryBudgetBytes: 24 * 1024 * 1024 * 1024,
            kvBackendConfig: "paged"
        )
    }

    /// Drive one OpenAI-shaped chat request through the same
    /// engine+service pipeline `ProviderLoop.runStartupSelfTestDecode` and
    /// `ProviderLoop.handleInferenceRequest` use, and collect the frames.
    private func streamRequest(
        bridge: EngineV2Bridge,
        tokenizer: TokenizerHandle,
        modelId: String,
        userText: String,
        maxTokens: Int
    ) async throws -> (frames: Int, content: String) {
        let engine = MultiModelBatchSchedulerEngine(
            registryProvider: { @Sendable in
                [modelId: .init(
                    tokenizer: tokenizer, modelType: Self.modelType,
                    engineV2Bridge: bridge)]
            },
            defaultMaxTokens: 256
        )
        let service = MLXOpenAIService(engine: engine)
        let request = OpenAIChatCompletionRequest(
            model: modelId,
            messages: [.init(role: .user, content: .text(userText))],
            // Mirror production: the self-test resolves the parser from the
            // slot's model_type (harmony for gpt_oss).
            reasoningParser: ProviderLoop.inferReasoningParser(for: Self.modelType),
            stream: true,
            temperature: 0,
            maxTokens: maxTokens
        )
        let frames = try await service.streamChatCompletionFrames(request: request)
        var frameCount = 0
        var content = ""
        for try await frame in frames {
            frameCount += 1
            if let parsed = ProviderLoop.parseStreamChunk(frame) {
                if let delta = parsed.contentDelta { content += delta }
                if let delta = parsed.reasoningDelta { content += delta }
            }
        }
        return (frameCount, content)
    }

    @Test(
        "self-test-shaped decode then a real request must not fault",
        .enabled(if: LiveInferenceFixtures.liveTestsEnabled)
    )
    func selfTestThenRealRequest() async throws {
        let loaded: LiveInferenceFixtures.LoadedBridge
        do {
            loaded = try await loadBridge()
        } catch let skip as LiveFixtureSkip {
            Issue.record("skipped: \(skip.description)")
            return
        }
        let bridge = loaded.bridge
        #expect(await bridge.kvBackendKind == .paged)
        defer {
            Task {
                await bridge.shutdown()
                MLX.Memory.clearCache()
            }
        }
        let tokenizer: TokenizerHandle = await loaded.container.perform { ctx in
            TokenizerHandle(ctx.tokenizer)
        }

        // 1. The startup self-test's exact shape: "Hi", greedy, one token.
        let selfTest = try await streamRequest(
            bridge: bridge, tokenizer: tokenizer,
            modelId: Self.modelID, userText: "Hi", maxTokens: 1
        )
        #expect(selfTest.frames > 0, "self-test decode produced no frames")

        // 2. A routed-request shape: longer prompt, multi-token decode.
        //    Residue from the 1-token warmup (KV pool, prefill state,
        //    compiled buckets) must not fault or corrupt this stream.
        let real = try await streamRequest(
            bridge: bridge, tokenizer: tokenizer,
            modelId: Self.modelID,
            userText: "What is 7 * 8? Reply with just the number.",
            maxTokens: 64
        )
        #expect(real.frames > 0, "real request after self-test produced no frames")
        #expect(!real.content.isEmpty, "real request after self-test produced no content")
    }

    @Test(
        "two sequential normal requests must not fault",
        .enabled(if: LiveInferenceFixtures.liveTestsEnabled)
    )
    func twoSequentialRealRequests() async throws {
        let loaded: LiveInferenceFixtures.LoadedBridge
        do {
            loaded = try await loadBridge()
        } catch let skip as LiveFixtureSkip {
            Issue.record("skipped: \(skip.description)")
            return
        }
        let bridge = loaded.bridge
        defer {
            Task {
                await bridge.shutdown()
                MLX.Memory.clearCache()
            }
        }
        let tokenizer: TokenizerHandle = await loaded.container.perform { ctx in
            TokenizerHandle(ctx.tokenizer)
        }

        let first = try await streamRequest(
            bridge: bridge, tokenizer: tokenizer,
            modelId: Self.modelID,
            userText: "Reply with the single word 'sky'.",
            maxTokens: 48
        )
        #expect(first.frames > 0, "first request produced no frames")

        let second = try await streamRequest(
            bridge: bridge, tokenizer: tokenizer,
            modelId: Self.modelID,
            userText: "What is 7 * 8? Reply with just the number.",
            maxTokens: 64
        )
        #expect(second.frames > 0, "second request produced no frames")
        #expect(!second.content.isEmpty, "second request produced no content")
    }
}
