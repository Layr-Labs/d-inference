import Foundation

/// A member's saved cluster claim as it registers it: which cluster it belongs
/// to, its fixed rank there, and the coordinator runtime policy it installed.
/// Mirrors `protocol.ClusterMembership` (darkbloom-platform coordinator/protocol/execution_role.go).
/// The coordinator matches it against a second member and its own approval
/// catalog; the claim grants nothing by itself. The coordinator closes the
/// socket on a malformed value, so this type cannot hold one.
public struct ClusterMembership: Codable, Sendable, Equatable {
    /// The saved cluster label both members share.
    public let clusterID: String
    /// 0 owns requests (leader); 1 is the follower.
    public let rank: Int
    /// Lowercase hex SHA-256 of the installed canonical coordinator policy.
    public let policySHA256: String

    enum CodingKeys: String, CodingKey {
        case clusterID = "cluster_id"
        case rank
        case policySHA256 = "policy_sha256"
    }

    public init(clusterID: String, rank: Int, policySHA256: String) throws {
        guard ClusterConfigurationSyntax.label(clusterID), rank == 0 || rank == 1,
              ClusterConfigurationSyntax.hash(policySHA256) else {
            throw ClusterMemberControlError.invalidMembership
        }
        self.clusterID = clusterID
        self.rank = rank
        self.policySHA256 = policySHA256
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            clusterID: container.decode(String.self, forKey: .clusterID),
            rank: container.decode(Int.self, forKey: .rank),
            policySHA256: container.decode(String.self, forKey: .policySHA256))
    }
}
