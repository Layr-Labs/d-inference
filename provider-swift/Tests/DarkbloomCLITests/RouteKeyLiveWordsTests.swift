import Foundation
import ProviderCore
import Testing

@testable import darkbloom

/// `darkbloom route key` (save and remove) counts on a running local API from its next request, with no restart, and
/// says so: "Your local API uses it now." or "It applies when your local API starts."; a key removed while the route
/// passes requests on says what the next request does. In a pair, it says whose key the pair's API uses. The key store
/// is in memory; no key is ever printed.
@Suite("route key: when the key counts")
struct RouteKeyLiveWordsTests {
    typealias Lines = RouteKeyCommandTests.Lines

    static var cli: String { BuildEnvironment.current.cliName }
    static let key = RouteKeyCommandTests.key
    static let other = "the other Mac (Apple M3 Ultra, 256 GB)"

    private func flow(route: LocalSettings.Route?, running: Bool, pair: RouteSaved.PairPart? = nil,
                      saved: String? = nil, keyless: Bool = false) -> (RouteKeyFlow, Lines) {
        let lines = Lines()
        var flow = RouteKeyFlow(store: InMemoryLocalRouterAccountKeyStore(saved), savedRoute: route,
                                check: { _ in .accepted(models: 1) }, say: { lines.append($0) })
        flow.localAPIRunning = running && !keyless
        flow.liveEndpointHasNoLocalKey = running && keyless
        flow.pair = pair
        return (flow, lines)
    }

    @Test func aKeySavedWhileTheLocalAPIRunsIsUsedNow() async {
        let (running, runningLines) = flow(route: .myMacs, running: true)
        #expect(await running.save(Self.key) == 0)
        #expect(runningLines.all.last == "Your local API uses it now.")
        #expect(!runningLines.text.contains("restart") && !runningLines.text.contains(Self.key))

        let (stopped, stoppedLines) = flow(route: .myMacs, running: false)
        #expect(await stopped.save(Self.key) == 0)
        #expect(stoppedLines.all.last == "It applies when your local API starts.")
    }

    @Test func aKeyRemovedWhileTheRouteGoesOnKeepsTheNextRequestOnThisMac() {
        let next = "Your local API uses it now. From its next request, one this Mac can't take gets this Mac's own "
            + "answer instead of going to your other Macs"
        for (route, tail) in [(LocalSettings.Route?.none, "."), (.myMacs, "."), (.myMacsFirst, " or the Darkbloom network.")] {
            let (flow, lines) = flow(route: route, running: true, saved: Self.key)
            #expect(flow.remove() == 0)
            #expect(lines.all == ["✓ Account key removed from this Mac's Keychain.",
                                  "Your requests: this Mac only, until an account key is saved again.",
                                  next + tail], "\(String(describing: route))")
        }
        // `this-mac` never used the key: nothing changes for the next request.
        let (pinned, pinnedLines) = flow(route: .thisMac, running: true, saved: Self.key)
        #expect(pinned.remove() == 0)
        #expect(pinnedLines.all.last == "Your local API uses it now.")
        // No local API running: it applies at its start.
        let (stopped, stoppedLines) = flow(route: .myMacsFirst, running: false, saved: Self.key)
        #expect(stopped.remove() == 0)
        #expect(stoppedLines.all.last == "It applies when your local API starts.")
    }

    @Test func inAPairThePairsAPIUsesTheLeadingMacsKey() async {
        let (follower, followerLines) = flow(route: .myMacs, running: true, pair: .follows(leader: Self.other))
        #expect(await follower.save(Self.key) == 0)
        #expect(followerLines.all.suffix(2) == [
            "It applies when this Mac serves alone (`\(Self.cli) start --solo`).",
            "In this pair, the pair's local API uses the leading Mac's key (\(Self.other)), not this one: run "
                + "`\(Self.cli) route key` there.",
        ])
        let (leader, leaderLines) = flow(route: .myMacs, running: true, pair: .leads(other: Self.other))
        #expect(await leader.save(Self.key) == 0)
        #expect(leaderLines.all.suffix(2) == [
            "Your local API uses it now.",
            "In this pair, the pair's local API runs on this Mac and passes requests on with this key.",
        ])
        #expect(!(followerLines.text + leaderLines.text).contains(Self.key))
        // On the leading Mac your requests are the pair's; on the other Mac, this Mac's when it serves alone.
        #expect(leaderLines.all.contains("Your requests: this pair first, then your other Macs (free)."))
        #expect(followerLines.all.contains("Your requests: this Mac first, then your other Macs (free)."))
    }

    /// `route key --remove`, in each role's true words: a single Mac's next request stays on it; the pair's local API on
    /// the leading Mac passes nothing on until a key is saved there again; on the other Mac, the pair keeps using the
    /// leading Mac's key.
    @Test func aKeyRemovedSaysWhatChangesForEachRole() {
        let (single, singleLines) = flow(route: .myMacs, running: true, saved: Self.key)
        #expect(single.remove() == 0)
        #expect(singleLines.all.last == "Your local API uses it now. From its next request, one this Mac can't take gets "
            + "this Mac's own answer instead of going to your other Macs.")

        let (leader, leaderLines) = flow(route: .myMacsFirst, running: true, pair: .leads(other: Self.other), saved: Self.key)
        #expect(leader.remove() == 0)
        #expect(leaderLines.all.suffix(3) == [
            "Your requests: this pair only, until an account key is saved again.",
            "Your local API uses it now. From its next request, one the pair can't take gets the pair's own answer "
                + "instead of going to your other Macs or the Darkbloom network.",
            "In this pair, the pair's local API runs on this Mac, so the pair passes nothing on until a key is saved "
                + "here again.",
        ])
        #expect(!leaderLines.text.contains("passes requests on with this key"))

        let (follower, followerLines) = flow(route: .myMacs, running: true, pair: .follows(leader: Self.other),
                                             saved: Self.key)
        #expect(follower.remove() == 0)
        #expect(followerLines.all.suffix(2) == [
            "It applies when this Mac serves alone (`\(Self.cli) start --solo`).",
            "In this pair, the pair's local API uses the leading Mac's key (\(Self.other)), not this one: to stop the "
                + "pair passing requests on, run `\(Self.cli) route key --remove` there.",
        ])
    }

    /// The leading Mac's key with a route that passes nothing on, or a pair API without a local key: no line says it
    /// passes requests on.
    @Test func theLeadingMacNeverClaimsToPassRequestsOnWhenItDoesnt() async {
        let pinnedLine = "In this pair, the pair's local API runs on this Mac and uses this Mac's key once its route "
            + "passes requests on."
        let (pinned, pinnedLines) = flow(route: .thisMac, running: true, pair: .leads(other: Self.other))
        #expect(await pinned.save(Self.key) == 0)
        #expect(pinnedLines.all.last == pinnedLine)
        // Removed, there is no key to name: a route that passes requests on needs one saved again.
        let (pinnedRemove, pinnedRemoveLines) = flow(route: .thisMac, running: true, pair: .leads(other: Self.other),
                                                     saved: Self.key)
        #expect(pinnedRemove.remove() == 0)
        #expect(pinnedRemoveLines.all.suffix(2) == [
            "Your local API uses it now.",
            "In this pair, the pair's local API runs on this Mac: once its route passes requests on, it needs a key "
                + "saved here again.",
        ])
        let (keyless, keylessLines) = flow(route: .myMacs, running: true, pair: .leads(other: Self.other), keyless: true)
        #expect(await keyless.save(Self.key) == 0)
        #expect(keylessLines.all.last == "The running local API has no local key (--no-auth): it keeps every request on "
            + "this pair and never uses the account key.")
        #expect(!keylessLines.text.contains("passes requests on with this key"))
        let (keylessRemove, keylessRemoveLines) = flow(route: .myMacs, running: true, pair: .leads(other: Self.other),
                                                       saved: Self.key, keyless: true)
        #expect(keylessRemove.remove() == 0)
        #expect(!keylessRemoveLines.text.contains("In this pair"))
    }

    /// What `route key` reads of the local API running now: one with a local key uses the account key from its next
    /// request; one without (`--no-auth`) never uses it; with none running, it counts at the next start.
    @Test func theLocalAPIRunningNowIsReadAsKeyedOrKeyless() {
        let keyed = LocalEndpoint.Info(host: "127.0.0.1", port: 8001, apiKey: "dk-local-fixture", version: "test",
                                       pid: 4242, updatedAt: "now")
        var keyless = keyed
        keyless.apiKey = ""
        let cases: [(name: String, live: LocalEndpoint.Info?, running: Bool, keyless: Bool)] = [
            ("keyed", keyed, true, false), ("--no-auth", keyless, false, true), ("none", nil, false, false),
        ]
        for (name, live, running, noKey) in cases {
            var flow = RouteKeyFlow(store: InMemoryLocalRouterAccountKeyStore(), savedRoute: .myMacs,
                                    check: { _ in .accepted(models: 1) }, say: { _ in })
            flow.seesLocalAPI(live)
            #expect(flow.localAPIRunning == running && flow.liveEndpointHasNoLocalKey == noKey, "\(name)")
        }
    }
}
