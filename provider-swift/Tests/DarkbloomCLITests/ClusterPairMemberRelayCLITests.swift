import ArgumentParser
import Foundation
import ProviderCore
import Testing

@testable import darkbloom

/// Every Mac of a pair answers locally (Both, me first as `cluster local`): a Mac whose part isn't rank 0 relays its own
/// port to the pair's API, so its own `status`, `darkbloom local` and `start --opencode` name an address on this Mac,
/// with this Mac's own key. No pair, cluster service, port or tool runs: the pair is a summary value and the tools a
/// scripted step in a temp home.
@Suite("A pair's every Mac answers locally (CLI)", .serialized)
struct ClusterPairMemberRelayCLITests {
    typealias F = LocalFirstStatusFixtures
    static let other = "the other Mac (Apple M5 Ultra, 256 GB)"

    /// A member (its part isn't rank 0) of a pair serving Both, me first, with the pair's API on `bind`.
    private func member(relaying: ClusterPairLocalAPI.Address? = .init(host: "0.0.0.0", port: 8003),
                        bind: String? = "0.0.0.0") -> ClusterPairSummary {
        Self.memberSummary(relaying: relaying, bind: bind)
    }

    /// The same, for an exit test's body, which captures nothing.
    static func memberSummary(relaying: ClusterPairLocalAPI.Address? = .init(host: "0.0.0.0", port: 8003),
                              bind: String? = "0.0.0.0") -> ClusterPairSummary {
        var pair = ClusterPairSummary(paired: true, role: .member, otherMacName: "Apple M5 Ultra, 256 GB", modelID: "qwen",
                                      modelName: "Qwen 3.8 27B", started: true, serviceRunning: true, state: .serving)
        pair.lines = ["Serving Qwen 3.8 27B through Darkbloom on both Macs (tensor parallel)."]
        pair.localAPI = ClusterPairLocalAPI(runsRankZero: false, listening: nil, meFirst: nil)
        pair.localAPIBind = bind
        pair.relaying = relaying
        return pair
    }

    /// The same Mac with the pair serving Only me (`darkbloom cluster local`), whose API every other Mac relays the same way.
    static func onlyMe(_ pair: ClusterPairSummary) -> ClusterPairSummary {
        var pair = pair
        pair.localAPI = nil
        pair.localOnly = true
        return pair
    }

    /// The relay's words while the other Mac is away, as the 503 says them.
    static let awayWords = ClusterLocalRelay.Refusals.pair(otherMac: "Apple M5 Ultra, 256 GB", cli: ClusterPairSummary.cli).unreachable
    /// The relay's words while the pair's API on the other Mac doesn't listen (its part starts again), as the 503 says them.
    static let notAnsweringWords = ClusterLocalRelay.Refusals.pair(otherMac: "Apple M5 Ultra, 256 GB", cli: ClusterPairSummary.cli)
        .notAnswering

    // MARK: - status

    /// The member's `status` names the address its tools dial on this Mac, and where its requests go.
    @Test func aMembersStatusNamesItsOwnAddress() {
        let passes = "Members: \(Self.other) runs the pair's API; this Mac passes your requests to it, and Darkbloom pauses for them too"
        #expect(member().localAPILines(now: F.now) == [
            "Local API: http://127.0.0.1:8003/v1 on this Mac, and port 8003 of its LAN or tailnet address (`\(ClusterPairSummary.cli) local` shows the key)",
            passes,
        ])
        #expect(member().clusterStatusLines.contains { $0.hasPrefix("Local API: http://127.0.0.1:8003/v1 on this Mac") })
        // Its relay isn't up yet (the pair's API is still starting on the other Mac).
        #expect(member(relaying: nil).localAPILines(now: F.now) == [
            "Local API: not listening on this Mac yet; it starts once the pair's API on \(Self.other) answers", passes,
        ])
        // The pair's API kept on its own Mac (loopback or one address): nothing relays it, as before.
        for bind in ["127.0.0.1", "192.168.1.5"] {
            #expect(member(relaying: nil, bind: bind).localAPILines(now: F.now) == [
                "Local API: on \(Self.other), which runs the pair's API; `\(ClusterPairSummary.cli) local` there shows its address "
                    + "and key, and `\(ClusterPairSummary.cli) status` there whether Darkbloom is paused for you",
                "Members: this Mac is part of the pair; it runs no local API",
            ], "\(bind)")
        }
    }

    /// While Darkbloom doesn't have the pair, rank 0 answers on its own Mac only, so the member passes nothing on and
    /// says so, never an address that resets every connection; a port another program holds is named, with what to do.
    @Test func aMemberSaysWhyItsPortDoesNotAnswer() {
        let neutral = "Members: \(Self.other) runs the pair's API; this Mac is part of the pair"
        var waiting = member(relaying: nil)
        waiting.relayWaitsForOffer = true
        #expect(waiting.localAPILines(now: F.now) == [
            "Local API: none on this Mac while Darkbloom doesn't have the pair; meanwhile the pair answers only on \(Self.other) "
                + "(`\(ClusterPairSummary.cli) local` there shows its address and key)",
            neutral,
        ])
        var held = member(relaying: nil)
        held.relayPortHeld = 8001
        #expect(held.localAPILines(now: F.now) == [
            "Local API: port 8001 on this Mac is held by another program, so this Mac doesn't answer for the pair; free it, "
                + "or set another `[local] port` in provider.toml, then `\(ClusterPairSummary.cli) restart`",
            neutral,
        ])
    }

    /// While rank 0's Mac can't be reached, the member's relay answers each request a 503, and its `status` says the
    /// same words: its address answers 503 for now, why, and what to do.
    @Test func aMembersStatusSaysItsPairsOtherMacIsAway() {
        var away = member()
        away.relayRankZeroAway = true
        #expect(away.localAPILines(now: F.now) == [
            "Local API: http://127.0.0.1:8003/v1 on this Mac answers 503 for now. \(Self.awayWords)",
            "Members: \(Self.other) runs the pair's API; this Mac is part of the pair",
        ])
        away.relayRankZeroAway = false
        #expect(away.localAPILines(now: F.now).first?.hasPrefix("Local API: http://127.0.0.1:8003/v1 on this Mac,") == true,
                "back: its address again")
    }

    /// While the pair's API on the other Mac doesn't listen (its part starts again after a stop, a restart or an update),
    /// the member's relay keeps its port and answers each request a 503, and its `status` says so in the 503's words,
    /// never "not listening": with Both, me first and with Only me. The other Mac away says that instead; once the API
    /// listens again, the address. Tools are still set up for the address (`memberAPIDown` says nothing): it passes
    /// requests on again by itself.
    @Test func aMembersStatusSaysItsRelayAnswers503WhileThePairsAPIStartsAgain() {
        var down = member()
        down.relayRankZeroAPIDown = true
        let line = "Local API: http://127.0.0.1:8003/v1 on this Mac answers 503 for now. \(Self.notAnsweringWords)"
        #expect(down.localAPILines(now: F.now) == [line, "Members: \(Self.other) runs the pair's API; this Mac is part of the pair"])
        #expect(Self.onlyMe(down).localAPILines(now: F.now) == [line])
        #expect(down.memberAPIDown == nil && down.memberAPIStarting == nil)
        #expect(down.appStartLines(named: [], localEndpoint: true, code: 0).isEmpty)
        var away = down
        away.relayRankZeroAway = true
        #expect(away.localAPILines(now: F.now).first == "Local API: http://127.0.0.1:8003/v1 on this Mac answers 503 for now. \(Self.awayWords)")
        down.relayRankZeroAPIDown = false
        #expect(down.localAPILines(now: F.now).first?.hasPrefix("Local API: http://127.0.0.1:8003/v1 on this Mac,") == true,
                "listening again: its address")
    }

    /// The app's Start on a member (`Start.appStartOptions`, `--local-endpoint`) never says "No local API was added"
    /// while its relay gives it one (#1905's rule for whichever of the two landed second): relaying, or still starting, it
    /// says nothing of one; with the other Mac away, or while Darkbloom doesn't have the pair, it says this Mac's state in
    /// `status`'s words. Only where the pair gives this Mac none (its API kept on the leading Mac) does that line stand.
    @Test func theAppsStartNeverSaysNoLocalAPIWhileTheRelayGivesOne() {
        let none = "No local API was added on this Mac: a pair's local API comes from how the pair serves "
            + "(`\(ClusterPairSummary.cli) cluster` on the leading Mac changes it)."
        var away = member(), waiting = member(relaying: nil)
        away.relayRankZeroAway = true
        waiting.relayWaitsForOffer = true
        for code: Int32 in [0, 3] {
            #expect(member().appStartLines(named: [], localEndpoint: true, code: code).isEmpty, "relaying, exit \(code)")
            #expect(member(relaying: nil).appStartLines(named: [], localEndpoint: true, code: code).isEmpty,
                    "its relay still starting, exit \(code)")
            #expect(away.appStartLines(named: [], localEndpoint: true, code: code)
                == ["Local API: http://127.0.0.1:8003/v1 on this Mac answers 503 for now. \(Self.awayWords)"], "away, exit \(code)")
            #expect(waiting.appStartLines(named: [], localEndpoint: true, code: code)
                == ["Local API: none on this Mac while Darkbloom doesn't have the pair; meanwhile the pair answers only on "
                        + "\(Self.other) (`\(ClusterPairSummary.cli) local` there shows its address and key)"], "not offered, exit \(code)")
            for bind in ["127.0.0.1", "192.168.1.5"] {
                #expect(member(relaying: nil, bind: bind).appStartLines(named: [], localEndpoint: true, code: code) == [none],
                        "kept on the leading Mac (\(bind)), exit \(code)")
            }
        }
        #expect(away.appStartLines(named: [], localEndpoint: false, code: 0).isEmpty, "no local API asked for")
        // Only me: a local API on every Mac only with the pair's API on every address (#1905's review, nit 2).
        #expect(Self.onlyMe(member()).appStartLines(named: [], localEndpoint: true, code: 0).isEmpty)
        #expect(Self.onlyMe(member(relaying: nil, bind: "127.0.0.1")).appStartLines(named: [], localEndpoint: true, code: 0)
            == [none])
    }

    /// With Only me on every address the other Mac relays the pair's API too, and says the same when its port can't answer
    /// now (the other Mac away, its port held): in `status`, which otherwise names no address for it (`darkbloom local`
    /// does), and in the app's Start. Relaying, or with nothing published (its relay starting, or the Mac that runs the
    /// pair's API, which publishes no relay), no line.
    @Test func anOnlyMeMemberSaysWhyItsPortCantAnswerToo() {
        var away = Self.onlyMe(member()), held = Self.onlyMe(member(relaying: nil))
        away.relayRankZeroAway = true
        held.relayPortHeld = 8001
        let awayLine = "Local API: http://127.0.0.1:8003/v1 on this Mac answers 503 for now. \(Self.awayWords)"
        let heldLine = "Local API: port 8001 on this Mac is held by another program, so this Mac doesn't answer for the pair; "
            + "free it, or set another `[local] port` in provider.toml, then `\(ClusterPairSummary.cli) restart`"
        #expect(away.localAPILines(now: F.now) == [awayLine])
        #expect(held.localAPILines(now: F.now) == [heldLine])
        #expect(away.appStartLines(named: [], localEndpoint: true, code: 0) == [awayLine])
        #expect(held.appStartLines(named: [], localEndpoint: true, code: 3) == [heldLine])
        for quiet in [Self.onlyMe(member()), Self.onlyMe(member(relaying: nil))] {
            #expect(quiet.memberAPIDown == nil && quiet.localAPILines(now: F.now).isEmpty, "\(quiet.relaying as Any)")
        }
    }

    /// Only a Mac that relays the pair's API on every address says its port answers 503 for now: with the pair's API kept
    /// on the leading Mac (loopback or one address), `status`, `darkbloom local` and `doctor` have no such line, whatever
    /// this Mac's cluster service last said of a relay, with Both, me first and with Only me.
    @Test func aPairKeptOnItsLeadingMacGivesAMemberNo503Line() {
        for bind in ["127.0.0.1", "192.168.1.5"] {
            for onlyMe in [false, true] {
                var kept = member(bind: bind)
                if onlyMe { kept = Self.onlyMe(kept) }
                kept.relayRankZeroAway = true
                kept.relayRankZeroAPIDown = true
                #expect(kept.memberAPIUnavailable == nil, "\(bind), Only me \(onlyMe)")
            }
        }
    }

    /// The Mac that runs the pair's API says the other Mac answers on its own port too, once the API is on every address:
    /// from where it listens, so an API on this Mac only (Both while Darkbloom doesn't have the pair) says it runs none.
    @Test func theLeadersStatusSaysTheOtherMacAnswersToo() {
        func leader(_ host: String, bind: String? = nil) -> ClusterPairSummary {
            var pair = ClusterPairSummary(paired: true, role: .leader, otherMacName: "Apple M3 Ultra, 256 GB", modelID: "qwen",
                                          modelName: "Qwen 3.8 27B", started: true, serviceRunning: true, state: .serving)
            pair.localAPI = ClusterPairLocalAPI(runsRankZero: true, listening: .init(host: host, port: 8003), meFirst: F.open)
            pair.localAPIBind = bind ?? host
            return pair
        }
        #expect(leader("0.0.0.0").localAPILines(now: F.now).last
            == "Members: the other Mac (Apple M3 Ultra, 256 GB) is part of the pair; its own port passes your requests to this API")
        #expect(leader("127.0.0.1").localAPILines(now: F.now).last
            == "Members: the other Mac (Apple M3 Ultra, 256 GB) is part of the pair; it runs no local API")
        #expect(leader("127.0.0.1", bind: "0.0.0.0").localAPILines(now: F.now).last
            == "Members: the other Mac (Apple M3 Ultra, 256 GB) is part of the pair; it runs no local API",
            "the API on this Mac only while Darkbloom doesn't have the pair")
    }

    /// This Mac's relay is the discovery record its own cluster service wrote: not its part's, and not another server's.
    @Test func thisMacsRelayIsTheRecordItsClusterServiceWrote() throws {
        var own = try JSONDecoder().decode(ClusterServiceStatus.self, from: Data(
            #"{"serving":true,"sessionLeader":false,"child":{"running":true,"starts":1,"pid":5000},"servicePID":4242}"#.utf8))
        func record(pid: Int32, host: String = "0.0.0.0") -> LocalEndpoint.Info {
            LocalEndpoint.Info(host: host, port: 8003, apiKey: "dk-local-k", version: "t", pid: pid, updatedAt: "")
        }
        #expect(ClusterPairSummary.relayAddress(own: own, live: record(pid: 4242)) == .init(host: "0.0.0.0", port: 8003))
        #expect(ClusterPairSummary.relayAddress(own: own, live: record(pid: 5000)) == nil, "its part's API is not a relay")
        #expect(ClusterPairSummary.relayAddress(own: own, live: record(pid: 77)) == nil, "another server")
        #expect(ClusterPairSummary.relayAddress(own: own, live: nil) == nil)
        own.servicePID = nil
        #expect(ClusterPairSummary.relayAddress(own: own, live: record(pid: 4242)) == nil, "an older service says no pid")
        #expect(ClusterPairSummary.relayAddress(own: nil, live: record(pid: 4242)) == nil)
    }

    // MARK: - darkbloom local

    /// `darkbloom local` on a member prints its relay's address on this Mac and this Mac's own key, which is the key
    /// file its tools read (`local_token`); the pair's key is never the one shown.
    @Test func localOnAMemberPrintsItsOwnAddressAndKey() async throws {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("member-relay-local-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            setenv("DARKBLOOM_LOCAL_DIR", directory.path, 1)
            let own = "dk-local-MemberOwnKeyAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
            let pair = "dk-local-PairKeyBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
            try own.write(to: directory.appendingPathComponent("local_token"), atomically: true, encoding: .utf8)
            try pair.write(to: directory.appendingPathComponent("cluster_local_token"), atomically: true, encoding: .utf8)
            try LocalEndpoint.writeInfo(ClusterService.relayDiscovery(port: 8003, keys: .init(own: own, pair: pair)))
            keepCommandsOffThisMacsCluster()
            var command = try Local.parse([])
            try await command.run()
            let keyFile = LocalEndpoint.keyFile(forPort: 8003)?.lastPathComponent
            print("---key file: \(keyFile ?? "none")")
            try? FileManager.default.removeItem(at: directory)
            exit(0)
        }
        let stdout = String(decoding: result?.standardOutputContent ?? [], as: UTF8.self)
        #expect(stdout.contains("  base URL: http://127.0.0.1:8003/v1\n"), "\(stdout)")
        #expect(stdout.contains("  API key:  dk-local-MemberOwnKeyAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n"), "\(stdout)")
        #expect(!stdout.contains("PairKey"), "never the pair's key")
        #expect(stdout.contains("---key file: local_token"), "tools read this Mac's own key file")
    }

    /// `darkbloom local` on a member without its own address says why, as `status` does, and never shows the pair's key
    /// (its API doesn't take it there): while Darkbloom doesn't have the pair, and while another program holds its port.
    @Test func localOnAMemberSaysWhyItHasNoAddress() async throws {
        for state in ["offer", "held"] {
            let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
                [state = state as String] in
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("member-relay-local-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                setenv("DARKBLOOM_LOCAL_DIR", directory.path, 1)
                try "dk-local-PairKeyBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
                    .write(to: directory.appendingPathComponent("cluster_local_token"), atomically: true, encoding: .utf8)
                var pair = ClusterPairMemberRelayCLITests.memberSummary(relaying: nil)
                if state == "held" { pair.relayPortHeld = 8001 } else { pair.relayWaitsForOffer = true }
                let summary = pair
                ClusterPairSummary.processReaderForTesting = { _ in summary }
                var command = try Local.parse([])
                do { try await command.run() } catch { exit(1) }
                exit(0)
            }
            let stderr = String(decoding: result?.standardErrorContent ?? [], as: UTF8.self)
            let expected = state == "held"
                ? "Local API: port 8001 on this Mac is held by another program, so this Mac doesn't answer for the pair"
                : "Local API: none on this Mac while Darkbloom doesn't have the pair"
            #expect(stderr.contains(expected), "\(state): \(stderr)")
            #expect(!stderr.contains("PairKey") && !stderr.contains("No local server running"), "\(state): \(stderr)")
        }
    }

    /// `darkbloom local` on a member whose pair's other Mac can't be reached, or whose pair's API there doesn't listen
    /// (its part starts again), shows its address, and says it answers 503 for now, in the 503's words: with Both, me
    /// first and with Only me.
    @Test func localOnAMemberWhosePairsOtherMacIsAwaySaysSo() async throws {
        for (onlyMe, away) in [(false, true), (true, true), (false, false), (true, false)] {
            let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
                [onlyMe = onlyMe as Bool, away = away as Bool] in
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("member-relay-local-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                setenv("DARKBLOOM_LOCAL_DIR", directory.path, 1)
                let own = "dk-local-MemberOwnKeyAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
                try own.write(to: directory.appendingPathComponent("local_token"), atomically: true, encoding: .utf8)
                try LocalEndpoint.writeInfo(ClusterService.relayDiscovery(port: 8003, keys: .init(own: own, pair: own)))
                var pair = ClusterPairMemberRelayCLITests.memberSummary()
                if onlyMe { pair = ClusterPairMemberRelayCLITests.onlyMe(pair) }
                if away { pair.relayRankZeroAway = true } else { pair.relayRankZeroAPIDown = true }
                let summary = pair
                ClusterPairSummary.processReaderForTesting = { _ in summary }
                var command = try Local.parse([])
                try await command.run()
                exit(0)
            }
            let stdout = String(decoding: result?.standardOutputContent ?? [], as: UTF8.self)
            let words = away ? Self.awayWords : Self.notAnsweringWords
            #expect(stdout.contains("  base URL: http://127.0.0.1:8003/v1\n"), "Only me \(onlyMe), away \(away): \(stdout)")
            #expect(stdout.contains("Local API: http://127.0.0.1:8003/v1 on this Mac answers 503 for now. \(words)"),
                    "Only me \(onlyMe), away \(away): \(stdout)")
        }
    }

    /// `darkbloom local` on a member whose relay is still starting says so, in `status`'s words, then shows the pair's key
    /// as it always has, in words true there: never "No local server running." while the pair's API runs on the other
    /// Mac and this Mac's port starts. With Both, me first and with Only me. A Mac the pair gives no port (its API kept
    /// on the other Mac) keeps the words it had.
    @Test func localOnAMemberWhoseRelayStartsSaysSoBesideThePairsKey() async throws {
        let key = "dk-local-PairKey" + String(repeating: "B", count: 36)
        for kind in ["both", "onlyMe", "kept"] {
            let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
                [kind = kind as String, key = key as String] in
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("member-relay-local-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                setenv("DARKBLOOM_LOCAL_DIR", directory.path, 1)
                try key.write(to: directory.appendingPathComponent("cluster_local_token"), atomically: true, encoding: .utf8)
                var pair = ClusterPairMemberRelayCLITests.memberSummary(relaying: nil, bind: kind == "kept" ? "127.0.0.1" : "0.0.0.0")
                if kind == "onlyMe" { pair = ClusterPairMemberRelayCLITests.onlyMe(pair) }
                let summary = pair
                ClusterPairSummary.processReaderForTesting = { _ in summary }
                var command = try Local.parse([])
                do { try await command.run() } catch { exit(1) }
                exit(0)
            }
            let stderr = String(decoding: result?.standardErrorContent ?? [], as: UTF8.self)
            #expect(stderr.contains("\n  \(key)\n"), "\(kind): \(stderr)")
            if kind == "kept" {
                #expect(stderr.contains("No local server running.\nThe cluster's API key (the same on both Macs;"), "\(kind): \(stderr)")
            } else {
                #expect(stderr.contains("Local API: not listening on this Mac yet; it starts once the pair's API on \(Self.other) "
                    + "answers.\nThe pair's API key (the same on both Macs, and taken on this Mac's port once it listens):\n"),
                        "\(kind): \(stderr)")
                #expect(!stderr.contains("No local server running"), "\(kind): \(stderr)")
            }
        }
    }

    // MARK: - start --opencode on a member

    /// The tools on a member point at its own relay, with its own key file, and say where its requests go: to the pair,
    /// never the paid network (rank 0's API sees another machine).
    @Test func startOpenCodeOnAMemberSetsItUpForItsOwnRelay() async throws {
        let sandbox = try ToolSandbox()
        let endpoint = IntegrationEndpoint(baseURL: "http://127.0.0.1:8003/v1", keyFile: sandbox.keyFile)
        let start = try Start.parse(["--opencode", "--config", sandbox.config.path])
        try await start.setUpToolsBesidePair(pair: member(), waitForAPI: { .ready(endpoint) }, step: sandbox.step())
        let written = String(decoding: try Data(contentsOf: sandbox.openCodeFile), as: UTF8.self)
        #expect(written.contains("http://127.0.0.1:8003/v1"))
        #expect(written.contains("{file:~/.darkbloom/local_token}"))
        #expect(sandbox.fetched == [endpoint], "the models were read through this Mac's own API")
        #expect(sandbox.said.contains("  Requests: the pair, on its API on the other Mac; never the paid Darkbloom network"),
                "\(sandbox.said)")
        #expect(!sandbox.said.joined().contains(sandbox.token), "no key printed")
    }

    /// A pair that serves only Darkbloom, an API kept on the other Mac, or an API that doesn't answer in time: one line
    /// that says why and what to do, nothing written, and the start fails while the pair keeps serving.
    @Test func aMemberWithoutItsOwnAPISaysWhyAndWritesNothing() async throws {
        var network = member(relaying: nil, bind: nil)
        network.localAPI = nil
        for pair in [network, member(relaying: nil, bind: "127.0.0.1"), member(relaying: nil)] {
            let sandbox = try ToolSandbox()
            await #expect(throws: ExitCode.failure) {
                try await Start.parse(["--opencode", "--config", sandbox.config.path])
                    .setUpToolsBesidePair(pair: pair, waitForAPI: { sandbox.waited(); return .notUp }, step: sandbox.step())
            }
            #expect(sandbox.said.isEmpty && !FileManager.default.fileExists(atPath: sandbox.openCodeFile.path))
            #expect(sandbox.waits == (pair.localAPIBind == nil ? 0 : 1), "a pair with no local API anywhere doesn't wait")
        }
        #expect(ToolIntegrationStep.noPairAPI([.opencode]) == "✗ This pair serves only the Darkbloom network, so OpenCode "
            + "has no local address to use and wasn't set up. Run `darkbloom cluster` on the leading Mac (it serves the pair "
            + "with its local API beside Darkbloom) or `darkbloom cluster local`, then run `darkbloom --opencode` again.")
        #expect(ToolIntegrationStep.pairAPIElsewhere([.opencode], bind: "127.0.0.1") == "✗ The pair's local API listens "
            + "on the Mac that runs it only (127.0.0.1), so OpenCode wasn't set up on this Mac: run `darkbloom "
            + "--opencode` on that Mac.")
    }

    /// `--opencode` on a member that has no working address for the pair says why at once, as `status` does, instead of
    /// waiting for an answer that can't come: while Darkbloom doesn't have the pair, its port held, or the other Mac away
    /// (Only me too).
    @Test func openCodeOnAMemberSaysAtOnceWhyItHasNoAddress() async throws {
        var waiting = member(relaying: nil), held = member(relaying: nil), away = member(), onlyMeAway = Self.onlyMe(member())
        waiting.relayWaitsForOffer = true
        held.relayPortHeld = 8001
        away.relayRankZeroAway = true
        onlyMeAway.relayRankZeroAway = true
        for pair in [waiting, held, away, onlyMeAway] {
            let sandbox = try ToolSandbox()
            await #expect(throws: ExitCode.failure) {
                try await Start.parse(["--opencode", "--config", sandbox.config.path])
                    .setUpToolsBesidePair(pair: pair, waitForAPI: { sandbox.waited(); return .notUp }, step: sandbox.step())
            }
            #expect(sandbox.waits == 0, "said at once, without the wait")
            #expect(sandbox.said.isEmpty && !FileManager.default.fileExists(atPath: sandbox.openCodeFile.path))
        }
        #expect(ToolIntegrationStep.noMemberAddress([.opencode], localAPI: "none on this Mac while Darkbloom doesn't have the pair")
            == "✗ OpenCode wasn't set up on this Mac. Local API: none on this Mac while Darkbloom doesn't have the pair. Run "
                + "`darkbloom --opencode` again once this Mac answers.")
    }

    /// `--opencode` beside this Mac's running relay while the pair's other Mac can't be reached says so at once, in
    /// `status`'s words, and sets nothing up: the relay answers 503 for now (the tool step said only "HTTP 503").
    @Test func openCodeBesideARelayWhosePairsOtherMacIsAwaySaysSoAtOnce() async throws {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardOutputContent]) {
            let sandbox = try ToolSandbox()
            setenv("DARKBLOOM_LOCAL_DIR", sandbox.keyFile.deletingLastPathComponent().path, 1)
            try LocalEndpoint.writeInfo(ClusterService.relayDiscovery(port: 8003, keys: .init(own: sandbox.token, pair: sandbox.token)))
            var pair = ClusterPairMemberRelayCLITests.memberSummary()
            pair.relayRankZeroAway = true
            let summary = pair
            ClusterPairSummary.processReaderForTesting = { _ in summary }
            let start = try Start.parse(["--opencode", "--config", sandbox.config.path])
            let ran = try? await start.setUpToolsForRunningLocalAPI(live: LocalEndpoint.readLiveInfo(), step: sandbox.step())
            let untouched = sandbox.said.isEmpty && !FileManager.default.fileExists(atPath: sandbox.openCodeFile.path)
            try? FileManager.default.removeItem(at: sandbox.directory.url)
            exit(ran == nil && untouched ? 1 : 0)
        }
        let stdout = String(decoding: result?.standardOutputContent ?? [], as: UTF8.self)
        let line = ToolIntegrationStep.noMemberAddress([.opencode],
                                                       localAPI: "http://127.0.0.1:8003/v1 on this Mac answers 503 for now. \(Self.awayWords)")
        #expect(stdout.contains(line + "\n"), "\(stdout)")
        #expect(!stdout.contains("already serves"), "\(stdout)")
    }

    /// A member whose API doesn't answer within the wait says why: with the pair's API on every address its relay isn't
    /// up yet, so run the start again later; with the API kept on the Mac that runs it, run the start on that Mac.
    @Test func aMemberWhoseAPIDoesNotAnswerSaysWhy() async throws {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            for bind in ["0.0.0.0", "127.0.0.1"] {
                let sandbox = try ToolSandbox()
                var pair = ClusterPairSummary(paired: true, role: .member, otherMacName: "Apple M5 Ultra, 256 GB",
                                              modelID: "qwen", modelName: "Qwen 3.8 27B", started: true,
                                              serviceRunning: true, state: .serving)
                pair.localAPI = ClusterPairLocalAPI(runsRankZero: false, listening: nil, meFirst: nil)
                pair.localAPIBind = bind
                print("--- \(bind)")
                let start = try Start.parse(["--opencode", "--config", sandbox.config.path])
                do {
                    try await start.setUpToolsBesidePair(pair: pair, waitForAPI: { .notUp }, step: sandbox.step())
                    print("--- set up")
                } catch {}
            }
            exit(0)
        }
        let stdout = String(decoding: result?.standardOutputContent ?? [], as: UTF8.self)
        let notUp = ToolIntegrationStep.notUp([.opencode], seconds: Start.toolWaitSeconds)
        let elsewhere = ToolIntegrationStep.pairAPIElsewhere([.opencode], bind: "127.0.0.1")
        #expect(stdout.contains("--- 0.0.0.0\n\(notUp)\n\(ToolIntegrationStep.keepsServing)\n"), "\(stdout)")
        #expect(stdout.contains("--- 127.0.0.1\n\(elsewhere)\n\(ToolIntegrationStep.keepsServing)\n"), "\(stdout)")
        #expect(!stdout.contains("--- set up"), "\(stdout)")
    }

    // MARK: - The leading part's keys

    /// The part that runs the pair's API takes this Mac's own key (its tools' key) and the pair's (every relay's);
    /// either one that can't be read keeps the API closed and Darkbloom serving.
    @Test func theLeadingPartTakesItsOwnKeyAndThePairs() {
        var said: [String] = []
        let file = URL(fileURLWithPath: "/tmp/member-relay/provider.toml")
        let leader = Start.clusterMemberLocalEndpoint(requested: true, hostsPairSlot: true, bind: "0.0.0.0", port: 8003,
            local: nil, settingsFile: file, coordinatorURL: nil, loadToken: { "dk-local-own" }, loadPairToken: { "dk-local-pair" },
            say: { said.append($0) })
        #expect(leader?.authToken == "dk-local-own")
        #expect(leader?.pairToken == "dk-local-pair")
        #expect(said.isEmpty)
        for (own, pair) in [(false, true), (true, false)] {
            let closed = Start.clusterMemberLocalEndpoint(requested: true, hostsPairSlot: true, bind: "0.0.0.0", port: 8003,
                local: nil, settingsFile: file, coordinatorURL: nil,
                loadToken: { if own { return "dk-local-own" }; throw CocoaError(.fileReadNoPermission) },
                loadPairToken: { if pair { return "dk-local-pair" }; throw CocoaError(.fileReadNoPermission) },
                say: { said.append($0) })
            #expect(closed == nil, "own key read: \(own), pair key read: \(pair)")
        }
        #expect(said.count == 2)
    }
}

/// A temp home with this Mac's key file and a provider config, and a scripted tool step that records what it read and
/// said. No tool runs, no port is bound, and no real home or tool config is touched.
private final class ToolSandbox: @unchecked Sendable {
    let directory: TemporaryDirectory
    let token = ToolIntegrationFixtures.freshToken()
    let home: URL
    let keyFile: URL
    let config: URL
    private let lock = NSLock()
    private var lines: [String] = []
    private var reads: [IntegrationEndpoint] = []
    private var waitCount = 0

    init() throws {
        directory = try TemporaryDirectory("member-relay-tools")
        home = directory.file("home")
        keyFile = try directory.write(token, to: "home/.darkbloom/local_token", mode: 0o600)
        config = try directory.write("[provider]\nname = \"member\"\n\n[local]\nroute = \"my-macs-first\"\n", to: "provider.toml")
    }

    var said: [String] { lock.withLock { lines } }
    var fetched: [IntegrationEndpoint] { lock.withLock { reads } }
    /// How often the start waited for this Mac's local API.
    var waits: Int { lock.withLock { waitCount } }
    func waited() { lock.withLock { waitCount += 1 } }
    var openCodeFile: URL { home.appendingPathComponent(".config/opencode/opencode.jsonc") }

    func step() -> ToolIntegrationStep {
        ToolIntegrationStep(
            tools: [.opencode], environment: ToolIntegrationEnvironment(home: home, variables: [:]),
            provider: ToolIntegrationFixtures.provider,
            findTool: { _ in .installed(URL(fileURLWithPath: "/fake/opencode")) },
            fetchModels: { endpoint in
                self.lock.withLock { self.reads.append(endpoint) }
                return [EndpointModel(id: "qwen3.8-27b", ownedBy: "this-mac", contextLength: 131_072)]
            },
            fetchCatalog: { nil },
            say: { line in self.lock.withLock { self.lines.append(line) } })
    }
}
