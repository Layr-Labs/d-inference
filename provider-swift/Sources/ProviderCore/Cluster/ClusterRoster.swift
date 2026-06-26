/// ClusterRoster -- the coordinator-signed roster of attested cluster members.
///
/// In a Darkbloom cluster (see docs/architecture/clustering.md and
/// cluster-node-handshake.md) the coordinator remains the trust anchor: every
/// member attests to the coordinator via the existing attestation +
/// challenge-response path, the coordinator computes `cluster trust =
/// min(member trust)`, and -- if every member clears the floor -- issues this
/// roster. Members then run pairwise handshakes among themselves
/// (`ClusterHandshake`), using the roster to learn which peer Secure-Enclave
/// keys are authorized. The coordinator is NOT in the per-message path.
///
/// The roster is signed by the coordinator's P-256 key over a deterministic,
/// sorted-key JSON encoding (the same approach `AttestationBuilder` uses for the
/// attestation blob, so Go and Swift produce identical bytes). Verification only
/// needs the coordinator's public key, so any node can check it offline.
///
/// This type is pure data + signature verification: it depends only on
/// CryptoKit (via `SecureEnclaveIdentity.verify`) and Foundation, so it is
/// fully unit-testable on a single machine with a software P-256 key.

import CryptoKit
import Foundation

/// A single attested member of a cluster, as vouched for by the coordinator.
public struct ClusterMember: Codable, Equatable, Sendable {
    /// Stable identifier for this node within the cluster (assigned by the
    /// coordinator). Used to order ring neighbors and to pick the handshake
    /// initiator deterministically (lower id initiates).
    public let nodeId: String

    /// Base64-encoded raw P-256 (64-byte X||Y) Secure-Enclave signing key.
    /// This is the long-term identity used to authenticate the member in the
    /// pairwise handshake. Matches `AttestationBlob.publicKey`.
    public let sePublicKeyBase64: String

    /// Base64-encoded raw 32-byte X25519 key bound to this member's attestation
    /// (`AttestationBlob.encryptionPublicKey`). Informational here -- the
    /// handshake uses *fresh ephemeral* X25519 keys for forward secrecy -- but
    /// carried so a verifier can cross-check against the attestation record.
    public let x25519PublicKeyBase64: String

    /// Trust level the coordinator assigned this member ("hardware",
    /// "self_signed", ...). The cluster's surfaced trust is the minimum across
    /// members; a roster is only issued when every member clears the floor.
    public let trustLevel: String

    public init(
        nodeId: String,
        sePublicKeyBase64: String,
        x25519PublicKeyBase64: String,
        trustLevel: String
    ) {
        self.nodeId = nodeId
        self.sePublicKeyBase64 = sePublicKeyBase64
        self.x25519PublicKeyBase64 = x25519PublicKeyBase64
        self.trustLevel = trustLevel
    }
}

/// The body of a roster -- everything covered by the coordinator's signature.
public struct ClusterRosterBody: Codable, Equatable, Sendable {
    public let clusterId: String
    public let members: [ClusterMember]
    /// ISO-8601 issuance time.
    public let issuedAt: Date
    /// ISO-8601 expiry. A stale roster must not be honored -- forces periodic
    /// re-issue so it cannot outlive the trust it represents.
    public let expiresAt: Date

    public init(clusterId: String, members: [ClusterMember], issuedAt: Date, expiresAt: Date) {
        self.clusterId = clusterId
        self.members = members
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }
}

/// A signed roster: the body plus a base64 DER P-256 ECDSA signature over the
/// body's deterministic JSON encoding, produced by the coordinator key.
public struct SignedClusterRoster: Codable, Equatable, Sendable {
    public let body: ClusterRosterBody
    /// Base64-encoded DER ECDSA signature over `Self.canonicalBytes(body)`.
    public let signature: String

    public init(body: ClusterRosterBody, signature: String) {
        self.body = body
        self.signature = signature
    }
}

public enum ClusterRosterError: Error, Equatable, Sendable {
    case encodingFailed
    case invalidSignatureEncoding
    case invalidCoordinatorKey
    case signatureInvalid
    case expired
    case notYetValid
    case memberNotFound(nodeId: String)
}

public enum ClusterRoster {
    /// Deterministic JSON for the signed region. Uses `.sortedKeys` +
    /// `.iso8601` to match `AttestationBuilder`'s scheme, so a Go coordinator
    /// signing with `encoding/json` (sorted map keys) produces identical bytes.
    public static func canonicalBytes(_ body: ClusterRosterBody) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        do {
            return try encoder.encode(body)
        } catch {
            throw ClusterRosterError.encodingFailed
        }
    }

    /// Verify a roster's coordinator signature and time validity.
    ///
    /// - Parameters:
    ///   - roster: the signed roster to check.
    ///   - coordinatorPublicKeyBase64: base64 raw P-256 (64B) coordinator key,
    ///     pinned in provider config / build.
    ///   - now: current time (injected for testability).
    public static func verify(
        _ roster: SignedClusterRoster,
        coordinatorPublicKeyBase64: String,
        now: Date
    ) throws {
        guard let sigData = Data(base64Encoded: roster.signature) else {
            throw ClusterRosterError.invalidSignatureEncoding
        }
        guard let coordKey = Data(base64Encoded: coordinatorPublicKeyBase64),
              coordKey.count == 64 || coordKey.count == 65 else {
            throw ClusterRosterError.invalidCoordinatorKey
        }

        let bytes = try canonicalBytes(roster.body)
        guard SecureEnclaveIdentity.verify(signature: sigData, for: bytes, publicKey: coordKey) else {
            throw ClusterRosterError.signatureInvalid
        }

        if now < roster.body.issuedAt {
            throw ClusterRosterError.notYetValid
        }
        if now >= roster.body.expiresAt {
            throw ClusterRosterError.expired
        }
    }

    /// Look up a member by node id within a (already-verified) roster body.
    public static func member(_ body: ClusterRosterBody, nodeId: String) throws -> ClusterMember {
        guard let m = body.members.first(where: { $0.nodeId == nodeId }) else {
            throw ClusterRosterError.memberNotFound(nodeId: nodeId)
        }
        return m
    }

    /// The cluster's surfaced trust = the weakest member.
    ///
    /// - Parameter strongestFirst: trust levels ranked strongest → weakest
    ///   (e.g. `["hardware", "self_signed", "none"]`). The weakest present
    ///   member trust is returned; an unranked level is treated as weakest.
    public static func minTrustLevel(_ body: ClusterRosterBody, strongestFirst order: [String]) -> String? {
        func rank(_ level: String) -> Int { order.firstIndex(of: level) ?? Int.max }
        // Weakest = the largest rank index (furthest from "strongest").
        return body.members.map(\.trustLevel).max { rank($0) < rank($1) }
    }
}
