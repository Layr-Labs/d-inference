import CryptoKit
import Foundation

/// The key one end of a link edge proves in link handshake v3. Production: the provider's Secure Enclave
/// attestation key, the key the coordinator verified when the member registered and the key the pairing pinned. It
/// signs only inside the Secure Enclave, for the signed provider that holds its keychain access group; nothing can
/// export it. Tests use a software P-256 key.
public protocol ClusterLinkIdentitySigner: Sendable {
    /// X9.63 uncompressed P-256 point, 65 bytes.
    var identityPublicKey: Data { get }
    /// ECDSA P-256 over SHA-256 of `message`: DER, or raw r‖s (64 bytes).
    func linkSignature(for message: Data) throws -> Data
}

/// Closed, payload-free failures. Never carries a key, a signature or a transcript.
public enum ClusterLinkIdentityError: Error, Equatable, Sendable, CustomStringConvertible {
    /// A key that is not a P-256 point, the same key on both ends, or an unusable cluster ID.
    case invalidIdentity
    /// The signer's key is not the key this end is pinned as, or its signature does not verify under it.
    case signerMismatch
    /// This end's key cannot sign: missing, or the binary has no access to it.
    case signerUnavailable
    /// This end's key cannot sign until the Mac is unlocked once after it started.
    case signerLocked

    public var description: String {
        switch self {
        case .invalidIdentity:
            return "the pairing's keys can't be used for the link; run `darkbloom cluster` on both Macs to pair them again"
        case .signerMismatch:
            return "this Mac's key is not the one its pair pinned; run `darkbloom cluster` on both Macs to pair them again"
        case .signerUnavailable:
            return "this Mac's key can't sign the link handshake (it is missing, or this build can't reach it)"
        case .signerLocked:
            return "this Mac's key is locked until someone logs in once after a restart (at its screen or with Screen "
                + "Sharing); the pair resumes by itself"
        }
    }
}

/// Who this end of one edge is and who the other end must be. Local configuration only (the roster both members
/// countersigned and the coordinator verified, or the pairing record), never read from the wire: a peer cannot ask
/// for less.
public struct ClusterLinkIdentity: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let signer: any ClusterLinkIdentitySigner
    /// The key this end is pinned as, and the key the other end must prove (X9.63, 65 bytes each).
    public let localIdentityKey: Data
    public let peerIdentityKey: Data
    /// The member pins of both keys (`ClusterPairingPin`, raw 32 bytes), as the handshake carries them.
    public let localPin: Data
    public let peerPin: Data
    /// The cluster ID both members' roster or pairing carries; every signature binds it.
    public let clusterID: String
    private let localKey: P256.Signing.PublicKey
    private let peerKey: P256.Signing.PublicKey

    public var description: String {
        "ClusterLinkIdentity(local \(Self.hex(localPin.prefix(8))), peer \(Self.hex(peerPin.prefix(8))))"
    }
    public var debugDescription: String { description }

    /// `localIdentityKey`: the key this end is pinned as (the roster's or the pairing's); nil uses the signer's own.
    /// A signer whose key is not that one is refused here, before any connection.
    public init(signer: any ClusterLinkIdentitySigner, localIdentityKey: Data? = nil, peerIdentityKey: Data,
                clusterID: String) throws {
        let local = localIdentityKey ?? signer.identityPublicKey
        guard ClusterPairingPin.isIdentityKey(local), ClusterPairingPin.isIdentityKey(peerIdentityKey),
              local != peerIdentityKey, !clusterID.isEmpty, clusterID.utf8.count <= 256, !clusterID.utf8.contains(0),
              let localKey = try? P256.Signing.PublicKey(x963Representation: local),
              let peerKey = try? P256.Signing.PublicKey(x963Representation: peerIdentityKey) else {
            throw ClusterLinkIdentityError.invalidIdentity
        }
        guard signer.identityPublicKey == local else { throw ClusterLinkIdentityError.signerMismatch }
        self.signer = signer; self.localIdentityKey = local; self.peerIdentityKey = peerIdentityKey
        self.localKey = localKey; self.peerKey = peerKey; self.clusterID = clusterID
        localPin = Self.pin(local); peerPin = Self.pin(peerIdentityKey)
    }

    /// This end's signature over one handshake transcript, raw r‖s (64 bytes). It is checked against this end's own
    /// pinned key before it is returned, so a wrong or failing signer never sends a signature.
    public func signature(role: ClusterLinkControlRole, epoch: UUID, edgeID: UUID, transcript: Data) throws -> Data {
        let message = ClusterLinkHandshakeSignature.message(role: role, epoch: epoch, edgeID: edgeID,
            clusterID: clusterID, transcript: transcript)
        let produced: Data
        do { produced = try signer.linkSignature(for: message) }
        catch let error as ClusterLinkIdentityError { throw error }
        catch { throw ClusterLinkIdentityError.signerUnavailable }
        guard let raw = Self.raw(produced), let value = try? P256.Signing.ECDSASignature(rawRepresentation: raw),
              localKey.isValidSignature(value, for: message) else {
            throw ClusterLinkIdentityError.signerMismatch
        }
        return raw
    }

    /// The other end's signature (raw r‖s) over the same transcript, under the pinned peer key.
    public func isValidPeerSignature(_ signature: Data, role: ClusterLinkControlRole, epoch: UUID, edgeID: UUID,
                                     transcript: Data) -> Bool {
        guard signature.count == 64, let value = try? P256.Signing.ECDSASignature(rawRepresentation: signature) else {
            return false
        }
        return peerKey.isValidSignature(value, for: ClusterLinkHandshakeSignature.message(role: role, epoch: epoch,
            edgeID: edgeID, clusterID: clusterID, transcript: transcript))
    }

    static func pin(_ key: Data) -> Data { Data(SHA256.hash(data: ClusterPairingPin.domain + key)) }

    /// DER or raw r‖s to raw r‖s.
    static func raw(_ signature: Data) -> Data? {
        if signature.count == 64 { return signature }
        return (try? P256.Signing.ECDSASignature(derRepresentation: signature))?.rawRepresentation
    }

    private static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
}

/// What each end of handshake v3 signs. The first byte, 0xFF, never occurs in UTF-8, and every other message this
/// key signs is UTF-8 text (attestation challenges, enrollment, response hashes, JSON) or starts with an ASCII
/// `darkbloom/…` domain (data-plane certificates, native-pair messages, calibration documents, the pairing proof):
/// no other use of the key can yield a handshake signature, and a handshake signature is good for nothing else.
enum ClusterLinkHandshakeSignature {
    static let prefix = Data([0xFF]) + Data("darkbloom/link-control/handshake-signature/v3\0".utf8)
    static let digestDomain = Data("darkbloom/link-control/handshake-transcript/v3\0".utf8)

    static func message(role: ClusterLinkControlRole, epoch: UUID, edgeID: UUID, clusterID: String,
                        transcript: Data) -> Data {
        var hasher = SHA256()
        hasher.update(data: digestDomain)
        hasher.update(data: Data([role.rawValue]))
        hasher.update(data: clusterRecordUUIDBytes(epoch)); hasher.update(data: clusterRecordUUIDBytes(edgeID))
        let cluster = Data(clusterID.utf8)
        hasher.update(data: Data([UInt8(truncatingIfNeeded: cluster.count >> 8), UInt8(truncatingIfNeeded: cluster.count)]))
        hasher.update(data: cluster)
        hasher.update(data: transcript)
        var message = prefix
        message.append(role.rawValue)
        message.append(contentsOf: hasher.finalize())
        return message
    }
}
