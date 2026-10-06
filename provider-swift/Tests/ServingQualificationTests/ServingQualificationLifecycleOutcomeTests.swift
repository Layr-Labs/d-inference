import Testing

@testable import ProviderCore

struct ServingQualificationLifecycleOutcomeTests {
    @Test func naturalTerminalAfterConsumerCancellationIsNotEngineCancellation() async {
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            // A consumer can stop while the engine has already emitted length.
            return (Task.isCancelled, ServingQualificationLifecycleOutcome(engineFinishReason: .length))
        }
        task.cancel()
        let (consumerCancelled, outcome) = await task.value
        #expect(consumerCancelled)
        #expect(outcome.engineFinishReason == .length)
        #expect(!outcome.cancelled)
    }

    @Test func normalIteratorEndStillUsesAuthoritativeCancellation() async throws {
        let stream = AsyncThrowingStream<String, Error> { continuation in continuation.finish() }
        for try await _ in stream {}
        let outcome = ServingQualificationLifecycleOutcome(engineFinishReason: .cancelled)
        #expect(outcome.cancelled)
        #expect(outcome.engineFinishReason == .cancelled)
    }

    @Test func missingOrNaturalTerminalCannotQualifyCancellation() {
        let reasons: [EngineFinishReason?] = [nil, .stop, .stopSequence, .length]
        for reason in reasons {
            #expect(!ServingQualificationLifecycleOutcome(engineFinishReason: reason).cancelled)
        }
    }
}
