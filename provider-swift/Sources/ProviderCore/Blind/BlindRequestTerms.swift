import CryptoKit
import Foundation

/// The coordinator-signed terms of a blind request: the `blind` member of the
/// `signed_request` payload. The client sealed the request body to this Mac's
/// X25519 key; the coordinator never opened it, so these terms are what it
/// routed, reserved and will bill by, and the provider holds the body to them.
public struct BlindSignedTerms: Decodable, Sendable, Equatable {
    public static let currentVersion = 1

    public let version: Int
    /// Base64 of SHA-256 of the clear meta bytes the coordinator acted on.
    public let metaSHA256: String
    /// The build the body must name and this Mac must serve.
    public let model: String
    /// The output bound: generation never exceeds it.
    public let maxTokens: Int
    /// The prompt bound, in tokens: a longer tokenized prompt is refused.
    public let promptTokenBound: Int
    public let traits: BlindTraits
    /// The client's credential binding (`cred`), carried sealed as well.
    public let accountBinding: String
    public let clientNonce: String
    /// The client's clock when it sealed, Unix milliseconds.
    public let clientTs: Int64
    /// Base64 X25519 keys the client sealed to, sorted.
    public let sealSet: [String]
    /// Base64 of the client's ephemeral X25519 key the body was sealed with.
    public let clientPublicKey: String

    enum CodingKeys: String, CodingKey {
        case version = "v"
        case metaSHA256 = "meta_sha256"
        case model
        case maxTokens = "max_tokens"
        case promptTokenBound = "prompt_token_bound"
        case traits
        case accountBinding = "account_binding"
        case clientNonce = "client_nonce"
        case clientTs = "client_ts"
        case sealSet = "seal_set"
        case clientPublicKey = "client_public_key"
    }
}

/// What the coordinator saw of the request's content: whether it declared
/// tools and whether it carries media.
public struct BlindTraits: Decodable, Sendable, Equatable {
    public let tools: Bool
    public let vision: Bool
}

/// The `blind` member of an `inference_request` frame. Its presence makes the
/// frame a blind request, whatever its contents: a malformed member is refused,
/// never read as an ordinary request.
public struct BlindFrameMember: Sendable, Equatable, Encodable {
    public let version: Int?
    /// The clear meta bytes the coordinator acted on (decoded from base64).
    public let meta: Data?

    public static let malformed = BlindFrameMember(version: nil, meta: nil)

    public init(version: Int?, meta: Data?) {
        self.version = version
        self.meta = meta
    }

    struct Wire: Decodable {
        let v: Int
        let meta: String
    }

    init(wire: Wire) {
        self.init(version: wire.v, meta: Data(base64Encoded: wire.meta))
    }

    private enum CodingKeys: String, CodingKey { case version = "v", meta }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(version, forKey: .version)
        try container.encodeIfPresent(meta?.base64EncodedString(), forKey: .meta)
    }
}

/// The `_darkbloom_blind` member of a sealed blind request body: the client's
/// copy of the terms that bind the body to the meta it sent in clear.
struct SealedBlindBinding: Decodable, Equatable {
    static let member = "_darkbloom_blind"

    let version: Int
    let metaSHA256: String
    let nonce: String
    let cred: String
    let ts: Int64
    /// Unpadded base64url of 16 to 32 random bytes that narrow the cache scope.
    let cacheSalt: String?

    enum CodingKeys: String, CodingKey {
        case version = "v"
        case metaSHA256 = "meta_sha256"
        case nonce, cred, ts
        case cacheSalt = "cache_salt"
    }

    /// The raw salt; nil when absent. Throws for a salt that is not 16 to 32
    /// bytes of unpadded base64url.
    func saltBytes() throws -> Data? {
        guard let cacheSalt else { return nil }
        guard !cacheSalt.contains("="), let bytes = CoordinatorRequestJWS.decodeBase64URL(cacheSalt[...]),
              (16...32).contains(bytes.count) else { throw BlindRefusalReason.bindingMismatch }
        return bytes
    }

    enum Lookup: Equatable {
        case absent
        /// A member that is not a version 1 binding.
        case malformed
        case binding(SealedBlindBinding)
    }

    private enum BodyKeys: String, CodingKey { case binding = "_darkbloom_blind" }

    /// The member of a request body, read from the decoder of its one parse.
    static func lookup(decoder: any Decoder) -> Lookup {
        guard let container = try? decoder.container(keyedBy: BodyKeys.self), container.contains(.binding) else {
            return .absent
        }
        guard let binding = try? container.decode(SealedBlindBinding.self, forKey: .binding),
              binding.version == BlindSignedTerms.currentVersion else { return .malformed }
        return .binding(binding)
    }
}
