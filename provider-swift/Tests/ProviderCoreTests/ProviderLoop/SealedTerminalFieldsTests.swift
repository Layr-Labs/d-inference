import CryptoKit
import Foundation
import Testing

@testable import ProviderCore

#if DEBUG
/// The fields that end a response (the matched stop sequence, the response
/// hash and its signature) as the coordinator receives them from
/// `ProviderLoop.run()`: inside the sealed usage only, for a coordinator that
/// advertises reading them there on its connection; as clear copies for every
/// other coordinator, exactly as before.
@Suite("Sealed terminal fields", .serialized)
struct SealedTerminalFieldsTests {
    static let feature = "terminal_fields_sealed"

    @Test("the registration says the provider seals them")
    func registrationAdvertisesSealing() async throws {
        let fixture = try await ServeLoopFixture.make()
        let task = fixture.start()
        _ = try await fixture.awaitRegistration()
        let frame = try #require(await fixture.mock.snapshot().registerFrames.first)
        let object = try #require(try JSONSerialization.jsonObject(with: frame) as? [String: Any])
        #expect(object[Self.feature] as? Int == 1)
        #expect(await fixture.stop(task))
    }

    @Test("a coordinator that reads them gets them only inside the sealed usage")
    func sealedForACoordinatorThatReadsThem() async throws {
        let run = try await serve(coordinatorFeatures: [Self.feature, "unrelated_feature"])
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
        // The usage and frame count are those of a usage sealed without them.
        #expect(run.opened["chunk_count"] as? Int == run.chunkCount)
        let usage = try #require(run.opened["usage"] as? [String: Any])
        #expect(usage["completion_tokens"] as? Int == Int(run.complete.usage.completionTokens))
    }

    @Test("every other coordinator gets the clear copies and a usage sealed without them",
          arguments: [nil, [], ["unrelated_feature"]] as [[String]?])
    func clearForEveryOtherCoordinator(features: [String]?) async throws {
        let run = try await serve(coordinatorFeatures: features)
        #expect(run.complete.stopSequence == "a")
        let hash = try #require(run.complete.responseHash)
        #expect(hash.count == 64)
        #expect(run.complete.seSignature != nil)
        #expect(Set(run.opened.keys) == ["chunk_count", "usage"])
    }

    @Test("an advertisement ends with a trust status that drops it")
    func aLaterTrustStatusWithoutItRestoresTheClearCopies() async throws {
        let run = try await serve(coordinatorFeatures: [Self.feature], thenFeatures: ["unrelated_feature"])
        #expect(run.complete.responseHash != nil)
        #expect(run.complete.stopSequence == "a")
        #expect(Set(run.opened.keys) == ["chunk_count", "usage"])
    }

    @Test("a usage that cannot be sealed fails the request for a coordinator that reads them")
    func unsealableUsageFailsInsteadOfSendingClearCopies() async throws {
        let outcome = try await serveWithFailingUsageSeal(coordinatorFeatures: [Self.feature])
        #expect(outcome.complete == nil)
        let error = try #require(outcome.error)
        #expect(error.failureCode == .encryptionFailure)
        #expect(error.statusCode == 502)
    }

    @Test("a usage that cannot be sealed still completes, with the clear copies, for every other coordinator")
    func unsealableUsageKeepsTheClearCopiesElsewhere() async throws {
        let outcome = try await serveWithFailingUsageSeal(coordinatorFeatures: nil)
        #expect(outcome.error == nil)
        let complete = try #require(outcome.complete)
        #expect(complete.encryptedUsage == nil)
        #expect(complete.stopSequence == "a")
        #expect(complete.responseHash != nil)
    }

    struct Run {
        var complete: ProviderMessage.InferenceComplete
        var opened: [String: Any]
        var chunkCount: Int
        var signerPublicKey: String
    }

    /// Serves one request whose usage seal fails, after a trust status with
    /// `coordinatorFeatures`, and returns its terminal.
    func serveWithFailingUsageSeal(coordinatorFeatures: [String]?) async throws
        -> (complete: ProviderMessage.InferenceComplete?, error: ProviderMessage.InferenceError?) {
        let fixture = try await ServeLoopFixture.make()
        await fixture.loop.setUsageSealFailsForTesting(true)
        let task = fixture.start()
        _ = try await fixture.awaitRegistration()
        try await fixture.mock.pushTrustStatus(.init(
            trustLevel: "hardware", status: "normal", coordinatorFeatures: coordinatorFeatures))
        let requestId = "terminal-fields-unsealed-\(UUID().uuidString)"
        try await fixture.pushChatRequest(requestId: requestId, body: Self.stoppingRequest())
        try await fixture.awaitSubmissions(1)
        Self.finishWithStop(fixture.engine.continuations[0])
        let done = try await fixture.mock.waitForSnapshot(timeout: .seconds(10)) {
            ServeLoopFixture.terminalCount($0, requestId: requestId) > 0
        }
        let snapshot = try #require(done)
        #expect(ServeLoopFixture.terminalCount(snapshot, requestId: requestId) == 1)
        #expect(await fixture.stop(task))
        return (snapshot.inferenceComplete.first { $0.requestId == requestId },
                snapshot.inferenceErrors.first { $0.requestId == requestId })
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

    /// Serves one request whose stop sequence ends it, after a trust status
    /// with `coordinatorFeatures` (and then one with `thenFeatures`, if given).
    func serve(coordinatorFeatures: [String]?, thenFeatures: [String]? = nil) async throws -> Run {
        let fixture = try await ServeLoopFixture.make()
        let task = fixture.start()
        _ = try await fixture.awaitRegistration()
        try await fixture.mock.pushTrustStatus(.init(
            trustLevel: "hardware", status: "normal", coordinatorFeatures: coordinatorFeatures))
        if let thenFeatures {
            try await fixture.mock.pushTrustStatus(.init(
                trustLevel: "hardware", status: "normal", coordinatorFeatures: thenFeatures))
        }

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
