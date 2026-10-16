import Foundation
import XCTest
import DarkbloomClusterProtocol
@testable import DarkbloomClusterRemote

/// Scheduled work held until the check runs it, in order.
private final class ManualSchedule: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [(UInt64, @Sendable () -> Void)] = []
    var schedule: ClusterLinkPeerLiveness.Schedule { { delay, work in self.lock.withLock { self.pending.append((delay, work)) } } }
    var delays: [UInt64] { lock.withLock { pending.map(\.0) } }
    func runAll() { for (_, work) in lock.withLock({ let all = pending; pending = []; return all }) { work() } }
}

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func add(_ value: String) { lock.withLock { values.append(value) } }
    var all: [String] { lock.withLock { values } }
}

private final class DiscardingTransport: ClusterLinkWorkerTransport, @unchecked Sendable {
    func send(_ bytes: Data) throws {}
}

final class ClusterLinkPeerLivenessTests: XCTestCase {
    let edge = UUID()

    func testResumeWindowIsTheEdgesOwnLinkTimingAndNeverPastTheLease() {
        var limits = ClusterLinkControlLimits()
        let redial = limits.reconnectMaximumDelay.clusterLinkNanoseconds + limits.connectTimeout.clusterLinkNanoseconds
            + limits.handshakeTimeout.clusterLinkNanoseconds
        XCTAssertEqual(ClusterLinkPeerLiveness.resumeWindowNanoseconds(after: .peerClosed, limits: limits), redial)
        for reason in [ClusterLinkControlDisconnect.peerSilent, .transportError, .writeTimeout, .protocolViolation, .authenticationFailed] {
            XCTAssertEqual(ClusterLinkPeerLiveness.resumeWindowNanoseconds(after: reason, limits: limits),
                           limits.silenceTimeout.clusterLinkNanoseconds + redial, "\(reason)")
        }
        for reason in [ClusterLinkControlDisconnect.rekey, .superseded, .localShutdown] {
            XCTAssertNil(ClusterLinkPeerLiveness.resumeWindowNanoseconds(after: reason, limits: limits), "\(reason) is planned")
        }
        // Defaults: well inside the rank lease (5 s and 10 s against 30 s).
        XCTAssertLessThan(ClusterLinkPeerLiveness.resumeWindowNanoseconds(after: .peerSilent, limits: limits)!, ClusterWorkerLease.ttlNanoseconds)
        // Slow link timing is capped by the lease: by then the follower fenced anyway.
        limits.silenceTimeout = .seconds(60); limits.connectTimeout = .seconds(40)
        XCTAssertEqual(ClusterLinkPeerLiveness.resumeWindowNanoseconds(after: .peerSilent, limits: limits), ClusterWorkerLease.ttlNanoseconds)
        XCTAssertEqual(ClusterLinkPeerLiveness.resumeWindowNanoseconds(after: .peerClosed, limits: limits), ClusterWorkerLease.ttlNanoseconds)
    }

    func testALinkThatDoesNotResumeIsOneStatedLoss() {
        let schedule = ManualSchedule(), lost = Recorder()
        let liveness = ClusterLinkPeerLiveness(schedule: schedule.schedule) { lost.add($0) }
        liveness.handle(.connected(edgeID: edge, peerIncarnation: UUID(), resumed: false, retransmitted: 0))
        liveness.handle(.disconnected(edgeID: edge, reason: .peerClosed))
        XCTAssertEqual(schedule.delays, [5_000_000_000])
        schedule.runAll()
        XCTAssertEqual(lost.all.count, 1)
        XCTAssertTrue(lost.all[0].contains("closed the link control connection"), lost.all[0])
        XCTAssertTrue(lost.all[0].contains("5.0 s"), lost.all[0])
        schedule.runAll()
        XCTAssertEqual(liveness.lossCount, 1)
    }

    func testAResumedLinkIsNoLossAndAPlannedRolloverArmsNothing() {
        let schedule = ManualSchedule(), lost = Recorder()
        let liveness = ClusterLinkPeerLiveness(schedule: schedule.schedule) { lost.add($0) }
        let incarnation = UUID()
        liveness.handle(.connected(edgeID: edge, peerIncarnation: incarnation, resumed: false, retransmitted: 0))
        liveness.handle(.disconnected(edgeID: edge, reason: .peerSilent))
        liveness.handle(.connected(edgeID: edge, peerIncarnation: incarnation, resumed: true, retransmitted: 3))
        schedule.runAll()
        XCTAssertEqual(lost.all, [])
        liveness.handle(.disconnected(edgeID: edge, reason: .rekey))
        liveness.handle(.disconnected(edgeID: edge, reason: .superseded))
        liveness.handle(.disconnected(edgeID: edge, reason: .localShutdown))
        XCTAssertEqual(schedule.delays, [])
        // A second drop after a resume is judged on its own.
        liveness.handle(.disconnected(edgeID: edge, reason: .transportError))
        liveness.handle(.disconnected(edgeID: edge, reason: .peerClosed))
        schedule.runAll()
        XCTAssertEqual(lost.all.count, 1, "only the latest disconnect's timer may fire")
        XCTAssertTrue(lost.all[0].contains("closed"), lost.all[0])
    }

    /// F3: the follower's process ended (no fence, cleanup or release can
    /// come). The router states the loss, the endpoint is invalid at once, and
    /// the waits for its proofs return now, unproven, instead of at the
    /// owner's retirement ceiling. A proof that arrives later is recorded
    /// without leaving a wait twice.
    func testALostFollowerEndsTheWaitsForProofsThatCannotArrive() throws {
        let schedule = ManualSchedule(), stated = Recorder()
        let router = ClusterLinkWorkerRouter(schedule: schedule.schedule) { stated.add($0) }
        let identity = ClusterWorkerIdentity(membershipEpoch: UUID(), modelID: "invented",
            artifactSHA256: String(repeating: "a", count: 64), configurationSHA256: String(repeating: "b", count: 64),
            peers: [.init(id: "first", buildSHA256: String(repeating: "c", count: 64)),
                    .init(id: "second", buildSHA256: String(repeating: "d", count: 64))])
        let profile = ClusterWorkerProfile(id: "invented", vocabularySize: 1000,
            maximumPromptTokens: 8, maximumOutputTokens: 4, maximumChunkTokens: 4, maximumContextTokens: 12)
        let endpoint = try ClusterLinkWorkerEndpoint(transport: DiscardingTransport(), clusterID: "fixture",
            expectedIdentity: identity, profile: profile, rank: 1, executionPlanSHA256: String(repeating: "e", count: 64),
            lifetimeDeadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 20_000_000_000, bootstrapRelay: nil,
            router: router)
        let invalidated = expectation(description: "invalidated")
        endpoint.setInvalidationHandler { invalidated.fulfill() }
        endpoint.accept(ClusterLinkWorkerWire(kind: .accepted, epoch: identity.membershipEpoch, session: endpoint.session, sequence: 0))

        router.handle(.disconnected(edgeID: edge, reason: .peerClosed))
        XCTAssertNil(endpoint.lossReason, "nothing is stated before the window")
        schedule.runAll()
        wait(for: [invalidated], timeout: 2)
        XCTAssertEqual(stated.all.count, 1)
        XCTAssertEqual(endpoint.lossReason, stated.all.first)
        XCTAssertNil(endpoint.readiness)

        let native = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { endpoint.waitForNativeCleanup(); native.signal() }
        XCTAssertEqual(native.wait(timeout: .now() + 2), .success, "the cleanup wait must not outlive a lost follower")
        let begin = DispatchTime.now().uptimeNanoseconds
        XCTAssertFalse(endpoint.waitForOwnerReleased(deadline: begin + 60_000_000_000), "a lost follower's release is never claimed")
        XCTAssertLessThan(DispatchTime.now().uptimeNanoseconds - begin, 2_000_000_000)
        XCTAssertFalse(endpoint.nativeCleanupObserved)
        XCTAssertFalse(endpoint.ownerDeviceLeaseReleasedObserved)

        // The link came back and the follower's proofs arrive late: recorded,
        // and no wait group is left twice (that would trap).
        endpoint.accept(ClusterLinkWorkerWire(kind: .cleanup, epoch: identity.membershipEpoch, session: endpoint.session, sequence: 1))
        var released = ClusterLinkWorkerWire(kind: .released, epoch: identity.membershipEpoch, session: endpoint.session, sequence: 2)
        released.releasedCleanly = true
        endpoint.accept(released)
        XCTAssertTrue(endpoint.nativeCleanupObserved)
        XCTAssertTrue(endpoint.ownerDeviceLeaseReleasedObserved)
        // A loss stated again (another endpoint's restart) changes nothing.
        router.followerLost(reason: "again")
        XCTAssertEqual(endpoint.lossReason, stated.all.first)
    }
}
