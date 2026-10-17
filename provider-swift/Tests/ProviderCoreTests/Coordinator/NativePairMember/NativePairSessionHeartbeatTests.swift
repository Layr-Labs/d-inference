import Foundation
import Testing
@testable import ProviderCore

/// The coordinator lets a cluster serve public requests only once every
/// member's heartbeat reports the cluster's current session with an encrypted,
/// peer-verified data plane (S16). A member that waits for its next periodic
/// heartbeat leaves a re-formed pair refused as "data plane unencrypted" for up
/// to a whole interval (~12 s on hardware, integration round 4 finding 1). The
/// member sends a heartbeat carrying `cluster_session` as soon as its session's
/// report changes (its owner launched; its worker published readiness).
@Suite("A member reports its formed session at once", .serialized, .timeLimit(.minutes(2)))
struct NativePairSessionHeartbeatTests {
    @Test func aHeartbeatCarryingTheNewSessionGoesOutWhenItsOwnerLaunchesNotAtTheNextInterval() async throws {
        let fixture = try NativePairMemberFixture(), peer = MemberFixturePeer(installation: fixture.installations[0])
        do {
            // The fixture client's periodic heartbeat is every 60 s: only an event heartbeat can arrive in time.
            try await peer.connect()
            let epoch = withUnsafeBytes(of: fixture.starts[0].common.epoch.uuid) { memberHex(Data($0)) }
            #expect(!peer.mock.snapshot().heartbeats.contains { $0.clusterSession != nil })
            try await peer.mock.pushNativePair(fixture.message("native_pair_prepare", rank: 0, nonce: peer.nonce, sequence: 1))
            _ = try await peer.wait("native_pair_prepared")
            try await peer.mock.pushNativePair(fixture.message("native_pair_owner_start", rank: 0, nonce: peer.nonce, sequence: 2))
            _ = try await peer.wait("native_pair_hello") // The owner launched; its native child waits for its peer.
            let launched = ContinuousClock.now
            let reported = try await peer.mock.waitForSnapshot(timeout: .seconds(5)) { snapshot in
                snapshot.heartbeats.contains { $0.clusterSession?.epoch == epoch && $0.clusterSession?.generation == 7 }
            }
            let session = try #require(reported?.heartbeats.compactMap(\.clusterSession).first { $0.epoch == epoch },
                "no heartbeat named the formed session within 5 s of its owner's launch (periodic interval 60 s)")
            #expect(ContinuousClock.now - launched < .seconds(5))
            // The key-only fixture keys no data plane: the report says so, never more.
            #expect(session.encryptedDataPlane == false && session.peerVerified == false)
            try await peer.mock.pushNativePair(fixture.message("native_pair_cancel", rank: 0, nonce: peer.nonce, sequence: 3,
                                                               payload: Data([68, 66, 78, 67, 1])))
            _ = try await peer.wait("native_pair_owner_released")
            await peer.close()
        } catch { await peer.close(); throw error }
    }

    /// The watch reports each change of the session's report once, stops at
    /// the final report (encrypted and verified), and stops with its session.
    @Test func theWatchReportsEachChangeOnceAndStopsAtTheFinalReportOrWithItsSession() async throws {
        let epoch = "00112233445566778899aabbccddeeff"
        let plain = ClusterSessionStatus(epoch: epoch, generation: 3, encryptedDataPlane: false, peerVerified: false)
        let keyed = ClusterSessionStatus(epoch: epoch, generation: 3, encryptedDataPlane: true, peerVerified: true)
        // Formation: nothing, the owner launched, readiness keyed the data plane; then nothing more is read.
        let reports = NativePairSessionReports(), source = NativePairSessionReports.Source([nil, nil, plain, plain, keyed, keyed, keyed])
        NativePairSessionStatusWatch.start(pollMilliseconds: 2, current: { source.current }, live: { true },
                                           changed: { reports.record($0) })
        try await memberFixtureWaitUntil { reports.values.count == 2 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(reports.values == [plain, keyed])
        #expect(source.reads == 5, "the watch stops reading at the final report")
        // A session that ends before its data plane is keyed: its one report, then nothing.
        let ended = NativePairSessionReports(), short = NativePairSessionReports.Source([nil, plain, plain])
        NativePairSessionStatusWatch.start(pollMilliseconds: 2, current: { short.current }, live: { short.live },
                                           changed: { ended.record($0) })
        try await memberFixtureWaitUntil { !short.live }
        try await Task.sleep(for: .milliseconds(50))
        #expect(ended.values == [plain])
    }
}

/// A scripted sequence of session reports and the changes the watch saw.
final class NativePairSessionReports: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [ClusterSessionStatus] = []
    func record(_ value: ClusterSessionStatus) { lock.withLock { seen.append(value) } }
    var values: [ClusterSessionStatus] { lock.withLock { seen } }

    final class Source: @unchecked Sendable {
        private let lock = NSLock()
        private var remaining: [ClusterSessionStatus?]
        private var last: ClusterSessionStatus?
        private var count = 0
        init(_ values: [ClusterSessionStatus?]) { remaining = values }
        /// Each read takes the next value; past the end the session has ended.
        var current: ClusterSessionStatus? {
            lock.withLock { count += 1; if !remaining.isEmpty { last = remaining.removeFirst() }; return last }
        }
        var live: Bool { lock.withLock { !remaining.isEmpty } }
        var reads: Int { lock.withLock { count } }
    }
}
