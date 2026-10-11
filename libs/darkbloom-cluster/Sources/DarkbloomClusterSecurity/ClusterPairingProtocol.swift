import CryptoKit
import Foundation

// The pairing ceremony (PROD-PLAN S17): two Macs on one Thunderbolt link pin
// each other's attested Secure Enclave key without SSH, without a coordinator
// and without any secret typed or shown.
//
// Shape: a short-authentication-string (SAS) exchange with a commitment, the
// numeric-comparison pattern of Bluetooth Secure Simple Pairing and ZRTP.
//
//   connector -> listener  offer:  identity key, ephemeral X25519 key, commitment H(identity, ephemeral, nonce_c)
//   listener -> connector  answer: identity key, ephemeral key, nonce_l, attestation, cluster label, generation
//   connector -> listener  reveal: nonce_c, attestation, generation           (listener checks the commitment)
//   both                   proof:  Secure Enclave signature over the transcript
//   both screens show the same six digits derived from the transcript; a person compares them
//   both                   decision: accept or decline, tagged with a key only the two ends hold
//   both                   countersign: Secure Enclave signature over the roster's canonical bytes
//   both                   committed: after the pin, the roster and the link edge secret are stored
//
// Why this resists a man in the middle and offline guessing: the six digits
// are not a secret, so there is nothing to guess offline. A relay that swaps
// keys sees each end's transcript differ; to make both screens show the same
// digits it must fix its own nonce toward the connector before it learns the
// listener's, so each attempt succeeds with probability one in a million, and
// the gate allows three failed attempts per ten minutes. The link edge secret
// comes from the X25519 agreement and never crosses the wire. The identity
// keys are proven by signatures over the transcript; each attestation binds
// the ephemeral key it was made for.
//
// The owner's oMLX pairing UX is kept (`omlx/cluster/pairing.py`): a code
// valid 600 s, three wrong attempts then a 600 s lockout, rollback of every
// write on any failure, an audit trail, and a rate limit on requests.

public enum ClusterPairingPolicy {
    public static let codeDigits = 6
    /// How long a ceremony may take from its start to the second confirmation.
    public static let codeLifetimeSeconds: Double = 600
    /// Failed ceremonies (declined, mismatched or tampered) before a lockout.
    public static let maximumFailedAttempts = 3
    public static let lockoutSeconds: Double = 600
    /// New offers a listener accepts: one per `offerIntervalSeconds`, at most `offerBurst` at once.
    public static let offerIntervalSeconds: Double = 5
    public static let offerBurst: Double = 3
    /// How long the two ends wait for each other's `committed` once both stored.
    public static let commitWaitSeconds: Double = 30
    public static let maximumMessageBytes = 32 * 1024
    public static let maximumAttestationBytes = 8 * 1024
    public static let maximumNameBytes = 96
    public static let maximumInterfaceBytes = 32
    public static let protocolVersion = 1
}

/// Closed, payload-free failures. Never carry a key, a code or an address.
public enum ClusterPairingError: Error, Equatable, Sendable, CustomStringConvertible {
    case malformedMessage
    case unexpectedMessage
    case unsupportedVersion
    case commitmentMismatch
    case proofInvalid
    case attestationInvalid
    case tagInvalid
    case selfPairing
    case declinedLocally
    case declinedByPeer
    case expired
    case lockedOut(untilEpochSeconds: Double)
    case peerLockedOut(untilEpochSeconds: Double)
    case rateLimited
    case busy
    case rosterInvalid
    case persistenceFailed
    case peerAborted
    case identityUnavailable
    case transport

    public var description: String {
        switch self {
        case .malformedMessage: return "the other Mac sent a malformed pairing message"
        case .unexpectedMessage: return "the other Mac sent a pairing message out of order"
        case .unsupportedVersion: return "the other Mac runs another pairing version"
        case .commitmentMismatch: return "the other Mac's nonce does not match its commitment (tampering)"
        case .proofInvalid: return "the other Mac did not prove its Secure Enclave key"
        case .attestationInvalid: return "the other Mac's attestation does not bind its keys"
        case .tagInvalid: return "a confirmation was not made with the agreed key (tampering)"
        case .selfPairing: return "the other end presented this Mac's own key"
        case .declinedLocally: return "the codes were not confirmed on this Mac"
        case .declinedByPeer: return "the codes were not confirmed on the other Mac"
        case .expired: return "the pairing code expired (600 s)"
        case .lockedOut(let until): return "too many failed pairings; locked until \(ClusterPairingPolicy.clock(until))"
        case .peerLockedOut(let until): return "the other Mac is locked out after failed pairings until \(ClusterPairingPolicy.clock(until))"
        case .rateLimited: return "too many pairing requests; wait a few seconds"
        case .busy: return "the other Mac is already pairing"
        case .rosterInvalid: return "the roster signatures do not verify"
        case .persistenceFailed: return "the pairing could not be stored; nothing was kept"
        case .peerAborted: return "the other Mac stopped the pairing"
        case .identityUnavailable: return "this Mac has no persistent Secure Enclave key"
        case .transport: return "the link connection to the other Mac was lost"
        }
    }

    /// Failures that count toward the lockout: a person said no, or the protocol saw tampering.
    public var countsAsFailedAttempt: Bool {
        switch self {
        case .commitmentMismatch, .proofInvalid, .attestationInvalid, .tagInvalid, .declinedLocally, .declinedByPeer,
             .expired, .rosterInvalid, .selfPairing: return true
        default: return false
        }
    }

    /// The wire name of an abort or refusal reason.
    public var wireReason: String {
        switch self {
        case .lockedOut: return "locked_out"
        case .peerLockedOut: return "locked_out"
        case .rateLimited: return "rate_limited"
        case .busy: return "busy"
        case .declinedLocally: return "declined"
        case .expired: return "expired"
        case .persistenceFailed: return "persistence_failed"
        case .unsupportedVersion: return "unsupported_version"
        default: return "protocol"
        }
    }
}

extension ClusterPairingPolicy {
    /// Wall-clock time as `HH:MM:SS` local time, for messages only.
    static func clock(_ epochSeconds: Double) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date(timeIntervalSince1970: epochSeconds))
    }
}

/// The Secure Enclave key a member pins and is pinned by. Production: the
/// provider's attestation signing key (the keychain-backed persistent key of a
/// signed build), the same key the coordinator derives the member pin from.
public protocol ClusterPairingIdentity: Sendable {
    /// X9.63 uncompressed P-256 point, 65 bytes.
    var identityPublicKey: Data { get }
    /// DER ECDSA P-256 over SHA-256 of `message`.
    func pairingSignature(for message: Data) throws -> Data
}

/// Which end of the ceremony: the listener accepted the link connection.
public enum ClusterPairingRole: String, Codable, Sendable, Equatable {
    case listener, connector

    var byte: UInt8 { self == .listener ? 0 : 1 }
    var peer: ClusterPairingRole { self == .listener ? .connector : .listener }
}

/// The member pin: lowercase hex SHA-256 of a dedicated domain and the key's
/// 65-byte uncompressed point (darkbloom-platform `ClusterMemberPin`).
public enum ClusterPairingPin {
    static let domain = Data("darkbloom/cluster-member-pin/v1\u{0}".utf8)

    public static func of(identityKey: Data) -> String {
        Data(SHA256.hash(data: domain + identityKey)).map { String(format: "%02x", $0) }.joined()
    }

    /// A valid P-256 point in X9.63 uncompressed form.
    public static func isIdentityKey(_ key: Data) -> Bool {
        key.count == 65 && key.first == 4 && (try? P256.Signing.PublicKey(x963Representation: key)) != nil
    }

    /// Lowercase 64-digit hex.
    public static func isPin(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

/// The cluster label rules shared with the coordinator (`clusterLabel`).
public enum ClusterPairingLabel {
    public static func isValid(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128, value.utf8.first != UInt8(ascii: "-") else { return false }
        return value.utf8.allSatisfy { c in
            (48...57).contains(c) || (65...90).contains(c) || (97...122).contains(c) || c == 45 || c == 46 || c == 95
        }
    }

    /// The default label for a pair: `pair-` and twelve hex digits of both pins in order.
    public static func derived(pins: [String]) -> String {
        let digest = SHA256.hash(data: Data(pins.sorted().joined(separator: "\n").utf8))
        return "pair-" + digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }
}

/// One message of the ceremony. Every field is bounded; which fields a kind
/// carries is fixed (`validate`). Binary fields are standard base64 in JSON.
public struct ClusterPairingMessage: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case offer, answer, reveal, proof, decision, countersign, committed, abort, refused
    }
    public var kind: Kind
    public var version: Int?
    public var name: String?
    public var interface: String?
    public var identityKey: Data?
    public var ephemeralKey: Data?
    public var commitment: Data?
    public var nonce: Data?
    public var attestation: Data?
    public var clusterID: String?
    public var knownGeneration: UInt64?
    public var signature: Data?
    public var accept: Bool?
    public var tag: Data?
    public var reason: String?
    public var retryAfterEpochSeconds: Double?

    public init(kind: Kind) { self.kind = kind }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= ClusterPairingPolicy.maximumMessageBytes else { throw ClusterPairingError.malformedMessage }
        return data
    }

    public static func decode(_ data: Data) throws -> ClusterPairingMessage {
        guard data.count <= ClusterPairingPolicy.maximumMessageBytes,
              let message = try? JSONDecoder().decode(ClusterPairingMessage.self, from: data) else {
            throw ClusterPairingError.malformedMessage
        }
        try message.validate()
        return message
    }

    /// Exactly the fields of the kind, each within its bound.
    func validate() throws {
        let present: Set<String> = Set([
            version.map { _ in "version" }, name.map { _ in "name" }, interface.map { _ in "interface" },
            identityKey.map { _ in "identityKey" }, ephemeralKey.map { _ in "ephemeralKey" },
            commitment.map { _ in "commitment" }, nonce.map { _ in "nonce" }, attestation.map { _ in "attestation" },
            clusterID.map { _ in "clusterID" }, knownGeneration.map { _ in "knownGeneration" },
            signature.map { _ in "signature" }, accept.map { _ in "accept" }, tag.map { _ in "tag" },
            reason.map { _ in "reason" }, retryAfterEpochSeconds.map { _ in "retryAfterEpochSeconds" },
        ].compactMap { $0 })
        let expected: Set<String>
        switch kind {
        case .offer: expected = ["version", "name", "interface", "identityKey", "ephemeralKey", "commitment"]
        case .answer: expected = ["version", "name", "interface", "identityKey", "ephemeralKey", "nonce", "attestation",
                                  "clusterID", "knownGeneration"]
        case .reveal: expected = ["nonce", "attestation", "knownGeneration"]
        case .proof: expected = ["signature"]
        case .decision: expected = ["accept", "tag"]
        case .countersign: expected = ["signature", "tag"]
        case .committed: expected = ["tag"]
        // An abort after the keys are agreed carries a tag; one without is ignored then (see the session).
        case .abort: expected = present.contains("tag") ? ["reason", "tag"] : ["reason"]
        case .refused: expected = present.contains("retryAfterEpochSeconds") ? ["reason", "retryAfterEpochSeconds"] : ["reason"]
        }
        guard present == expected else { throw ClusterPairingError.malformedMessage }
        if let version, version < 1 { throw ClusterPairingError.malformedMessage }
        if let name { guard Self.printable(name, limit: ClusterPairingPolicy.maximumNameBytes) else { throw ClusterPairingError.malformedMessage } }
        if let interface {
            guard Self.printable(interface, limit: ClusterPairingPolicy.maximumInterfaceBytes) else { throw ClusterPairingError.malformedMessage }
        }
        if let identityKey { guard ClusterPairingPin.isIdentityKey(identityKey) else { throw ClusterPairingError.malformedMessage } }
        if let ephemeralKey { guard ephemeralKey.count == 32 else { throw ClusterPairingError.malformedMessage } }
        for value in [commitment, nonce, tag].compactMap({ $0 }) where value.count != 32 { throw ClusterPairingError.malformedMessage }
        if let attestation { guard (1...ClusterPairingPolicy.maximumAttestationBytes).contains(attestation.count) else { throw ClusterPairingError.malformedMessage } }
        if let clusterID { guard ClusterPairingLabel.isValid(clusterID) else { throw ClusterPairingError.malformedMessage } }
        if let knownGeneration { guard knownGeneration < UInt64.max / 2 else { throw ClusterPairingError.malformedMessage } }
        if let signature { guard (8...72).contains(signature.count) else { throw ClusterPairingError.malformedMessage } }
        if let reason { guard Self.printable(reason, limit: 64) else { throw ClusterPairingError.malformedMessage } }
    }

    static func printable(_ value: String, limit: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= limit && value.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value < 0x7F }
    }
}

/// The ceremony's derivations, as pure functions of public values and the
/// agreement. Domains are NUL-terminated so no input can extend one.
enum ClusterPairingDerivation {
    static let commitDomain = Data("darkbloom/cluster-pairing/commit/v1\0".utf8)
    static let transcriptDomain = Data("darkbloom/cluster-pairing/transcript/v1\0".utf8)
    static let codeDomain = Data("darkbloom/cluster-pairing/code/v1\0".utf8)
    static let proofDomain = Data("darkbloom/cluster-pairing/proof/v1\0".utf8)
    static let tagDomain = Data("darkbloom/cluster-pairing/tag/v1\0".utf8)
    static let confirmKeyDomain = Data("darkbloom/cluster-pairing/confirm-key/v1".utf8)
    static let edgeSecretDomain = Data("darkbloom/cluster-pairing/link-edge-secret/v1".utf8)
    static let epochDomain = Data("darkbloom/cluster-pairing/link-epoch/v1\0".utf8)

    static func commitment(identityKey: Data, ephemeralKey: Data, nonce: Data) -> Data {
        Data(SHA256.hash(data: commitDomain + lengthPrefixed(identityKey) + lengthPrefixed(ephemeralKey) + lengthPrefixed(nonce)))
    }

    struct TranscriptInputs {
        var connectorIdentity: Data, connectorEphemeral: Data, commitment: Data, connectorName: String, connectorInterface: String
        var listenerIdentity: Data, listenerEphemeral: Data, listenerNonce: Data, listenerName: String, listenerInterface: String
        var listenerAttestation: Data, clusterID: String, listenerGeneration: UInt64
        var connectorNonce: Data, connectorAttestation: Data, connectorGeneration: UInt64
    }

    static func transcript(_ t: TranscriptInputs) -> Data {
        var bytes = transcriptDomain
        for field in [t.connectorIdentity, t.connectorEphemeral, t.commitment, Data(t.connectorName.utf8), Data(t.connectorInterface.utf8),
                      t.listenerIdentity, t.listenerEphemeral, t.listenerNonce, Data(t.listenerName.utf8), Data(t.listenerInterface.utf8),
                      Data(SHA256.hash(data: t.listenerAttestation)), Data(t.clusterID.utf8)] {
            bytes.append(lengthPrefixed(field))
        }
        append(t.listenerGeneration, to: &bytes)
        bytes.append(lengthPrefixed(t.connectorNonce))
        bytes.append(lengthPrefixed(Data(SHA256.hash(data: t.connectorAttestation))))
        append(t.connectorGeneration, to: &bytes)
        return Data(SHA256.hash(data: bytes))
    }

    /// Six decimal digits from the transcript. The bias of 2^64 mod 10^6 is below 10^-13.
    static func code(transcript: Data) -> String {
        let digest = SHA256.hash(data: codeDomain + transcript)
        let value = digest.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } % 1_000_000
        let digits = String(value)
        return String(repeating: "0", count: ClusterPairingPolicy.codeDigits - digits.count) + digits
    }

    static func proofMessage(role: ClusterPairingRole, transcript: Data) -> Data {
        proofDomain + Data([role.byte]) + transcript
    }

    static func tag(kind: ClusterPairingMessage.Kind, role: ClusterPairingRole, transcript: Data, payload: Data,
                    key: SymmetricKey) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: tagMessage(kind: kind, role: role, transcript: transcript, payload: payload), using: key))
    }

    static func isValidTag(_ tag: Data, kind: ClusterPairingMessage.Kind, role: ClusterPairingRole, transcript: Data,
                           payload: Data, key: SymmetricKey) -> Bool {
        tag.count == 32 && HMAC<SHA256>.isValidAuthenticationCode(tag,
            authenticating: tagMessage(kind: kind, role: role, transcript: transcript, payload: payload), using: key)
    }

    private static func tagMessage(kind: ClusterPairingMessage.Kind, role: ClusterPairingRole, transcript: Data, payload: Data) -> Data {
        tagDomain + lengthPrefixed(Data(kind.rawValue.utf8)) + Data([role.byte]) + transcript + lengthPrefixed(payload)
    }

    /// The confirmation key and the link edge secret from the X25519
    /// agreement, salted with the transcript. Refuses a non-canonical peer
    /// key and an all-zero agreement.
    static func keys(privateKey: Curve25519.KeyAgreement.PrivateKey, peerEphemeral: Data,
                     transcript: Data) throws -> (confirm: SymmetricKey, edgeSecret: Data) {
        guard nativeCanonicalX25519PublicKey(peerEphemeral), transcript.count == 32,
              let peer = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerEphemeral),
              let shared = try? privateKey.sharedSecretFromKeyAgreement(with: peer),
              shared.withUnsafeBytes({ $0.reduce(UInt8(0)) { $0 | $1 } }) != 0 else {
            throw ClusterPairingError.malformedMessage
        }
        let confirm = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: transcript, sharedInfo: confirmKeyDomain,
            outputByteCount: 32)
        let edge = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: transcript, sharedInfo: edgeSecretDomain,
            outputByteCount: 32)
        return (confirm, edge.withUnsafeBytes { Data($0) })
    }

    /// The link epoch both ends key their link control edge with: a UUID
    /// (version 8, RFC 4122 variant) from the transcript.
    static func linkEpoch(transcript: Data) -> UUID {
        var bytes = Array(SHA256.hash(data: epochDomain + transcript).prefix(16))
        bytes[6] = bytes[6] & 0x0F | 0x80
        bytes[8] = bytes[8] & 0x3F | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    static func lengthPrefixed(_ data: Data) -> Data {
        var bytes = Data()
        let count = UInt32(data.count)
        for shift in stride(from: 24, through: 0, by: -8) { bytes.append(UInt8(truncatingIfNeeded: count >> UInt32(shift))) }
        bytes.append(data)
        return bytes
    }

    static func append(_ value: UInt64, to data: inout Data) {
        for shift in stride(from: 56, through: 0, by: -8) { data.append(UInt8(truncatingIfNeeded: value >> UInt64(shift))) }
    }
}

/// The listener's rate limit on new offers: a token bucket on the monotonic
/// clock, `offerBurst` at once and one more every `offerIntervalSeconds` (the
/// owner's oMLX `pair_request_rate_limiter`, per link instead of per address).
public struct ClusterPairingOfferBucket: Sendable, Equatable {
    private var tokens = ClusterPairingPolicy.offerBurst
    private var last: UInt64?

    public init() {}

    public mutating func allow(nowNanoseconds: UInt64) -> Bool {
        if let last, nowNanoseconds > last {
            tokens = min(ClusterPairingPolicy.offerBurst,
                tokens + Double(nowNanoseconds - last) / 1e9 / ClusterPairingPolicy.offerIntervalSeconds)
        }
        last = max(last ?? 0, nowNanoseconds)
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }
}
