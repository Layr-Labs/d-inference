import Darwin
import Foundation
import DarkbloomClusterProtocol
import DarkbloomClusterProcess
import DarkbloomClusterSecurity
@testable import DarkbloomClusterRemote

// The follower member of the two-process link check: dials the leader over
// loopback, serves its sessions by launching the stand-in owner for rank 1,
// prints each report as one line, and ends when standard input closes.
//
//   follower PORT LINK-EPOCH EDGE OWNER WORKER DIRECTORY PROFILE BEHAVIOR
//
// PROFILE is none, mesh2 or prelude (this member's own selection). The edge
// secret is the first line of standard input, never an argument.

private final class ServerBox: @unchecked Sendable {
    let lock = NSLock()
    var server: ClusterLinkWorkerServer?
    func handle(_ event: ClusterLinkControlEvent) { lock.withLock { server }?.handle(event) }
}

@main struct LinkWorkerFollower {
    static func main() throws {
        let a = CommandLine.arguments
        guard a.count == 9, let port = UInt16(a[1]), let linkEpoch = UUID(uuidString: a[2]), let edgeID = UUID(uuidString: a[3]) else { exit(64) }
        let owner = URL(fileURLWithPath: a[4]), worker = a[5], directory = a[6], behavior = a[8]
        let profile: ClusterOwnerBootstrapProfile?
        switch a[7] { case "none": profile = nil; case "mesh2": profile = .mesh2; case "prelude": profile = .nativeKeyPreludeMesh2; default: exit(64) }
        alarm(120)
        let secret = try ClusterLinkControlKey.readQualificationSecret(fromDescriptor: STDIN_FILENO)
        let key = try ClusterLinkControlKey.qualification(secret: secret, epoch: linkEpoch, edgeID: edgeID)
        let loopback = ClusterLinkIPv4Address("127.0.0.1")!
        let edge = try ClusterLinkControlEdge(edgeID: edgeID, epoch: linkEpoch, key: key, peerAddress: loopback)
        let box = ServerBox()
        let client = try ClusterLinkControlClient(configuration: .init(interface: "lo0", localAddress: loopback, port: port,
            policy: .loopbackForTests, edge: edge)) { event, _ in box.handle(event) }
        let output = FileHandle.standardOutput, outputLock = NSLock()
        let server = ClusterLinkWorkerServer(transport: ClusterLinkPeerWorkerTransport(peer: client.peer), clusterID: "cpu-test",
            rank: 1, bootstrapProfile: profile, admit: { open in
                // This member's own configuration: the fixture identity at the
                // epoch the leader opened, and its stand-in owner for rank 1.
                guard open.membershipEpoch == fixtureIdentity.membershipEpoch, open.executionPlanSHA256 == fixturePlan else {
                    throw ClusterOwnerStateError.invalid("Open names another membership or plan")
                }
                return .init(identity: fixtureIdentity, profile: fixtureProfile) { relay in
                    try ClusterRemoteWorkerEndpoint(transport: .init(executable: owner, arguments: [worker, directory, "1", behavior], environment: [:]),
                        clusterID: "cpu-test", expectedIdentity: fixtureIdentity, profile: fixtureProfile, rank: 1,
                        executionPlanSHA256: fixturePlan, lifetimeDeadlineUptimeNanoseconds: open.lifetimeDeadlineUptimeNanoseconds,
                        bootstrapRelay: relay)
                }
            }, report: { report in
                let line: String
                switch report {
                case .opened: line = "opened"
                case .refused(let reason): line = "refused \(reason)"
                case .fenced(_, let reason): line = "fenced \(reason)"
                case .cleanup: line = "cleanup"
                case .released(_, let cleanly): line = "released \(cleanly)"
                }
                outputLock.withLock { output.write(Data((line + "\n").utf8)) }
            })
        box.lock.withLock { box.server = server }
        client.start()
        // Until the leader's harness closes standard input.
        var byte: UInt8 = 0
        while true { let n = Darwin.read(STDIN_FILENO, &byte, 1); if n == 0 || (n < 0 && errno != EINTR) { break } }
        server.stop()
        let idle = server.waitUntilIdle(deadline: DispatchTime.now().uptimeNanoseconds + 40_000_000_000)
        _ = try? client.peer.waitUntilAcknowledged(timeout: .seconds(2))
        client.stop()
        outputLock.withLock { output.write(Data("exit idle=\(idle) served=\(server.served)\n".utf8)) }
        exit(idle ? 0 : 3)
    }
}
