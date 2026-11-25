import Foundation
import Testing

@testable import ProviderCore

/// A blind request's refusals that follow from its opened body, as they leave:
/// one signed closed reason, `content_unsupported`, and nothing else.
@Suite("Blind content refusals")
struct BlindContentRefusalTests {
    static func verifiedFrame() throws -> (VerifiedBlindFrame, requestID: String) {
        let recipient = NodeKeyPair.generate().publicKeyBytes
        let request = BlindRequestFixture()
        let frame = try request.frame(recipient: recipient)
        let blind = try #require(frame.blind)
        let body = try #require(frame.encryptedBody)
        let ciphertext = try #require(Data(base64Encoded: body.ciphertext))
        let checked = BlindFrameCheck.verify(
            blind, requestID: frame.requestId, serviceReservationID: nil, ownPublicKey: recipient,
            senderPublicKey: request.client.publicKeyBytes, ciphertext: ciphertext,
            pins: [BlindRequestFixture.pin], now: Date())
        return (try checked.get(), frame.requestId)
    }

    static func failure(of message: OutboundMessage) -> (String, InferenceFailure)? {
        if case .inferenceError(let id, let failure, _) = message { return (id, failure) }
        return nil
    }

    @Test("failures that follow from the request's content, and only those, become content_unsupported")
    func classification() {
        #expect(InferenceFailure(code: .invalidRequest, statusCode: 400).followsFromRequestContent)
        #expect(InferenceFailure(code: .unsupportedMedia, statusCode: 415).followsFromRequestContent)
        #expect(InferenceFailure(code: .templateRender, statusCode: 400).followsFromRequestContent)
        #expect(InferenceFailure(code: .capacity, statusCode: 400, errorReason: .requestExceedsContext)
            .followsFromRequestContent)
        #expect(!InferenceFailure(code: .capacity, statusCode: 503, errorReason: .tokenBudgetExhausted)
            .followsFromRequestContent)
        #expect(!InferenceFailure(code: .modelUnavailable, statusCode: 503).followsFromRequestContent)
        #expect(!InferenceFailure(code: .generationFailure, statusCode: 500).followsFromRequestContent)
        #expect(!InferenceFailure(code: .cancelled, statusCode: 499).followsFromRequestContent)
    }

    @Test("once armed, a content failure leaves as a signed content_unsupported, without its detail or profile")
    func mapping() throws {
        let (verified, requestID) = try Self.verifiedFrame()
        let signer = ServeLoopTestSigner()
        let refusals = BlindContentRefusal(requestId: requestID, signer: signer)
        var content = InferenceFailure(code: .invalidRequest, statusCode: 400)
        content.refusal = .unsupportedAudio
        let message = OutboundMessage.inferenceError(requestId: requestID, failure: content, profile: RequestProfileBuilder())

        // Before the frame verified, nothing changes.
        #expect(Self.failure(of: refusals.map(message))?.1 == content)

        refusals.arm(verified)
        guard case .inferenceError(let id, let mapped, let profile) = refusals.map(message) else {
            Issue.record("not an error")
            return
        }
        #expect(id == requestID && profile == nil)
        #expect(mapped.code == .blindRefused && mapped.statusCode == 400 && mapped.refusal == nil)
        let statement = try #require(mapped.blindRefusal)
        #expect(statement.statement["reason"] == .text("content_unsupported"))
        #expect(statement.statement["signed_request_sha256"] == .text(verified.signature.jwsSHA256.base64EncodedString()))
        #expect(try BlindRequestFixture.refusalVerifies(statement, publicKeyBase64: signer.publicKeyBase64))

        // Load, capacity and other requests' failures pass unchanged.
        let busy = InferenceFailure(code: .capacity, statusCode: 503, errorReason: .capacityBusy)
        #expect(Self.failure(of: refusals.map(.inferenceError(requestId: requestID, failure: busy, profile: nil)))?.1
            == busy)
        #expect(Self.failure(of: refusals.map(.inferenceError(requestId: "other", failure: content, profile: nil)))?.1
            == content)
    }
}
