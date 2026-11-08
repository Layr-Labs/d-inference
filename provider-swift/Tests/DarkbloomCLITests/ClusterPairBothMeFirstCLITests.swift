import ArgumentParser
import Foundation
import ProviderCore
import Testing
import TOMLKit

@testable import darkbloom

/// A pair served through Darkbloom can also run its leader's local API, with Darkbloom paused while the owner uses it
/// ("Both, me first"). The CLI side: the leading part's flags and API, the answer saved in `[local]`, `cluster local`
/// unchanged, and the plain words `status` and `cluster status` say.
@Suite("Cluster pair: Both, me first (CLI)")
struct ClusterPairBothMeFirstCLITests {
    typealias F = LocalFirstStatusFixtures

    // MARK: - The leading part

    @Test("the cluster service's part takes the local API's flags", arguments: [
        ["--foreground", "--cluster-member", "--local-endpoint", "--port", "8001", "--bind", "0.0.0.0"],
        ["--foreground", "--cluster-member", "--config", "/fixture/provider.toml", "--local-endpoint", "--port", "8019",
         "--bind", "127.0.0.1"],
    ])
    func thePartAcceptsTheLocalAPIFlags(arguments: [String]) throws {
        let part = try Start.parse(arguments)
        #expect(part.clusterMember && part.localEndpoint && !part.local && !part.noAuth)
    }

    @Test("nothing weakens or replaces the pair's local API", arguments: [
        ["--cluster-member", "--local-endpoint", "--no-auth"], ["--cluster-member", "--local"],
        ["--cluster-member", "--local", "--local-endpoint"], ["--cluster-member", "--distributed", "--local"],
        ["--cluster-member", "--local-endpoint", "--always-on"],
        ["--foreground", "--cluster-member", "--local-endpoint", "--supervise"],
        ["--cluster-member", "--me-first"], ["--cluster-member", "--local-endpoint", "--me-first-idle", "5"],
    ])
    func refusals(arguments: [String]) {
        #expect(throws: (any Error).self) { _ = try Start.parse(arguments) }
    }

    @Test func onlyThePartThatHostsThePairsSlotStartsTheLocalAPI() {
        var said: [String] = []
        let leader = Start.clusterMemberLocalEndpoint(requested: true, hostsPairSlot: true, bind: "0.0.0.0", port: 8001,
            local: LocalSettings(route: .thisMac), coordinatorURL: "wss://example.invalid/ws/provider",
            loadToken: { "dk-cluster-fixture" }, say: { said.append($0) })
        #expect(leader?.host == "0.0.0.0" && leader?.port == 8001)
        #expect(leader?.authToken == "dk-cluster-fixture", "always the pair's key, as `cluster local`")
        #expect(leader?.router != nil, "the local router rides along: this Mac's engine is the pair")
        #expect(leader?.router?.takesCoordinatorWork == true, "Both: the pair takes Darkbloom work beside the API")
        #expect(said.isEmpty)

        // Every other member: no API, no key read, one line.
        var loads = 0
        let other = Start.clusterMemberLocalEndpoint(requested: true, hostsPairSlot: false, bind: "0.0.0.0", port: 8001,
            local: nil, coordinatorURL: nil, loadToken: { loads += 1; return "dk" }, say: { said.append($0) })
        #expect(other == nil && loads == 0 && said.count == 1)

        // Today's member, without --local-endpoint: nothing at all.
        let today = Start.clusterMemberLocalEndpoint(requested: false, hostsPairSlot: true, bind: "127.0.0.1", port: 8000,
            local: nil, coordinatorURL: nil, loadToken: { loads += 1; return "dk" }, say: { said.append($0) })
        #expect(today == nil && loads == 0 && said.count == 1)

        // A key that can't be read: Darkbloom keeps serving, and the API never opens without its key.
        let keyless = Start.clusterMemberLocalEndpoint(requested: true, hostsPairSlot: true, bind: "0.0.0.0", port: 8001,
            local: nil, coordinatorURL: nil, loadToken: { throw CocoaError(.fileWriteNoPermission) }, say: { said.append($0) })
        #expect(keyless == nil && said.count == 2)
    }

    // MARK: - The answer, saved in [local]

    @Test func theAnswerIsSavedAsLocalModeAndNothingElseChanges() throws {
        let url = try makeTempConfig("""
            [provider]
            name = "pair-test"

            [local]
            me_first_idle_minutes = 5
            port = 8009
            future_local_key = "kept"
            """)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(Cluster.Setup.servingChoiceAsk(config: url.path) == ClusterServingChoiceAsk(saved: nil, idleMinutes: 5))

        guard case .success = Cluster.Setup.saveServingChoice(.bothMeFirst, config: url.path) else {
            Issue.record("the answer was not saved")
            return
        }
        let written = try String(contentsOf: url, encoding: .utf8)
        #expect(try ConfigManager.load(from: url).local == LocalSettings(mode: .both, meFirstIdleMinutes: 5, port: 8009))
        #expect(try TOMLTable(string: written)["local"]?.table?["future_local_key"]?.string == "kept")
        #expect(try ConfigManager.load(from: url).provider.name == "pair-test")
        #expect(Cluster.Setup.servingChoiceAsk(config: url.path) == ClusterServingChoiceAsk(saved: .bothMeFirst, idleMinutes: 5))

        for choice in [ClusterServingChoice.onlyMe, .network] {
            _ = Cluster.Setup.saveServingChoice(choice, config: url.path)
            #expect(try ConfigManager.load(from: url).local?.mode?.rawValue == choice.rawValue)
        }
    }

    @Test func withNothingSavedTheQuestionPreselectsBothAndTwoMinutes() throws {
        let url = try makeTempConfig("[provider]\nname = \"pair-test\"\n")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(Cluster.Setup.servingChoiceAsk(config: url.path) == ClusterServingChoiceAsk(saved: nil, idleMinutes: 2))
    }

    /// Plain `darkbloom cluster` (and `darkbloom start` on a paired Mac) in a terminal asks; `cluster local` never does,
    /// and keeps serving locally only on every interface, as before.
    @Test func onlyPlainClusterAsksAndClusterLocalIsUnchanged() throws {
        #expect(Cluster.Setup.asksServingChoice(request: .init()))
        let local = try Cluster.Local.parse([])
        #expect(local.onboardingRequest.scope == .localOnly(bind: "0.0.0.0"))
        #expect(!Cluster.Setup.asksServingChoice(request: local.onboardingRequest))
        let bound = try Cluster.Local.parse(["--bind", "127.0.0.1", "qwen"])
        #expect(bound.onboardingRequest.scope == .localOnly(bind: "127.0.0.1") && bound.onboardingRequest.model == "qwen")
        #expect(!Cluster.Setup.asksServingChoice(request: bound.onboardingRequest))
    }

    // MARK: - Status

    /// This Mac's part runs rank 0, so the pair's API and its pause are here.
    private func leader(listening: ClusterPairLocalAPI.Address? = ClusterPairLocalAPI.Address(host: "0.0.0.0", port: 8001),
                        meFirst: MeFirstSnapshot? = F.paused, started: Bool = true) -> ClusterPairSummary {
        var pair = ClusterPairSummary(paired: true, role: .leader, otherMacName: "Apple M3 Ultra, 256 GB",
                                      modelID: "qwen", modelName: "Qwen 3.8 27B", started: started, serviceRunning: true,
                                      state: started ? .serving : .stopped)
        pair.lines = started ? ["Serving Qwen 3.8 27B through Darkbloom on both Macs (tensor parallel)."] : ["Stopped; last model Qwen 3.8 27B."]
        pair.localAPI = ClusterPairLocalAPI(runsRankZero: true, listening: listening, meFirst: meFirst)
        return pair
    }

    /// The Mac that follows: its part doesn't run rank 0, so the pair's API and its pause are on the other Mac.
    private func member() -> ClusterPairSummary {
        var pair = leader()
        pair.role = .member
        pair.localAPI = ClusterPairLocalAPI(runsRankZero: false, listening: nil, meFirst: nil)
        return pair
    }

    @Test func theLeadingPartsMacSaysWhetherThePairIsPausedItsAddressAndTheMembers() {
        let paused = leader().localAPILines(now: F.now)
        #expect(paused == [
            "Pair: you first — Darkbloom paused for 10 minutes (your last request 1 minute ago; back in about 1 minute if you "
                + "stay idle)",
            "Local API: http://127.0.0.1:8001/v1 on this Mac, and port 8001 of its LAN or tailnet address (`\(ClusterPairSummary.cli) local` shows the key)",
            "Members: the other Mac (Apple M3 Ultra, 256 GB) is part of the pair; it runs no local API",
        ])
        let open = leader(listening: ClusterPairLocalAPI.Address(host: "127.0.0.1", port: 8002), meFirst: F.open).localAPILines(now: F.now)
        #expect(open == [
            "Pair: Darkbloom and you, me first — open to Darkbloom (none of your requests in the last 2 minutes)",
            "Local API: http://127.0.0.1:8002/v1 on this Mac (`\(ClusterPairSummary.cli) local` shows the key)",
            "Members: the other Mac (Apple M3 Ultra, 256 GB) is part of the pair; it runs no local API",
        ])
        let finishing = MeFirstSnapshot(idleMs: 120_000, paused: true, sinceMs: F.ms(14, 2), lastUseMs: F.ms(14, 11),
                                        localRequestsInFlight: 1, darkbloomRequestsFinishing: 2)
        #expect(leader(meFirst: finishing).localAPILines(now: F.now).prefix(2) == [
            "Pair: you first — Darkbloom paused for 10 minutes (your request is running; back 2 minutes after it ends)",
            "      2 Darkbloom requests are finishing",
        ])
        #expect(leader(meFirst: nil).localAPILines(now: F.now).first
            == "Pair: Darkbloom and you, shared — Darkbloom keeps serving while you use the pair (me first is off)")
        #expect(leader(listening: nil, meFirst: nil).localAPILines(now: F.now) == [
            "Local API: not listening yet; it starts with this Mac's part of the pair",
            "Members: the other Mac (Apple M3 Ultra, 256 GB) is part of the pair; it runs no local API",
        ])
        // A stopped pair says how it serves, and nothing about an API that doesn't run.
        #expect(leader(started: false).localAPILines(now: F.now).isEmpty)
    }

    @Test func aMemberSaysItIsPartOfThePairAndWhereTheAPIIs() {
        // An older leading Mac's status, which doesn't say whether the pair is paused: where to look.
        #expect(member().localAPILines(now: F.now) == [
            "Local API: on the other Mac (Apple M3 Ultra, 256 GB), which runs the pair's API; `\(ClusterPairSummary.cli) local` "
                + "there shows its address and key, and `\(ClusterPairSummary.cli) status` there whether Darkbloom is paused for you",
            "Members: this Mac is part of the pair; it runs no local API",
        ])
    }

    /// Journey 2a (pair-2, J2-h): while the pair was paused for its owner, the Mac that follows said only "✓ Serving …
    /// through Darkbloom". The leading Mac's status, which every status read on the other Mac asks for anyway, carries
    /// the pause (`OnboardingLive.pauseLines`): that Mac says it under the pair's line, and points to the leading Mac
    /// only for its address and key.
    @Test("the Mac that follows says the pair is paused for its owner, for how long and when it comes back, from the leading Mac's status")
    func aMemberSaysThePause() {
        var pair = member()
        pair.lines = Self.pausedStatus
        let lines = pair.clusterStatusLines
        #expect(lines.contains("\u{2713} Serving Qwen 3.8 27B through Darkbloom on both Macs (tensor parallel)."), "\(lines)")
        #expect(lines.contains("  " + Self.pausedStatus[1]), "\(lines)")
        #expect(lines.contains("Local API: on the other Mac (Apple M3 Ultra, 256 GB), which runs the pair's API; "
            + "`\(ClusterPairSummary.cli) local` there shows its address and key"), "\(lines)")
        #expect(!lines.joined(separator: "\n").contains("whether Darkbloom is paused"), "\(lines)")
        #expect(lines.filter { $0.contains("Pair: ") }.count == 1, "\(lines)")
    }

    /// The Mac whose part runs rank 0 and leads reads its own status: the pause is said once, there.
    @Test("the leading Mac says the pause once when its status already carries it")
    func theLeaderSaysThePauseOnce() {
        var pair = leader()
        pair.lines = Self.pausedStatus
        #expect(pair.localAPILines(now: F.now) == [
            "Local API: http://127.0.0.1:8001/v1 on this Mac, and port 8001 of its LAN or tailnet address (`\(ClusterPairSummary.cli) local` shows the key)",
            "Members: the other Mac (Apple M3 Ultra, 256 GB) is part of the pair; it runs no local API",
        ])
        let lines = pair.clusterStatusLines
        #expect(lines.filter { $0.contains("Pair: ") } == ["  " + Self.pausedStatus[1]], "\(lines)")
    }

    /// The leading Mac's status while the pair is paused, as `OnboardingLive.localStatus` writes it.
    static let pausedStatus = [
        "Serving Qwen 3.8 27B through Darkbloom on both Macs (tensor parallel).",
        "Pair: you first — Darkbloom paused for 1 minute (your last request under a minute ago; back in about 2 minutes if you stay idle)",
    ]

    /// The address a tool dials: an API that listens on ::1 alone isn't reached at 127.0.0.1 (review N8).
    @Test func anAPIOnIPv6LoopbackIsDialledThere() {
        #expect(ClusterPairSummary.addressLine(.init(host: "::1", port: 8003))
            == "Local API: http://[::1]:8003/v1 on this Mac (`\(ClusterPairSummary.cli) local` shows the key)")
        #expect(ClusterPairSummary.addressLine(.init(host: "localhost", port: 8003))
            == "Local API: http://127.0.0.1:8003/v1 on this Mac (`\(ClusterPairSummary.cli) local` shows the key)")
    }

    @Test func clusterStatusSaysBothBeforeWhatToDoNext() {
        let lines = leader().clusterStatusLines
        #expect(lines.contains("Serves: through Darkbloom, and on its local API with you first"))
        guard let pause = lines.firstIndex(where: { $0.hasPrefix("Pair: ") }),
              let next = lines.firstIndex(where: { $0.hasPrefix("Next: ") }) else {
            Issue.record("no pause or next line: \(lines)")
            return
        }
        #expect(pause < next)
        #expect(lines.contains { $0.hasPrefix("Local API: http://127.0.0.1:8001/v1") })
        // The Darkbloom network and local only: no new line.
        var network = leader()
        network.localAPI = nil
        #expect(!network.clusterStatusLines.contains { $0.hasPrefix("Pair: ") || $0.hasPrefix("Local API: ") || $0.hasPrefix("Members: ") })
        #expect(network.servesWords == "through Darkbloom")
    }

    /// Owner rule: no speed anywhere, and never the key.
    @Test func noSpeedAndNoKeyInAnyLine() {
        var lines: [String] = []
        let snapshots: [MeFirstSnapshot?] = [nil, F.open, F.paused,
            MeFirstSnapshot(idleMs: 60_000, paused: true, sinceMs: F.ms(14, 2), lastUseMs: F.ms(14, 11),
                            localRequestsInFlight: 3, darkbloomRequestsFinishing: 3)]
        for snapshot in snapshots {
            let addresses: [ClusterPairLocalAPI.Address?] = [ClusterPairLocalAPI.Address(host: "0.0.0.0", port: 8001),
                ClusterPairLocalAPI.Address(host: "127.0.0.1", port: 8001), ClusterPairLocalAPI.Address(host: "100.64.0.9", port: 8020), nil]
            for listening in addresses {
                for rankZero in [true, false] {
                    var pair = leader(listening: listening, meFirst: snapshot)
                    pair.localAPI?.runsRankZero = rankZero
                    lines += pair.localAPILines(now: F.now) + pair.clusterStatusLines + [pair.statusLine, pair.pairSentence]
                }
            }
        }
        let text = lines.joined(separator: "\n")
        for said in ["Pair: you first", "Local API: http://", "Members: ", "Serves: through Darkbloom, and on its local API"] {
            #expect(text.contains(said), "the check covers \(said)")
        }
        #expect(!text.contains("tok/s"))
        #expect(!text.lowercased().contains("tokens per second"))
        #expect(text.range(of: #"[0-9][0-9.,]*\s*[A-Za-z]*/s\b"#, options: .regularExpression) == nil, "a number per second: \(text)")
        #expect(!text.contains("dk-"), "a key")
    }

    private func makeTempConfig(_ toml: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pair-both-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("provider.toml")
        try toml.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
