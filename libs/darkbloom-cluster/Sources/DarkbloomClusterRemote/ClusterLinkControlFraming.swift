import CryptoKit
import DarkbloomClusterSecurity
import Foundation

/// Frame kinds inside one authenticated record. Sequenced kinds carry a
/// message ID and are retransmitted across reconnects; the others are
/// per-connection only.
enum LinkFrameKind: UInt8, Sendable {
    case heartbeat = 1
    case ack = 2
    case ping = 3
    case pong = 4
    case goodbye = 5
    case message = 16
    case opaque = 17

    var isSequenced: Bool { self == .message || self == .opaque }
}

/// Why a peer said goodbye before closing.
enum LinkGoodbyeReason: UInt8, Sendable {
    case shutdown = 1
    case rekey = 2
    case superseded = 3
    case protocolViolation = 4
}

/// Plaintext layout (authenticated and encrypted by the record layer):
/// version u8 | kind u8 | flags u16 (0) | messageID u64 | ackThrough u64 | body.
struct LinkFrame: Sendable, Equatable {
    static let headerBytes = 20
    static let version: UInt8 = 1
    static let pingBodyBytes = 16

    let kind: LinkFrameKind
    let messageID: UInt64
    let ackThrough: UInt64
    let body: Data

    func plaintext() -> Data {
        var result = Data(capacity: Self.headerBytes + body.count)
        result.append(Self.version); result.append(kind.rawValue); result.append(contentsOf: [0, 0])
        result.clusterLinkAppend(messageID); result.clusterLinkAppend(ackThrough)
        result.append(body)
        return result
    }

    static func parse(_ plaintext: Data, maximumBodyBytes: Int) throws -> LinkFrame {
        guard plaintext.count >= headerBytes, plaintext.count - headerBytes <= maximumBodyBytes else {
            throw ClusterLinkControlError.protocolViolation
        }
        let base = plaintext.startIndex
        guard plaintext[base] == version, let kind = LinkFrameKind(rawValue: plaintext[base + 1]),
              plaintext[base + 2] == 0, plaintext[base + 3] == 0 else { throw ClusterLinkControlError.protocolViolation }
        let messageID = plaintext.clusterLinkUInt64(at: 4)
        let ackThrough = plaintext.clusterLinkUInt64(at: 12)
        let body = plaintext.subdata(in: (base + headerBytes)..<plaintext.endIndex)
        guard kind.isSequenced == (messageID != 0) else { throw ClusterLinkControlError.protocolViolation }
        switch kind {
        case .heartbeat: guard body.count <= 64 else { throw ClusterLinkControlError.protocolViolation }
        case .ack: guard body.isEmpty else { throw ClusterLinkControlError.protocolViolation }
        case .ping: guard body.count >= pingBodyBytes else { throw ClusterLinkControlError.protocolViolation }
        case .pong: guard body.count == pingBodyBytes else { throw ClusterLinkControlError.protocolViolation }
        case .goodbye: guard body.count == 1 else { throw ClusterLinkControlError.protocolViolation }
        case .message: guard !body.isEmpty else { throw ClusterLinkControlError.protocolViolation }
        case .opaque: guard body.count >= 2 else { throw ClusterLinkControlError.protocolViolation }
        }
        return .init(kind: kind, messageID: messageID, ackThrough: ackThrough, body: body)
    }
}

/// Fixed-size handshake records, big endian (version 3). Every read before
/// the peer is authenticated is fixed-size, so an unauthenticated peer never
/// chooses an allocation, and the listener speaks first with only a fresh
/// nonce and a fresh public key.
///
///   listener  -> CHALLENGE "DBLC" v 000 | nonce(32) | ephemeral X25519(32)  72 B
///   connector -> HELLO     "DBLH" v role 00 | epoch | edge | nonce(32) |
///                          ephemeral X25519(32) | incarnation | known
///                          listener incarnation | delivered u64 |
///                          limits (u32 u64 u64) | connector pin(32) |
///                          listener pin(32) | signature(64) | tag(32)      324 B
///   listener  -> ACCEPT    "DBLA" v 000 | incarnation | known connector
///                          incarnation | delivered u64 | signature(64) |
///                          tag(32)                                         144 B
///
/// On a serving edge each end signs with the Secure Enclave key the other
/// pinned (`ClusterLinkIdentity`): the connector over CHALLENGE + HELLO up to
/// its signature (the listener's fresh nonce and key, its own key, both pins),
/// the listener, after it verified that, over CHALLENGE + HELLO + ACCEPT up to
/// its signature (the connector's nonce, key and signature). The pins are the
/// ones each end holds for the other, never trusted from the wire: each end
/// checks them against its own configuration, then the signature under the
/// pinned key, before anything is derived. An edge-key-only edge (bootstrap,
/// setup exchange, qualification) sends zero pins and signatures.
///
/// The edge key's tags cover each record up to the tag (signatures included);
/// they are checked first, so a party without the edge secret never makes an
/// end verify or sign. Session keys come from the X25519 agreement of the two
/// ephemeral keys (each made for this connection, in memory only), the SHA-256
/// of all three records, the edge key, the epoch and the edge
/// (`ClusterLinkControlKey.sessionKeys`). Each end reads the peer's first eight
/// bytes before the rest: another version (v1 of 0.10.12, v2 of the DevNet
/// builds) is refused there, with no fallback (`protocolVersionMismatch`).
enum LinkHandshake {
    static let version: UInt8 = 3
    /// Magic and version: what each end reads first of the peer's record.
    static let headerBytes = 8
    static let challengeBytes = 72
    static let helloBytes = 324
    static let acceptBytes = 144
    static let publicKeyBytes = 32
    static let pinBytes = 32
    static let signatureBytes = 64
    static let tagBytes = 32
    private static let challengeMagic: [UInt8] = Array("DBLC".utf8)
    private static let helloMagic: [UInt8] = Array("DBLH".utf8)
    private static let acceptMagic: [UInt8] = Array("DBLA".utf8)
    private static let transcriptDomain = Data("darkbloom/link-control/transcript/v3\0".utf8)

    /// Byte ranges of the HELLO's identity fields.
    enum HelloLayout {
        static let connectorPin = 164..<196
        static let listenerPin = 196..<228
        static let signature = 228..<292
        static let tag = 292..<324
    }

    /// Byte ranges of the ACCEPT's identity fields.
    enum AcceptLayout {
        static let signature = 48..<112
        static let tag = 112..<144
    }

    /// The peer's challenge or hello header: the right magic, then this version
    /// only. Another version is a refusal of its own; anything else is malformed.
    static func requireVersion(_ header: Data, hello: Bool) throws {
        let bytes = Array(header)
        guard bytes.count == headerBytes, Array(bytes[0..<4]) == (hello ? helloMagic : challengeMagic) else {
            throw ClusterLinkControlError.malformedHandshake
        }
        guard bytes[4] == version else { throw ClusterLinkControlRefusal.protocolVersionMismatch }
    }

    /// What one end knows about the reliable stream when it (re)connects.
    struct Resume: Sendable, Equatable {
        let incarnation: UUID
        /// The peer incarnation this end last spoke with; nil before the first session.
        let knownPeerIncarnation: UUID?
        /// Highest message ID delivered from `knownPeerIncarnation`.
        let deliveredThrough: UInt64
    }

    struct Hello: Sendable, Equatable {
        let epoch: UUID
        let edgeID: UUID
        let nonce: Data
        /// The connector's ephemeral X25519 public key for this connection.
        let ephemeralPublicKey: Data
        let resume: Resume
        let maximumPlaintextBytes: UInt32
        let maximumRecords: UInt64
        let maximumCumulativeBytes: UInt64
        /// The connector's own pin and the pin it holds for the listener (zero on an edge-key-only edge).
        let connectorPin: Data
        let listenerPin: Data
    }

    static func challenge(nonce: Data, ephemeralPublicKey: Data) -> Data {
        var result = Data(challengeMagic); result.append(contentsOf: [version, 0, 0, 0]); result.append(nonce)
        result.append(ephemeralPublicKey)
        return result
    }

    /// The listener's ephemeral public key.
    static func parseChallenge(_ data: Data) throws -> Data {
        let bytes = Array(data)
        guard bytes.count == challengeBytes, Array(bytes[0..<4]) == challengeMagic, bytes[4] == version,
              bytes[5] == 0, bytes[6] == 0, bytes[7] == 0 else { throw ClusterLinkControlError.malformedHandshake }
        return Data(bytes[40..<72])
    }

    /// The HELLO up to the connector's signature: what the connector signs (after the challenge).
    static func helloSigned(_ hello: Hello) -> Data {
        var result = Data(helloMagic)
        result.append(contentsOf: [version, ClusterLinkControlRole.connector.rawValue, 0, 0])
        result.append(uuidBytes(hello.epoch)); result.append(uuidBytes(hello.edgeID)); result.append(hello.nonce)
        result.append(hello.ephemeralPublicKey)
        result.append(uuidBytes(hello.resume.incarnation))
        result.append(uuidBytes(hello.resume.knownPeerIncarnation))
        result.clusterLinkAppend(hello.resume.deliveredThrough)
        result.clusterLinkAppend(hello.maximumPlaintextBytes)
        result.clusterLinkAppend(hello.maximumRecords)
        result.clusterLinkAppend(hello.maximumCumulativeBytes)
        result.append(hello.connectorPin); result.append(hello.listenerPin)
        return result
    }

    /// The HELLO up to its tag: what the edge key's connector tag covers (after the challenge).
    static func helloWithoutTag(_ hello: Hello, signature: Data) -> Data {
        var result = helloSigned(hello); result.append(signature)
        return result
    }

    static func parseHello(_ data: Data) throws -> (Hello, signature: Data, tag: Data) {
        let bytes = Array(data)
        guard bytes.count == helloBytes, Array(bytes[0..<4]) == helloMagic, bytes[4] == version,
              bytes[5] == ClusterLinkControlRole.connector.rawValue, bytes[6] == 0, bytes[7] == 0 else {
            throw ClusterLinkControlError.malformedHandshake
        }
        guard let epoch = uuid(bytes, 8), let edge = uuid(bytes, 24), let incarnation = uuid(bytes, 104) else {
            throw ClusterLinkControlError.malformedHandshake
        }
        let data = Data(bytes)
        let hello = Hello(epoch: epoch, edgeID: edge, nonce: Data(bytes[40..<72]),
            ephemeralPublicKey: Data(bytes[72..<104]),
            resume: .init(incarnation: incarnation, knownPeerIncarnation: uuid(bytes, 120),
                          deliveredThrough: data.clusterLinkUInt64(at: 136)),
            maximumPlaintextBytes: data.clusterLinkUInt32(at: 144),
            maximumRecords: data.clusterLinkUInt64(at: 148),
            maximumCumulativeBytes: data.clusterLinkUInt64(at: 156),
            connectorPin: Data(bytes[HelloLayout.connectorPin]), listenerPin: Data(bytes[HelloLayout.listenerPin]))
        return (hello, Data(bytes[HelloLayout.signature]), Data(bytes[HelloLayout.tag]))
    }

    /// The ACCEPT up to the listener's signature: what the listener signs (after the challenge and the hello).
    static func acceptSigned(_ resume: Resume) -> Data {
        var result = Data(acceptMagic); result.append(contentsOf: [version, 0, 0, 0])
        result.append(uuidBytes(resume.incarnation)); result.append(uuidBytes(resume.knownPeerIncarnation))
        result.clusterLinkAppend(resume.deliveredThrough)
        return result
    }

    /// The ACCEPT up to its tag: what the edge key's listener tag covers (after the challenge and the hello).
    static func acceptWithoutTag(_ resume: Resume, signature: Data) -> Data {
        var result = acceptSigned(resume); result.append(signature)
        return result
    }

    static func parseAccept(_ data: Data) throws -> (Resume, signature: Data, tag: Data) {
        let bytes = Array(data)
        guard bytes.count == acceptBytes, Array(bytes[0..<4]) == acceptMagic, bytes[4] == version,
              bytes[5] == 0, bytes[6] == 0, bytes[7] == 0, let incarnation = uuid(bytes, 8) else {
            throw ClusterLinkControlError.malformedHandshake
        }
        let data = Data(bytes)
        return (.init(incarnation: incarnation, knownPeerIncarnation: uuid(bytes, 24),
                      deliveredThrough: data.clusterLinkUInt64(at: 40)),
                Data(bytes[AcceptLayout.signature]), Data(bytes[AcceptLayout.tag]))
    }

    static func transcriptSHA256(challenge: Data, hello: Data, accept: Data) -> Data {
        var hasher = SHA256()
        hasher.update(data: transcriptDomain); hasher.update(data: challenge)
        hasher.update(data: hello); hasher.update(data: accept)
        return Data(hasher.finalize())
    }

    static func uuidBytes(_ value: UUID?) -> Data {
        guard var raw = value?.uuid else { return Data(repeating: 0, count: 16) }
        return withUnsafeBytes(of: &raw) { Data($0) }
    }

    /// Nil for the all-zero UUID (meaning "none").
    static func uuid(_ bytes: [UInt8], _ offset: Int) -> UUID? {
        let slice = Array(bytes[offset..<offset + 16])
        guard !slice.allSatisfy({ $0 == 0 }) else { return nil }
        return UUID(uuid: (slice[0], slice[1], slice[2], slice[3], slice[4], slice[5], slice[6], slice[7],
                           slice[8], slice[9], slice[10], slice[11], slice[12], slice[13], slice[14], slice[15]))
    }

    static func randomNonce() -> Data {
        var generator = SystemRandomNumberGenerator()
        var result = Data(capacity: 32)
        for _ in 0..<4 { result.clusterLinkAppend(generator.next() as UInt64) }
        return result
    }
}

/// The two record codecs of one connection: one only seals (this end to the
/// peer), one only opens (peer to this end). Each has its own key, sequence
/// and budget, so a reader and a writer never contend for one codec.
struct LinkRecordPair: Sendable {
    let sealer: ClusterAuthenticatedRecordChannel
    let opener: ClusterAuthenticatedRecordChannel
    let sealContext: ClusterRecordContext
    let openContext: ClusterRecordContext
    let limits: ClusterRecordLimits

    init(role: ClusterLinkControlRole, key: ClusterLinkControlKey, ephemeralPrivateKey: Curve25519.KeyAgreement.PrivateKey,
         peerEphemeralPublicKey: Data, transcriptSHA256: Data, epoch: UUID, edgeID: UUID, limits: ClusterRecordLimits) throws {
        let keys = try key.sessionKeys(ephemeralPrivateKey: ephemeralPrivateKey, peerEphemeralPublicKey: peerEphemeralPublicKey,
            transcriptSHA256: transcriptSHA256, epoch: epoch, edgeID: edgeID)
        var edgeDigest = SHA256()
        edgeDigest.update(data: Data("darkbloom/link-control/edge/v1\0".utf8))
        edgeDigest.update(data: LinkHandshake.uuidBytes(edgeID))
        let binding = try ClusterRecordBinding(epoch: epoch, planSHA256: Data(edgeDigest.finalize()),
            membershipTranscriptSHA256: transcriptSHA256)
        // The record layer's rank selects the directional sub-key; the listener
        // is rank 0 and the connector rank 1 on both of this connection's codecs.
        let rank = Int(role.rawValue)
        let outbound = role == .connector ? keys.connectorToListener : keys.listenerToConnector
        let inbound = role == .connector ? keys.listenerToConnector : keys.connectorToListener
        sealer = try ClusterAuthenticatedRecordChannel(sessionKey: outbound, binding: binding, localRank: rank, limits: limits)
        opener = try ClusterAuthenticatedRecordChannel(sessionKey: inbound, binding: binding, localRank: rank, limits: limits)
        func context(_ direction: ClusterLinkControlRole) throws -> ClusterRecordContext {
            var hasher = SHA256()
            hasher.update(data: Data("darkbloom/link-control/frame/v1\0".utf8))
            hasher.update(data: LinkHandshake.uuidBytes(edgeID)); hasher.update(data: Data([direction.rawValue]))
            return try ClusterRecordContext(requestID: nil, type: .linkControl, expectationSHA256: Data(hasher.finalize()))
        }
        let peerRole: ClusterLinkControlRole = role == .connector ? .listener : .connector
        sealContext = try context(role); openContext = try context(peerRole)
        self.limits = limits
    }

    func invalidate() { sealer.invalidate(); opener.invalidate() }
}

extension Data {
    mutating func clusterLinkAppend<T: FixedWidthInteger>(_ value: T) {
        var value = value.bigEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }

    func clusterLinkUInt64(at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<8 { value = value << 8 | UInt64(self[startIndex + offset + index]) }
        return value
    }

    func clusterLinkUInt32(at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for index in 0..<4 { value = value << 8 | UInt32(self[startIndex + offset + index]) }
        return value
    }

    func clusterLinkUInt16(at offset: Int) -> UInt16 {
        UInt16(self[startIndex + offset]) << 8 | UInt16(self[startIndex + offset + 1])
    }
}
