import Foundation
import Testing
@testable import ProviderCore

/// An external pair on 0.10.12 (2026-11-12): the joining Mac took the leading Mac's "Stopped" status for a stop 20 s into
/// a download nobody stopped. The leading Mac now counts each stop a person asks for (`ClusterSetupRecord.stopsAsked`),
/// its status carries the count, and the screens end on a stop only once it grew. The leading Mac here is the
/// `ClusterApprovalMacs` fixture's, in its own home; nothing asks the other Mac (its answer is given).
@Suite("Cluster onboarding: the stops a person asked for", .serialized)
struct ClusterOnboardingStopsAskedTests {
    /// A reply's shape as a build before the count decodes it.
    struct OlderReply: Decodable { var lines: [String]; var failed: Bool; var leaderID: String? }

    /// The leading Mac of a pair the fixture saved, its pair started. Its cluster service runs no loop.
    private static func leader() throws -> (ClusterApprovalMacs, ClusterService) {
        let macs = try ClusterApprovalMacs(coordinatorURL: "ws://127.0.0.1:9/ws/provider")
        return (macs, try macs.startedLeaderService(powerAssertionReason: "Cluster stops asked test " + UUID().uuidString))
    }

    @Test func theStatusCarriesTheStopsAskedForAndAnOlderMacIgnoresThem() throws {
        var reply = ClusterControlReply(lines: ["Stopped; last model Qwen 3.8 27B."], failed: false, leaderID: "a")
        reply.stopsAsked = 3
        let data = try JSONEncoder().encode(reply)
        #expect(try JSONDecoder().decode(ClusterControlReply.self, from: data) == reply, "round trip")
        #expect(try JSONDecoder().decode(OlderReply.self, from: data).lines == reply.lines, "an older Mac reads the rest")
        #expect(ClusterOnboardingLeaderStatus(reply: reply).stopsAsked == 3, "the Mac that forwarded the status reads the count")
        let fromOlder = try JSONDecoder().decode(ClusterControlReply.self, from: Data(#"{"lines":["Stopped."],"failed":false}"#.utf8))
        #expect(fromOlder.stopsAsked == nil && !ClusterOnboardingStopped.asked(since: 0, now: ClusterOnboardingLeaderStatus(reply: fromOlder).stopsAsked),
                "an older leader sends none: no stop")
        let request = ClusterControlRequest(op: .serve, stopsBefore: 2)
        #expect(try JSONDecoder().decode(ClusterControlRequest.self, from: JSONEncoder().encode(request)).stopsBefore == 2, "a start's count travels")
        #expect(try JSONDecoder().decode(ClusterControlRequest.self, from: Data(#"{"op":"serve"}"#.utf8)).stopsBefore == nil,
                "an older Mac's start carries none, and serves as before")
    }

    /// Each stop's first write: only one a person asked for is counted; the start's own (a model change, the
    /// registration's restart) and the cluster service's are not. Each stops the pair the same way.
    @Test func onlyAStopAPersonAskedForIsCounted() throws {
        var record = ClusterSetupRecord()
        record.leadership = ClusterOnboardingLeadership(role: "leader", leaderPin: "a", peerPin: "b", peerName: "Apple M5 Max, 128 GB",
                                                        since: "2026-11-12T20:40:00Z")
        record.leadership?.serving = true
        let own = UUID()
        OnboardingLive.recordStop(&record, id: own, asked: false)
        #expect(record.leadership?.serving == false && record.stopDrain?.id == own && record.stopsAsked == nil, "the start's own stop")
        OnboardingLive.recordStop(&record, id: UUID(), asked: true)
        OnboardingLive.recordStop(&record, id: UUID(), asked: true)
        #expect(record.leadership?.serving == false && record.stopsAsked == 2, "each stop a person asked for, counted")
        #expect(try JSONDecoder().decode(ClusterSetupRecord.self, from: JSONEncoder().encode(record)).stopsAsked == 2, "kept")
        let older = try JSONDecoder().decode(ClusterSetupRecord.self, from: Data(
            #"{"schema":"darkbloom_cluster_setup_wizard_v1","confirmed":[],"sent":[],"checks":[]}"#.utf8))
        #expect(older.stopsAsked == nil, "an older record counts none")
    }

    /// The real stop on the leading Mac's record, and the status reply the Mac that joined reads it from: 0 before the
    /// first; a stop asked for counts, the pair's own doesn't.
    @Test func theLeadingMacCountsAStopAskedForAndItsStatusCarriesIt() throws {
        let (macs, service) = try Self.leader()
        let live = service.controlLive
        #expect(live.currentStopsAsked() == 0 && live.followerStatus(.init(lines: [], failed: false)).stopsAsked == 0, "none yet")
        if case .failure(let failure) = live.localStop(seconds: 1, asked: true, stopPeer: {}) { Issue.record("stop: \(failure.lines)") }
        let stopped = try service.store.readRecord()
        #expect(live.currentStopsAsked() == 1 && stopped.leadership?.serving == false, "a stop asked for")
        if case .failure(let failure) = live.localStop(seconds: 1, stopPeer: {}) { Issue.record("own stop: \(failure.lines)") }
        #expect(live.currentStopsAsked() == 1, "the pair's own stop counts none")
        #expect(live.followerStatus(.init(lines: ["Stopped; last model fixture/qwen."], failed: false)).stopsAsked == 1,
                "the status the Mac that joined reads carries it")
        withExtendedLifetime(macs) {}
    }

    /// A start that took the command lock after a stop asked since it began never undoes that stop: it serves nothing.
    @Test func aStartNeverUndoesAStopAskedSinceItBegan() throws {
        let (macs, service) = try Self.leader()
        let live = service.controlLive
        if case .failure(let failure) = live.localStop(seconds: 1, asked: true, stopPeer: {}) { Issue.record("stop: \(failure.lines)") }
        guard case .failure(let refused) = live.localServe(unlessStoppedSince: 0) else {
            Issue.record("served after a stop asked since the start began")
            return
        }
        #expect(refused.stopped && refused.lines == [ClusterOnboardingStopped.line], "the stop line, marked stopped")
        let record = try service.store.readRecord()
        #expect(record.leadership?.serving == false, "the pair stays stopped")
        withExtendedLifetime(macs) {}
    }
}
