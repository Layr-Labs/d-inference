import CryptoKit
import Foundation
import Testing

@testable import ProviderCore

/// One blind request as a coordinator relays it: a body a client sealed to the
/// provider's X25519 key, the clear meta, and the coordinator's JWS over the
/// frame with its `blind` terms. The signing key is RFC 8032 section 7.1 TEST 1,
/// a published test key that no build pins.
struct BlindRequestFixture {
    static let signingSeedHex = "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"

    static var signingKey: Curve25519.Signing.PrivateKey {
        // A fixed published test key, always valid.
        try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(hexString: signingSeedHex))
    }

    /// The pin a test provider verifies with, valid for a year from now.
    static var pin: CoordinatorRequestSigningPin {
        CoordinatorRequestSigningPin(
            publicKey: signingKey.publicKey,
            expiresAtMs: Int64(Date().addingTimeInterval(365 * 86_400).timeIntervalSince1970 * 1000))
    }

    var requestID = "blind-\(UUID().uuidString)"
    var model = ServeLoopFixture.modelId
    var bodyModel = ServeLoopFixture.modelId
    var maxTokens = 64
    var promptTokenBound = 4_096
    var tools = false
    var vision = false
    var clientTs = Int64(Date().timeIntervalSince1970 * 1000)
    var nonce = CoordinatorRequestJWS.base64URL(Data((0..<16).map { _ in UInt8.random(in: .min ... .max) }))
    var cred = "credential-binding"
    var cacheScope: String? = "blind-v1:account-scope"
    /// The sealed body's `messages` (raw JSON).
    var messages = #"[{"role":"user","content":"fixture"}]"#
    /// Members of the sealed body after `model`, `messages` and `stream`
    /// (raw JSON members, no braces).
    var defaultMembers = [#""reasoning_parser":"none""#]
    /// Extra members of the sealed body (raw JSON members, no braces).
    var bodyFields: [String] = []
    /// The key the frame names as the body's sender, in place of `client`'s.
    var senderKey: Data?
    /// The client key the terms name, in place of the sender's.
    var termsClientKey: Data?
    /// The body's `_darkbloom_blind` member: nil for the one matching the
    /// terms, `.some(nil)` for none, or the raw JSON of another.
    var sealedBinding: String?? = nil
    var issuedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
    let client = NodeKeyPair.generate()

    var meta: Data {
        Data(#"{"v":1,"model":"\#(model)","max_tokens":\#(maxTokens),"stream":true,"ts":\#(clientTs),"nonce":"\#(nonce)","cred":"\#(cred)"}"#.utf8)
    }

    var metaSHA256: String { Data(SHA256.hash(data: meta)).base64EncodedString() }

    /// The sealed body, sealed to `recipient`.
    func ciphertext(to recipient: Data) throws -> Data {
        let binding = sealedBinding
            ?? #"{"v":1,"meta_sha256":"\#(metaSHA256)","nonce":"\#(nonce)","cred":"\#(cred)","ts":\#(clientTs)}"#
        var members = [#""model":"\#(bodyModel)""#, #""messages":\#(messages)"#, #""stream":true"#]
        members += defaultMembers + bodyFields
        if let binding { members.append(#""_darkbloom_blind":\#(binding)"#) }
        return try client.encrypt(recipientPublicKey: recipient,
                                  plaintext: Data(("{" + members.joined(separator: ",") + "}").utf8))
    }

    /// The coordinator's signed JWS over a frame carrying `ciphertext` to `recipient`.
    func signedRequest(recipient: Data, ciphertext: Data, sealSet: [Data]? = nil) throws -> String {
        let sender = senderKey ?? client.publicKeyBytes
        let digest = CoordinatorRequestJWS.sealedBodySHA256(senderPublicKey: sender, ciphertext: ciphertext)
        var payload: [String: Any] = [
            "issued_at_ms": issuedAtMs, "request_id": requestID, "model": model,
            "recipient_public_key": recipient.base64EncodedString(), "sealed_body_sha256": digest.base64EncodedString(),
            "blind": [
                "v": 1, "meta_sha256": metaSHA256, "model": model, "max_tokens": maxTokens,
                "prompt_token_bound": promptTokenBound, "traits": ["tools": tools, "vision": vision],
                "account_binding": cred, "client_nonce": nonce, "client_ts": clientTs,
                "seal_set": (sealSet ?? [recipient]).map { $0.base64EncodedString() }.sorted(),
                "client_public_key": (termsClientKey ?? sender).base64EncodedString(),
            ] as [String: Any],
        ]
        if let cacheScope { payload["cache_scope"] = cacheScope }
        let header = CoordinatorRequestJWS.protectedHeader(kid: Self.pin.keyID)
        let signingInput = CoordinatorRequestJWS.base64URL(Data(header.utf8)) + "."
            + CoordinatorRequestJWS.base64URL(try JSONSerialization.data(withJSONObject: payload))
        let signature = try Self.signingKey.signature(for: Data(signingInput.utf8))
        return signingInput + "." + CoordinatorRequestJWS.base64URL(signature)
    }

    /// The whole `inference_request` for a provider whose X25519 key is `recipient`.
    /// `clearCacheScope` is the frame's unsigned `cache_scope`.
    func frame(
        recipient: Data, sealedTo: Data? = nil, sealSet: [Data]? = nil,
        member: BlindFrameMember? = nil, signedRequest override: String? = nil, clearCacheScope: String? = nil
    ) throws -> CoordinatorMessage.InferenceRequest {
        let ciphertext = try ciphertext(to: sealedTo ?? recipient)
        let jws = try override ?? signedRequest(recipient: recipient, ciphertext: ciphertext, sealSet: sealSet)
        return CoordinatorMessage.InferenceRequest(
            requestId: requestID,
            encryptedBody: EncryptedPayload(
                ephemeralPublicKey: (senderKey ?? client.publicKeyBytes).base64EncodedString(),
                ciphertext: ciphertext.base64EncodedString()),
            cacheScope: clearCacheScope,
            blind: BlindFrame(member: member ?? BlindFrameMember(version: 1, meta: meta), signedRequest: jws))
    }

    /// Base64 of SHA-256 of a JWS as sent: the value a statement names the request by.
    static func digest(of jws: String) -> String {
        Data(SHA256.hash(data: Data(jws.utf8))).base64EncodedString()
    }

    /// Whether `signed` is a refusal statement signed by the P-256 key whose
    /// raw public key is `publicKeyBase64`, over the bytes its fields give.
    static func refusalVerifies(_ signed: SignedBlindStatement, publicKeyBase64: String) throws -> Bool {
        guard case .text(let requestID) = signed.statement["request_id"],
              case .text(let digest) = signed.statement["signed_request_sha256"],
              case .text(let reason) = signed.statement["reason"],
              case .integer(let issuedAtMs) = signed.statement["issued_at_ms"],
              let refusalReason = BlindRefusalReason(rawValue: reason),
              signed.statement.count == 4
        else { return false }
        let statement = BlindStatement.refusal(
            requestID: requestID, signedRequestSHA256: digest.isEmpty ? nil : Data(base64Encoded: digest),
            reason: refusalReason, issuedAtMs: issuedAtMs)
        let key = try P256.Signing.PublicKey(rawRepresentation: #require(Data(base64Encoded: publicKeyBase64)))
        let signature = try P256.Signing.ECDSASignature(
            derRepresentation: #require(Data(base64Encoded: signed.signature)))
        return key.isValidSignature(signature, for: statement.signedBytes)
    }
}
