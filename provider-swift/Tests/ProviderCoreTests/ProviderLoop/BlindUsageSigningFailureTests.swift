import Foundation
import Testing

@testable import ProviderCore

#if DEBUG
/// A served blind request whose usage cannot be signed, as the coordinator
/// receives it from `ProviderLoop.run()`: the request ends with
/// `encryption_failure`, never a completion without its signed usage.
@Suite("Blind usage signing failure", .serialized)
struct BlindUsageSigningFailureTests {
    @Test("a blind request whose usage cannot be signed ends with encryption_failure, sending nothing unsigned")
    func unsignableUsage() async throws {
        let (fixture, task) = try await BlindRequestServeTests.serving()
        await fixture.loop.setBlindUsageSigningFailsForTesting(true)
        let recipient = await fixture.loop.keyPair.publicKeyBytes
        let request = BlindRequestFixture()
        let requestID = request.requestID
        try await fixture.mock.pushInferenceRequest(try request.frame(recipient: recipient))
        try await fixture.awaitSubmissions(1)
        fixture.completeSubmission(0)
        let done = try await fixture.mock.waitForSnapshot(timeout: .seconds(10)) {
            ServeLoopFixture.terminalCount($0, requestId: requestID) > 0
        }
        let snapshot = try #require(done)
        #expect(await fixture.stop(task))

        #expect(ServeLoopFixture.terminalCount(snapshot, requestId: requestID) == 1)
        #expect(!snapshot.inferenceComplete.contains { $0.requestId == requestID })
        let error = try #require(snapshot.inferenceErrors.first { $0.requestId == requestID })
        #expect(error.failureCode == .encryptionFailure)
        #expect(error.statusCode == 502)
        #expect(error.blindRefusal == nil)
        let frames = try snapshot.inferenceErrorFrames.compactMap {
            try JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        let raw = try #require(frames.first { $0["request_id"] as? String == requestID })
        for key in ["blind_usage", "stop_sequence", "response_hash", "se_signature", "encrypted_usage", "usage"] {
            #expect(raw[key] == nil, "\(key)")
        }
    }
}
#endif
