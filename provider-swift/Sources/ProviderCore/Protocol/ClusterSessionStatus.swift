import Foundation

/// A cluster member's report, on every heartbeat (`cluster_session`), of the
/// coordinator-formed native session its owner currently runs and how that
/// session's data plane is protected (S16). Mirrors the coordinator's
/// `protocol.ClusterSessionStatus`. It grants nothing by itself: the
/// coordinator lets a cluster serve public requests only while every member
/// reports the cluster's current session with both properties.
///
/// Both properties are what this member's own worker observed and published
/// in its readiness: `encryptedDataPlane` when every transfer with its peer is
/// an authenticated, encrypted record under keys derived for this session
/// (rekeyed inside the record limits), `peerVerified` when it checked its
/// peer's hello against the identity it pins before deriving any key. Until
/// the worker is ready, and on a session whose data plane is not keyed, both
/// are false. A member omits the report while it runs no owner.
public struct ClusterSessionStatus: Codable, Sendable, Equatable {
    /// Lowercase hex of the session's 16-byte epoch, as its frames name it.
    public let epoch: String
    /// The session's membership generation, positive.
    public let generation: UInt64
    public let encryptedDataPlane: Bool
    public let peerVerified: Bool

    public init(epoch: String, generation: UInt64, encryptedDataPlane: Bool, peerVerified: Bool) {
        self.epoch = epoch; self.generation = generation
        self.encryptedDataPlane = encryptedDataPlane
        // A verified peer is only meaningful on an encrypted data plane.
        self.peerVerified = encryptedDataPlane && peerVerified
    }

    enum CodingKeys: String, CodingKey {
        case epoch, generation
        case encryptedDataPlane = "encrypted_data_plane"
        case peerVerified = "peer_verified"
    }

    /// Whether this names a session the way its frames do: a nonzero 16-byte
    /// epoch in lowercase hex and a positive generation.
    public var isValid: Bool {
        epoch.utf8.count == 32 && epoch.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
            && epoch.utf8.contains { $0 != 48 } && generation > 0
    }
}
