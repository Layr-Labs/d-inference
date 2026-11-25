import CryptoKit
import Foundation
import MLXLMCommon
import Testing

@testable import ProviderCore

#if DEBUG
/// The fields that end a response (the finish reason, the matched stop
/// sequence, the response hash and its signature) as the coordinator receives
/// them from `ProviderLoop.run()`: only inside the sealed usage, on every
/// connection, whatever the coordinator advertises.
@Suite("Sealed terminal fields", .serialized)
struct SealedTerminalFieldsTests {
    @Test("the registration says the provider seals them")
    func registrationAdvertisesSealing() async throws {
        let fixture = try await ServeLoopFixture.make()
        let task = fixture.start()
        _ = try await fixture.awaitRegistration()
        let frame = try #require(await fixture.mock.snapshot().registerFrames.first)
        let object = try #require(try JSONSerialization.jsonObject(with: frame) as? [String: Any])
        #expect(object["terminal_fields_sealed"] as? Int == 1)
        #expect(await fixture.stop(task))
    }

    @Test("they are sealed even when coordinator_features lacks the flag",
          arguments: [nil, [], ["unrelated_feature"], ["terminal_fields_sealed"]] as [[String]?])
    func sealedWhateverTheCoordinatorAdvertises(features: [String]?) async throws {
        let run = try await serve(coordinatorFeatures: features)
        #expect(run.complete.stopSequence == nil)
        #expect(run.complete.responseHash == nil)
        #expect(run.complete.seSignature == nil)

        #expect(run.opened["stop_sequence"] as? String == "a")
        #expect(run.opened["finish_reason"] as? String == "stop")
        let hash = try #require(run.opened["response_hash"] as? String)
        #expect(hash.count == 64)
        let signature = try #require((run.opened["se_signature"] as? String).flatMap { Data(base64Encoded: $0) })
        let publicKey = try P256.Signing.PublicKey(
            rawRepresentation: #require(Data(base64Encoded: run.signerPublicKey)))
        #expect(publicKey.isValidSignature(
            try P256.Signing.ECDSASignature(derRepresentation: signature), for: Data(hash.utf8)))
        #expect(run.opened["chunk_count"] as? Int == run.chunkCount)
        let usage = try #require(run.opened["usage"] as? [String: Any])
        #expect(usage["completion_tokens"] as? Int == Int(run.complete.usage.completionTokens))
        // The clear profile names the stop string's finish only as `stop`.
        #expect(run.complete.profile?.engine?.finishReason == .stop)
    }

    struct Run {
        var complete: ProviderMessage.InferenceComplete
        var opened: [String: Any]
        var chunkCount: Int
        var signerPublicKey: String
    }

    /// A request whose stop sequence ends it: the fixture's tokenizer decodes
    /// every token as "a".
    static func stoppingRequest() throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "model": ServeLoopFixture.modelId,
            "messages": [["role": "user", "content": "fixture"]],
            "max_tokens": 4, "stream": true, "reasoning_parser": "none", "stop": ["a"],
        ])
    }

    static func finishWithStop(_ continuation: AsyncStream<CBv2Event>.Continuation) {
        continuation.yield(.delta(text: "a", tokens: [5], logprobs: nil))
        continuation.yield(.finished(reason: .stop, usage: .init(promptTokens: 3, completionTokens: 1)))
        continuation.finish()
    }

    /// Serves one stopping request after a trust status with `coordinatorFeatures`.
    func serve(coordinatorFeatures: [String]?) async throws -> Run {
        let fixture = try await ServeLoopFixture.make()
        let task = fixture.start()
        _ = try await fixture.awaitRegistration()
        try await fixture.mock.pushTrustStatus(.init(
            trustLevel: "hardware", status: "normal", coordinatorFeatures: coordinatorFeatures))

        let consumer = NodeKeyPair.generate()
        let requestId = "terminal-fields-\(UUID().uuidString)"
        try await fixture.pushChatRequest(requestId: requestId, consumer: consumer, body: Self.stoppingRequest())
        try await fixture.awaitSubmissions(1)
        Self.finishWithStop(fixture.engine.continuations[0])

        let done = try await fixture.mock.waitForSnapshot(timeout: .seconds(10)) {
            $0.inferenceComplete.contains { $0.requestId == requestId }
        }
        let snapshot = try #require(done)
        let complete = try #require(snapshot.inferenceComplete.first { $0.requestId == requestId })
        let sealed = try #require(complete.encryptedUsage)
        let opened = try #require(
            try JSONSerialization.jsonObject(with: consumer.decryptPayload(sealed)) as? [String: Any])
        let chunkCount = snapshot.inferenceChunks.filter { $0.requestId == requestId }.count
        #expect(await fixture.stop(task))
        return Run(complete: complete, opened: opened, chunkCount: chunkCount,
                   signerPublicKey: fixture.signer.publicKeyBase64)
    }
}
#endif
