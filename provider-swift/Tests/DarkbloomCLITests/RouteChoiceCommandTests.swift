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
    final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        var all: [String] { lock.withLock { stored } }
        var text: String { all.joined(separator: "\n") }
        func append(_ line: String) { lock.withLock { stored.append(line) } }
    }

    static var cli: String { BuildEnvironment.current.cliName }

    private func makeTempConfig(_ toml: String = "[provider]\nname = \"route-test\"\n") throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("route-choice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("provider.toml")
        try toml.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func flow(config url: URL, keySaved: Bool, live: LocalEndpoint.Info? = nil,
                      pairLeader: String? = nil) -> (RouteChoiceFlow, Lines) {
        let lines = Lines()
        let flow = RouteChoiceFlow(
            accountKeySaved: { keySaved },
            save: { route in try setLocalSettings(configPath: url.path) { $0.route = route }.changed },
            liveEndpoint: live, pairLeader: pairLeader, say: { lines.append($0) })
        return (flow, lines)
    }

    @Test func eachChoiceParsesBesideRouteKey() throws {
        #expect(try Darkbloom.parseAsRoot(["route", "this-mac"]) is RouteThisMac)
        #expect(try Darkbloom.parseAsRoot(["route", "my-macs"]) is RouteMyMacs)
        #expect(try Darkbloom.parseAsRoot(["route", "my-macs-first"]) is RouteMyMacsFirst)
        #expect(try Darkbloom.parseAsRoot(["route", "my-macs", "--config", "/tmp/provider.toml"]) is RouteMyMacs)
        #expect(try Darkbloom.parseAsRoot(["route", "key", "--stdin"]) is RouteKey)
        #expect(throws: (any Error).self) { try Darkbloom.parseAsRoot(["route", "everywhere"]) }
    }

    @Test func aChoiceIsSavedAsTheLocalRouteAndKeepsTheRestOfTheFile() throws {
        let url = try makeTempConfig("[provider]\nname = \"route-test\"\n\n[local]\nmode = \"both\"\nport = 8003\n")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (flow, lines) = flow(config: url, keySaved: true)

        #expect(flow.choose(.myMacsFirst) == 0)
        let config = try ConfigManager.load(from: url)
        #expect(config.local == LocalSettings(mode: .both, route: .myMacsFirst, port: 8003))
        #expect(config.provider.name == "route-test")
        #expect(lines.all.first == "✓ Saved: [local] route = \"my-macs-first\".")

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
        #expect(lines.all.first == "✓ Already saved: [local] route = \"my-macs\".")
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

    @Test func aRunningLocalAPIKeepsItsRouteUntilItStartsAgain() throws {
        let url = try makeTempConfig()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let keyed = LocalEndpoint.Info(host: "127.0.0.1", port: 8001, apiKey: "dk-local-fixture", version: "test",
                                       pid: 4242, updatedAt: "now")
        let (flow, lines) = flow(config: url, keySaved: true, live: keyed)
        #expect(flow.choose(.myMacs) == 0)
        #expect(lines.text.contains("The local API running now (http://127.0.0.1:8001/v1) keeps the route it started "
            + "with until it starts again: `\(Self.cli) restart`."))
        #expect(!lines.text.contains("dk-local-fixture"))

        var keyless = keyed
        keyless.apiKey = ""
        let (open, openLines) = self.flow(config: url, keySaved: true, live: keyless)
        #expect(open.choose(.myMacsFirst) == 0)
        #expect(openLines.text.contains("has no local key (--no-auth): it keeps every request on this Mac"))
    }

    @Test func onAMacThatFollowsInAPairThePairsRouteIsTheLeadingMacs() throws {
        let url = try makeTempConfig()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let leader = "the other Mac (Apple M3 Ultra, 256 GB)"
        let (flow, lines) = flow(config: url, keySaved: true, pairLeader: leader)
        #expect(flow.choose(.myMacs) == 0)
        #expect(try ConfigManager.load(from: url).local?.route == .myMacs)
        #expect(lines.text.contains("the pair's API passes requests on as \(leader) says: run `\(Self.cli) route my-macs` there"))
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

    @Test func routeKeyNamesTheCommandThatChoosesYourMacs() {
        let line = RouteKeyFlow.routeLines(savedRoute: .thisMac, keySaved: true).joined()
        #expect(line.contains("`\(Self.cli) route my-macs`"))
    }
}
