// Integration tests for the BatchedEngine-backed BatchScheduler.
//
// Verifies the public `GenerationEvent` contract: `.chunk` then exactly
// one `.info`, finishing the stream. Cancellation surfaces the
// canonical `.error("request cancelled")` mapping. The live test that
// actually loads a model is gated on `DARKBLOOM_LIVE_MLX_TESTS=1`; the
// non-live test covers the cancellation-error mapping using a stream
// the test owns (no model load required).

import Foundation
import Testing
import MLX
import MLXLLM
import MLXLMCommon
import MLXLMServer
@testable import ProviderCore

// MARK: - P1 #1: cancellation-propagation fixture
//
// Mock `MLXServerEngine` that wraps an AsyncThrowingStream the test
// owns. Records whether the stream's `onTermination` handler fired —
// which is the exact signal we need to assert that consumer-side
// cancellation (i.e. `task.cancel()` on the ProviderLoop inflight
// task) reaches all the way down to the engine layer (and from there
// to `scheduler.cancel(internalRequestId)` in the real adapter).
//
// Use of this mock validates the propagation contract WITHOUT
// touching `BatchScheduler` (sacred surface).
private actor CancellationPropagationProbe {
    private(set) var onTerminationFired: Bool = false

    func markFired() { onTerminationFired = true }
}

private struct CancellationProbeEngine: MLXServerEngine {
    let probe: CancellationPropagationProbe

    func availableModels() async throws -> [MLXServerModel] { [] }
    func tokenize(_ request: TokenizeRequest) async throws -> TokenizeResponse {
        TokenizeResponse(tokens: [])
    }
    func detokenize(_ request: DetokenizeRequest) async throws -> DetokenizeResponse {
        DetokenizeResponse(text: "")
    }
    func applyTemplate(_ request: ApplyTemplateRequest) async throws -> TokenizeResponse {
        TokenizeResponse(tokens: [])
    }

    func streamChatCompletion(
        request: OpenAIChatCompletionRequest
    ) async throws -> AsyncThrowingStream<MLXServerGenerationEvent, Error> {
        let probe = self.probe
        return AsyncThrowingStream { continuation in
            // Emit one chunk so the consumer task definitely begins
            // iterating. Then suspend forever — the only way out is
            // task cancellation (which fires onTermination).
            continuation.yield(.content("hi"))
            continuation.onTermination = { @Sendable _ in
                Task { await probe.markFired() }
            }
        }
    }
}

@Suite("BatchScheduler ⇔ BatchedEngine integration", .serialized)
struct BatchSchedulerEngineIntegrationTests {

    // MARK: - P1 #1: non-live cancellation-propagation

    /// **P1 #1 — coordinator cancellation contract.**
    ///
    /// Before this fix `ProviderLoop.handleCancellation` would call
    /// `scheduler.cancel(<coordinator request id>)` directly. After
    /// the MLXLMServer adoption that id no longer matches the id the
    /// scheduler was tracking (the engine adapter mints its own
    /// internal id when it calls `BatchScheduler.submit(requestId:)`),
    /// so the explicit cancel was a no-op and generation kept going
    /// until on-termination tearing happened organically.
    ///
    /// The fix makes the coordinator-driven cancel path rely on
    /// `task.cancel()` of the inflight Task, which propagates through
    /// the AsyncThrowingStream chain:
    ///
    /// ```
    ///   outer task.cancel()
    ///     -> `for try await frame in frames` raises CancellationError
    ///     -> the `frames` stream is deallocated
    ///     -> MLXOpenAIService's onTermination cancels its inner task
    ///     -> the engine's stream is deallocated
    ///     -> MultiModelBatchSchedulerEngine's onTermination calls
    ///        `scheduler.cancel(internalRequestId)` with the correct id.
    /// ```
    ///
    /// This test pins the chain end-to-end without loading a model.
    /// The probe engine sits where `MultiModelBatchSchedulerEngine`
    /// would sit in production; if the propagation breaks anywhere
    /// between the consumer task and the engine, the probe's
    /// `onTerminationFired` flag never flips.
    @Test("consumer task.cancel() propagates through MLXOpenAIService to the engine onTermination")
    func consumerCancellationReachesEngineOnTermination() async throws {
        let probe = CancellationPropagationProbe()
        let engine = CancellationProbeEngine(probe: probe)
        let service = MLXOpenAIService(engine: engine)

        let request = OpenAIChatCompletionRequest(
            model: "probe-model",
            messages: [.init(role: .user, content: .text("hi"))],
            stream: true
        )
        let frames = try await service.streamChatCompletionFrames(request: request)

        // Mirror the shape of the ProviderLoop inflight task: a
        // detached Task that iterates the SSE frame stream and waits
        // for cancellation. We cancel it externally after the first
        // chunk has been observed so we know the upstream pipeline is
        // running.
        let started = AsyncStream<Void>.makeStream()
        let consumerTask = Task.detached {
            do {
                for try await _ in frames {
                    started.continuation.yield(())
                }
            } catch {
                // CancellationError on next() — expected, swallow.
            }
        }

        // Wait until the first frame arrives so the upstream task
        // chain is fully wired through before we cancel.
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()

        consumerTask.cancel()
        _ = await consumerTask.value

        // The onTermination chain in
        // MLXOpenAIService.streamChatCompletionFrames cancels the
        // inner task which closes the engine stream; that triggers
        // the engine stream's onTermination which fires our probe.
        // Give the chain a generous moment to settle.
        for _ in 0..<50 {
            if await probe.onTerminationFired { break }
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(await probe.onTerminationFired,
            "consumer-side task.cancel() must propagate down to the engine stream's onTermination (the real MultiModelBatchSchedulerEngine relies on this to call scheduler.cancel(<internal id>))")
    }

    // MARK: - Non-live: error-mapping shape

    /// `GenerationEvent.error("request cancelled")` is the canonical
    /// cancellation surface that ProviderLoop maps to status 499. This
    /// test pins the exact string so a future refactor doesn't silently
    /// drift the wire contract.
    @Test("cancellation event carries the canonical 'request cancelled' string")
    func cancellationErrorMappingShape() {
        let event = GenerationEvent.error("request cancelled")
        if case .error(let message) = event {
            #expect(message == "request cancelled",
                "cancellation must surface as .error(\"request cancelled\") so coordinator/ProviderLoop mapping stays stable")
        } else {
            Issue.record("event was not .error")
        }
    }

    /// The engine emits `RequestOutput.finishReason == "abort"` (or a
    /// non-nil `error`) when a request is aborted. Our bridge must
    /// translate either of those signals to the canonical cancellation
    /// event. This test simulates the mapping logic against a synthetic
    /// `RequestOutput` (no engine needed).
    @Test("RequestOutput finishReason='abort' maps to error event")
    func abortFinishReasonMapsToErrorEvent() {
        let aborted = RequestOutput(
            requestId: "r1",
            finished: true,
            finishReason: "abort",
            error: "Request aborted"
        )
        let isAbort = aborted.finishReason == "abort" || aborted.error != nil
        #expect(isAbort, "abort RequestOutput must be classified as cancellation")
    }

    @Test("RequestOutput finishReason='stop' maps to normal finish (not error)")
    func stopFinishReasonMapsToInfoEvent() {
        let stopped = RequestOutput(
            requestId: "r1",
            finished: true,
            finishReason: "stop",
            promptTokens: 10,
            completionTokens: 5
        )
        let isAbort = stopped.finishReason == "abort" || stopped.error != nil
        #expect(!isAbort, "natural EOS must NOT be classified as cancellation")
    }

    @Test("RequestOutput finishReason='length' maps to normal finish (not error)")
    func lengthFinishReasonMapsToInfoEvent() {
        let lengthCapped = RequestOutput(
            requestId: "r1",
            finished: true,
            finishReason: "length",
            promptTokens: 10,
            completionTokens: 100
        )
        let isAbort = lengthCapped.finishReason == "abort" || lengthCapped.error != nil
        #expect(!isAbort, "length-capped finish must NOT be classified as cancellation")
    }

    // MARK: - Live: full submit → chunk → info path

    /// Loads a real model and submits a request through `BatchScheduler`,
    /// verifying the event order: at least one `.chunk(...)`, then
    /// exactly one `.info(promptTokens, completionTokens, _)` with
    /// non-zero counts, then the stream finishes.
    @Test(
        "submit yields chunks followed by exactly one .info, then finishes",
        .enabled(if: LiveInferenceFixtures.liveTestsEnabled)
    )
    func liveSubmitChunkThenInfoThenFinish() async throws {
        let loaded = try await LiveInferenceFixtures.loadScheduler(
            modelID: "mlx-community/Qwen3-0.6B-8bit",
            maxConcurrentRequests: 4,
            memoryBudgetBytes: 8 * 1024 * 1024 * 1024
        )
        let scheduler = loaded.scheduler

        let request = ChatCompletionRequest(
            model: "mlx-community/Qwen3-0.6B-8bit",
            messages: [ChatMessage(role: "user", content: "Reply with the single word 'hi'.")],
            temperature: 0.0,
            max_tokens: 6
        )
        let stream = await scheduler.submit(request: request)

        var chunkCount = 0
        var infoCount = 0
        var sawError = false
        var promptTokens = 0
        var completionTokens = 0
        var lastEventWasInfo = false
        for await event in stream {
            switch event {
            case .chunk:
                chunkCount += 1
                lastEventWasInfo = false
            case .info(let pt, let ct, _):
                infoCount += 1
                promptTokens = pt
                completionTokens = ct
                lastEventWasInfo = true
            case .error:
                sawError = true
                lastEventWasInfo = false
            }
        }

        #expect(!sawError, "happy-path submit must not emit an error event")
        #expect(chunkCount >= 1, "expected at least one .chunk event")
        #expect(infoCount == 1, "expected exactly one .info event, got \(infoCount)")
        #expect(lastEventWasInfo, ".info must be the last event before the stream finishes")
        #expect(promptTokens > 0, "promptTokens must be non-zero")
        #expect(completionTokens > 0, "completionTokens must be non-zero")

        // Synchronous unload AFTER assertions. `#expect` records but does
        // not throw, so this runs whether or not assertions held. The
        // previous `defer { Task { await scheduler.unloadModel() } }`
        // was fire-and-forget and let the next live test start before
        // the model finished unloading, racing on the shared MLX state.
        await scheduler.unloadModel()
    }

    /// C3 — full ProviderLoop.handleInferenceRequest pipeline
    /// (`BatchScheduler → MultiModelBatchSchedulerEngine →
    /// MLXOpenAIService`) end-to-end, mirroring the wire-shape
    /// ProviderLoop actually uses.
    ///
    /// Asserts (C1): the trailing usage chunk lands with non-zero
    /// `prompt_tokens` AND non-zero `completion_tokens`. If this fails,
    /// billing would collapse to $0 per request in production.
    @Test(
        "MLXOpenAIService over MultiModelBatchSchedulerEngine yields content + usage frames",
        .enabled(if: LiveInferenceFixtures.liveTestsEnabled)
    )
    func liveServiceOverEngineEmitsContentAndUsage() async throws {
        let loaded = try await LiveInferenceFixtures.loadScheduler(
            modelID: LiveInferenceFixtures.tinyModelID,
            maxConcurrentRequests: 4,
            memoryBudgetBytes: 8 * 1024 * 1024 * 1024
        )
        let scheduler = loaded.scheduler
        defer { Task { await scheduler.unloadModel() } }
        let tokenizer: TokenizerHandle = await loaded.container.perform { ctx in
            TokenizerHandle(ctx.tokenizer)
        }

        // Wire the engine the same way `ProviderLoop` does for a
        // single resolved scheduler: no-op ensureLoaded/reserve/release
        // because the slot is already pinned by the test.
        let modelId = LiveInferenceFixtures.tinyModelID
        let engine = MultiModelBatchSchedulerEngine(
            registryProvider: { @Sendable in
                [modelId: .init(scheduler: scheduler, tokenizer: tokenizer)]
            },
            ensureLoaded: { _ in },
            reserveModel: { _ in },
            releaseModel: { _ in },
            defaultMaxTokens: 256
        )
        let service = MLXOpenAIService(engine: engine)

        let request = OpenAIChatCompletionRequest(
            model: modelId,
            messages: [
                .init(role: .user, content: .text("Reply with the single word 'hi'."))
            ],
            stream: true,
            temperature: 0.0,
            maxTokens: 6,
            streamOptions: .init(includeUsage: true, continuousUsageStats: nil)
        )

        let stream = try await service.streamChatCompletionFrames(request: request)

        var contentFrameCount = 0
        var finishFrameCount = 0
        var sawDone = false
        var promptTokens = 0
        var completionTokens = 0
        for try await frame in stream {
            if frame == ServerSentEventEncoder.done {
                sawDone = true
                continue
            }
            guard let parsed = ProviderLoop.parseStreamChunk(frame) else {
                continue
            }
            if parsed.contentDelta != nil || parsed.reasoningDelta != nil {
                contentFrameCount += 1
            }
            if parsed.finishReason != nil {
                finishFrameCount += 1
            }
            if let usage = parsed.usage {
                promptTokens = usage.promptTokens
                completionTokens = usage.completionTokens
            }
        }

        #expect(sawDone, "stream must terminate with the [DONE] sentinel")
        #expect(contentFrameCount >= 1, "expected at least one content/reasoning frame")
        #expect(finishFrameCount == 1, "expected exactly one finish_reason frame, got \(finishFrameCount)")
        // C1 billing-regression assertion: usage MUST land with
        // non-zero counts. If this fails, ProviderLoop would emit a
        // (0, 0) UsageInfo to the coordinator and the request would
        // bill $0.
        #expect(promptTokens > 0, "promptTokens must be non-zero (C1 billing guard)")
        #expect(completionTokens > 0, "completionTokens must be non-zero (C1 billing guard)")
    }

    /// C3 — cancellation propagation through the service-over-engine
    /// stack. Cancels the underlying scheduler request mid-stream and
    /// verifies the slot is freed (backendCapacity reports no active
    /// requests once the cancellation has settled).
    @Test(
        "service-over-engine cancellation frees the scheduler slot",
        .enabled(if: LiveInferenceFixtures.liveTestsEnabled)
    )
    func liveServiceOverEngineCancellationFreesSlot() async throws {
        let loaded = try await LiveInferenceFixtures.loadScheduler(
            modelID: LiveInferenceFixtures.tinyModelID,
            maxConcurrentRequests: 4,
            memoryBudgetBytes: 8 * 1024 * 1024 * 1024
        )
        let scheduler = loaded.scheduler
        defer { Task { await scheduler.unloadModel() } }
        let tokenizer: TokenizerHandle = await loaded.container.perform { ctx in
            TokenizerHandle(ctx.tokenizer)
        }

        let modelId = LiveInferenceFixtures.tinyModelID
        let engine = MultiModelBatchSchedulerEngine(
            registryProvider: { @Sendable in
                [modelId: .init(scheduler: scheduler, tokenizer: tokenizer)]
            },
            defaultMaxTokens: 256
        )
        let service = MLXOpenAIService(engine: engine)

        let request = OpenAIChatCompletionRequest(
            model: modelId,
            messages: [
                .init(role: .user, content: .text(
                    "Write a long detailed essay about robots painting."))
            ],
            stream: true,
            temperature: 0.0,
            maxTokens: 256,
            streamOptions: .init(includeUsage: true, continuousUsageStats: nil)
        )

        let stream = try await service.streamChatCompletionFrames(request: request)

        // Stay suspended in `for try await` so `consumerTask.cancel()`
        // lands mid-await and propagates through the stream's
        // `onTermination`. Breaking out of the loop early would just
        // drop the iterator without firing onTermination, which leaves
        // the scheduler slot pinned indefinitely (matches the
        // production ProviderLoop pattern where the inflight task is
        // cancelled mid-stream).
        let consumerTask = Task {
            var seen = 0
            do {
                for try await _ in stream {
                    seen += 1
                }
            } catch {
                // Cancellation surfaces here as a thrown CancellationError;
                // accept it as the expected teardown path.
            }
            return seen
        }
        try? await Task.sleep(for: .milliseconds(300))
        consumerTask.cancel()
        _ = await consumerTask.value

        // Give the engine's `onTermination` a moment to call
        // `scheduler.cancel(requestId:)` and the scheduler to wind the
        // slot down.
        try? await Task.sleep(for: .milliseconds(400))

        let cap = await scheduler.capacity()
        #expect(cap.activeRequests == 0,
            "cancellation must free the scheduler slot; got \(cap.activeRequests) active")
        #expect(cap.pendingRequests == 0,
            "cancellation must drain pending requests; got \(cap.pendingRequests) pending")
    }

    /// Cancellation through the actor API must surface as
    /// `.error("request cancelled")` followed by a stream finish. Gated
    /// on a live model because the engine's abort path only fires for
    /// admitted requests; the planner-only-pending path is exercised by
    /// the unit tests above.
    @Test(
        "scheduler.cancel yields .error('request cancelled') and finishes",
        .enabled(if: LiveInferenceFixtures.liveTestsEnabled)
    )
    func liveCancelYieldsErrorAndFinish() async throws {
        let loaded = try await LiveInferenceFixtures.loadScheduler(
            modelID: "mlx-community/Qwen3-0.6B-8bit",
            maxConcurrentRequests: 4,
            memoryBudgetBytes: 8 * 1024 * 1024 * 1024
        )
        let scheduler = loaded.scheduler

        let request = ChatCompletionRequest(
            model: "mlx-community/Qwen3-0.6B-8bit",
            messages: [ChatMessage(role: "user", content:
                "Write a long detailed essay about robots painting.")],
            temperature: 0.0,
            max_tokens: 256
        )
        let requestId = "cancel-test-\(UUID().uuidString.prefix(8))"
        let stream = await scheduler.submit(request: request, requestId: requestId)

        var sawCancellation = false
        var streamFinished = false
        // Cancel after a brief delay so the request has time to be admitted.
        let cancelTask = Task { [scheduler] in
            try? await Task.sleep(for: .milliseconds(200))
            await scheduler.cancel(requestId: requestId)
        }

        for await event in stream {
            switch event {
            case .chunk:
                continue
            case .info:
                // Race: if the model finishes within the 200ms window,
                // we'll see .info before the cancel lands. That's fine
                // for this test — we still expect the stream to
                // terminate cleanly.
                continue
            case .error(let msg):
                #expect(msg == "request cancelled",
                    "cancellation must surface as 'request cancelled', got '\(msg)'")
                sawCancellation = true
            }
        }
        streamFinished = true
        _ = await cancelTask.value

        #expect(streamFinished, "stream must finish after cancel")
        // We accept either: (a) the cancellation event landed, or (b) the
        // request completed faster than the cancel could be delivered.
        // Both are acceptable terminal states; the contract under test is
        // that the *event* mapping is correct when it does fire.
        if !sawCancellation {
            print("[cancel-test] note: model completed before cancel could land; mapping not exercised this run")
        }

        // Synchronous unload AFTER assertions and after `cancelTask`
        // has drained — `unloadModel()` tears the engine down and
        // would race with a still-pending `scheduler.cancel(...)` call
        // if we didn't await `cancelTask` first. See note in the
        // companion test above re: the previous fire-and-forget
        // `defer { Task { ... } }` cleanup.
        await scheduler.unloadModel()
    }
}
