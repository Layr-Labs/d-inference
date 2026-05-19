// InferenceLiveTests -- end-to-end live MLX inference against models in
// the local HuggingFace cache.
//
// Gating
// ------
// These tests load real model weights, run real generations on the GPU,
// and take seconds to minutes. They are **opt-in** via env vars:
//
//   DARKBLOOM_LIVE_MLX_TESTS=1   required for any test in this file
//   DARKBLOOM_LIVE_MLX_GEMMA=1        required additionally for the 27 GB Gemma test
//   DARKBLOOM_LIVE_MLX_MULTI_MODEL=1  required additionally for tests needing two local models
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
// Adding the two-model cases:
//   DARKBLOOM_LIVE_MLX_TESTS=1 \
//     DARKBLOOM_LIVE_MLX_MULTI_MODEL=1 \
//     swift test --filter InferenceLiveTests
//
// Cleanup
// -------
// Each test `defer`s `await scheduler.unloadModel()` so the next test
// starts with a fresh GPU. Memory budget is set up-front via
// `MLX.GPU.set(memoryLimit:)` to keep a runaway test from consuming all
// of unified RAM.

import Foundation
import Darwin
import Hummingbird
import HummingbirdTesting
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

    // MARK: 4. Multi-model residency

    @Test(
        "two different model schedulers generate while both resident",
        .enabled(
            if: LiveInferenceFixtures.multiModelLiveTestsEnabled,
            "set DARKBLOOM_LIVE_MLX_TESTS=1 and DARKBLOOM_LIVE_MLX_MULTI_MODEL=1 to run two-model live tests"
        )
    )
    func liveInferenceTwoDifferentModelsGenerateWhileResident() async throws {
        let primary: (scheduler: BatchScheduler, container: ModelContainer, modelDirectory: URL)
        let secondary: (scheduler: BatchScheduler, container: ModelContainer, modelDirectory: URL)
        do {
            primary = try await LiveInferenceFixtures.loadScheduler(
                modelID: LiveInferenceFixtures.tinyModelID,
                maxConcurrentRequests: 2,
                memoryBudgetBytes: 16 * 1024 * 1024 * 1024
            )
            secondary = try await LiveInferenceFixtures.loadScheduler(
                modelID: LiveInferenceFixtures.tinyModelFallbackID,
                maxConcurrentRequests: 2,
                memoryBudgetBytes: 16 * 1024 * 1024 * 1024
            )
        } catch let skip as LiveFixtureSkip {
            Issue.record("skipped: \(skip.description)")
            return
        }
        defer {
            Task { await primary.scheduler.unloadModel() }
            Task { await secondary.scheduler.unloadModel() }
        }

        async let primaryResult = collect(
            from: primary.scheduler,
            request: ChatCompletionRequest(
                model: LiveInferenceFixtures.tinyModelID,
                messages: [ChatMessage(role: "user", content: "Reply with one short word: alpha.")],
                temperature: 0.0,
                max_tokens: 12
            ),
            requestId: "multi-primary-\(UUID().uuidString)"
        )
        async let secondaryResult = collect(
            from: secondary.scheduler,
            request: ChatCompletionRequest(
                model: LiveInferenceFixtures.tinyModelFallbackID,
                messages: [ChatMessage(role: "user", content: "Reply with one short word: beta.")],
                temperature: 0.0,
                max_tokens: 12
            ),
            requestId: "multi-secondary-\(UUID().uuidString)"
        )

        let results = await [primaryResult, secondaryResult]
        for (index, result) in results.enumerated() {
            #expect(!result.didError, "model \(index) errored: \(result.error ?? "")")
            #expect(!result.fullText.isEmpty, "model \(index) produced empty text")
            #expect(result.info != nil, "model \(index) did not emit usage info")
        }

        let primaryCapacity = await primary.scheduler.capacity()
        let secondaryCapacity = await secondary.scheduler.capacity()
        #expect(primaryCapacity.model == LiveInferenceFixtures.tinyModelID)
        #expect(secondaryCapacity.model == LiveInferenceFixtures.tinyModelFallbackID)
        #expect(primaryCapacity.activeRequests == 0)
        #expect(secondaryCapacity.activeRequests == 0)
        #expect(primaryCapacity.pendingRequests == 0)
        #expect(secondaryCapacity.pendingRequests == 0)
    }

    @Test(
        "standalone server serves two local models through one process",
        .enabled(
            if: LiveInferenceFixtures.multiModelLiveTestsEnabled,
            "set DARKBLOOM_LIVE_MLX_TESTS=1 and DARKBLOOM_LIVE_MLX_MULTI_MODEL=1 to run two-model live tests"
        )
    )
    func liveStandaloneServerServesTwoModelsThroughOneProcess() async throws {
        guard LiveInferenceFixtures.ensureMetallibColocated() != nil else {
            Issue.record("skipped: \(LiveFixtureSkip.missingMetallib.description)")
            return
        }
        guard case .found = LiveInferenceFixtures.locate(LiveInferenceFixtures.tinyModelID) else {
            Issue.record("skipped: \(LiveFixtureSkip.modelNotInCache(LiveInferenceFixtures.tinyModelID).description)")
            return
        }
        guard case .found = LiveInferenceFixtures.locate(LiveInferenceFixtures.tinyModelFallbackID) else {
            Issue.record("skipped: \(LiveFixtureSkip.modelNotInCache(LiveInferenceFixtures.tinyModelFallbackID).description)")
            return
        }
        LiveInferenceFixtures.applyMemoryBudget(maxBytes: 16 * 1024 * 1024 * 1024)

        let server = StandaloneServer(
            config: StandaloneServerConfig(maxCachedModels: 2),
            models: [
                liveModelInfo(id: LiveInferenceFixtures.tinyModelID, quantization: "8bit"),
                liveModelInfo(id: LiveInferenceFixtures.tinyModelFallbackID, quantization: "4bit"),
            ]
        )
        let app = server.makeApplication()

        try await app.test(.router) { client in
            func assertChat(model: String, prompt: String) async throws {
                let request = ChatCompletionRequest(
                    model: model,
                    messages: [ChatMessage(role: "user", content: prompt)],
                    temperature: 0.0,
                    max_tokens: 12,
                    stream: false
                )
                let body = String(data: try JSONEncoder().encode(request), encoding: .utf8) ?? "{}"
                try await client.execute(
                    uri: "/v1/chat/completions",
                    method: .post,
                    headers: [.contentType: "application/json"],
                    body: ByteBuffer(string: body)
                ) { response in
                    let responseBody = String(buffer: response.body)
                    #expect(response.status == .ok, "standalone response for \(model): \(response.status) \(responseBody)")
                    let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: Data(responseBody.utf8))
                    #expect(decoded.model == model)
                    #expect(!decoded.choices.isEmpty)
                    #expect(!decoded.choices[0].message.content.isEmpty)
                    #expect(decoded.usage.completion_tokens > 0)
                }
            }

            try await assertChat(model: LiveInferenceFixtures.tinyModelID, prompt: "Reply with one word: first.")
            try await assertChat(model: LiveInferenceFixtures.tinyModelFallbackID, prompt: "Reply with one word: second.")
            try await assertChat(model: LiveInferenceFixtures.tinyModelID, prompt: "Reply with one word: again.")
        }
    }

    @Test(
        "standalone socket disconnect cleans up scheduler reservations",
        .enabled(
            if: LiveInferenceFixtures.liveTestsEnabled,
            "set DARKBLOOM_LIVE_MLX_TESTS=1 to run live MLX inference tests"
        )
    )
    func liveStandaloneSocketDisconnectCleansUpSchedulerReservations() async throws {
        guard LiveInferenceFixtures.ensureMetallibColocated() != nil else {
            Issue.record("skipped: \(LiveFixtureSkip.missingMetallib.description)")
            return
        }
        guard case .found = LiveInferenceFixtures.locate(LiveInferenceFixtures.tinyModelID) else {
            Issue.record("skipped: \(LiveFixtureSkip.modelNotInCache(LiveInferenceFixtures.tinyModelID).description)")
            return
        }
        LiveInferenceFixtures.applyMemoryBudget()

        let port = try reserveUnusedTCPPort()
        let server = StandaloneServer(
            config: StandaloneServerConfig(port: port, maxCachedModels: 1),
            models: [liveModelInfo(id: LiveInferenceFixtures.tinyModelID, quantization: "8bit")]
        )
        do {
            try await server.start()
            let listening = try await waitForTCPPort(port, timeout: .seconds(10))
            try #require(listening, "standalone server did not listen on port \(port)")

            try await assertStandaloneDisconnectCleanup(server: server, port: port, stream: true)
            try await assertStandaloneDisconnectCleanup(server: server, port: port, stream: false)
        } catch {
            await server.stopAndWait()
            throw error
        }
        await server.stopAndWait()
    }

    @Test(
        "provider loop coalesces duplicate live load_model requests",
        .enabled(
            if: LiveInferenceFixtures.liveTestsEnabled,
            "set DARKBLOOM_LIVE_MLX_TESTS=1 to run live MLX inference tests"
        )
    )
    func liveProviderLoopCoalescesDuplicateLoadModelRequests() async throws {
        guard LiveInferenceFixtures.ensureMetallibColocated() != nil else {
            Issue.record("skipped: \(LiveFixtureSkip.missingMetallib.description)")
            return
        }
        guard case .found = LiveInferenceFixtures.locate(LiveInferenceFixtures.tinyModelID) else {
            Issue.record("skipped: \(LiveFixtureSkip.modelNotInCache(LiveInferenceFixtures.tinyModelID).description)")
            return
        }
        LiveInferenceFixtures.applyMemoryBudget()

        let mock = MockCoordinator()
        let baseURL = try await mock.start()
        let config = liveProviderLoopConfig(
            coordinatorURL: baseURL.mockProviderWebSocketURL(),
            models: [liveModelInfo(id: LiveInferenceFixtures.tinyModelID, quantization: "8bit")]
        )
        let loadGate = LiveLoadModelGate()
        let loop = try ProviderLoop(
            config: config,
            purgeLegacyFiles: false,
            attestationSigner: nil,
            preloadTaskStarted: { modelId in
                loadGate.recordPreloadTaskStarted(modelId)
            },
            beforeModelLoad: { modelId in
                await loadGate.waitBeforeLoading(modelId)
            }
        )
        let loopTask = Task { try await loop.run() }

        do {
            let register = try await mock.awaitFirstRegister(timeout: .seconds(10))
            try #require(register != nil)

            try await mock.pushLoadModel(modelId: LiveInferenceFixtures.tinyModelID)
            let reachedLoadGate = try await waitUntil(timeout: .seconds(10)) {
                loadGate.loadReached(for: LiveInferenceFixtures.tinyModelID)
            }
            try #require(reachedLoadGate, "provider did not reach the real model-load gate")

            try await mock.pushLoadModel(modelId: LiveInferenceFixtures.tinyModelID)
            let startedSnapshot = try await mock.waitForSnapshot(timeout: .seconds(10)) { snapshot in
                let statuses = snapshot.loadModelStatuses.filter { $0.modelId == LiveInferenceFixtures.tinyModelID }
                return statuses.filter { $0.status == .started }.count == 2
            }
            try #require(startedSnapshot != nil)
            loadGate.release()

            let statusSnapshot = try await mock.waitForSnapshot(timeout: .seconds(90)) { snapshot in
                let statuses = snapshot.loadModelStatuses.filter { $0.modelId == LiveInferenceFixtures.tinyModelID }
                return statuses.filter { $0.status == .started }.count == 2
                    && statuses.filter { $0.status == .succeeded }.count == 2
            }
            let snapshot = try #require(statusSnapshot)
            let statuses = snapshot.loadModelStatuses.filter { $0.modelId == LiveInferenceFixtures.tinyModelID }
            #expect(statuses.count == 4, "expected exactly two started and two succeeded statuses, got \(statuses)")
            #expect(statuses.map(\.status) == [.started, .started, .succeeded, .succeeded])
            #expect(statuses.allSatisfy { $0.error == nil })
            #expect(loadGate.preloadTaskStartCount(for: LiveInferenceFixtures.tinyModelID) == 1)
        } catch {
            await shutdownLiveProviderLoop(loopTask, mock: mock, loadGate: loadGate)
            throw error
        }
        await shutdownLiveProviderLoop(loopTask, mock: mock, loadGate: loadGate)
    }

    // MARK: 6. Gemma 26B

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

    // MARK: 7. Chat-template fidelity (Phase 0)

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

private func liveModelInfo(id: String, quantization: String) -> ModelInfo {
    ModelInfo(
        id: id,
        modelType: "chat",
        quantization: quantization,
        sizeBytes: 0,
        estimatedMemoryGb: 0.25
    )
}

private func liveProviderLoopConfig(coordinatorURL: String, models: [ModelInfo]) -> ProviderLoopConfig {
    ProviderLoopConfig(
        coordinatorURL: coordinatorURL,
        hardware: HardwareInfo(
            machineModel: "Mac16,5",
            chipName: "Apple M4 Max",
            chipFamily: .m4,
            chipTier: .max,
            memoryGb: 128,
            memoryAvailableGb: 124,
            cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
            gpuCores: 40,
            memoryBandwidthGbs: 546
        ),
        models: models,
        config: ProviderConfig(
            provider: ProviderSettings(name: "darkbloom-live-test", memoryReserveGB: 1),
            backend: BackendSettings(
                continuousBatching: true,
                idleTimeoutMins: 0,
                maxModelSlots: UInt64(max(1, models.count))
            ),
            coordinator: CoordinatorSettings(heartbeatIntervalSecs: 60)
        )
    )
}

private final class LiveLoadModelGate: @unchecked Sendable {
    private let lock = NSLock()
    private var reachedModels = Set<String>()
    private var released = false
    private var preloadStarts: [String: Int] = [:]

    func recordPreloadTaskStarted(_ modelId: String) {
        lock.lock()
        preloadStarts[modelId, default: 0] += 1
        lock.unlock()
    }

    func waitBeforeLoading(_ modelId: String) async {
        markLoadReached(modelId)

        while !Task.isCancelled {
            if isReleased() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func markLoadReached(_ modelId: String) {
        lock.lock()
        reachedModels.insert(modelId)
        lock.unlock()
    }

    private func isReleased() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return released
    }

    func loadReached(for modelId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return reachedModels.contains(modelId)
    }

    func release() {
        lock.lock()
        released = true
        lock.unlock()
    }

    func preloadTaskStartCount(for modelId: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return preloadStarts[modelId] ?? 0
    }
}

private func waitUntil(timeout: Duration, predicate: () -> Bool) async throws -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if predicate() { return true }
        try await Task.sleep(for: .milliseconds(25))
    }
    return predicate()
}

private func waitUntilAsync(timeout: Duration, predicate: () async -> Bool) async throws -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await predicate() { return true }
        try await Task.sleep(for: .milliseconds(25))
    }
    return await predicate()
}

private func shutdownLiveProviderLoop(
    _ loopTask: Task<Void, any Error>,
    mock: MockCoordinator,
    loadGate: LiveLoadModelGate
) async {
    loadGate.release()
    loopTask.cancel()
    _ = try? await loopTask.value
    await mock.shutdown()
}

private func assertStandaloneDisconnectCleanup(
    server: StandaloneServer,
    port: UInt16,
    stream: Bool
) async throws {
    var fd: Int32? = try openRawStandaloneRequest(port: port, stream: stream)
    defer {
        if let fd { closeSocket(fd) }
    }

    let becameActive = try await waitUntilAsync(timeout: .seconds(90)) {
        guard let capacity = await server.debugCapacity(modelId: LiveInferenceFixtures.tinyModelID) else {
            return false
        }
        return capacity.activeRequests + capacity.pendingRequests > 0
    }
    try #require(becameActive, "standalone \(stream ? "streaming" : "non-streaming") request never became active")

    if let openFD = fd {
        abortSocket(openFD)
        fd = nil
    }

    let cleanedUp = try await waitUntilAsync(timeout: .seconds(3)) {
        guard let capacity = await server.debugCapacity(modelId: LiveInferenceFixtures.tinyModelID) else {
            return false
        }
        let reservations = await server.debugSchedulerReservationCount(modelId: LiveInferenceFixtures.tinyModelID)
        return capacity.activeRequests == 0
            && capacity.pendingRequests == 0
            && reservations == 0
    }

    let capacity = await server.debugCapacity(modelId: LiveInferenceFixtures.tinyModelID)
    let reservations = await server.debugSchedulerReservationCount(modelId: LiveInferenceFixtures.tinyModelID)
    #expect(
        cleanedUp,
        "standalone \(stream ? "streaming" : "non-streaming") disconnect left capacity=\(String(describing: capacity)), reservations=\(reservations)"
    )
}

private func openRawStandaloneRequest(port: UInt16, stream: Bool) throws -> Int32 {
    let request = ChatCompletionRequest(
        model: LiveInferenceFixtures.tinyModelID,
        messages: [
            ChatMessage(
                role: "user",
                content: "Write a long, detailed story about a robot exploring Mars. Continue until you reach the token limit."
            ),
        ],
        temperature: 0.7,
        max_tokens: 512,
        stream: stream
    )
    let body = String(data: try JSONEncoder().encode(request), encoding: .utf8) ?? "{}"
    let raw = """
        POST /v1/chat/completions HTTP/1.1\r
        Host: 127.0.0.1:\(port)\r
        Content-Type: application/json\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """

    let fd = try connectSocket(port: port)
    do {
        try writeAll(fd: fd, Data(raw.utf8))
        return fd
    } catch {
        closeSocket(fd)
        throw error
    }
}

private func waitForTCPPort(_ port: UInt16, timeout: Duration) async throws -> Bool {
    try await waitUntil(timeout: timeout) {
        guard let fd = try? connectSocket(port: port) else { return false }
        closeSocket(fd)
        return true
    }
}

private func reserveUnusedTCPPort() throws -> UInt16 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw LiveSocketError.posix("socket", errno) }
    defer { closeSocket(fd) }

    var reuse: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

    let bindResult = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
            Darwin.bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bindResult == 0 else { throw LiveSocketError.posix("bind", errno) }

    var bound = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameResult = withUnsafeMutablePointer(to: &bound) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
            getsockname(fd, sockaddrPointer, &length)
        }
    }
    guard nameResult == 0 else { throw LiveSocketError.posix("getsockname", errno) }
    return UInt16(bigEndian: bound.sin_port)
}

private func connectSocket(port: UInt16) throws -> Int32 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw LiveSocketError.posix("socket", errno) }

    var noSigpipe: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

    let connectResult = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
            Darwin.connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connectResult == 0 else {
        let err = errno
        closeSocket(fd)
        throw LiveSocketError.posix("connect", err)
    }
    return fd
}

private func writeAll(fd: Int32, _ data: Data) throws {
    try data.withUnsafeBytes { rawBuffer in
        guard let base = rawBuffer.baseAddress else { return }
        var written = 0
        while written < rawBuffer.count {
            let result = Darwin.send(fd, base.advanced(by: written), rawBuffer.count - written, 0)
            guard result > 0 else { throw LiveSocketError.posix("send", errno) }
            written += result
        }
    }
}

private func closeSocket(_ fd: Int32) {
    _ = Darwin.shutdown(fd, SHUT_RDWR)
    _ = Darwin.close(fd)
}

private func abortSocket(_ fd: Int32) {
    var lingerOption = linger(l_onoff: 1, l_linger: 0)
    setsockopt(fd, SOL_SOCKET, SO_LINGER, &lingerOption, socklen_t(MemoryLayout<linger>.size))
    _ = Darwin.close(fd)
}

private enum LiveSocketError: Error, CustomStringConvertible {
    case posix(String, Int32)

    var description: String {
        switch self {
        case .posix(let operation, let code):
            return "\(operation) failed: \(String(cString: strerror(code)))"
        }
    }
}
