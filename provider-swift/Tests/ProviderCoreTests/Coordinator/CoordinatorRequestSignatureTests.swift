import CryptoKit
import Foundation
import Testing

@testable import ProviderCore

@Suite("Coordinator request signature")
struct CoordinatorRequestSignatureTests {
    /// A fixed signature over a fixed request: the statement bytes a signer
    /// writes for it.
    enum Vector {
        static let publicKey = "KDLAK2UK42w6VsfhtekPL/bM99r5a/67knFCA3t7ons="
        static let keyID = "730a9168324e18f6"
        static let issuedAtMs: Int64 = 1_795_000_000_123
        static let model = "mlx-community/Qwen3-0.6B-8bit"
        static let statementSHA256 = "7719e0931a83847b329cf7e35b526346c8d914fa7d5f602762220529389c2a82"
        static let signature = "vMikKpBvr0Gv5lAcJTlQoeNK0Zg9y+Z99KUR+IK4ouG6qZnniWmIQxNu0iQKjpljTxqH+07aJr/ELynN5vE/Bw=="
        static let recipient = Data((1...32).map { UInt8($0) })
        static let sender = Data((0..<32).map { UInt8(0xA0 + $0) })
        static let ciphertext = Data("nonce-and-box-bytes-for-the-vector".utf8)
        static var issuedAt: Date { Date(timeIntervalSince1970: TimeInterval(issuedAtMs) / 1000) }

        static var request: CoordinatorMessage.InferenceRequest {
            .init(requestId: "6f1c2b9e-request",
                  encryptedBody: .init(ephemeralPublicKey: sender.base64EncodedString(),
                                       ciphertext: ciphertext.base64EncodedString()),
                  cacheReceiptNonce: "nonce-a", cacheScope: "scope-a", prefixCacheProtocol: 2,
                  cacheReceiptBoundaryMode: "checkpoint", cacheRepeatedPrefixTokens: 2048,
                  toolSchemaMetadataProtocol: 1, serviceReservationID: "7a3d-reservation",
                  gemmaPromptContract: 2,
                  coordinatorSignature: .init(keyID: keyID, issuedAtMs: issuedAtMs, model: model, signature: signature))
        }

        static var verifier: CoordinatorRequestVerifier {
            CoordinatorRequestVerifier(
                keys: [try! Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: publicKey)!)],
                requireSignature: true)
        }
    }

    private func check(_ request: CoordinatorMessage.InferenceRequest,
                       verifier: CoordinatorRequestVerifier = Vector.verifier,
                       recipient: Data? = Vector.recipient, sender: Data = Vector.sender,
                       ciphertext: Data = Vector.ciphertext, now: Date = Vector.issuedAt,
                       served: inout CoordinatorServedRequests) -> CoordinatorRequestVerifier.Refusal? {
        verifier.check(request, senderPublicKey: sender, ciphertext: ciphertext,
                       recipientPublicKey: recipient, now: now, served: &served)
    }

    private func check(_ request: CoordinatorMessage.InferenceRequest,
                       verifier: CoordinatorRequestVerifier = Vector.verifier,
                       recipient: Data? = Vector.recipient, sender: Data = Vector.sender,
                       ciphertext: Data = Vector.ciphertext, now: Date = Vector.issuedAt) -> CoordinatorRequestVerifier.Refusal? {
        var served = CoordinatorServedRequests()
        return check(request, verifier: verifier, recipient: recipient, sender: sender,
                     ciphertext: ciphertext, now: now, served: &served)
    }

    @Test func coordinatorSignatureVerifies() throws {
        let request = Vector.request
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: #require(Data(base64Encoded: Vector.publicKey)))
        #expect(CoordinatorRequestSignature.keyID(of: key) == Vector.keyID)
        let statement = CoordinatorRequestSignature.statement(
            keyID: Vector.keyID, issuedAtMs: Vector.issuedAtMs, model: Vector.model, request: request,
            recipientPublicKey: Vector.recipient,
            sealedBodyDigest: CoordinatorRequestSignature.sealedBodyDigest(
                senderPublicKey: Vector.sender, ciphertext: Vector.ciphertext))
        #expect(SHA256.hash(data: statement).map { String(format: "%02x", $0) }.joined() == Vector.statementSHA256)
        #expect(check(request) == nil)
    }

    /// The common dispatch shapes, signed by the coordinator: no granted cache
    /// scope, and a granted scope no other plan shared (a present zero count).
    @Test(arguments: [
        ("a1b2-request", "c3d4-reservation", Int64(1_795_000_000_456), nil, nil, nil, nil,
         "c576c9ba95ff51b16cc320c6dc7d381a30a456667456ad20a714d37ca7bc0c1a",
         "FR4awP1oTToeJFLd/XddMvzopLL68bjtya66C+FDj+4BH0ozu8DEWxBEsF9+cH+QBnjGRe/vjlbBNrMLu2v0Ag=="),
        ("e5f6-request", "a7b8-reservation", Int64(1_795_000_000_789), "scope-b", "nonce-b", 2, 0,
         "b7d74b21e1ce900ae2e5f090f986ed5f4380c7abefb463a9549bfbafdddb99d2",
         "/HzMHQfVOgvemMKq5Ap6W1LRNFwDn89oRI3ab9SP17wjEjxAe56S1EGx/Eui5FUItpdw6gUAJbi2sVcWLeZsDg=="),
    ] as [(String, String, Int64, String?, String?, Int?, Int?, String, String)])
    func commonShapesVerify(_ shape: (String, String, Int64, String?, String?, Int?, Int?, String, String)) throws {
        let (id, reservation, issued, scope, nonce, prefixProtocol, repeated, digest, signature) = shape
        let request = CoordinatorMessage.InferenceRequest(
            requestId: id,
            encryptedBody: .init(ephemeralPublicKey: Vector.sender.base64EncodedString(),
                                 ciphertext: Vector.ciphertext.base64EncodedString()),
            cacheReceiptNonce: nonce, cacheScope: scope, prefixCacheProtocol: prefixProtocol,
            cacheRepeatedPrefixTokens: repeated, toolSchemaMetadataProtocol: 1, serviceReservationID: reservation,
            coordinatorSignature: .init(keyID: Vector.keyID, issuedAtMs: issued, model: Vector.model, signature: signature))
        // Through the wire, as the provider receives it.
        let wire = try ProviderProtocolCodec.encodeCoordinatorMessage(.inferenceRequest(request))
        guard case .inferenceRequest(let received) = try CoordinatorClientCodec.decodeIncomingMessage(from: wire) else {
            Issue.record("not an inference request")
            return
        }
        let statement = CoordinatorRequestSignature.statement(
            keyID: Vector.keyID, issuedAtMs: issued, model: Vector.model, request: received,
            recipientPublicKey: Vector.recipient,
            sealedBodyDigest: CoordinatorRequestSignature.sealedBodyDigest(
                senderPublicKey: Vector.sender, ciphertext: Vector.ciphertext))
        #expect(SHA256.hash(data: statement).map { String(format: "%02x", $0) }.joined() == digest)
        #expect(check(received, now: Date(timeIntervalSince1970: TimeInterval(issued) / 1000)) == nil)
    }

    @Test func everyBoundValueChangesTheStatement() {
        let changes: [(String, (inout CoordinatorMessage.InferenceRequest) -> Void)] = [
            ("request id", { $0.requestId += "x" }),
            ("reservation", { $0.serviceReservationID = nil }),
            ("cache scope", { $0.cacheScope = "scope-b" }),
            ("receipt nonce", { $0.cacheReceiptNonce = nil }),
            ("prefix protocol", { $0.prefixCacheProtocol = 1 }),
            ("boundary mode", { $0.cacheReceiptBoundaryMode = nil }),
            ("repeated tokens", { $0.cacheRepeatedPrefixTokens = 0 }),
            ("tool schema", { $0.toolSchemaMetadataProtocol = nil }),
            ("gemma contract", { $0.gemmaPromptContract = nil }),
            ("model", { $0.coordinatorSignature?.model = "other" }),
            ("issued at", { $0.coordinatorSignature?.issuedAtMs += 1 }),
        ]
        for (name, change) in changes {
            var request = Vector.request
            change(&request)
            #expect(check(request) == .badSignature, "changed \(name)")
        }
        #expect(check(Vector.request, recipient: Data(repeating: 9, count: 32)) == .badSignature)
        #expect(check(Vector.request, recipient: nil) == .badSignature)
        #expect(check(Vector.request, sender: Data(repeating: 9, count: 32)) == .badSignature)
        #expect(check(Vector.request, ciphertext: Vector.ciphertext + Data([0])) == .badSignature)
    }

    @Test func signatureHeaderMustNameAPinnedKeyAndThisVersion() {
        var request = Vector.request
        request.coordinatorSignature?.keyID = "0000000000000000"
        #expect(check(request) == .unknownKey)
        request = Vector.request
        request.coordinatorSignature?.version = 2
        #expect(check(request) == .unsupportedVersion)
        request = Vector.request
        request.coordinatorSignature?.signature = "not base64"
        #expect(check(request) == .badSignature)
    }

    @Test func signatureIsFreshWithinTheWindowEitherWay() {
        let window = CoordinatorRequestVerifier.defaultFreshness
        #expect(check(Vector.request, now: Vector.issuedAt.addingTimeInterval(window)) == nil)
        #expect(check(Vector.request, now: Vector.issuedAt.addingTimeInterval(-window)) == nil)
        #expect(check(Vector.request, now: Vector.issuedAt.addingTimeInterval(window + 1)) == .stale)
        #expect(check(Vector.request, now: Vector.issuedAt.addingTimeInterval(-window - 1)) == .stale)
    }

    @Test func signedRequestIsServedOnce() {
        var served = CoordinatorServedRequests()
        #expect(check(Vector.request, served: &served) == nil)
        #expect(check(Vector.request, now: Vector.issuedAt.addingTimeInterval(1), served: &served) == .alreadyServed)
        #expect(served.count == 1)
    }

    @Test func unsignedRequestFollowsTheBuild() {
        var unsigned = Vector.request
        unsigned.coordinatorSignature = nil
        #expect(check(unsigned) == .unsigned)
        let verifyOnly = CoordinatorRequestVerifier(keys: Array(Vector.verifier.keys.values), requireSignature: false)
        #expect(check(unsigned, verifier: verifyOnly) == nil)
        #expect(check(Vector.request, verifier: verifyOnly) == nil)
        // Without a key nothing is checked, and nothing can be required.
        let unpinned = CoordinatorRequestVerifier(keys: [], requireSignature: true)
        #expect(!unpinned.requireSignature)
        var malformed = Vector.request
        malformed.coordinatorSignature?.signature = "not base64"
        #expect(check(unsigned, verifier: unpinned) == nil)
        #expect(check(malformed, verifier: .none) == nil)
        #expect(!CoordinatorRequestVerifier.none.checksRequests)
    }

    /// Production and dev builds pin the key their coordinator logs at startup
    /// (`provider request-signing key key_id=…`) and still serve a request
    /// without a signature; staging pins none. Changing a key or requiring a
    /// signature is a deliberate change that updates this.
    @Test(arguments: BuildEnvironment.allCases)
    func eachEnvironmentPinsTheKeyItsCoordinatorLogged(environment: BuildEnvironment) throws {
        let logged: [BuildEnvironment: [String]] = [.prod: ["e7d53f46617e9494"], .dev: ["7c638fff1a85dd4a"], .staging: []]
        let pin = CoordinatorRequestSigningKeys.pin(for: environment)
        let keys = try pin.publicKeys.map {
            try Curve25519.Signing.PublicKey(rawRepresentation: #require(Data(base64Encoded: $0)))
        }
        #expect(keys.map(CoordinatorRequestSignature.keyID(of:)) == logged[environment])
        let verifier = CoordinatorRequestVerifier.pinned(for: environment)
        #expect(!pin.requireSignature && !verifier.requireSignature)
        #expect(verifier.checksRequests == !keys.isEmpty)
    }

    @Test(arguments: BuildEnvironment.allCases)
    func everyPinnedKeyIsAnEd25519PublicKey(environment: BuildEnvironment) {
        let pin = CoordinatorRequestSigningKeys.pin(for: environment)
        let verifier = CoordinatorRequestVerifier.pinned(for: environment)
        #expect(verifier.keys.count == pin.publicKeys.count)
        #expect(verifier.requireSignature == (pin.requireSignature && !pin.publicKeys.isEmpty))
    }

    @Test func servedRequestsForgetExpiredEntriesAndStayBounded() {
        var served = CoordinatorServedRequests(capacity: 2)
        let now = Date(timeIntervalSince1970: 1_000), later = now.addingTimeInterval(12)
        let admitted = [
            served.admit(Data([1]), until: now.addingTimeInterval(10), now: now),
            served.admit(Data([1]), until: now.addingTimeInterval(10), now: now),
            served.admit(Data([2]), until: now.addingTimeInterval(9), now: now),
            // Full: the entry nearest expiry ([2]) leaves for the new one.
            served.admit(Data([3]), until: now.addingTimeInterval(11), now: now),
            served.admit(Data([1]), until: now.addingTimeInterval(10), now: now),
            served.admit(Data([2]), until: now.addingTimeInterval(10), now: now),
            // Past their window, entries are served again.
            served.admit(Data([3]), until: later.addingTimeInterval(10), now: later),
            served.admit(Data([1]), until: later.addingTimeInterval(10), now: later),
        ]
        #expect(admitted == [true, false, true, true, false, true, true, true])
        #expect(served.count <= 2)
    }

    @Test func wireFieldRoundTripsAndAMalformedOneReadsAsNone() throws {
        let wire = try ProviderProtocolCodec.encodeCoordinatorMessage(.inferenceRequest(Vector.request))
        let object = try #require(try JSONSerialization.jsonObject(with: wire) as? [String: Any])
        let signature = try #require(object["coordinator_signature"] as? [String: Any])
        #expect(Set(signature.keys) == ["version", "key_id", "issued_at_ms", "model", "signature"])
        #expect(try CoordinatorClientCodec.decodeIncomingMessage(from: wire) == .inferenceRequest(Vector.request))

        var malformed = object
        malformed["coordinator_signature"] = ["key_id": 7]
        let decoded = try CoordinatorClientCodec.decodeIncomingMessage(
            from: JSONSerialization.data(withJSONObject: malformed))
        guard case .inferenceRequest(let request) = decoded else {
            Issue.record("a malformed signature dropped the request")
            return
        }
        #expect(request.coordinatorSignature == nil)
        #expect(request.requestId == Vector.request.requestId)
    }
}
