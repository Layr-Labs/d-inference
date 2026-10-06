import Testing

@testable import ProviderCore

struct ServingQualificationCollectorTests {
    @Test(arguments: [false, true])
    func normalIteratorEndPreservesAuthoritativeEngineCancellation(hasContent: Bool) async throws {
        let stream = AsyncThrowingStream<String, Error> { continuation in
            if hasContent { continuation.yield("content") }
            continuation.finish()
        }
        var contentSeen = false
        for try await _ in stream { contentSeen = true }
        #expect(ServingQualificationFixture.collectionFailure(observedFailure: nil,
            terminalReason: .cancelled, hasContent: contentSeen) == "cancelled")
    }

    @Test func naturalOrMissingTerminalDoesNotInventCancellation() {
        let reasons: [EngineFinishReason?] = [nil, .length, .stop, .stopSequence]
        for reason in reasons {
            #expect(ServingQualificationFixture.collectionFailure(observedFailure: nil,
                terminalReason: reason, hasContent: true) == nil)
            #expect(ServingQualificationFixture.collectionFailure(observedFailure: nil,
                terminalReason: reason, hasContent: false) == "no_first_content")
        }
    }

    @Test func authoritativeCancellationPreservesAnEarlierFailure() {
        #expect(ServingQualificationFixture.collectionFailure(observedFailure: "request_failed",
            terminalReason: .cancelled, hasContent: true) == "request_failed")
    }
}
