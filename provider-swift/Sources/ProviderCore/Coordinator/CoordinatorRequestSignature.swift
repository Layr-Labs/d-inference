import CryptoKit
import Foundation

/// The coordinator's Ed25519 signature over one inference request it
/// dispatched (`coordinator_signature`). It binds the request and reservation
/// ids, the provider key the body is sealed to, the model, the sealed body
/// and the cache fields outside it, at the time the coordinator sent it.
///
/// A signer writes exactly the statement bytes of `statement`; a different
/// layout is a new `version`.
public struct CoordinatorRequestSignature: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    public var keyID: String
    public var issuedAtMs: Int64
    public var model: String
    /// Base64 of the 64-byte Ed25519 signature.
    public var signature: String

    public init(version: Int = currentVersion, keyID: String, issuedAtMs: Int64, model: String, signature: String) {
        self.version = version
        self.keyID = keyID
        self.issuedAtMs = issuedAtMs
        self.model = model
        self.signature = signature
    }

    enum CodingKeys: String, CodingKey {
        case version
        case keyID = "key_id"
        case issuedAtMs = "issued_at_ms"
        case model, signature
    }

    static let domain = "darkbloom-coordinator-inference-request-v1"

    /// The first 16 hex characters of SHA-256(public key).
    public static func keyID(of publicKey: Curve25519.Signing.PublicKey) -> String {
        SHA256.hash(data: publicKey.rawRepresentation).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// The bytes a version 1 signature covers: every value as a 4-byte
    /// big-endian length and its bytes, in a fixed order. An absent integer is
    /// the empty string; a present one is its decimal form.
    static func statement(
        keyID: String, issuedAtMs: Int64, model: String,
        request: CoordinatorMessage.InferenceRequest,
        recipientPublicKey: Data, sealedBodyDigest: Data
    ) -> Data {
        func decimal(_ value: Int?) -> String { value.map(String.init) ?? "" }
        func omittedIfZero(_ value: Int?) -> String { value == 0 ? "" : decimal(value) }
        let fields: [Data] = [
            Data(domain.utf8),
            Data(keyID.utf8),
            Data(String(issuedAtMs).utf8),
            Data(request.requestId.utf8),
            Data((request.serviceReservationID ?? "").utf8),
            recipientPublicKey,
            Data(model.utf8),
            sealedBodyDigest,
            Data((request.cacheScope ?? "").utf8),
            Data((request.cacheReceiptNonce ?? "").utf8),
            Data(omittedIfZero(request.prefixCacheProtocol).utf8),
            Data((request.cacheReceiptBoundaryMode ?? "").utf8),
            Data(decimal(request.cacheRepeatedPrefixTokens).utf8),
            Data(omittedIfZero(request.toolSchemaMetadataProtocol).utf8),
            Data(omittedIfZero(request.gemmaPromptContract).utf8),
        ]
        var out = Data(capacity: fields.reduce(0) { $0 + 4 + $1.count })
        for field in fields {
            withUnsafeBytes(of: UInt32(field.count).bigEndian) { out.append(contentsOf: $0) }
            out.append(field)
        }
        return out
    }

    /// SHA-256 over the raw sender public key followed by the raw ciphertext
    /// (nonce ‖ box): the bytes the provider opens.
    static func sealedBodyDigest(senderPublicKey: Data, ciphertext: Data) -> Data {
        var hash = SHA256()
        hash.update(data: senderPublicKey)
        hash.update(data: ciphertext)
        return Data(hash.finalize())
    }
}

/// What the receive path learned of one request's coordinator signature. A
/// request whose signature fails, or that the build requires to be signed and
/// is not, never reaches the loop.
public enum CoordinatorSignatureCheck: Sendable, Equatable {
    /// The build pins no key: signatures are not checked.
    case notChecked
    /// It carries a signature that verifies against a pinned key.
    case verified
    /// The build pins a key but does not require one, and it carries none.
    case unsigned
}

/// What a provider build requires of the coordinator's request signatures.
///
/// With no key, a signature is ignored and every request is served as before.
/// With a key, a request that carries a signature is served only if it
/// verifies, is fresh and has not been served already. `requireSignature`
/// also refuses a request that carries none. Keys and the requirement come
/// from the build (`pinned(for:)`), never from the connection.
public struct CoordinatorRequestVerifier: Sendable {
    public enum Refusal: String, Sendable, Equatable {
        case unsigned
        case unsupportedVersion = "unsupported_version"
        case unknownKey = "unknown_key"
        case badSignature = "bad_signature"
        case stale
        /// The same signed request again: the first copy is the one served.
        case alreadyServed = "already_served"
    }

    public let keys: [String: Curve25519.Signing.PublicKey]
    public let requireSignature: Bool
    /// How far `issued_at_ms` may be from this Mac's clock, either way.
    public let freshness: TimeInterval

    public static let defaultFreshness: TimeInterval = 300

    public init(keys: [Curve25519.Signing.PublicKey], requireSignature: Bool,
                freshness: TimeInterval = defaultFreshness) {
        self.keys = Dictionary(keys.map { (CoordinatorRequestSignature.keyID(of: $0), $0) },
                               uniquingKeysWith: { first, _ in first })
        self.requireSignature = requireSignature && !keys.isEmpty
        self.freshness = freshness
    }

    /// Verifies nothing and serves every request: builds and tests without a pin.
    public static let none = CoordinatorRequestVerifier(keys: [], requireSignature: false)

    /// False when no key is pinned: every request is served unchecked.
    public var checksRequests: Bool { !keys.isEmpty }

    /// The verifier compiled into this build for its coordinator.
    public static func pinned(for environment: BuildEnvironment = .current) -> CoordinatorRequestVerifier {
        let pin = CoordinatorRequestSigningKeys.pin(for: environment)
        return CoordinatorRequestVerifier(
            keys: pin.publicKeys.compactMap { Data(base64Encoded: $0).flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) } },
            requireSignature: pin.requireSignature)
    }

    /// Checks `request`, already decoded to its raw sender key and ciphertext,
    /// for a provider whose sealing public key is `recipientPublicKey`. A
    /// verified request is recorded in `served` so it is served once.
    public func check(
        _ request: CoordinatorMessage.InferenceRequest,
        senderPublicKey: Data, ciphertext: Data, recipientPublicKey: Data?,
        now: Date, served: inout CoordinatorServedRequests
    ) -> Refusal? {
        guard !keys.isEmpty else { return nil }
        guard let signed = request.coordinatorSignature else { return requireSignature ? .unsigned : nil }
        guard signed.version == CoordinatorRequestSignature.currentVersion else { return .unsupportedVersion }
        guard let key = keys[signed.keyID] else { return .unknownKey }
        guard let signature = Data(base64Encoded: signed.signature), signature.count == 64,
              let recipientPublicKey, recipientPublicKey.count == 32 else { return .badSignature }
        let statement = CoordinatorRequestSignature.statement(
            keyID: signed.keyID, issuedAtMs: signed.issuedAtMs, model: signed.model, request: request,
            recipientPublicKey: recipientPublicKey,
            sealedBodyDigest: CoordinatorRequestSignature.sealedBodyDigest(
                senderPublicKey: senderPublicKey, ciphertext: ciphertext))
        guard key.isValidSignature(signature, for: statement) else { return .badSignature }
        let issuedAt = Date(timeIntervalSince1970: TimeInterval(signed.issuedAtMs) / 1000)
        guard abs(issuedAt.timeIntervalSince(now)) <= freshness else { return .stale }
        guard served.admit(Data(SHA256.hash(data: statement)), until: issuedAt.addingTimeInterval(freshness), now: now)
        else { return .alreadyServed }
        return nil
    }
}

/// The signed requests served within their freshness window, by the SHA-256 of
/// their signed statement, so each is served at most once. An entry leaves
/// once its window has passed; at capacity the entry nearest expiry leaves first.
public struct CoordinatorServedRequests: Sendable {
    public static let defaultCapacity = 65_536

    private var expiries: [Data: Date] = [:]
    private let capacity: Int
    private var nextPrune: Date = .distantPast

    public init(capacity: Int = defaultCapacity) { self.capacity = capacity }

    public var count: Int { expiries.count }

    /// Records `digest` until `expiry`; false if it is already recorded and
    /// not yet expired.
    mutating func admit(_ digest: Data, until expiry: Date, now: Date) -> Bool {
        if let previous = expiries[digest], previous.timeIntervalSince(now) >= 0 { return false }
        if now.timeIntervalSince(nextPrune) >= 0 || expiries.count >= capacity {
            expiries = expiries.filter { $0.value.timeIntervalSince(now) >= 0 }
            nextPrune = now.addingTimeInterval(60)
        }
        if expiries.count >= capacity, let nearest = expiries.min(by: { $0.value < $1.value }) {
            expiries[nearest.key] = nil
        }
        expiries[digest] = expiry
        return true
    }
}
