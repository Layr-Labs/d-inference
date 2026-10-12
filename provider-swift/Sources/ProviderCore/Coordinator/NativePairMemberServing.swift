import Foundation
import DarkbloomClusterProcess
import DarkbloomClusterProtocol
import DarkbloomClusterRemote
import DarkbloomClusterSecurity

// A member serving a start the coordinator committed (S10).
//
// The member session prepares, commits and launches its owner exactly as
// before, and still sends its release receipt only once its owner proved
// native cleanup and released its device. What changes is the time between:
// a session with a serving host hands its launched owner endpoint to the host,
// which on the leader builds the pair from it and the follower's endpoint and
// publishes the pair slot (`ProviderLoop+ClusterPairServing`), and on the
// follower offers it to the leader over the link (S08). The session keeps the
// grant lease; whatever ends it (lease, cancel, a lost rank, the member
// stopping) first retires what the host published, then waits for the owner's
// release, then sends the receipt.

/// One committed start a member serves.
public struct NativePairMemberServingStart: @unchecked Sendable {
    /// The coordinator's committed start for this member.
    public let start: ClusterNativeAuthorizationStart
    /// The worker identity of this session: the installed one under the
    /// start's membership epoch.
    public let identity: ClusterWorkerIdentity
    public let profile: ClusterWorkerProfile
    public let executionPlanSHA256: String
    /// This Mac's owner endpoint the session launched for the start.
    public let endpoint: any ClusterWorkerEndpoint
    /// The current grant's end on this Mac's uptime clock when serving began.
    public let leaseDeadlineUptimeNanoseconds: UInt64
    /// The owner's combined bootstrap, whose mesh rounds wait for the serving
    /// host: the leader attaches the pair's mesh relay, the follower the link
    /// proxy to it. Nil for the prelude-only profile.
    public var mesh: ClusterOwnerCommittedBootstrap? = nil

    public var rank: Int { start.rank }
    public var membershipEpoch: UUID { start.common.epoch }
}

/// What a member does with a committed start once its owner launched.
public protocol NativePairMemberServingHost: AnyObject, Sendable {
    /// Serve the start. Returns once serving began (on the leader: the pair
    /// slot is published); throws when it cannot, and the session then cancels
    /// and releases. Never takes ownership of the endpoint's cleanup: the
    /// session keeps that obligation.
    func serveCommittedStart(_ start: NativePairMemberServingStart) async throws
    /// The session is ending: retire what `serveCommittedStart` published for
    /// this epoch (or stop a serve still under way) and return once it is
    /// retired. Idempotent; an unknown epoch does nothing.
    func stopServingCommittedStart(epoch: UUID) async
}

/// Why a pair slot or a member serving host refused (kept beside the seam so
/// the model-free check runners that compile the link members build it).
public enum ClusterPairSlotError: Error, Sendable, Equatable {
    /// Only a cluster member serves a pair slot, one at a time, while it is
    /// connected and not stopping.
    case notServing(String)
    /// The model is not this member's registered cluster model.
    case unknownModel
    /// The owner was not ready, or its identity or profile differs.
    case ownerUnavailable
}
