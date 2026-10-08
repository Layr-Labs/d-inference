import Foundation
import DarkbloomClusterProtocol

public enum ClusterOwnerStateError: Error, Equatable, Sendable {
    case invalid(String)
}

/// Routing on an already authenticated connection. These fields do not authenticate it.
public struct ClusterOwnerRoute: Equatable, Sendable {
    public let clusterID: String
    public let ownerPeerID: String
    public let ownerIncarnation: UUID
    public let leaseID: UUID
    public let membershipEpoch: UUID
}

/// One configured local rank and one native-child lifetime, independent of SSH/TLS.
public struct ClusterOwnerBinding: Sendable {
    public let route: ClusterOwnerRoute
    public let identity: ClusterWorkerIdentity
    public let profile: ClusterWorkerProfile
    public let rank: Int
    public let executionPlanSHA256: String

    public init(clusterID: String, ownerIncarnation: UUID, leaseID: UUID,
                identity: ClusterWorkerIdentity, profile: ClusterWorkerProfile,
                rank: Int, executionPlanSHA256: String) throws {
        guard (1...128).contains(clusterID.utf8.count),
              clusterID.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw ClusterOwnerStateError.invalid("Invalid configured cluster label")
        }
        // Reuse the actual worker's identity/profile/plan validation.
        _ = try ClusterWorkerSession(identity: identity, rank: rank, profile: profile,
                                     executionPlanSHA256: executionPlanSHA256)
        self.identity = identity; self.profile = profile; self.rank = rank
        self.executionPlanSHA256 = executionPlanSHA256
        route = .init(clusterID: clusterID, ownerPeerID: identity.peers[rank].id,
                      ownerIncarnation: ownerIncarnation, leaseID: leaseID,
                      membershipEpoch: identity.membershipEpoch)
    }

    func matches(_ ready: ClusterWorkerReady) -> Bool {
        ready.identity == identity && ready.profile == profile && ready.rank == rank
            && ready.executionPlanSHA256 == executionPlanSHA256
            && (1...ClusterWorkerLimits.capacityBytes).contains(ready.requestCapacityBytes)
    }
}

/// Control intent only. The existing worker codec/session remains the authority
/// for actual prompt geometry, token decisions, native admission and generation.
public enum ClusterOwnerControl: Sendable {
    case reserve(requestID: UUID, capacityLimitBytes: Int, remainingNanoseconds: UInt64)
    case start(requestID: UUID)
    case cancel(requestID: UUID, reason: ClusterWorkerCancellationReason)
    case release(requestID: UUID)
    case shutdown
}

public struct ClusterOwnerControlFrame: Sendable {
    public let route: ClusterOwnerRoute
    public let sequence: UInt64
    public let control: ClusterOwnerControl
    public init(route: ClusterOwnerRoute, sequence: UInt64, control: ClusterOwnerControl) {
        self.route = route; self.sequence = sequence; self.control = control
    }
}

/// The adapter must perform this operation; returning it is not evidence of completion.
public enum ClusterOwnerAction: Equatable, Sendable {
    case forwardReserve(UUID, localDeadlineUptimeNanoseconds: UInt64)
    case forwardStart(UUID)
    case forwardCancel(UUID, ClusterWorkerCancellationReason)
    case releaseRequestResources(UUID)
    case sendShutdown
}
