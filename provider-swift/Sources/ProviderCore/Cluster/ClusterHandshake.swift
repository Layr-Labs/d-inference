/// ClusterHandshake -- mutual-authenticated key agreement between two cluster
/// members, before any activation crosses the link.
///
/// A SIGMA-style "sign the transcript" exchange (3 messages). Each side proves
/// it controls an attested Secure-Enclave identity (listed in the
/// coordinator-signed `ClusterRoster`) AND that it chose this session's
/// ephemeral X25519 key -- the same SE-vouches-for-an-X25519-key binding the
/// coordinator already enforces at registration
/// (`coordinator/api/provider.go` EncryptionPublicKey == register key),
/// applied pairwise. See docs/architecture/cluster-node-handshake.md §5.
///
///   transcript1 = clusterId ‖ A.nodeId ‖ eA.pub ‖ nonceA ‖ B.nodeId ‖ eB.pub ‖ nonceB
///   A → B  Msg1 { clusterId, A.nodeId, eA.pub, nonceA }
///   B → A  Msg2 { B.nodeId, eB.pub, nonceB, sigB }   sigB = SE_B.sign(transcript1)
///   A → B  Msg3 { sigA }                             sigA = SE_A.sign(transcript1 ‖ sigB)
///
/// Ephemeral X25519 keys give forward secrecy; the long-term SE key only signs
/// (SE P-256 is signing-only). The derived master secret feeds
/// `ClusterSessionKeys` / `ClusterLinkCrypto` for per-token sealing.
///
/// Built on existing primitives -- `X25519KeyAgreementKeyPair`,
/// `AttestationSigner`, `SecureEnclaveIdentity.verify` -- so the whole flow is
/// unit-testable on one machine with a software P-256 signer.

import CryptoKit
import Foundation

public enum ClusterHandshakeError: Error, Equatable, Sendable {
    case peerNotInRoster(nodeId: String)
    case peerSignatureInvalid(nodeId: String)
    case staleNonce
    case badPublicKeyLength
    case rosterClusterMismatch
}

// MARK: - Wire messages

public struct ClusterHandshakeMsg1: Codable, Equatable, Sendable {
    public let clusterId: String
    public let initiatorNodeId: String
    public let ephemeralPublicKey: Data   // 32-byte X25519
    public let nonce: Data                // 32-byte random
}

public struct ClusterHandshakeMsg2: Codable, Equatable, Sendable {
    public let responderNodeId: String
    public let ephemeralPublicKey: Data   // 32-byte X25519
    public let nonce: Data                // 32-byte random
    public let signature: Data            // DER P-256 over transcript1
}

public struct ClusterHandshakeMsg3: Codable, Equatable, Sendable {
    public let signature: Data            // DER P-256 over transcript1 ‖ sigB
}

/// The result both sides converge on: a shared master secret plus the
/// directional keys ready for `ClusterLinkCrypto`.
public struct ClusterSession: Sendable {
    public let clusterId: String
    public let localNodeId: String
    public let peerNodeId: String
    public let masterSecret: SymmetricKey

    /// Construct a session directly from an agreed master secret. Used by the
    /// handshake, and by direct ephemeral key-agreement paths (e.g. the
    /// ring-only encrypted link without a coordinator roster).
    public init(clusterId: String, localNodeId: String, peerNodeId: String, masterSecret: SymmetricKey) {
        self.clusterId = clusterId
        self.localNodeId = localNodeId
        self.peerNodeId = peerNodeId
        self.masterSecret = masterSecret
    }

    /// Key for frames this node SENDS to the peer.
    public func sendKey() -> SymmetricKey {
        ClusterSessionKeys.directionalKey(
            masterSecret: masterSecret, clusterId: clusterId,
            fromNodeId: localNodeId, toNodeId: peerNodeId)
    }

    /// Key for frames this node RECEIVES from the peer.
    public func recvKey() -> SymmetricKey {
        ClusterSessionKeys.directionalKey(
            masterSecret: masterSecret, clusterId: clusterId,
            fromNodeId: peerNodeId, toNodeId: localNodeId)
    }
}

// MARK: - Transcript

enum ClusterTranscript {
    /// Length-prefixed concatenation so no field boundary is ambiguous.
    static func part(_ data: Data) -> Data {
        var out = Data()
        var len = UInt32(data.count).bigEndian
        withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
        out.append(data)
        return out
    }

    static func one(
        clusterId: String,
        initiatorNodeId: String, eAPub: Data, nonceA: Data,
        responderNodeId: String, eBPub: Data, nonceB: Data
    ) -> Data {
        var t = Data()
        t.append(part(Data(clusterId.utf8)))
        t.append(part(Data(initiatorNodeId.utf8)))
        t.append(part(eAPub))
        t.append(part(nonceA))
        t.append(part(Data(responderNodeId.utf8)))
        t.append(part(eBPub))
        t.append(part(nonceB))
        return t
    }
}

// MARK: - Shared helpers

enum ClusterKeyAgreement {
    static let masterInfoPrefix = "darkbloom-cluster-handshake-v1"

    /// Derive the master secret from the ephemeral agreement, channel-bound to
    /// the cluster and the (sorted) identity pair so a recorded handshake can't
    /// be re-pointed at a different peer.
    static func masterSecret(
        ephemeral: X25519KeyAgreementKeyPair,
        peerEphemeralPublicKey: Data,
        clusterId: String,
        nodeIdA: String,
        nodeIdB: String,
        nonceA: Data,
        nonceB: Data
    ) throws -> SymmetricKey {
        let pair = [nodeIdA, nodeIdB].sorted().joined(separator: "<>")
        let sharedInfo = Data("\(masterInfoPrefix)|\(clusterId)|\(pair)".utf8)
        return try ephemeral.symmetricKey(
            peerPublicKey: peerEphemeralPublicKey,
            salt: nonceA + nonceB,
            sharedInfo: sharedInfo
        )
    }

    static func randomNonce() -> Data {
        var key = SymmetricKey(size: .bits256)
        return key.withUnsafeBytes { Data($0) }
    }
}

// MARK: - Initiator (node A, lower nodeId)

public final class ClusterHandshakeInitiator {
    private let clusterId: String
    private let localNodeId: String
    private let signer: any AttestationSigner
    private let roster: ClusterRosterBody

    private let ephemeral = X25519KeyAgreementKeyPair()
    private let nonceA = ClusterKeyAgreement.randomNonce()

    public init(
        clusterId: String,
        localNodeId: String,
        signer: any AttestationSigner,
        roster: ClusterRosterBody
    ) {
        self.clusterId = clusterId
        self.localNodeId = localNodeId
        self.signer = signer
        self.roster = roster
    }

    /// Build Msg1.
    public func start() -> ClusterHandshakeMsg1 {
        ClusterHandshakeMsg1(
            clusterId: clusterId,
            initiatorNodeId: localNodeId,
            ephemeralPublicKey: ephemeral.publicKey,
            nonce: nonceA
        )
    }

    /// Consume Msg2 (verify B), produce Msg3, and finalize the session.
    public func finish(_ msg2: ClusterHandshakeMsg2) throws -> (ClusterHandshakeMsg3, ClusterSession) {
        guard msg2.ephemeralPublicKey.count == 32, msg2.nonce.count == 32 else {
            throw ClusterHandshakeError.badPublicKeyLength
        }
        // We must be on the roster we were issued before forming a link.
        _ = try ClusterRoster.member(roster, nodeId: localNodeId)
        let peer = try ClusterRoster.member(roster, nodeId: msg2.responderNodeId)
        guard let peerSEKey = Data(base64Encoded: peer.sePublicKeyBase64) else {
            throw ClusterHandshakeError.peerNotInRoster(nodeId: msg2.responderNodeId)
        }

        let t1 = ClusterTranscript.one(
            clusterId: clusterId,
            initiatorNodeId: localNodeId, eAPub: ephemeral.publicKey, nonceA: nonceA,
            responderNodeId: msg2.responderNodeId, eBPub: msg2.ephemeralPublicKey, nonceB: msg2.nonce)

        guard SecureEnclaveIdentity.verify(signature: msg2.signature, for: t1, publicKey: peerSEKey) else {
            throw ClusterHandshakeError.peerSignatureInvalid(nodeId: msg2.responderNodeId)
        }

        let sigA = try signer.sign(t1 + msg2.signature)
        let master = try ClusterKeyAgreement.masterSecret(
            ephemeral: ephemeral,
            peerEphemeralPublicKey: msg2.ephemeralPublicKey,
            clusterId: clusterId,
            nodeIdA: localNodeId, nodeIdB: msg2.responderNodeId,
            nonceA: nonceA, nonceB: msg2.nonce)

        let session = ClusterSession(
            clusterId: clusterId, localNodeId: localNodeId,
            peerNodeId: msg2.responderNodeId, masterSecret: master)
        return (ClusterHandshakeMsg3(signature: sigA), session)
    }
}

// MARK: - Responder (node B)

public final class ClusterHandshakeResponder {
    private let localNodeId: String
    private let signer: any AttestationSigner
    private let roster: ClusterRosterBody

    private let ephemeral = X25519KeyAgreementKeyPair()
    private let nonceB = ClusterKeyAgreement.randomNonce()

    // captured between respond() and confirm()
    private var transcript1: Data?
    private var sigB: Data?
    private var peerNodeId: String?
    private var pendingSession: ClusterSession?

    public init(localNodeId: String, signer: any AttestationSigner, roster: ClusterRosterBody) {
        self.localNodeId = localNodeId
        self.signer = signer
        self.roster = roster
    }

    /// Consume Msg1, produce Msg2. Stages the session pending Msg3 verification.
    public func respond(_ msg1: ClusterHandshakeMsg1) throws -> ClusterHandshakeMsg2 {
        guard msg1.ephemeralPublicKey.count == 32, msg1.nonce.count == 32 else {
            throw ClusterHandshakeError.badPublicKeyLength
        }
        // Both ends must be vouched for by the roster we were issued: the peer
        // (initiator) AND ourselves. A node absent from the roster must refuse
        // to participate rather than form an unattested link.
        _ = try ClusterRoster.member(roster, nodeId: localNodeId)
        _ = try ClusterRoster.member(roster, nodeId: msg1.initiatorNodeId)

        let t1 = ClusterTranscript.one(
            clusterId: msg1.clusterId,
            initiatorNodeId: msg1.initiatorNodeId, eAPub: msg1.ephemeralPublicKey, nonceA: msg1.nonce,
            responderNodeId: localNodeId, eBPub: ephemeral.publicKey, nonceB: nonceB)
        let signature = try signer.sign(t1)

        let master = try ClusterKeyAgreement.masterSecret(
            ephemeral: ephemeral,
            peerEphemeralPublicKey: msg1.ephemeralPublicKey,
            clusterId: msg1.clusterId,
            nodeIdA: msg1.initiatorNodeId, nodeIdB: localNodeId,
            nonceA: msg1.nonce, nonceB: nonceB)

        self.transcript1 = t1
        self.sigB = signature
        self.peerNodeId = msg1.initiatorNodeId
        self.pendingSession = ClusterSession(
            clusterId: msg1.clusterId, localNodeId: localNodeId,
            peerNodeId: msg1.initiatorNodeId, masterSecret: master)

        return ClusterHandshakeMsg2(
            responderNodeId: localNodeId,
            ephemeralPublicKey: ephemeral.publicKey,
            nonce: nonceB,
            signature: signature)
    }

    /// Consume Msg3 (verify A), returning the confirmed session.
    public func confirm(_ msg3: ClusterHandshakeMsg3) throws -> ClusterSession {
        guard let t1 = transcript1, let sigB, let peerNodeId, let session = pendingSession else {
            throw ClusterHandshakeError.staleNonce
        }
        let peer = try ClusterRoster.member(roster, nodeId: peerNodeId)
        guard let peerSEKey = Data(base64Encoded: peer.sePublicKeyBase64) else {
            throw ClusterHandshakeError.peerNotInRoster(nodeId: peerNodeId)
        }
        guard SecureEnclaveIdentity.verify(signature: msg3.signature, for: t1 + sigB, publicKey: peerSEKey) else {
            throw ClusterHandshakeError.peerSignatureInvalid(nodeId: peerNodeId)
        }
        return session
    }
}
