// InferenceLiveTests -- end-to-end live MLX inference against models in
// the local HuggingFace cache.
//
// Gating
// ------
// These tests load real model weights, run real generations on the GPU,
// and take seconds to minutes. They are **opt-in** via two env vars:
//
//   DARKBLOOM_LIVE_MLX_TESTS=1   required for any test in this file
//   DARKBLOOM_LIVE_MLX_GEMMA=1   required additionally for the 27 GB Gemma test
//
// The CI runner (`macos-26-xlarge` in `.github/workflows/release-swift.yml`)
// sets only the first env var; it does not have Gemma cached. Local laptops
// with the model on disk can run the Gemma case manually.
//
// They also require an `mlx.metallib` to exist somewhere under
// `provider-swift/.build/`. `LiveInferenceFixtures.ensureMetallibColocated()`
// finds it and copies it next to the xctest runner so MLX's colocated
// lookup succeeds. If the metallib is missing entirely, every test is
// skipped with an explanation of how to install one
// (`./scripts/fetch-metallib.sh debug`).
//
// Running
// -------
//   cd provider-swift
//   DARKBLOOM_LIVE_MLX_TESTS=1 swift test --filter InferenceLiveTests
//
// Adding the Gemma case:
//   DARKBLOOM_LIVE_MLX_TESTS=1 \
//     DARKBLOOM_LIVE_MLX_GEMMA=1 \
//     swift test --filter InferenceLiveTests
//
// Cleanup
// -------
// Each test `defer`s `await scheduler.unloadModel()` so the next test
// starts with a fresh GPU. Memory budget is set up-front via
// `MLX.GPU.set(memoryLimit:)` to keep a runaway test from consuming all
// of unified RAM.

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Testing
@testable import ProviderCore

// MARK: - Suite

/// Live tests are serialized by default. MLX state (caches, peak memory,
/// loaded weights) is process-global; running two model loads in parallel
/// produces unpredictable OOM-vs-eviction behavior that masks real bugs.
@Suite("live MLX inference", .serialized)
struct InferenceLiveTests {

    // MARK: 1. Tiny model, end-to-end

    @Test(
        "tiny model loads and produces non-empty output",
        .enabled(
            if: LiveInferenceFixtures.liveTestsEnabled,
            "set DARKBLOOM_LIVE_MLX_TESTS=1 to run live MLX inference tests"
        )
    )
    func liveInferenceLoadsTinyModelAndProducesNonEmptyOutput() async throws {
        let loaded: (scheduler: BatchScheduler, container: ModelContainer, modelDirectory: URL)
        do {
            loaded = try await LiveInferenceFixtures.loadScheduler(
                modelID: LiveInferenceFixtures.tinyModelID
            )
        } catch let skip as LiveFixtureSkip {
            Issue.record("skipped: \(skip.description)")
            return
        }
        let scheduler = loaded.scheduler
        defer {
            // Synchronous defer can't await; spawn an unstructured cleanup
            // task. The next test's first action is a fresh load, which
            // serializes naturally with the cleanup.
            Task { await scheduler.unloadModel() }
        }

        let request = ChatCompletionRequest(
            model: LiveInferenceFixtures.tinyModelID,
            messages: [
                ChatMessage(role: "user", content: "Reply with the single word 'hello'."),
            ],
            temperature: 0.0,
            max_tokens: 16
        )

        let result = await collect(from: scheduler, request: request)

        #expect(!result.didError, "unexpected error: \(result.error ?? "")")
        #expect(!result.chunks.isEmpty, "no .chunk events received")
        #expect(!result.fullText.isEmpty, "concatenated text is empty")
        #expect(result.info != nil, "no .info event received")
        if let info = result.info {
            #expect(info.completionTokens > 0, "completionTokens should be > 0")
            #expect(info.completionTokens <= 16, "completionTokens should be <= max_tokens")
            #expect(info.promptTokens > 0, "promptTokens should be > 0 for a non-empty prompt")
        }
    }

    // MARK: 2. Cancellation

    @Test(
        "cancellation stops generation quickly",
        .enabled(
            if: LiveInferenceFixtures.liveTestsEnabled,
            "set DARKBLOOM_LIVE_MLX_TESTS=1 to run live MLX inference tests"
        )
    )
    func liveInferenceCancellationStopsGenerationQuickly() async throws {
        let loaded: (scheduler: BatchScheduler, container: ModelContainer, modelDirectory: URL)
        do {
            loaded = try await LiveInferenceFixtures.loadScheduler(
                modelID: LiveInferenceFixtures.tinyModelID
            )
        } catch let skip as LiveFixtureSkip {
            Issue.record("skipped: \(skip.description)")
            return
        }
        let scheduler = loaded.scheduler
        defer { Task { await scheduler.unloadModel() } }

        // Ask for a long generation so we can cancel mid-stream.
        let request = ChatCompletionRequest(
            model: LiveInferenceFixtures.tinyModelID,
            messages: [
                ChatMessage(
                    role: "user",
                    content: "Write a long, detailed story about a robot exploring Mars. Take your time."
                ),
            ],
            temperature: 0.7,
            max_tokens: 200
        )

        let requestID = "cancel-test-\(UUID().uuidString)"
        let stream = await scheduler.submit(request: request, requestId: requestID)

        let cancelDelayMs = 200
        let postCancelBudgetMs = 1500

        let collectorStart = ContinuousClock.now
        let collector = Task { () -> CollectedGeneration in
            var collected = CollectedGeneration()
            for await event in stream {
                switch event {
                case .chunk(let text):
                    collected.chunks.append(text)
                case .info(let prompt, let completion, let tps):
                    collected.info = (prompt, completion, tps)
                case .error(let message):
                    collected.error = message
                }
            }
            return collected
        }

        try await Task.sleep(for: .milliseconds(cancelDelayMs))
        let cancelInstant = ContinuousClock.now
        await scheduler.cancel(requestId: requestID)

        // Bound how long we're willing to wait after the cancel.
        let timeoutTask = Task {
            try await Task.sleep(for: .milliseconds(postCancelBudgetMs))
            collector.cancel()
        }

        let result = await collector.value
        timeoutTask.cancel()
        let endInstant = ContinuousClock.now
        let totalElapsed = endInstant - collectorStart
        let postCancelElapsed = endInstant - cancelInstant

        // The stream may yield either an error ("Request cancelled") or
        // simply finish without an info event -- depends on whether the
        // generation task picked up Task.isCancelled before yielding the
        // info chunk. Both are valid "we stopped" signals; what matters is
        // that we stopped fast and short of `max_tokens`.
        let stoppedFast = postCancelElapsed < .milliseconds(postCancelBudgetMs)
        #expect(
            stoppedFast,
            "stream did not finish within \(postCancelBudgetMs) ms after cancel (post-cancel elapsed: \(postCancelElapsed); total: \(totalElapsed))"
        )

        if let info = result.info {
            #expect(
                info.completionTokens < 200,
                "expected fewer than 200 completion tokens after cancel, got \(info.completionTokens)"
            )
        }

        let cap = await scheduler.capacity()
        #expect(cap.activeRequests == 0, "scheduler still reports \(cap.activeRequests) active requests")
        #expect(cap.pendingRequests == 0, "scheduler still reports \(cap.pendingRequests) pending requests")
    }

    // MARK: 3. Concurrent requests

    @Test(
        "concurrent requests share a single model",
        .enabled(
            if: LiveInferenceFixtures.liveTestsEnabled,
            "set DARKBLOOM_LIVE_MLX_TESTS=1 to run live MLX inference tests"
        )
    )
    func liveInferenceConcurrentRequestsShareModel() async throws {
        let loaded: (scheduler: BatchScheduler, container: ModelContainer, modelDirectory: URL)
        do {
            loaded = try await LiveInferenceFixtures.loadScheduler(
                modelID: LiveInferenceFixtures.tinyModelID,
                maxConcurrentRequests: 4
            )
        } catch let skip as LiveFixtureSkip {
            Issue.record("skipped: \(skip.description)")
            return
        }
        let scheduler = loaded.scheduler
        defer { Task { await scheduler.unloadModel() } }

        let prompts = [
            "Reply with the single word 'one'.",
            "Reply with the single word 'two'.",
            "Reply with the single word 'three'.",
        ]

        let results = await withTaskGroup(of: (Int, CollectedGeneration).self) { group in
            for (idx, prompt) in prompts.enumerated() {
                group.addTask {
                    let req = ChatCompletionRequest(
                        model: LiveInferenceFixtures.tinyModelID,
                        messages: [ChatMessage(role: "user", content: prompt)],
                        temperature: 0.0,
                        max_tokens: 16
                    )
                    let result = await collect(
                        from: scheduler,
                        request: req,
                        requestId: "concurrent-\(idx)"
                    )
                    return (idx, result)
                }
            }
            var out = [(Int, CollectedGeneration)]()
            for await pair in group { out.append(pair) }
            return out
        }

        #expect(results.count == prompts.count, "expected \(prompts.count) results, got \(results.count)")
        for (idx, result) in results {
            #expect(!result.didError, "request \(idx) errored: \(result.error ?? "")")
            #expect(!result.fullText.isEmpty, "request \(idx) produced empty text")
            #expect(result.info != nil, "request \(idx) missing .info event")
            if let info = result.info {
                #expect(info.completionTokens > 0, "request \(idx) had zero completion tokens")
            }
        }

        // Allow the scheduler a moment to run its post-completion bookkeeping
        // (the generation task posts `requestCompleted` back to the actor).
        try await Task.sleep(for: .milliseconds(100))
        let cap = await scheduler.capacity()
        #expect(cap.activeRequests == 0, "expected 0 active requests, got \(cap.activeRequests)")
        #expect(cap.pendingRequests == 0, "expected 0 pending requests, got \(cap.pendingRequests)")
    }

    // MARK: 4. Gemma 26B

    @Test(
        "Gemma 26B produces plausible arithmetic answer",
        .enabled(
            if: LiveInferenceFixtures.gemmaTestsEnabled,
            "set DARKBLOOM_LIVE_MLX_TESTS=1 and DARKBLOOM_LIVE_MLX_GEMMA=1 to run the 27 GB Gemma test"
        )
    )
    func liveInferenceWithGemmaProducesPlausibleOutput() async throws {
        let loaded: (scheduler: BatchScheduler, container: ModelContainer, modelDirectory: URL)
        do {
            // Larger memory budget for the 27 GB MoE.
            LiveInferenceFixtures.applyMemoryBudget(maxBytes: 64 * 1024 * 1024 * 1024)
            loaded = try await LiveInferenceFixtures.loadScheduler(
                modelID: LiveInferenceFixtures.gemmaModelID,
                maxConcurrentRequests: 1
            )
        } catch let skip as LiveFixtureSkip {
            Issue.record("skipped: \(skip.description)")
            return
        }
        let scheduler = loaded.scheduler
        defer { Task { await scheduler.unloadModel() } }

        let request = ChatCompletionRequest(
            model: LiveInferenceFixtures.gemmaModelID,
            messages: [
                ChatMessage(role: "user", content: "What is 7 * 8? Reply with just the number."),
            ],
            temperature: 0.0,
            max_tokens: 32
        )

        let result = await collect(from: scheduler, request: request)

        #expect(!result.didError, "unexpected error: \(result.error ?? "")")
        #expect(result.info != nil, "no .info event received")
        #expect(
            result.fullText.contains("56"),
            "expected '56' in output, got: \(result.fullText.debugDescription)"
        )
    }

    // MARK: 5. Chat-template fidelity (Phase 0)

    @Test(
        "tokenizer chat template embeds system + user content in order",
        .enabled(
            if: LiveInferenceFixtures.liveTestsEnabled,
            "set DARKBLOOM_LIVE_MLX_TESTS=1 to run live MLX inference tests"
        )
    )
    func liveInferenceTokenizerChatTemplateMatchesExpected() async throws {
        // The fidelity check doesn't need the scheduler -- it operates on
        // the model's UserInputProcessor directly. But it does need the
        // metallib (mlx-swift-lm pulls in MLX initialization on tokenizer
        // load) and a real model on disk.
        guard LiveInferenceFixtures.ensureMetallibColocated() != nil else {
            Issue.record("skipped: \(LiveFixtureSkip.missingMetallib.description)")
            return
        }
        LiveInferenceFixtures.applyMemoryBudget()

        let modelID: String
        let directory: URL
        switch LiveInferenceFixtures.locate(LiveInferenceFixtures.tinyModelID) {
        case .found(let url):
            modelID = LiveInferenceFixtures.tinyModelID
            directory = url
        case .missing:
            switch LiveInferenceFixtures.locate(LiveInferenceFixtures.tinyModelFallbackID) {
            case .found(let url):
                modelID = LiveInferenceFixtures.tinyModelFallbackID
                directory = url
            case .missing(let id):
                Issue.record("skipped: \(LiveFixtureSkip.modelNotInCache(id).description)")
                return
            }
        }

        let container = try await LLMModelFactory.shared.loadContainer(
            from: directory,
            using: LocalTokenizerLoader()
        )

        let systemContent = "You are a terse assistant. Reply with one word."
        let userContent = "What color is the sky on a clear day?"

        let messages: [[String: any Sendable]] = [
            ["role": "system", "content": systemContent],
            ["role": "user", "content": userContent],
        ]
        let userInput = UserInput(messages: messages)

        // Use `ModelContainer.prepare(input:)` rather than the closure-form
        // `perform(...)` because the closure-form requires `UserInput` to be
        // `Sendable`, and it is not (it can carry CIImage / AVAsset).
        // `prepare(input:)` declares `consuming sending UserInput` so the
        // value transfers cleanly across the actor isolation boundary.
        let prepared = try await container.prepare(input: userInput)
        let tokenIds: [Int] = prepared.text.tokens.asArray(Int.self)

        #expect(!tokenIds.isEmpty, "tokenizer produced 0 tokens for a 2-message chat")

        let decoded = await container.decode(tokenIds: tokenIds)

        // The chat template shape varies by model family (Qwen3 uses
        // ChatML-ish "<|im_start|>system" sections; Qwen2.5 uses
        // "<|im_start|>system" identically). What MUST hold across all of
        // them is that the system content appears before the user content
        // in the rendered string, both verbatim.
        guard let systemRange = decoded.range(of: systemContent) else {
            let snippet = String(decoded.prefix(300))
            Issue.record(
                "system content '\(systemContent)' missing from decoded prompt for \(modelID): \(snippet.debugDescription)"
            )
            return
        }
        guard let userRange = decoded.range(of: userContent) else {
            let snippet = String(decoded.prefix(300))
            Issue.record(
                "user content '\(userContent)' missing from decoded prompt for \(modelID): \(snippet.debugDescription)"
            )
            return
        }
        #expect(
            systemRange.lowerBound < userRange.lowerBound,
            "system content must precede user content in chat template (model: \(modelID))"
        )

        // Sanity check: re-encoding the decoded prompt should round-trip
        // to a token count within a small delta. This guards against
        // tokenizer / Jinja regressions that drop characters silently.
        let reencoded = await container.encode(decoded)
        let drift = abs(reencoded.count - tokenIds.count)
        #expect(
            drift <= 4,
            "decode -> encode round-trip drifted by \(drift) tokens (orig: \(tokenIds.count), reencoded: \(reencoded.count))"
        )
    }
}
