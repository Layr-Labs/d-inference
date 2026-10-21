import Foundation
import MLXLMCommon
import MLXLMServer
import Testing
@testable import ProviderCore

struct NemotronSuperImageHTTPRelayTests {
    @Test func backpressureKeepsFirstFailureAfterCancellation() async throws {
        let pair = AsyncThrowingStream<MLXServerGenerationEvent, Error>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let body = Data(("{\"model\":\"" + NemotronSuperLocalBinding.modelID
            + "\",\"messages\":[],\"enable_thinking\":false}").utf8)
        let output = try NemotronSuperLocalOutput(plan: .init(body: body), streaming: true)
        let relay = SuperImageHTTPRelay(continuation: pair.continuation, output: output)
        await relay.accept(.chunk("first"))
        await relay.accept(.chunk("over capacity"))
        await relay.fail(CancellationError())
        var count = 0
        do {
            for try await _ in pair.stream { count += 1 }
            Issue.record("backpressure completed without rejection")
        } catch MultiModelBatchSchedulerEngineError.requestRejected(let message) {
            #expect(message == "image response consumer is too slow")
        }
        #expect(count == 1)
    }

    /// A JSON answer with thinking off is held until validation, yet its first
    /// accepted chunk starts the stream: the caller stops waiting for headers
    /// while generation runs, and a failed validation ends the started stream
    /// with its error and nothing of the held text.
    @Test func heldOutputStartsAtTheFirstAcceptedChunk() async throws {
        let pair = AsyncThrowingStream<MLXServerGenerationEvent, Error>.makeStream(bufferingPolicy: .bufferingOldest(8))
        let body = Data(("{\"model\":\"" + NemotronSuperLocalBinding.modelID
            + "\",\"messages\":[],\"enable_thinking\":false,\"response_format\":{\"type\":\"json_object\"}}").utf8)
        let output = try NemotronSuperLocalOutput(plan: .init(body: body), streaming: true)
        let relay = SuperImageHTTPRelay(continuation: pair.continuation, output: output)
        await relay.accept(.chunk("not"))
        // Bounds the wait: a start this chunk did not signal fails it instead.
        let watchdog = Task {
            try await Task.sleep(for: .seconds(10))
            await relay.fail(MultiModelBatchSchedulerEngineError.generationFailed("the held chunk did not start the stream"))
        }
        try await relay.waitUntilStarted()
        watchdog.cancel()
        await relay.accept(.chunk(" json"))
        await relay.accept(.info(promptTokens: 3, completionTokens: 2, tokensPerSecond: 0, finishReason: "stop"))
        await relay.complete()
        var count = 0
        do {
            for try await _ in pair.stream { count += 1 }
            Issue.record("invalid held JSON completed")
        } catch let error as MLXOpenAIServiceError {
            guard case .invalidResponseFormatOutput = error else {
                Issue.record("unexpected validation error \(error)")
                return
            }
        }
        #expect(count == 0)
    }
}
