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
}
