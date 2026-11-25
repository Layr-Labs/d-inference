import CryptoKit
import Foundation
import Testing

@testable import ProviderCore

#if DEBUG
/// A served blind request's completion as the coordinator receives it from
/// `ProviderLoop.run()`: beside the clear usage and the sealed usage, a usage
/// statement this Mac signs over the request's terms, the usage, and digests of
/// the frames and the sealed usage it sent.
@Suite("Blind usage in the serve loop", .serialized)
struct BlindUsageServeTests {
    /// The field names of a usage statement, in signed order.
    static let fields = [
        "request_id", "signed_request_sha256", "recipient_public_key", "client_public_key", "client_nonce",
        "model", "max_tokens", "prompt_tokens", "completion_tokens", "reasoning_tokens", "cached_tokens",
        "finish_reason", "chunk_count", "frames_sha256", "sealed_usage_sha256", "issued_at_ms",
    ]

    static func object(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The completion frame of `requestID`, as sent.
    static func completeFrame(_ fixture: ServeLoopFixture, _ requestID: String) throws -> [String: Any] {
        let frames = try fixture.mock.snapshot().inferenceCompleteFrames.map(object)
        return try #require(frames.first { $0["request_id"] as? String == requestID })
    }

    @Test("a served blind request's completion carries its usage, signed over its terms, frames and sealed usage")
    func signedUsage() async throws {
        let (fixture, task) = try await BlindRequestServeTests.serving()
        let recipient = await fixture.loop.keyPair.publicKeyBytes
        let request = BlindRequestFixture()
        let requestID = request.requestID
        let frame = try request.frame(recipient: recipient)
        try await fixture.mock.pushInferenceRequest(frame)
        try await fixture.awaitSubmissions(1)
        fixture.completeSubmission(0)
        let done = try await fixture.mock.waitForSnapshot(timeout: .seconds(10)) {
            ServeLoopFixture.terminalCount($0, requestId: requestID) > 0
        }
        let snapshot = try #require(done)
        #expect(await fixture.stop(task))

        let complete = try Self.completeFrame(fixture, requestID)
        let signed = try #require(complete["blind_usage"] as? [String: Any])
        let statement = try #require(signed["statement"] as? [String: Any])
        #expect(Set(statement.keys) == Set(Self.fields))
        let jws = try #require(frame.blind?.signedRequest)
        #expect(statement["request_id"] as? String == requestID)
        #expect(statement["signed_request_sha256"] as? String == BlindRequestFixture.digest(of: jws))
        #expect(statement["recipient_public_key"] as? String == recipient.base64EncodedString())
        #expect(statement["client_public_key"] as? String == request.client.publicKeyBytes.base64EncodedString())
        #expect(statement["client_nonce"] as? String == request.nonce)
        #expect(statement["model"] as? String == request.model)
        #expect(statement["max_tokens"] as? Int == request.maxTokens)
        #expect(statement["finish_reason"] as? String == "length")

        // The numbers are the clear usage's.
        let usage = try #require(complete["usage"] as? [String: Any])
        #expect(statement["prompt_tokens"] as? Int == usage["prompt_tokens"] as? Int)
        #expect(statement["completion_tokens"] as? Int == usage["completion_tokens"] as? Int)
        #expect(statement["reasoning_tokens"] as? Int == (usage["reasoning_tokens"] as? Int ?? 0))
        #expect(statement["cached_tokens"] as? Int == (usage["cached_tokens"] as? Int ?? 0))

        // The digests are of the frames and the sealed usage as sent.
        let chunks = snapshot.inferenceChunks.filter { $0.requestId == requestID }
        #expect(statement["chunk_count"] as? Int == chunks.count)
        var frames = SHA256()
        for chunk in chunks {
            let payload = try #require(chunk.encryptedData)
            let box = try #require(Data(base64Encoded: payload.ciphertext))
            frames.update(data: box)
        }
        #expect(statement["frames_sha256"] as? String == Data(frames.finalize()).base64EncodedString())
        let sealed = try #require(complete["encrypted_usage"] as? [String: Any])
        let sealedText = try #require(sealed["ciphertext"] as? String)
        let sealedBytes = try #require(Data(base64Encoded: sealedText))
        #expect(statement["sealed_usage_sha256"] as? String == Data(SHA256.hash(data: sealedBytes)).base64EncodedString())
        let sender = try #require(sealed["ephemeral_public_key"] as? String)
        let opened = try Self.object(request.client.decryptPayload(
            EncryptedPayload(ephemeralPublicKey: sender, ciphertext: sealedText)))
        #expect(opened["chunk_count"] as? Int == chunks.count)

        // The signature covers the fields' string forms in order.
        var bytes = Data()
        func append(_ text: String) {
            withUnsafeBytes(of: UInt32(text.utf8.count).bigEndian) { bytes.append(contentsOf: $0) }
            bytes.append(Data(text.utf8))
        }
        append("darkbloom-blind-usage-v1")
        for field in Self.fields {
            let value = try #require(statement[field])
            if let text = value as? String {
                append(text)
            } else {
                let number = try #require(value as? Int)
                append(String(number))
            }
        }
        let key = try P256.Signing.PublicKey(
            rawRepresentation: #require(Data(base64Encoded: fixture.signer.publicKeyBase64)))
        let signatureText = try #require(signed["signature"] as? String)
        let signature = try P256.Signing.ECDSASignature(derRepresentation: #require(Data(base64Encoded: signatureText)))
        #expect(key.isValidSignature(signature, for: bytes))
    }

    @Test("an ordinary request's completion carries no blind usage")
    func ordinaryCompletion() async throws {
        let (fixture, task) = try await BlindRequestServeTests.serving()
        let requestID = "ordinary-\(UUID().uuidString)"
        try await fixture.pushChatRequest(requestId: requestID)
        try await fixture.awaitSubmissions(1)
        fixture.completeSubmission(0)
        _ = try await fixture.mock.waitForSnapshot(timeout: .seconds(10)) {
            ServeLoopFixture.terminalCount($0, requestId: requestID) > 0
        }
        #expect(await fixture.stop(task))
        #expect(try Self.completeFrame(fixture, requestID)["blind_usage"] == nil)
    }
}
#endif
