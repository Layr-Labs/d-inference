import Foundation
import Testing
@testable import ProviderCore

/// The start's progress travels in the leading Mac's status (`ClusterControlReply.start`) and its record; each Mac's
/// service reports which ranks are ready (`ClusterServiceStatus.Session.readyRankList`). Every field is optional: an
/// older Mac sends none and ignores them, and a later build's phase reads as unknown.
struct ClusterOnboardingStartProgressWireTests {
    /// A reply's shape as a build before these fields decodes it.
    struct OlderReply: Decodable { var lines: [String]; var failed: Bool; var leaderID: String? }
    struct OlderSession: Decodable { var observed: Bool; var ready: Bool; var readyRanks: Int; var ranks: Int }

    @Test func theStatusCarriesTheStartAndAnOlderMacIgnoresIt() throws {
        var reply = ClusterControlReply(lines: ["Loading Qwen: 1 of 2 parts ready."], failed: false, leaderID: "a")
        reply.start = .init(.loading, parts: [.init(rank: 0, state: .ready, layers: "0–46"), .init(rank: 1, state: .loading, layers: "47–93")],
                            since: 1_700_000_000)
        let data = try JSONEncoder().encode(reply)
        #expect(try JSONDecoder().decode(ClusterControlReply.self, from: data) == reply, "round trip")
        let older = try JSONDecoder().decode(OlderReply.self, from: data)
        #expect(older.lines == reply.lines && older.leaderID == "a", "an older Mac reads the rest")
        let fromOlder = try JSONDecoder().decode(ClusterControlReply.self, from: Data(#"{"lines":["Stopped."],"failed":false}"#.utf8))
        #expect(fromOlder.start == nil, "an older leader sends none")
    }

    @Test func aLaterPhaseReadsAsUnknown() throws {
        let data = Data(#"{"lines":[],"failed":false,"start":{"phase":"warming","done":3,"later":true}}"#.utf8)
        let reply = try JSONDecoder().decode(ClusterControlReply.self, from: data)
        #expect(reply.start?.phase == .unknown && reply.start?.done == 3)
    }

    /// f2 (0.10.9 DevNet, pair-2): the leading Mac's final ✗ travels in its status, each Mac named by its part, and the
    /// joining Mac reads it from its own side; a record after the leader's screen ended keeps it for a while.
    @Test func theLeadersFinalCrossTravelsNamedByPart() throws {
        let failed = ClusterOnboardingStartProgress.failed(title: "Not serving: The other Mac (Apple M5 Max, 128 GB) isn't logged in to Darkbloom.",
                                                           lines: ["Run `darkbloom login` on this Mac and the other Mac."], retry: true)
        var reply = ClusterControlReply(lines: [], failed: false)
        reply.start = failed
        let read = try JSONDecoder().decode(ClusterControlReply.self, from: JSONEncoder().encode(reply))
        let viewed = try #require(read.start).viewed(leader: "Apple M3 Ultra, 256 GB")
        #expect(viewed.phase == .failed && viewed.retry == true)
        #expect(viewed.title == "Not serving: This Mac isn't logged in to Darkbloom.")
        #expect(viewed.lines == ["Run `darkbloom login` on the other Mac (Apple M3 Ultra, 256 GB) and this Mac."])
        let older = try JSONDecoder().decode(OlderReply.self, from: JSONEncoder().encode(reply))
        #expect(older.lines.isEmpty, "an older Mac reads the rest")
        let mark = ClusterOnboardingStartProgressMark(progress: failed, pid: 42, started: 7, at: 100)
        #expect(mark.current(now: 100 + 600, started: { _ in nil }) != nil, "the ✗ outlives the leader's screen")
        #expect(mark.current(now: 100 + ClusterOnboardingStartProgressMark.outcomeSeconds, started: { _ in nil }) == nil, "for a while only")
    }

    @Test func theSessionNamesTheReadyRanksAndAnOlderMacIgnoresThem() throws {
        var session = ClusterServiceStatus.Session(observed: true, ready: false, readyRanks: 1, ranks: 2, port: nil, detail: nil)
        session.readyRankList = [0]
        let data = try JSONEncoder().encode(session)
        #expect(try JSONDecoder().decode(ClusterServiceStatus.Session.self, from: data).readyRankList == [0])
        #expect(try JSONDecoder().decode(OlderSession.self, from: data).readyRanks == 1)
        let fromOlder = try JSONDecoder().decode(ClusterServiceStatus.Session.self,
                                                 from: Data(#"{"observed":true,"ready":false,"readyRanks":1,"ranks":2}"#.utf8))
        #expect(fromOlder.readyRankList == nil)
    }

    @Test func eachMacsPartFromItsProcess() {
        var running = ClusterServiceStatus.Child(running: true, starts: 1)
        #expect(OnboardingLive.part(rank: 1, ready: false, child: running, layers: "47–93") == .init(rank: 1, state: .loading, layers: "47–93"))
        #expect(OnboardingLive.part(rank: 1, ready: true, child: running, layers: nil).state == .ready)
        #expect(OnboardingLive.part(rank: 1, ready: false, child: nil, layers: nil).state == .starting)
        running.running = false
        running.lastEnd = "exit 1"
        running.restartInSeconds = 5
        let ended = OnboardingLive.part(rank: 0, ready: false, child: running, layers: nil)
        #expect(ended.state == (OnboardingLive.endShown(running) ? .ended : .starting))
    }
}
