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
            // The session's timeline (`darkbloom-pair-owner-timeline-v1`): each step up to the launch, in order, on
            // the uptime clock; the first session of this member has no previous one.
            let timeline = try #require(peer.control.sessionTimeline)
            let steps = [timeline.prepareReceived, timeline.prepared, timeline.committed, timeline.launchBegan, timeline.launched]
            #expect(steps.allSatisfy { $0 != nil } && steps.compactMap { $0 } == steps.compactMap { $0 }.sorted())
            #expect(timeline.previousCancelled == nil && timeline.previousFinished == nil)
            #expect(timeline.durations.map { $0.name }.starts(with: ["prepare", "prepared_to_commit", "commit_to_launch", "launch"]))
            #expect(peer.control.previousSessionMarks.cancelled == nil)
            try await peer.mock.pushNativePair(fixture.message("native_pair_cancel", rank: 0, nonce: peer.nonce, sequence: 3,
                                                               payload: Data([68, 66, 78, 67, 1])))
            _ = try await peer.wait("native_pair_owner_released")
            // The cancel and the end of the old owner's run are what the next session's timeline starts from.
            try await memberFixtureWaitUntil { peer.control.previousSessionMarks.finished != nil }
            let marks = peer.control.previousSessionMarks
            #expect(marks.cancelled.map { $0 >= timeline.launched! } == true)
            #expect(marks.finished.flatMap { finished in marks.cancelled.map { finished >= $0 } } == true)
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

/// The member's timeline and heartbeat lines: each step's duration on the
/// uptime clock, a step that did not happen left out, no key.
@Suite("A member's session timeline lines")
struct NativePairOwnerTimelineTests {
    @Test func theTimelineLineNamesEachStepOnTheUptimeClock() throws {
        let ms: UInt64 = 1_000_000
        var timeline = NativePairOwnerTimeline(prepareReceived: 1_000 * ms, previousCancelled: 100 * ms,
                                               previousFinished: 700 * ms)
        timeline.prepared = 1_150 * ms; timeline.committed = 1_400 * ms
        timeline.launchBegan = 1_420 * ms; timeline.launched = 1_470 * ms
        let epoch = try #require(UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF"))
        // Not ready yet: no readiness spans.
        #expect(timeline.line(epoch: epoch, generation: 7, rank: 1, modelID: "registered_qwen38_27b", dataPlane: nil)
            == "darkbloom-pair-owner-timeline-v1 epoch=00112233-4455-6677-8899-aabbccddeeff generation=7 rank=1"
            + " model=registered_qwen38_27b ready=none cancel_to_prepare_ms=900 old_owner_stopped_to_prepare_ms=300"
            + " prepare_ms=150 prepared_to_commit_ms=250 commit_to_launch_ms=20 launch_ms=50")
        timeline.firstReady = 16_470 * ms
        #expect(timeline.line(epoch: epoch, generation: 7, rank: 1, modelID: "registered_qwen38_27b",
                              dataPlane: (encrypted: true, peerVerified: true))
            == "darkbloom-pair-owner-timeline-v1 epoch=00112233-4455-6677-8899-aabbccddeeff generation=7 rank=1"
            + " model=registered_qwen38_27b ready=seen encrypted=1 peer_verified=1 cancel_to_prepare_ms=900"
            + " old_owner_stopped_to_prepare_ms=300 prepare_ms=150 prepared_to_commit_ms=250 commit_to_launch_ms=20"
            + " launch_ms=50 launch_to_ready_ms=15000 commit_to_ready_ms=15070 cancel_to_ready_ms=16370")
        // A first session has no previous one; a clock that went backwards gives no span.
        var first = NativePairOwnerTimeline(prepareReceived: 5 * ms)
        first.prepared = 4 * ms
        #expect(first.durations.isEmpty)
    }

    @Test func theHeartbeatLineNamesTheReportAndItsTimes() {
        let ms: UInt64 = 1_000_000
        let keyed = ClusterSessionStatus(epoch: "00112233445566778899aabbccddeeff", generation: 7,
                                         encryptedDataPlane: true, peerVerified: true)
        #expect(NativePairOwnerTimeline.heartbeatLine(keyed, sent: true, changedAt: 10 * ms, sentAt: 12 * ms,
                                                      committed: 2 * ms)
            == "darkbloom-pair-session-heartbeat-v1 epoch=00112233-4455-6677-8899-aabbccddeeff generation=7"
            + " encrypted=1 peer_verified=1 sent=1 change_to_send_ms=2 commit_to_send_ms=10")
        let plain = ClusterSessionStatus(epoch: "00112233445566778899aabbccddeeff", generation: 7,
                                         encryptedDataPlane: false, peerVerified: true)
        #expect(NativePairOwnerTimeline.heartbeatLine(plain, sent: false, changedAt: 10 * ms, sentAt: 10 * ms,
                                                      committed: nil)
            == "darkbloom-pair-session-heartbeat-v1 epoch=00112233-4455-6677-8899-aabbccddeeff generation=7"
            + " encrypted=0 peer_verified=0 sent=0 change_to_send_ms=0")
        #expect(NativePairOwnerTimeline.uuidText(hex: "short") == "short")
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
