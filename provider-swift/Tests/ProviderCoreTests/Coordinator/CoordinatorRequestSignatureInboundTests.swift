import CryptoKit
import Foundation
import Testing

@testable import ProviderCore

@Suite("Coordinator request signature on the receive path")
struct CoordinatorRequestSignatureInboundTests {
    let provider = NodeKeyPair.generate()
    let coordinatorKey = Curve25519.Signing.PrivateKey()

    /// When the build requires a signature, an unsigned request is refused
    /// before the serving loop sees it.
    @Test func unsignedRequestIsRefusedWhenSignaturesAreRequired() async throws {
        let reservation = UUID().uuidString
        let request = try sealedRequest(id: "unsigned-request", reservation: reservation)
        let released = await releases(after: [request], verifier: verifier(required: true))
        #expect(released == [reservation.lowercased()])
    }

    @Test func requestSignedByAnotherKeyIsRefused() async throws {
        let reservation = UUID().uuidString
        var request = try sealedRequest(id: "other-key", reservation: reservation)
        request.coordinatorSignature = sign(request, with: Curve25519.Signing.PrivateKey())
        let released = await releases(after: [request], verifier: verifier(required: false))
        #expect(released == [reservation.lowercased()])
    }

    /// The coordinator's own signature is served, once. A second copy gets no
    /// answer, so the copy being served keeps its reservation.
    @Test func signedRequestIsServedOnce() async throws {
        var request = try sealedRequest(id: "signed", reservation: UUID().uuidString)
        request.coordinatorSignature = sign(request, with: coordinatorKey)
        let (served, released) = await outcome(after: [request, request], verifier: verifier(required: true))
        #expect(served == ["signed"])
        #expect(released == [])
    }

    /// A signature for one provider does not serve on another.
    @Test func requestSignedForAnotherProviderIsRefused() async throws {
        let reservation = UUID().uuidString
        var request = try sealedRequest(id: "other-provider", reservation: reservation)
        request.coordinatorSignature = sign(request, with: coordinatorKey,
            recipient: NodeKeyPair.generate().publicKeyBytes)
        #expect(await releases(after: [request], verifier: verifier(required: false))
            == [reservation.lowercased()])
    }

    /// Without a pinned key the provider serves as before, signed or not.
    @Test func withoutAPinnedKeyEveryRequestIsServed() async throws {
        var signed = try sealedRequest(id: "signed", reservation: UUID().uuidString)
        signed.coordinatorSignature = sign(signed, with: Curve25519.Signing.PrivateKey())
        let unsigned = try sealedRequest(id: "unsigned", reservation: UUID().uuidString)
        #expect(await releases(after: [signed, unsigned], verifier: .none) == [])
    }

    private func verifier(required: Bool) -> CoordinatorRequestVerifier {
        CoordinatorRequestVerifier(keys: [coordinatorKey.publicKey], requireSignature: required)
    }

    private func sealedRequest(id: String, reservation: String) throws -> CoordinatorMessage.InferenceRequest {
        let body = try NodeKeyPair.generate().encryptPayload(
            recipientPublicKey: provider.publicKeyBytes, plaintext: Data("{}".utf8))
        return .init(requestId: id, encryptedBody: body, cacheScope: "scope", serviceReservationID: reservation)
    }

    private func sign(_ request: CoordinatorMessage.InferenceRequest, with key: Curve25519.Signing.PrivateKey,
                      recipient: Data? = nil) -> CoordinatorRequestSignature {
        let body = request.encryptedBody!
        let keyID = CoordinatorRequestSignature.keyID(of: key.publicKey)
        let issued = Int64(Date().timeIntervalSince1970 * 1000)
        let statement = CoordinatorRequestSignature.statement(
            keyID: keyID, issuedAtMs: issued, model: "model", request: request,
            recipientPublicKey: recipient ?? provider.publicKeyBytes,
            sealedBodyDigest: CoordinatorRequestSignature.sealedBodyDigest(
                senderPublicKey: Data(base64Encoded: body.ephemeralPublicKey)!,
                ciphertext: Data(base64Encoded: body.ciphertext)!))
        return CoordinatorRequestSignature(keyID: keyID, issuedAtMs: issued, model: "model",
            signature: try! key.signature(for: statement).base64EncodedString())
    }

    private func releases(after requests: [CoordinatorMessage.InferenceRequest],
                          verifier: CoordinatorRequestVerifier) async -> [String] {
        await outcome(after: requests, verifier: verifier).released
    }

    /// Feeds `requests` to one client and returns the ids it passed to the
    /// serving loop and the reservations it released, which a refusal on the
    /// receive path does and a served request does not.
    private func outcome(after requests: [CoordinatorMessage.InferenceRequest],
                         verifier: CoordinatorRequestVerifier) async -> (served: [String], released: [String]) {
        let client = CoordinatorClient(config: .init(
            url: "",
            hardware: HardwareInfo(machineModel: "Mac16,5", chipName: "Apple M4 Max",
                chipFamily: .m4, chipTier: .max, memoryGb: 128, memoryAvailableGb: 124,
                cpuCores: .init(total: 16, performance: 12, efficiency: 4),
                gpuCores: 40, memoryBandwidthGbs: 546),
            models: [], backendName: "mlx-swift", publicKey: provider.publicKeyBase64,
            requestVerifier: verifier),
            stats: AtomicProviderStats(), state: ProviderState(), liveAPNsToken: { nil })
        let (outbound, continuation) = AsyncStream<OutboundMessage>.makeStream()
        let router = await client.outboundRouter
        router.activate(continuation)
        // An empty URL fails before any network use; the first reconnect waits
        // out the test, and shutdown ends the event stream.
        let (events, _) = await client.start()
        for request in requests {
            let wire = try! ProviderProtocolCodec.encodeCoordinatorMessage(.inferenceRequest(request))
            await client.handleIncomingFrame(wire, receivedAt: .now)
        }
        await client.shutdown()
        continuation.finish()
        var released: [String] = []
        for await message in outbound {
            if case .serviceReservationReleased(let id) = message { released.append(id) }
        }
        var served: [String] = []
        for await event in events {
            if case .inferenceRequest(let id, _, _, _, _, _, _, _, _, _, _, _, _, _, _) = event { served.append(id) }
        }
        return (served, released)
    }
}
