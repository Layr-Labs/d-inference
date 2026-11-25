import Foundation
import Testing

@testable import ProviderCore

#if DEBUG
/// What a frame or body marked blind gets from `ProviderLoop.run()` when the
/// provider cannot verify it: a refusal, never an answer as an ordinary request.
@Suite("Blind frames on the wire", .serialized)
struct BlindFrameWireTests {
    @Test("a frame with a blind member it cannot verify is refused, never served")
    func unverifiableBlindFrameIsRefused() async throws {
        let fixture = try await ServeLoopFixture.make()
        let task = fixture.start()
        _ = try await fixture.awaitRegistration()
        let providerKey = try #require(Data(base64Encoded: await fixture.loop.keyPair.publicKeyBase64))
        let body = try JSONSerialization.data(withJSONObject: [
            "model": ServeLoopFixture.modelId, "messages": [["role": "user", "content": "fixture"]],
            "max_tokens": 1, "stream": true, "reasoning_parser": "none",
        ])
        let sealed = try NodeKeyPair.generate().encryptPayload(recipientPublicKey: providerKey, plaintext: body)
        let requestId = "blind-frame-\(UUID().uuidString)"
        try await fixture.mock.pushRawFrame([
            "type": "inference_request", "request_id": requestId,
            "encrypted_body": ["ephemeral_public_key": sealed.ephemeralPublicKey, "ciphertext": sealed.ciphertext],
            "blind": ["v": 1, "meta": Data("{}".utf8).base64EncodedString()],
            "signed_request": "e30.e30.AAAA",
        ])
        let done = try await fixture.mock.waitForSnapshot(timeout: .seconds(10)) {
            ServeLoopFixture.terminalCount($0, requestId: requestId) > 0
        }
        let submissions = fixture.engine.ordinarySubmissionCount
        #expect(await fixture.stop(task))
        let snapshot = try #require(done)
        #expect(!snapshot.inferenceComplete.contains { $0.requestId == requestId })
        let error = try #require(snapshot.inferenceErrors.first { $0.requestId == requestId })
        #expect(error.failureCode?.rawValue == "blind_refused")
        #expect(error.statusCode == 502)
        #expect(submissions == 0)
    }

    @Test("an ordinary frame whose body is sealed as a blind request is refused")
    func blindBodyOnAnOrdinaryFrameIsRefused() async throws {
        let fixture = try await ServeLoopFixture.make()
        let task = fixture.start()
        _ = try await fixture.awaitRegistration()
        let requestId = "blind-body-\(UUID().uuidString)"
        try await fixture.pushChatRequest(requestId: requestId, body: try JSONSerialization.data(withJSONObject: [
            "model": ServeLoopFixture.modelId, "messages": [["role": "user", "content": "fixture"]],
            "max_tokens": 1, "stream": true, "reasoning_parser": "none",
            "_darkbloom_blind": ["v": 1, "meta_sha256": "", "nonce": "n", "cred": "c", "ts": 0],
        ]))
        let done = try await fixture.mock.waitForSnapshot(timeout: .seconds(10)) {
            ServeLoopFixture.terminalCount($0, requestId: requestId) > 0
        }
        let submissions = fixture.engine.ordinarySubmissionCount
        #expect(await fixture.stop(task))
        let error = try #require(try #require(done).inferenceErrors.first { $0.requestId == requestId })
        #expect(error.statusCode == 400)
        #expect(error.refusalReason?.rawValue == "sealed_for_blind_request")
        #expect(submissions == 0)
    }
}
#endif
