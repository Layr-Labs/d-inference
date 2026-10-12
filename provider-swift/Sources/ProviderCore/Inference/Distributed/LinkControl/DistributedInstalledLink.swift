import Darwin
import Foundation
import DarkbloomClusterProtocol
import DarkbloomClusterRemote
import DarkbloomClusterSecurity
#if canImport(Logging)
import Logging

/// Link edge refusals and connections on the member path (no payload).
let clusterLinkMemberLog = Logger(label: "darkbloom.cluster-link")
#else
/// The plain-swiftc check runners build this file without swift-log: the
/// same calls, discarded.
struct ClusterLinkMemberLogStandIn: Sendable {
    func info(_ message: @autoclosure () -> String) {}
    func warning(_ message: @autoclosure () -> String) {}
}
let clusterLinkMemberLog = ClusterLinkMemberLogStandIn()
#endif

/// The follower rank over the link control channel (PROD-PLAN S08), for a
/// saved setup with a `linkControl` attachment and no SSH trust.
///
/// The leader's session hosts the listener inside the provider process (the
/// signed binary the owner approves once) on its link interface, and opens
/// rank 1 as a `ClusterLinkWorkerEndpoint`. The follower member
/// (`darkbloom cluster link-follower`) dials the leader's link address and
/// serves each session through its own local owner, enforcing the rank lease
/// the leader renews on the link.
enum DistributedInstalledLinkEdge {
    /// The edge of this setup: its key from the private secret file, bound
    /// to the setup's link epoch and edge.
    static func edge(configuration: ClusterConfiguration, peerAddress: ClusterLinkIPv4Address?) throws -> ClusterLinkControlEdge {
        guard let link = configuration.linkControl else {
            throw ClusterConfigurationError.invalid("This setup does not reach its follower over the link control channel")
        }
        let secret = try readSecret(URL(fileURLWithPath: link.secretFile))
        let key = try ClusterLinkControlKey.qualification(secret: secret, epoch: link.linkEpochUUID, edgeID: link.edgeUUID)
        return try ClusterLinkControlEdge(edgeID: link.edgeUUID, epoch: link.linkEpochUUID, key: key, peerAddress: peerAddress)
    }

    /// One hex line from a private regular file of this user; never echoed.
    static func readSecret(_ url: URL) throws -> Data {
        try ClusterConfigurationFiles.credentialMetadata(url, privateMode: true)
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ClusterConfigurationError.invalid("Cannot open the link control secret") }
        defer { close(fd) }
        do { return try ClusterLinkControlKey.readQualificationSecret(fromDescriptor: fd) }
        catch { throw ClusterConfigurationError.invalid("The link control secret is not one hex line of 32 to 1024 bytes") }
    }

    /// The interface that carries IPv4 for this Mac's link device and reaches
    /// the leader's link address: the port, or the bridge holding that subnet
    /// when the port has only a link-local alias (today's second Mac).
    static func interface(device: String, reaching leader: ClusterLinkIPv4Address) throws -> String {
        guard device.hasPrefix("rdma_"), let name = ClusterLinkSystemInterfaceInspector.carrierInterface(
            forPort: String(device.dropFirst("rdma_".count)), reaching: leader) else {
            throw ClusterConfigurationError.invalid("No interface carries IPv4 for the link device \(device)")
        }
        return name
    }

    static func leaderAddress(_ configuration: ClusterConfiguration) throws -> ClusterLinkIPv4Address {
        guard let address = ClusterLinkIPv4Address(configuration.coordinator.address) else {
            throw ClusterConfigurationError.invalid("The leader's link address is not IPv4")
        }
        return address
    }
}

/// The leader's side, owned by one installed session.
final class DistributedInstalledLinkLeader: @unchecked Sendable {
    let router = ClusterLinkWorkerRouter()
    private let host = ClusterLinkControlHost()
    let peer: ClusterLinkControlPeer

    init(configuration: ClusterConfiguration) throws {
        guard configuration.role == .leader, let link = configuration.linkControl else {
            throw ClusterConfigurationError.invalid("Only a link control leader hosts the follower's edge")
        }
        let edge = try DistributedInstalledLinkEdge.edge(configuration: configuration, peerAddress: nil)
        let local = configuration.peers[configuration.localRank]
        let router = self.router
        let address = try DistributedInstalledLinkEdge.leaderAddress(configuration)
        let listener = try host.start(.init(interface: try DistributedInstalledLinkEdge.interface(device: local.jacclDevice,
            reaching: address), localAddress: address, port: UInt16(link.port),
            policy: .thunderboltOnly, edges: [edge])) { event, _ in
            switch event {
            case .connected: clusterLinkMemberLog.info("link edge: follower connected")
            case .disconnected(_, let reason): clusterLinkMemberLog.info("link edge: follower disconnected (\(reason))")
            case .refused(_, let reason): clusterLinkMemberLog.warning("link edge: refused a connection (\(reason))")
            default: break
            }
            router.handle(event)
        }
        guard let peer = listener.peer(for: edge.edgeID) else {
            host.stop(); throw ClusterConfigurationError.invalid("The link control listener has no peer for its edge")
        }
        self.peer = peer
    }

    /// The follower member must be connected before its rank is opened; a
    /// session never waits on a member that is not there.
    func waitForFollower(until deadline: UInt64) throws {
        let now = DispatchTime.now().uptimeNanoseconds
        let seconds = deadline > now ? Double(deadline - now) / 1e9 : 0
        guard peer.waitUntilConnected(timeout: .milliseconds(Int(seconds * 1000))) else {
            throw ClusterConfigurationError.invalid("The follower member did not connect over the link control channel (is `darkbloom cluster link-follower` running on the other Mac?)")
        }
    }

    func endpoint(plan: DistributedInstalledPlan, identity: ClusterWorkerIdentity, rank: Int, lifetime: UInt64,
                  relay: (any ClusterOwnerBootstrapExchange)?) throws -> ClusterLinkWorkerEndpoint {
        try ClusterLinkWorkerEndpoint(transport: ClusterLinkPeerWorkerTransport(peer: peer), clusterID: plan.configuration.clusterID,
            expectedIdentity: identity, profile: plan.capability.profile, rank: rank, executionPlanSHA256: plan.partition.planSHA256,
            lifetimeDeadlineUptimeNanoseconds: lifetime, bootstrapRelay: relay, router: router)
    }

    /// After every endpoint's proofs: delivers what is queued, then closes.
    func stop() {
        _ = try? peer.waitUntilAcknowledged(timeout: .seconds(2))
        host.stop()
    }
}

/// The follower member: `darkbloom cluster link-follower`.
public enum DistributedInstalledLinkFollower {
    public enum Event: Sendable {
        case ready, connected, disconnected, opened, refused(String), fenced(String), cleanup, released(Bool)
        /// The link refused or failed a dial (reported once per change, names only).
        case linkRefused(String)
    }

    /// Serves sessions until `stop` is signalled, then fences what runs and
    /// waits (bounded) for its owner to release. Returns whether it ended idle.
    public static func serve(reference: ClusterConfigurationReference, stop: DispatchSemaphore,
                             events: @escaping @Sendable (Event) -> Void) throws -> Bool {
        let prepared = try DistributedInstalledPreparation.prepare(reference: reference,
            paths: ClusterUserPaths(), deadline: DispatchTime.now().uptimeNanoseconds + 15_000_000_000)
        let plan = prepared.plan
        guard plan.configuration.role == .follower, plan.configuration.linkControl != nil else {
            throw ClusterConfigurationError.invalid("Only a follower setup with a link control attachment serves over the link")
        }
        // The rank this Mac serves must be granted on this Mac's own class: a
        // follower whose chip the model's grant does not list says so when it
        // starts, instead of at each open (its owner checks again before it serves).
        try plan.requireLocalRankGranted(numericsClass: ClusterNumericsClass.local())
        let leader = try DistributedInstalledLinkEdge.leaderAddress(plan.configuration)
        let edge = try DistributedInstalledLinkEdge.edge(configuration: plan.configuration, peerAddress: leader)
        final class Box: @unchecked Sendable {
            let lock = NSLock(); var server: ClusterLinkWorkerServer?; weak var client: ClusterLinkControlClient?
            func handle(_ event: ClusterLinkControlEvent) { lock.withLock { server }?.handle(event) }
            var connectFailure: String? { lock.withLock { client }?.lastConnectFailure }
        }
        let box = Box()
        let client = try ClusterLinkControlClient(configuration: .init(
            interface: try DistributedInstalledLinkEdge.interface(device: plan.localPeer.jacclDevice, reaching: leader),
            port: UInt16(plan.configuration.linkControl!.port), policy: .thunderboltOnly, edge: edge)) { event, _ in
            switch event {
            case .connected: events(.connected)
            case .disconnected: events(.disconnected)
            case .refused(_, let reason):
                let detail = reason == .connectFailed ? box.connectFailure.map { " (\($0))" } ?? "" : ""
                events(.linkRefused("\(reason)" + detail))
            default: break
            }
            box.handle(event)
        }
        box.lock.withLock { box.client = client }
        let owner = try ClusterLocalOwnerConfiguration(installedDarkbloom: URL(fileURLWithPath: plan.localPeer.ownerExecutable))
        let server = ClusterLinkWorkerServer(transport: ClusterLinkPeerWorkerTransport(peer: client.peer),
            clusterID: plan.configuration.clusterID, rank: plan.configuration.localRank,
            bootstrapProfile: plan.bootstrap.ownerProfile, admit: { open in
                guard open.executionPlanSHA256 == plan.partition.planSHA256 else {
                    throw ClusterConfigurationError.invalid("The leader opened another plan")
                }
                let identity = plan.identity(epoch: open.membershipEpoch)
                return .init(identity: identity, profile: plan.capability.profile) { relay in
                    try ClusterRemoteWorkerEndpoint(localOwner: owner, clusterID: plan.configuration.clusterID,
                        expectedIdentity: identity, profile: plan.capability.profile, rank: open.rank,
                        executionPlanSHA256: plan.partition.planSHA256,
                        lifetimeDeadlineUptimeNanoseconds: open.lifetimeDeadlineUptimeNanoseconds, bootstrapRelay: relay)
                }
            }, report: { report in
                switch report {
                case .opened: events(.opened)
                case .refused(let reason): events(.refused(reason))
                case .fenced(_, let reason): events(.fenced(reason))
                case .cleanup: events(.cleanup)
                case .released(_, let cleanly): events(.released(cleanly))
                }
            })
        box.lock.withLock { box.server = server }
        client.start()
        events(.ready)
        stop.wait()
        server.stop()
        let idle = server.waitUntilIdle(deadline: DispatchTime.now().uptimeNanoseconds
            + ClusterLinkWorkerEndpoint.retirementAllowanceNanoseconds)
        _ = try? client.peer.waitUntilAcknowledged(timeout: .seconds(2))
        client.stop()
        return idle
    }
}
