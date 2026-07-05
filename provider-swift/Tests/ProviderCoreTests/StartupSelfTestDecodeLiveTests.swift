// Copyright © 2026 Eigen Labs.
//
// Regression tests for the v0.6.31 CI failure: the startup preload
// SELF-TEST decode (1-token greedy through MultiModelBatchSchedulerEngine)
// left residual state in the legacy BatchScheduler for hybrid
// (SSM + attention) models, and every subsequent real request crashed the
// process with an MLX broadcast fatal:
//
//   [broadcast_shapes] Shapes (1,8,19,64) and (1,1,12,64) cannot be broadcast
//
// (second operand frozen at the self-test's ~12-token prompt length).
//
// These tests drive the EXACT serving path the self-test and a routed
// request share — `MultiModelBatchSchedulerEngine` over one live
// `BatchScheduler` via `MLXOpenAIService.streamChatCompletionFrames` —
// first with the self-test-shaped request (tiny prompt, maxTokens=1,
// greedy), then with a normal longer request, and assert the second one
// streams content instead of dying.
//
// Weight-gated like the other live tests: enabled only when
// DARKBLOOM_LIVE_MLX_TESTS is set and the model is in the local HF cache.

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXLMServer
import MLXVLM
import Testing

@testable import ProviderCore

@Suite("startup self-test decode leaves the engine reusable", .serialized)
struct StartupSelfTestDecodeLiveTests {

    /// The model the CI e2e suite serves. Its config.json declares a
    /// `vision_config`, so the provider loads it via `VLMModelFactory`
    /// (see `ProviderLoop.loadModelContainer`) — the bug only existed in
    /// the MLXVLM `Qwen35` implementation (stale `precomputedPositionIds`
    /// on the shared LanguageModel module), NOT in the MLXLLM one, so the
    /// regression test MUST load through the same factory the provider
    /// uses.
    static let hybridModelID = "mlx-community/Qwen3.5-0.8B-MLX-4bit"

    /// Load the model into a fresh `BatchScheduler` through the SAME
    /// factory selection `ProviderLoop.loadModelContainer` uses (VLM
    /// factory when config.json declares `vision_config`). The shared
    /// `LiveInferenceFixtures.loadScheduler` always uses `LLMModelFactory`,
    /// which does not reproduce this bug.
    private func loadProviderStyle(
        modelID: String
    ) async throws -> (scheduler: BatchScheduler, container: ModelContainer) {
        guard LiveInferenceFixtures.ensureMetallibColocated() != nil else {
            throw LiveFixtureSkip.missingMetallib
        }
        guard case .found(let directory) = LiveInferenceFixtures.locate(modelID) else {
            throw LiveFixtureSkip.modelNotInCache(modelID)
        }
        LiveInferenceFixtures.applyMemoryBudget(maxBytes: 8 * 1024 * 1024 * 1024)

        let container: ModelContainer
        if ProviderLoop.modelIsVLM(at: directory) {
            container = try await VLMModelFactory.shared.loadContainer(
                from: directory, using: LocalTokenizerLoader())
        } else {
            container = try await LLMModelFactory.shared.loadContainer(
                from: directory, using: LocalTokenizerLoader())
        }
        let scheduler = BatchScheduler(
            maxConcurrentRequests: 4,
            pendingTimeout: .seconds(60),
            defaultMaxTokens: 256
        )
        await scheduler.loadModel(container: container, modelId: modelID)
        return (scheduler, container)
    }

    /// Drive one OpenAI-shaped chat request through the same
    /// engine+service pipeline `ProviderLoop.runStartupSelfTestDecode` and
    /// `ProviderLoop.handleInferenceRequest` use, and collect the frames.
    private func streamRequest(
        scheduler: BatchScheduler,
        tokenizer: TokenizerHandle,
        modelId: String,
        userText: String,
        maxTokens: Int
    ) async throws -> (frames: Int, content: String) {
        let engine = MultiModelBatchSchedulerEngine(
            registryProvider: { @Sendable in
                [modelId: .init(scheduler: scheduler, tokenizer: tokenizer)]
            },
            defaultMaxTokens: 256
        )
        let service = MLXOpenAIService(engine: engine)
        let request = OpenAIChatCompletionRequest(
            model: modelId,
            messages: [.init(role: .user, content: .text(userText))],
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
        "hybrid model: self-test-shaped decode then a real request must not fault",
        .enabled(if: LiveInferenceFixtures.liveTestsEnabled)
    )
    func selfTestThenRealRequest() async throws {
        let loaded = try await loadProviderStyle(modelID: Self.hybridModelID)
        let scheduler = loaded.scheduler
        defer { Task { await scheduler.unloadModel() } }
        let tokenizer: TokenizerHandle = await loaded.container.perform { ctx in
            TokenizerHandle(ctx.tokenizer)
        }

        // 1. The startup self-test's exact shape: "Hi", greedy, one token.
        let selfTest = try await streamRequest(
            scheduler: scheduler, tokenizer: tokenizer,
            modelId: Self.hybridModelID, userText: "Hi", maxTokens: 1
        )
        #expect(selfTest.frames > 0, "self-test decode produced no frames")

        // 2. A routed-request shape: longer prompt, multi-token decode.
        //    Before the fix this died in MLX with a broadcast_shapes fatal
        //    against the self-test's 12-token residue.
        let real = try await streamRequest(
            scheduler: scheduler, tokenizer: tokenizer,
            modelId: Self.hybridModelID,
            userText: "What is 7 * 8? Reply with just the number.",
            maxTokens: 8
        )
        #expect(real.frames > 0, "real request after self-test produced no frames")
        #expect(!real.content.isEmpty, "real request after self-test produced no content")
    }

    @Test(
        "hybrid model: two sequential normal requests must not fault",
        .enabled(if: LiveInferenceFixtures.liveTestsEnabled)
    )
    func twoSequentialRealRequests() async throws {
        let loaded = try await loadProviderStyle(modelID: Self.hybridModelID)
        let scheduler = loaded.scheduler
        defer { Task { await scheduler.unloadModel() } }
        let tokenizer: TokenizerHandle = await loaded.container.perform { ctx in
            TokenizerHandle(ctx.tokenizer)
        }

        let first = try await streamRequest(
            scheduler: scheduler, tokenizer: tokenizer,
            modelId: Self.hybridModelID,
            userText: "Reply with the single word 'sky'.",
            maxTokens: 6
        )
        #expect(first.frames > 0, "first request produced no frames")

        let second = try await streamRequest(
            scheduler: scheduler, tokenizer: tokenizer,
            modelId: Self.hybridModelID,
            userText: "What is 7 * 8? Reply with just the number.",
            maxTokens: 8
        )
        #expect(second.frames > 0, "second request produced no frames")
        #expect(!second.content.isEmpty, "second request produced no content")
    }
}
