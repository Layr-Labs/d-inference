import ArgumentParser
import Foundation
import ProviderCore
import Testing

@testable import darkbloom

/// `darkbloom route this-mac|my-macs|my-macs-first`: saves `[local] route` without a hand-edited provider.toml, says in
/// plain words where your requests go, and refuses a route that passes requests on while no account key is saved.
/// Every test writes a temporary provider.toml and stands in for the Keychain; no key is ever read or printed.
@Suite("route <choice>")
struct RouteChoiceCommandTests {
    typealias Lines = RouteKeyCommandTests.Lines

    static var cli: String { BuildEnvironment.current.cliName }

    private func makeTempConfig(_ toml: String = "[provider]\nname = \"route-test\"\n") throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("route-choice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("provider.toml")
        try toml.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func flow(config url: URL, keySaved: Bool, live: LocalEndpoint.Info? = nil,
                      pair: RouteSaved.PairPart? = nil) -> (RouteChoiceFlow, Lines) {
        let lines = Lines()
        let flow = RouteChoiceFlow(
            accountKeySaved: { keySaved },
            save: { route in try setLocalSettings(configPath: url.path) { $0.route = route }.changed },
            liveEndpoint: live, pair: pair, say: { lines.append($0) })
        return (flow, lines)
    }

    @Test func eachChoiceParsesBesideRouteKey() throws {
        #expect(try Darkbloom.parseAsRoot(["route", "this-mac"]) is RouteThisMac)
        #expect(try Darkbloom.parseAsRoot(["route", "my-macs"]) is RouteMyMacs)
        #expect(try Darkbloom.parseAsRoot(["route", "my-macs-first"]) is RouteMyMacsFirst)
        #expect(try Darkbloom.parseAsRoot(["route", "my-macs", "--config", "/tmp/provider.toml"]) is RouteMyMacs)
        #expect(try Darkbloom.parseAsRoot(["route", "key", "--stdin"]) is RouteKey)
        #expect(throws: (any Error).self) { try Darkbloom.parseAsRoot(["route", "everywhere"]) }
        // What each saves is the route it is named after: `route my-macs` never saves the paid route.
        #expect(RouteThisMac.route == .thisMac && RouteMyMacs.route == .myMacs)
        #expect(RouteMyMacsFirst.route == .myMacsFirst)
    }

    @Test func aChoiceIsSavedAsTheLocalRouteAndKeepsTheRestOfTheFile() throws {
        let url = try makeTempConfig("[provider]\nname = \"route-test\"\n\n[local]\nmode = \"both\"\nport = 8003\n")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (flow, lines) = flow(config: url, keySaved: true)

        #expect(flow.choose(.myMacsFirst) == 0)
        let config = try ConfigManager.load(from: url)
        #expect(config.local == LocalSettings(mode: .both, route: .myMacsFirst, port: 8003))
        #expect(config.provider.name == "route-test")
        #expect(lines.all.first == "✓ Saved. It applies when your local API starts.")

        #expect(flow.choose(.thisMac) == 0)
        #expect(try ConfigManager.load(from: url).local?.route == .thisMac)
    }

    @Test func theSameChoiceAgainChangesNothing() throws {
        let url = try makeTempConfig("[local]\nroute = \"my-macs\"\n")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let before = try Data(contentsOf: url)
        let (flow, lines) = flow(config: url, keySaved: true)
        #expect(flow.choose(.myMacs) == 0)
        #expect(try Data(contentsOf: url) == before)
        #expect(lines.all.first == "✓ Already saved. It applies when your local API starts.")
    }

    @Test(arguments: [LocalSettings.Route.myMacs, .myMacsFirst])
    func aRouteThatPassesRequestsOnNeedsASavedAccountKey(_ route: LocalSettings.Route) throws {
        let url = try makeTempConfig()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let before = try Data(contentsOf: url)
        let (flow, lines) = flow(config: url, keySaved: false)

        #expect(flow.choose(route) == 1)
        #expect(try Data(contentsOf: url) == before)
        #expect(lines.all.first?.hasPrefix("✗ Not saved: ") == true)
        #expect(lines.text.contains("`\(Self.cli) route key`"))
        #expect(lines.text.contains("`\(Self.cli) route \(route.rawValue)` again"))
    }

    @Test func thisMacNeedsNoAccountKey() throws {
        let url = try makeTempConfig()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (flow, lines) = flow(config: url, keySaved: false)
        #expect(flow.choose(.thisMac) == 0)
        #expect(try ConfigManager.load(from: url).local?.route == .thisMac)
        #expect(lines.text.contains("stay on this Mac"))
    }

    @Test func eachChoiceSaysWhatItMeansInPlainWords() throws {
        func said(_ route: LocalSettings.Route) throws -> String {
            let url = try makeTempConfig()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let (flow, lines) = flow(config: url, keySaved: true)
            #expect(flow.choose(route) == 0)
            return lines.text
        }
        let thisMac = try said(.thisMac), myMacs = try said(.myMacs), first = try said(.myMacsFirst)
        #expect(thisMac.contains("Your requests stay on this Mac"))
        #expect(myMacs.contains("your other Macs, free"))
        #expect(myMacs.contains("never goes to the Darkbloom network"))
        #expect(first.contains("then to the Darkbloom network, billed to your balance"))
        #expect(first.contains("Requests from other machines (your LAN or tailnet) never use the paid network"))
        for words in [thisMac, myMacs, first] {
            #expect(!words.contains("tok/s") && !words.lowercased().contains("tokens per second"))
            #expect(!words.contains("dk-local-") && !words.contains("sk-"))
        }
    }

    static let keyed = LocalEndpoint.Info(host: "127.0.0.1", port: 8001, apiKey: "dk-local-fixture", version: "test",
                                          pid: 4242, updatedAt: "now")

    @Test func aRunningLocalAPIUsesTheSavedRouteNowWithNoRestart() throws {
        let url = try makeTempConfig()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let keyed = Self.keyed
        let (flow, lines) = flow(config: url, keySaved: true, live: keyed)
        #expect(flow.choose(.myMacs) == 0)
        #expect(lines.all.first == "✓ Saved. Your local API uses it now.")
        #expect(!lines.text.contains("restart"))
        #expect(!lines.text.contains("dk-local-fixture"))
        let (again, againLines) = self.flow(config: url, keySaved: true, live: keyed)
        #expect(again.choose(.myMacs) == 0)
        #expect(againLines.all.first == "✓ Already saved. Your local API uses it now.")

        var keyless = keyed
        keyless.apiKey = ""
        let (open, openLines) = self.flow(config: url, keySaved: true, live: keyless)
        #expect(open.choose(.myMacsFirst) == 0)
        #expect(openLines.all.first == "✓ Saved.")
        #expect(openLines.text.contains("has no local key (--no-auth): it keeps every request on this Mac"))
    }

    @Test func inAPairTheLeadingMacsRouteApplies() throws {
        let url = try makeTempConfig()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let other = "the other Mac (Apple M3 Ultra, 256 GB)"
        // The Mac that follows: saved for when it serves alone; the pair uses the leading Mac's.
        let (follower, followerLines) = flow(config: url, keySaved: true, live: Self.keyed, pair: .follows(leader: other))
        #expect(follower.choose(.myMacs) == 0)
        #expect(try ConfigManager.load(from: url).local?.route == .myMacs)
        #expect(followerLines.all.first == "✓ Saved. It applies when this Mac serves alone (`\(Self.cli) start --solo`).")
        // It can't know the leading Mac's route or key, so it says only whose route decides.
        #expect(followerLines.all.last == "In this pair, the leading Mac's route applies (\(other)): its route decides "
            + "what the pair passes on, including requests from this Mac. Run `\(Self.cli) route my-macs` there.")
        // The leading Mac runs the pair's API: it uses the route now.
        let leaderURL = try makeTempConfig()
        defer { try? FileManager.default.removeItem(at: leaderURL.deletingLastPathComponent()) }
        let (leader, leaderLines) = flow(config: leaderURL, keySaved: true, live: Self.keyed, pair: .leads(other: other))
        #expect(leader.choose(.myMacs) == 0)
        #expect(leaderLines.all.first == "✓ Saved. Your local API uses it now.")
        #expect(leaderLines.all.last == "In this pair, this Mac's route applies: the pair's local API runs here and passes "
            + "on what the pair can't take, including requests from \(other).")
        // With `this-mac`, the pair's API passes nothing on.
        let (pinned, pinnedLines) = flow(config: url, keySaved: true, live: Self.keyed, pair: .leads(other: other))
        #expect(pinned.choose(.thisMac) == 0)
        #expect(pinnedLines.all.last == "In this pair, this Mac's route applies: the pair's local API runs here and passes "
            + "nothing on, including requests from \(other).")
        // No line says the other Mac forwards anything: a Both pair's other Mac runs no relay.
        #expect(!(followerLines.text + leaderLines.text + pinnedLines.text).contains("forwards"))
    }

    /// The pair's other Mac is another machine to the leading Mac's API: with `my-macs-first`, its requests go to your
    /// other Macs, never to the paid network, and both Macs say so.
    @Test func inAPairMyMacsFirstNeverPaysForTheOtherMacsRequests() throws {
        let url = try makeTempConfig()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let other = "the other Mac (Apple M3 Ultra, 256 GB)"
        let (leader, leaderLines) = flow(config: url, keySaved: true, live: Self.keyed, pair: .leads(other: other))
        #expect(leader.choose(.myMacsFirst) == 0)
        #expect(leaderLines.all.last == "In this pair, this Mac's route applies: the pair's local API runs here and passes "
            + "on what the pair can't take, including requests from \(other); to this Mac those come from another "
            + "machine, so they never use the paid network.")
        let (follower, followerLines) = flow(config: url, keySaved: true, live: Self.keyed, pair: .follows(leader: other))
        #expect(follower.choose(.myMacsFirst) == 0)
        #expect(followerLines.all.last == "In this pair, the leading Mac's route applies (\(other)): its route decides "
            + "what the pair passes on, including requests from this Mac; to the leading Mac those come from another "
            + "machine, so they never use the paid network. Run `\(Self.cli) route my-macs-first` there.")
    }

    /// On the Mac that follows, a route refused for want of a key says first that the pair's route and key are the
    /// leading Mac's, so no key is saved on the wrong Mac for the pair; a single Mac and the leading Mac say as before.
    @Test func onTheMacThatFollowsTheNoKeyRefusalNamesTheLeadingMac() throws {
        let url = try makeTempConfig()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let before = try Data(contentsOf: url)
        let leading = "the leading Mac (Apple M3 Ultra, 256 GB)"
        let (follower, lines) = flow(config: url, keySaved: false, live: Self.keyed, pair: .follows(leader: leading))
        #expect(follower.choose(.myMacs) == 1)
        #expect(try Data(contentsOf: url) == before)
        #expect(lines.all == [
            "✗ Not saved: `\(Self.cli) route my-macs` passes your requests on with your account API key, and this Mac has "
                + "none saved.",
            "In this pair, the leading Mac's route and key apply (\(leading)): for the pair, run `\(Self.cli) route key` "
                + "and `\(Self.cli) route my-macs` there.",
            "For this Mac alone (`\(Self.cli) start --solo`), save one here from the Darkbloom console with "
                + "`\(Self.cli) route key` (a self-route-only key is safest), then run `\(Self.cli) route my-macs` again.",
        ])
        let saveHere = "Save one from the Darkbloom console with `\(Self.cli) route key` (a self-route-only key is safest), "
            + "then run `\(Self.cli) route my-macs-first` again."
        for pair in [RouteSaved.PairPart?.none, .leads(other: "the other Mac")] {
            let (flow, lines) = flow(config: url, keySaved: false, live: Self.keyed, pair: pair)
            #expect(flow.choose(.myMacsFirst) == 1)
            #expect(lines.all.count == 2 && lines.all.last == saveHere, "\(String(describing: pair))")
        }
    }

    /// The pair's local API on the leading Mac without a local key (`cluster local --no-auth`) passes nothing on, so no
    /// line says it does.
    @Test func aLeadingMacWithoutALocalKeyNeverClaimsToPassRequestsOn() throws {
        let url = try makeTempConfig()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var keyless = Self.keyed
        keyless.apiKey = ""
        let (leader, lines) = flow(config: url, keySaved: true, live: keyless, pair: .leads(other: "the other Mac"))
        #expect(leader.choose(.myMacs) == 0)
        #expect(try ConfigManager.load(from: url).local?.route == .myMacs)
        #expect(lines.all.first == "✓ Saved.")
        // That API is the pair's: it keeps every request on the pair, not on this Mac alone.
        #expect(lines.all.last == "The local API running now has no local key (--no-auth): it keeps every request on "
            + "this pair, whatever the route.")
        #expect(!lines.text.contains("passes on"))
    }

    @Test func aRefusedFileSaysWhyAndChangesNothing() throws {
        let url = try makeTempConfig("[local]\nmode = \"elsewhere\"\n")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let before = try Data(contentsOf: url)
        let (flow, lines) = flow(config: url, keySaved: true)
        #expect(flow.choose(.myMacs) == 1)
        #expect(try Data(contentsOf: url) == before)
        #expect(lines.all.first?.hasPrefix("✗ Not saved: ") == true)
        #expect(lines.text.contains("[local] mode must be"))
    }

    /// Every local API's router reads its route again from the provider.toml its start loaded: Only me's, Both's, the
    /// pair's beside Darkbloom and `cluster local`'s. Each start passes that file to the function tested here, which
    /// takes it as a `URL` (never optional), so a start that drops it doesn't build.
    @Test func eachLocalAPIsRouterReadsTheConfigFileItCameFrom() throws {
        let file = URL(fileURLWithPath: "/tmp/route-choice-wiring/provider.toml")
        let config = ProviderConfig(provider: ProviderSettings(name: "wiring"))
        let onlyMe = Start.onlyMeRouter(config: config, configFile: file, coordinatorURL: nil)
        #expect(onlyMe.settingsFile == file)
        #expect(!onlyMe.takesCoordinatorWork, "Only me never registers, so a `self` request can't come back to it")
        let serving = StartServing(mode: .both, source: .saved, meFirst: true, meFirstIdleMinutes: 2, route: .myMacs,
                                   accountKeySaved: true, port: 8001, bind: "127.0.0.1", noAuth: false)
        let both = try #require(try Start.unifiedLocalEndpoint(
            serving: serving, config: config, settingsFile: file,
            coordinatorURL: "wss://coordinator.invalid/ws/provider", loadToken: { "dk-local-fixture" }))
        #expect(both.router?.settingsFile == file)
        let pair = Start.clusterMemberLocalEndpoint(requested: true, hostsPairSlot: true, bind: "0.0.0.0", port: 8001,
                                                    local: nil, settingsFile: file, coordinatorURL: nil,
                                                    loadToken: { "dk-local-fixture" }, say: { _ in })
        #expect(pair?.router?.settingsFile == file)
        // `cluster local` loads `[local]` and the coordinator from that file itself, and has today's defaults without it.
        let saved = try makeTempConfig(
            "[local]\nroute = \"my-macs-first\"\n\n[coordinator]\nurl = \"wss://saved.invalid/ws/provider\"\n")
        defer { try? FileManager.default.removeItem(at: saved.deletingLastPathComponent()) }
        let clusterLocal = Start.clusterLocalRouter(configFile: saved, coordinatorURL: nil)
        #expect(clusterLocal.settingsFile == saved && clusterLocal.settings.route == .myMacsFirst)
        #expect(clusterLocal.upstreamBaseURL == URL(string: "https://saved.invalid"))
        #expect(!clusterLocal.takesCoordinatorWork)
        let fresh = Start.clusterLocalRouter(configFile: file, coordinatorURL: "wss://flag.invalid/ws/provider")
        #expect(fresh.settingsFile == file && fresh.settings == LocalSettings())
        #expect(fresh.upstreamBaseURL == URL(string: "https://flag.invalid"))
    }

    /// Each Mac's part comes from its pairing role: the leading Mac's lines name the other Mac, the other Mac's name the
    /// leading one. A Mac in no pair, or whose pairing or role can't be read, has none.
    @Test func eachMacsPartInAPairComesFromItsRole() {
        let leading = ClusterPairSummary(paired: true, role: .leader, otherMacName: "Apple M3 Ultra, 256 GB")
        #expect(RouteSaved.PairPart.of(leading) == .leads(other: leading.otherMac))
        let following = ClusterPairSummary(paired: true, role: .member, otherMacName: "Apple M5 Max, 128 GB")
        #expect(RouteSaved.PairPart.of(following) == .follows(leader: following.otherMac))
        #expect(RouteSaved.PairPart.of(.notPaired) == nil)
        #expect(RouteSaved.PairPart.of(ClusterPairSummary(paired: true, role: .leader, state: .pairingUnreadable)) == nil)
        #expect(RouteSaved.PairPart.of(ClusterPairSummary(paired: true)) == nil)
    }

    @Test func routeKeyNamesTheCommandThatChoosesYourMacs() {
        let line = RouteKeyFlow.routeLines(savedRoute: .thisMac, keySaved: true).joined()
        #expect(line.contains("`\(Self.cli) route my-macs`"))
    }
}
