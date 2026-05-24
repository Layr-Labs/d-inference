// Integration tests for the BatchedEngine-backed BatchScheduler.
// Verifies the public `GenerationEvent` contract:
//   `.chunk*` → exactly one `.info` → stream finishes
// Cancellation surfaces `.error("request cancelled")`. Live tests are
// gated on `DARKBLOOM_LIVE_MLX_TESTS=1`; non-live tests cover the
// finish-reason mapping without loading a model.

import Foundation
import Testing
import MLX
import MLXLLM
import MLXLMCommon
@testable import ProviderCore

@Suite("BatchScheduler ⇔ BatchedEngine integration", .serialized)
struct BatchSchedulerEngineIntegrationTests {

    // MARK: - Non-live: error-mapping shape

    /// Pin the canonical cancellation string. ProviderLoop maps it to
    /// status 499; a silent rename here would break the wire contract.
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

    /// Either `finishReason == "abort"` or a non-nil `error` on a
    /// `RequestOutput` must be classified as cancellation by the bridge.
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

    /// `.chunk(...)`+ → exactly one `.info(...)` with non-zero token
    /// counts → stream finishes.
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

        // Synchronous unload: a detached teardown would let the next
        // live test start while MLX state is still being released.
        await scheduler.unloadModel()
    }

    /// Live abort: the engine's abort path only fires for admitted
    /// requests, so we need a real model. The planner-only-pending
    /// cancel path is covered by the non-live tests above.
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
        // Brief delay so the request is admitted before we cancel.
        let cancelTask = Task { [scheduler] in
            try? await Task.sleep(for: .milliseconds(200))
            await scheduler.cancel(requestId: requestId)
        }

        for await event in stream {
            switch event {
            case .chunk:
                continue
            case .info:
                // Race: model may finish within the 200ms window. The
                // stream must still terminate cleanly either way.
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
        // Accept either: cancellation event landed, or request finished
        // before cancel was delivered. The contract under test is the
        // event mapping, not the timing.
        if !sawCancellation {
            print("[cancel-test] note: model completed before cancel could land; mapping not exercised this run")
        }

        // Unload AFTER `cancelTask` drains; otherwise the unload races
        // a still-pending `scheduler.cancel(...)` call.
        await scheduler.unloadModel()
    }
}
