import CryptoKit
import Foundation

/// The coordinator's signature of one `inference_request` (`signed_request`):
/// a JWS (RFC 7515) in compact serialization with the fully specified
/// algorithm `Ed25519` (RFC 9864, RFC 8032). The protected header is exactly
/// `protectedHeader(kid:)`; the payload is the JSON of `SignedInferenceRequest`.
///
/// The header segment is compared byte for byte with the one of a pinned key,
/// the signature is checked over the exact signed bytes, and only then is the
/// payload decoded. The shared vectors are
/// `Tests/ProviderCoreTests/Fixtures/request-signing-vectors.json`.
public enum CoordinatorRequestJWS {
    public static let type = "darkbloom-inference-request+jws"
    public static let algorithm = "Ed25519"
    /// `issued_at_ms` must be strictly within this of the provider's clock, either way.
    public static let freshnessMs: Int64 = 300_000

    /// Why a signature was not accepted, in the order the checks run, except
    /// `bad_payload`: a payload that does not decode is refused before the
    /// freshness checks, one whose bindings are malformed after them.
    public enum Refusal: String, Error, Sendable, Equatable, CaseIterable {
        case missingSignature = "missing_signature"
        case malformedJWS = "malformed_jws"
        case unknownKey = "unknown_key"
        case expiredKey = "expired_key"
        case badSignature = "bad_signature"
        case stale
        case future
        case wrongRecipient = "wrong_recipient"
        case wrongBody = "wrong_body"
        case badPayload = "bad_payload"
    }

    /// A signature that verified: the payload decoded from the signed bytes.
    public struct Verified: Sendable, Equatable {
        public let keyID: String
        public let payload: SignedInferenceRequest
        /// SHA-256 of the JWS as sent (its ASCII bytes): the value a blind
        /// statement names the request by.
        public let jwsSHA256: Data
        /// SHA-256 of the signed bytes (`header.payload`), which identify one
        /// write of one request.
        public let signingInputSHA256: Data
    }

    /// The one protected header of a signature by key `kid`, member for member.
    public static func protectedHeader(kid: String) -> String {
        #"{"alg":"\#(algorithm)","kid":"\#(kid)","typ":"\#(type)"}"#
    }

    /// The key id: the RFC 7638 thumbprint (SHA-256) of the key's JWK, unpadded base64url.
    public static func keyID(of publicKey: Curve25519.Signing.PublicKey) -> String {
        let jwk = #"{"crv":"Ed25519","kty":"OKP","x":"\#(base64URL(publicKey.rawRepresentation))"}"#
        return base64URL(Data(SHA256.hash(data: Data(jwk.utf8))))
    }

    /// Checks `jws` for a request to the provider whose sealing key is
    /// `recipientPublicKey`, sealed by `senderPublicKey` as `ciphertext`.
    /// `requestID` and `serviceReservationID` are the frame's.
    public static func verify(
        _ jws: String?, pins: [CoordinatorRequestSigningPin],
        requestID: String, serviceReservationID: String?,
        recipientPublicKey: Data, senderPublicKey: Data, ciphertext: Data, now: Date
    ) -> Result<Verified, Refusal> {
        guard let jws, !jws.isEmpty else { return .failure(.missingSignature) }
        let segments = jws.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3, segments.allSatisfy({ !$0.isEmpty && isBase64URL($0) }) else {
            return .failure(.malformedJWS)
        }
        let nowMs = Int64((now.timeIntervalSince1970 * 1000).rounded(.down))
        guard let pin = pins.first(where: { base64URL(Data(protectedHeader(kid: $0.keyID).utf8)) == segments[0] })
        else { return .failure(.unknownKey) }
        guard pin.expiresAtMs > nowMs else { return .failure(.expiredKey) }

        let signingInput = Data(jws.utf8.prefix(segments[0].utf8.count + 1 + segments[1].utf8.count))
        guard let signature = decodeBase64URL(segments[2]), signature.count == 64,
              isCanonicalScalar(signature.suffix(32)),
              pin.publicKey.isValidSignature(signature, for: signingInput)
        else { return .failure(.badSignature) }

        guard let payloadBytes = decodeBase64URL(segments[1]),
              let payload = try? JSONDecoder().decode(SignedInferenceRequest.self, from: payloadBytes)
        else { return .failure(.badPayload) }
        if nowMs - payload.issuedAtMs >= freshnessMs { return .failure(.stale) }
        if payload.issuedAtMs - nowMs >= freshnessMs { return .failure(.future) }
        if let refusal = payload.refusal(requestID: requestID, serviceReservationID: serviceReservationID,
                                         recipientPublicKey: recipientPublicKey,
                                         sealedBodySHA256: sealedBodySHA256(senderPublicKey: senderPublicKey,
                                                                            ciphertext: ciphertext)) {
            return .failure(refusal)
        }
        return .success(Verified(
            keyID: pin.keyID, payload: payload,
            jwsSHA256: Data(SHA256.hash(data: Data(jws.utf8))),
            signingInputSHA256: Data(SHA256.hash(data: signingInput))))
    }

    /// SHA-256 over the raw sender public key followed by the raw ciphertext
    /// (nonce ‖ box): the bytes the provider opens.
    static func sealedBodySHA256(senderPublicKey: Data, ciphertext: Data) -> Data {
        var hash = SHA256()
        hash.update(data: senderPublicKey)
        hash.update(data: ciphertext)
        return Data(hash.finalize())
    }

    /// The Ed25519 group order L, little-endian (RFC 8032 section 5.1).
    private static let groupOrder: [UInt8] = [
        0xED, 0xD3, 0xF5, 0x5C, 0x1A, 0x63, 0x12, 0x58, 0xD6, 0x9C, 0xF7, 0xA2, 0xDE, 0xF9, 0xDE, 0x14,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10,
    ]

    /// Whether the little-endian scalar S is below L, as RFC 8032 section
    /// 5.1.7 requires: a verifier that skipped it would accept S + L too.
    static func isCanonicalScalar(_ scalar: Data) -> Bool {
        let bytes = [UInt8](scalar)
        guard bytes.count == 32 else { return false }
        for index in stride(from: 31, through: 0, by: -1) where bytes[index] != groupOrder[index] {
            return bytes[index] < groupOrder[index]
        }
        return false
    }

    private static func isBase64URL(_ segment: Substring) -> Bool {
        segment.utf8.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "_"):
                return true
            default:
                return false
            }
        }
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decodeBase64URL(_ segment: Substring) -> Data? {
        var text = segment.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        switch text.count % 4 {
        case 0: break
        case 2: text += "=="
        case 3: text += "="
        default: return nil
        }
        return Data(base64Encoded: text)
    }
}

/// One coordinator request-signing key a build pins, until `expiresAtMs`.
public struct CoordinatorRequestSigningPin: Sendable {
    public let publicKey: Curve25519.Signing.PublicKey
    public let expiresAtMs: Int64
    public let keyID: String

    public init(publicKey: Curve25519.Signing.PublicKey, expiresAtMs: Int64) {
        self.publicKey = publicKey
        self.expiresAtMs = expiresAtMs
        self.keyID = CoordinatorRequestJWS.keyID(of: publicKey)
    }

    /// From the base64 of a raw 32-byte Ed25519 public key; nil if it is not one.
    public init?(base64PublicKey: String, expiresAtMs: Int64) {
        guard let raw = Data(base64Encoded: base64PublicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { return nil }
        self.init(publicKey: key, expiresAtMs: expiresAtMs)
    }
}
