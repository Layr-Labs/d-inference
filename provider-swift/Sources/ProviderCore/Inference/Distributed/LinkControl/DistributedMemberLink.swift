import Foundation
import DarkbloomClusterProtocol
import DarkbloomClusterRemote
import DarkbloomClusterSecurity

// The link control channel between the two members of a coordinator-formed
// pair (S10 over S08).
//
// Each member launches its own owner for the start the coordinator committed
// to it; the native key prelude goes through each member's coordinator
// session. What the link carries is the rest of rank 1: the leader member
// hosts the listener inside its provider process and opens the follower's
// rank as a `ClusterLinkWorkerEndpoint`; the follower member dials it and,
// for the leader's session of a start it holds, serves the owner its own
// session launched (worker commands and events, the mesh rounds of its
// combined bootstrap, the rank lease, cleanup and release proofs). The
// follower never launches anything for the link: an open names an epoch, and
// only a start this member's session committed and launched is served.

extension DistributedInstalledLinkLeader {
    /// Rank 1 of a committed start, reached over the link. Its mesh rounds
    /// meet rank 0's in `relay`.
    func memberEndpoint(start: NativePairMemberServingStart, clusterID: String,
                        relay: ClusterOwnerBootstrapRelay?) throws -> ClusterLinkWorkerEndpoint {
        try ClusterLinkWorkerEndpoint(transport: ClusterLinkPeerWorkerTransport(peer: peer), clusterID: clusterID,
            expectedIdentity: start.identity, profile: start.profile, rank: 1, executionPlanSHA256: start.executionPlanSHA256,
            lifetimeDeadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + ClusterWorkerLease.maximumNanoseconds,
            bootstrapRelay: relay, router: router)
    }
}

/// The follower member's side: dials the leader member's link listener and
/// serves its committed starts to the leader's pair. It is the follower
/// session's serving host: a start it is handed waits for the leader's open
/// of the same epoch; the session's stop fences what the leader opened.
public final class DistributedMemberLinkFollower: NativePairMemberServingHost, @unchecked Sendable {
    public enum Event: Sendable { case connected, disconnected, opened, refused(String), fenced(String), cleanup, released(Bool) }
    /// How long an open waits for this member's own session to hand over its start.
    static let startArrivalNanoseconds: UInt64 = 10_000_000_000

    private let client: ClusterLinkControlClient
    private let box = ServerBox()
    /// This member's status, mirrored to the leader over the edge (S24).
    private let reporter: ClusterFollowerStatusReporter
    private let linkEpoch: UUID
    private let rank: UInt16
    private let lock = NSLock()
    private var pending: [UUID: NativePairMemberServingStart] = [:]
    private var servedEpoch: UUID?
    private var stopped = false

    private final class ServerBox: @unchecked Sendable {
        let lock = NSLock(); var server: ClusterLinkWorkerServer?
        func handle(_ event: ClusterLinkControlEvent) { lock.withLock { server }?.handle(event) }
        var value: ClusterLinkWorkerServer? { lock.withLock { server } }
    }

    init(configuration: ClusterConfiguration, events: @escaping @Sendable (Event) -> Void = { _ in }) throws {
        guard configuration.role == .follower, configuration.nativeMember != nil, let link = configuration.linkControl else {
            throw ClusterConfigurationError.invalid("Only a follower member saved for coordinator pairing over the link serves its rank there")
        }
        let leader = try DistributedInstalledLinkEdge.leaderAddress(configuration)
        let edge = try DistributedInstalledLinkEdge.edge(configuration: configuration, peerAddress: leader)
        let box = self.box
        let reporter = ClusterFollowerStatusReporter(observability: .current(), modelID: configuration.publicModelID)
        self.reporter = reporter; linkEpoch = link.linkEpochUUID; rank = UInt16(configuration.localRank)
        client = try ClusterLinkControlClient(configuration: .init(
            interface: try DistributedInstalledLinkEdge.interface(device: configuration.peers[configuration.localRank].jacclDevice,
                reaching: leader),
            port: UInt16(link.port), policy: .thunderboltOnly, edge: edge)) { event, _ in
            switch event {
            case .connected: events(.connected); reporter.note(.idle)
            case .disconnected: events(.disconnected)
            case .refused(_, let reason): events(.refused("link edge: \(reason)"))
            default: break
            }
            box.handle(event)
        }
        let server = ClusterLinkWorkerServer(transport: ClusterLinkPeerWorkerTransport(peer: client.peer),
            clusterID: configuration.clusterID, rank: configuration.localRank, bootstrapProfile: .mesh2,
            linkLimits: edge.limits, admit: { [weak self] open in
                guard let self else { throw ClusterConfigurationError.invalid("The follower member is stopping") }
                return try self.admit(open)
            }, report: { report in
                switch report {
                case .opened: events(.opened); reporter.note(.serving, "serving the leader's session")
                case .refused(let reason):
                    events(.refused(reason)); reporter.note(.idle, "refused a session: \(reason)")
                    reporter.recordIncident(.memberStartFailed, error: reason)
                case .fenced(_, let reason):
                    events(.fenced(reason))
                    // The leader was asked to stop: a planned end, not a lost peer.
                    if ClusterSessionStopCause.isRequestedStop(fenceReason: reason) {
                        reporter.note(.idle, "the leader stopped the session")
                    } else {
                        reporter.note(.failed, "session fenced: \(reason)")
                        reporter.recordIncident(.peerLost, error: "the leader's session was fenced: \(reason)")
                    }
                case .cleanup: events(.cleanup)
                case .released(_, let cleanly):
                    events(.released(cleanly)); reporter.note(.idle, cleanly ? "released cleanly" : "released without its owner's proof")
                    if !cleanly { reporter.recordIncident(.cleanupUnresolved, error: "the session was released without its owner's proof; ownership cannot be resolved yet", severity: .warn) }
                }
            })
        box.lock.withLock { box.server = server }
    }

    func start() {
        client.start()
        reporter.start(peer: client.peer, epoch: linkEpoch, rank: rank)
    }

    /// Fences what runs and refuses new opens, waits (bounded) for the owner
    /// the leader was served to release, then closes the edge.
    func stop() {
        let server = lock.withLock { () -> ClusterLinkWorkerServer? in stopped = true; pending.removeAll(); return box.value }
        reporter.stop()
        server?.stop()
        _ = server?.waitUntilIdle(deadline: DispatchTime.now().uptimeNanoseconds + ClusterLinkWorkerEndpoint.retirementAllowanceNanoseconds)
        _ = try? client.peer.waitUntilAcknowledged(timeout: .seconds(2))
        client.stop()
    }

    public func serveCommittedStart(_ start: NativePairMemberServingStart) async throws {
        guard start.rank == 1, start.mesh != nil, start.endpoint is ClusterRemoteWorkerEndpoint else {
            throw ClusterPairSlotError.notServing("the follower serves only its own committed owner under the combined profile")
        }
        try lock.withLock {
            guard !stopped, pending[start.membershipEpoch] == nil else {
                throw ClusterPairSlotError.notServing("the follower member is stopping or already holds this start")
            }
            pending[start.membershipEpoch] = start
        }
    }

    public func stopServingCommittedStart(epoch: UUID) async {
        let fence = lock.withLock { () -> Bool in
            pending[epoch] = nil
            guard servedEpoch == epoch else { return false }
            servedEpoch = nil; return true
        }
        // Fences the leader's session of this start: its owner's cleanup
        // follows and the session waits for the release before its receipt.
        if fence { box.value?.leaderLost() }
    }

    /// The leader's open of a start this member holds: the epoch, rank and
    /// plan must be the session's own. The "launch" hands over the owner the
    /// session already launched, and attaches the link's mesh proxy to its
    /// bootstrap.
    private func admit(_ open: ClusterLinkWorkerOpen) throws -> ClusterLinkWorkerAdmission {
        // Both members are told to start at once; the leader's open can
        // arrive while this member's session is still launching its owner.
        let waitUntil = DispatchTime.now().uptimeNanoseconds + Self.startArrivalNanoseconds
        while DispatchTime.now().uptimeNanoseconds < waitUntil,
              lock.withLock({ !stopped && pending[open.membershipEpoch] == nil }) {
            Thread.sleep(forTimeInterval: 0.02)
        }
        let start = try lock.withLock { () -> NativePairMemberServingStart in
            guard !stopped, let start = pending[open.membershipEpoch], open.rank == start.rank,
                  open.executionPlanSHA256 == start.executionPlanSHA256, open.bootstrapProfile == .mesh2,
                  open.nativeStart == nil else {
                throw ClusterConfigurationError.invalid("The leader opened a session this member holds no committed start for")
            }
            servedEpoch = open.membershipEpoch
            return start
        }
        guard let mesh = start.mesh, let endpoint = start.endpoint as? ClusterRemoteWorkerEndpoint else {
            throw ClusterConfigurationError.invalid("The committed start has no owner to serve")
        }
        return .init(identity: start.identity, profile: start.profile) { proxy in
            guard let proxy else { throw ClusterConfigurationError.invalid("The leader's session carries no mesh relay") }
            try mesh.attachMesh(proxy)
            return endpoint
        }
    }
}
