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
                      saved: String? = nil) -> (RouteKeyFlow, Lines) {
        let lines = Lines()
        var flow = RouteKeyFlow(store: InMemoryLocalRouterAccountKeyStore(saved), savedRoute: route,
                                check: { _ in .accepted(models: 1) }, say: { lines.append($0) })
        flow.localAPIRunning = running
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
            "In this pair, the pair's local API passes requests on with the leading Mac's key (\(Self.other)): run "
                + "`\(Self.cli) route key` there.",
        ])
        let (leader, leaderLines) = flow(route: .myMacs, running: true, pair: .leads(other: Self.other))
        #expect(await leader.save(Self.key) == 0)
        #expect(leaderLines.all.suffix(2) == [
            "Your local API uses it now.",
            "In this pair, the pair's local API runs on this Mac and passes requests on with this key.",
        ])
        #expect(!(followerLines.text + leaderLines.text).contains(Self.key))
    }
}
