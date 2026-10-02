import Foundation
import Testing

@testable import ProviderCore

#if DEBUG
/// `ProviderLoop.run()` against a mock coordinator: what the event loop does
/// with each coordinator message, and what it sends back.
@Suite("Serve loop dispatch", .serialized)
struct ServeLoopDispatchTests {
    @Test("an inference request reaches the engine and streams encrypted chunks and usage back")
    func inferenceRequestIsServed() async throws {
        let fixture = try await ServeLoopFixture.make()
        let task = fixture.start()
        _ = try await fixture.awaitRegistration()

        let consumer = NodeKeyPair.generate()
        try await fixture.pushChatRequest(requestId: "served", consumer: consumer)
        try await fixture.awaitSubmissions(1)
        #expect(fixture.engine.ordinarySubmissionCount == 1)
        fixture.completeSubmission(0)

        let done = try await fixture.mock.waitForSnapshot(timeout: .seconds(10)) {
            $0.inferenceComplete.contains { $0.requestId == "served" }
        }
        let snapshot = try #require(done)
        let complete = try #require(snapshot.inferenceComplete.first { $0.requestId == "served" })
        #expect(complete.usage.promptTokens == 3)
        #expect(complete.usage.completionTokens == 1)
        #expect(ServeLoopFixture.terminalCount(snapshot, requestId: "served") == 1)

        // Response chunks are sealed to the consumer's key, never plaintext.
        let chunks = snapshot.inferenceChunks.filter { $0.requestId == "served" }
        #expect(!chunks.isEmpty)
        var text = ""
        for chunk in chunks {
            let sealed = try #require(chunk.encryptedData)
            text += String(decoding: try consumer.decryptPayload(sealed), as: UTF8.self)
        }
        #expect(text.contains("data: "))
        #expect(text.contains("\"a\""), "the engine's token text reaches the consumer")

        #expect(await fixture.stop(task))
    }

    @Test("a coordinator cancel stops the engine request and ends it with one terminal frame")
    func cancelStopsTheEngineRequest() async throws {
        let fixture = try await ServeLoopFixture.make()
        let task = fixture.start()
        _ = try await fixture.awaitRegistration()

        try await fixture.pushChatRequest(requestId: "cancelled")
        try await fixture.awaitSubmissions(1)
        try await fixture.mock.pushCancel(requestId: "cancelled")
        try await fixture.awaitEngineCancellations(1)

        let ended = try await fixture.mock.waitForSnapshot(timeout: .seconds(15)) {
            ServeLoopFixture.terminalCount($0, requestId: "cancelled") > 0
        }
        let snapshot = try #require(ended)
        #expect(ServeLoopFixture.terminalCount(snapshot, requestId: "cancelled") == 1)
        // Nothing was delivered, so the terminal is a 499 the coordinator refunds.
        let error = try #require(snapshot.inferenceErrors.first { $0.requestId == "cancelled" })
        #expect(error.statusCode == 499)
        #expect(error.failureCode == .cancelled)
        #expect(error.terminalCause == .cancelled)

        #expect(await fixture.stop(task))
    }

    @Test("a request sealed to another key is refused with 400 and never reaches the engine")
    func undecryptableRequestIsRefused() async throws {
        let fixture = try await ServeLoopFixture.make()
        let task = fixture.start()
        _ = try await fixture.awaitRegistration()

        let body = try JSONSerialization.data(withJSONObject: [
            "model": ServeLoopFixture.modelId,
            "messages": [["role": "user", "content": "fixture"]],
        ])
        try await fixture.mock.pushInferenceRequest(
            requestId: "wrong-key",
            providerPublicKeyBase64: NodeKeyPair.generate().publicKeyBase64,
            chatRequestJSON: body)

        let refused = try await fixture.mock.waitForSnapshot(timeout: .seconds(10)) {
            $0.inferenceErrors.contains { $0.requestId == "wrong-key" }
        }
        let error = try #require(refused?.inferenceErrors.first { $0.requestId == "wrong-key" })
        #expect(error.statusCode == 400)
        #expect(error.failureCode == .invalidRequest)
        #expect(fixture.engine.continuations.isEmpty)

        #expect(await fixture.stop(task))
    }

    @Test("a request body that is not a chat request is refused with 400")
    func malformedRequestIsRefused() async throws {
        let fixture = try await ServeLoopFixture.make()
        let task = fixture.start()
        _ = try await fixture.awaitRegistration()

        try await fixture.pushChatRequest(requestId: "malformed", body: Data("{\"model\": 7".utf8))

        let refused = try await fixture.mock.waitForSnapshot(timeout: .seconds(10)) {
            $0.inferenceErrors.contains { $0.requestId == "malformed" }
        }
        let error = try #require(refused?.inferenceErrors.first { $0.requestId == "malformed" })
        #expect(error.statusCode == 400)
        #expect(error.failureCode == .invalidRequest)
        #expect(fixture.engine.continuations.isEmpty)

        // The session stays up: the next valid request is served.
        try await fixture.pushChatRequest(requestId: "valid-after-malformed")
        try await fixture.awaitSubmissions(1)
        fixture.completeSubmission(0)
        let served = try await fixture.mock.waitForSnapshot(timeout: .seconds(10)) {
            $0.inferenceComplete.contains { $0.requestId == "valid-after-malformed" }
        }
        #expect(served != nil)

        #expect(await fixture.stop(task))
    }

    @Test("an attestation challenge gets a signed reply for the same nonce")
    func attestationChallengeIsAnswered() async throws {
        let fixture = try await ServeLoopFixture.make()
        let task = fixture.start()
        let register = try await fixture.awaitRegistration()

        try await fixture.mock.pushAttestationChallenge(
            nonce: "c2VydmUtbG9vcA==", timestamp: "2026-09-30T12:00:00Z")
        let answered = try await fixture.mock.waitForSnapshot(timeout: .seconds(10)) {
            !$0.attestationResponses.isEmpty
        }
        let response = try #require(answered?.attestationResponses.first)
        #expect(response.nonce == "c2VydmUtbG9vcA==")
        #expect(response.publicKey == register.publicKey)
        // The signature covers nonce + timestamp and verifies with the
        // signer's public key. Another nonce must not verify.
        let signature = try #require(Data(base64Encoded: response.signature))
        let signerKey = try #require(Data(base64Encoded: fixture.signer.publicKeyBase64))
        #expect(SecureEnclaveIdentity.verify(
            signature: signature,
            for: Data("c2VydmUtbG9vcA==2026-09-30T12:00:00Z".utf8),
            publicKey: signerKey))
        #expect(!SecureEnclaveIdentity.verify(
            signature: signature,
            for: Data("b3RoZXItbm9uY2U=2026-09-30T12:00:00Z".utf8),
            publicKey: signerKey))
        #expect(Set(response.modelHashes.keys) == [ServeLoopFixture.modelId],
                "the reply reports only the model this loop serves")

        #expect(await fixture.stop(task))
    }
}
#endif
