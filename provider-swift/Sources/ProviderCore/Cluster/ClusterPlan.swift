/// ClusterPlan -- resolves `[cluster]` config into the concrete topology the
/// provider needs to join a pipeline: this node's rank, its ring neighbors, and
/// the MLX ring transport environment (host list + rank), exo-style.
///
/// Pure resolution + validation (no IO, no MLX): unit-testable on one machine.
/// The provider start path builds a `ClusterPlan`, uses `mlxRingEnvironment()`
/// to configure the transport before `MLXDistributedGroup.initialize`, and feeds
/// `neighbors` into the handshake + `DistributedInferenceEngine`.

import Foundation

public enum ClusterPlanError: Error, Equatable, Sendable {
    case disabled
    case missingClusterId
    case emptyMembers
    case selfNotInMembers(nodeId: String)
    case duplicateNodeId(String)
    case singleMember
    case unsupportedBackend(String)
}

public struct ClusterPlan: Equatable, Sendable {
    public let clusterId: String
    public let nodeId: String
    public let rank: Int
    public let worldSize: Int
    public let backend: MLXDistributedBackend
    /// Members in ring order (rank == index).
    public let members: [ClusterMemberSettings]

    /// Previous rank in the ring; nil at the head of a non-wrapping pipeline.
    public var prevRank: Int? { rank == 0 ? nil : rank - 1 }
    /// Next rank in the ring; nil at the tail.
    public var nextRank: Int? { rank == worldSize - 1 ? nil : rank + 1 }

    public var isHead: Bool { rank == 0 }
    public var isTail: Bool { rank == worldSize - 1 }

    /// Build and validate a plan from `[cluster]` settings.
    public static func resolve(_ s: ClusterSettings) throws -> ClusterPlan {
        guard s.enabled else { throw ClusterPlanError.disabled }
        guard !s.clusterId.isEmpty else { throw ClusterPlanError.missingClusterId }
        guard !s.members.isEmpty else { throw ClusterPlanError.emptyMembers }
        guard s.members.count > 1 else { throw ClusterPlanError.singleMember }

        // No duplicate node ids (rank must be unambiguous).
        var seen = Set<String>()
        for m in s.members {
            if !seen.insert(m.nodeId).inserted {
                throw ClusterPlanError.duplicateNodeId(m.nodeId)
            }
        }

        guard let rank = s.members.firstIndex(where: { $0.nodeId == s.nodeId }) else {
            throw ClusterPlanError.selfNotInMembers(nodeId: s.nodeId)
        }
        guard let backend = MLXDistributedBackend(rawValue: s.backend) else {
            throw ClusterPlanError.unsupportedBackend(s.backend)
        }

        return ClusterPlan(
            clusterId: s.clusterId,
            nodeId: s.nodeId,
            rank: rank,
            worldSize: s.members.count,
            backend: backend,
            members: s.members)
    }

    /// Node ids of this node's ring neighbors (for the pairwise handshake).
    public func neighborNodeIds() -> (prev: String?, next: String?) {
        let prev = prevRank.map { members[$0].nodeId }
        let next = nextRank.map { members[$0].nodeId }
        return (prev, next)
    }

    /// Environment variables that configure MLX's ring transport, matching
    /// exo's approach (a host list keyed by position + this node's rank). The
    /// provider sets these before `MLXDistributedGroup.initialize(.ring)`.
    ///
    /// `MLX_HOSTLIST` is a comma-separated, rank-ordered list of member
    /// addresses; `MLX_RANK` is this node's index. (exo writes a hostfile and
    /// sets `MLX_HOSTFILE`/`MLX_RANK`; we expose the addresses here and let the
    /// start path materialize whatever the linked MLX build expects.)
    public func mlxRingEnvironment() -> [String: String] {
        [
            "MLX_HOSTLIST": members.map(\.address).joined(separator: ","),
            "MLX_RANK": String(rank),
            "MLX_WORLD_SIZE": String(worldSize),
        ]
    }

    /// Layer plan for this cluster given the model's layer count and each
    /// member's available memory (ring order must match `members`).
    /// Convenience that forwards to `LayerPartition`.
    public func layerPlan(totalLayers: Int, memoryBytesByNodeId: [String: UInt64]) throws -> [LayerInterval] {
        let weights = try members.map { m -> LayerPartition.NodeWeight in
            guard let w = memoryBytesByNodeId[m.nodeId] else {
                throw ClusterPlanError.selfNotInMembers(nodeId: m.nodeId)
            }
            return LayerPartition.NodeWeight(nodeId: m.nodeId, weightBytes: w)
        }
        return try LayerPartition.partition(totalLayers: totalLayers, nodes: weights)
    }
}
