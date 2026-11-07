import Foundation
import Testing

@testable import ProviderCore
@testable import darkbloom

// 0.10.8: a Mac that stopped clustering was online with no traffic, and every ordinary way back to single-Mac serving
// acted on the pair or was refused. Whether the pair runs here now comes from what runs (`ClusterPairWatch`); a Mac whose
// pair doesn't run serves alone again. The pair is a fixture; no pairing, cluster service, launchd or ~/.darkbloom is read.

private let otherMac = "the other Mac (Apple M5 Max, 128 GB)"
/// The CLI as this build names it (`darkbloom`, or `darkbloom-dev` for DevNet).
private let cli = ClusterPairSummary.cli
private let notRunning = "The other Mac (Apple M5 Max, 128 GB) hasn't answered for 15 min; this Mac's part stopped. Run "
    + "`\(cli) start` to serve this Mac alone, or `\(cli) cluster` to start the pair again."

/// A Mac whose saved start is on and whose cluster service runs: `running` is the service's verdict.
private func pair(running: Bool?, reachable: Bool = false, started: Bool = true, role: ClusterPairSummary.Role = .leader)
    -> ClusterPairSummary {
    var pair = ClusterPairSummary(paired: true)
    pair.role = role
    pair.otherMacName = "Apple M5 Max, 128 GB"
    pair.modelID = "EigenLabs/Qwen3.8-27B-4bit-mtp"
    pair.modelName = "Qwen 3.8 27B"
    pair.started = started
    pair.serviceRunning = true
    pair.pairRunning = running
    pair.pairNotRunning = running == false ? notRunning : nil
    pair.otherMacReachable = reachable
    return pair
}

private let staleAlone = "This Mac is in a two-Mac cluster with \(otherMac), which isn't running here (\(otherMac) isn't "
    + "answering): serving this Mac alone, and its saved start is cleared (`\(cli) cluster` starts the pair again)."

@Suite("A Mac that stopped clustering serves normally")
struct UnpairedMacServesNormallyTests {
    @Test("start --solo is never refused for a start left from a pair that doesn't run here")
    func soloIsNeverRefusedByAStaleStart() {
        #expect(Start.pairStart(pair(running: false), solo: true, terminal: true) == .serveAlone(note: staleAlone))
        #expect(Start.pairStart(pair(running: false), solo: true, terminal: false) == .serveAlone(note: staleAlone))
        // A pair that runs here keeps its protection.
        if case .refuse = Start.pairStart(pair(running: true), solo: true, terminal: false) {} else { Issue.record("not refused") }
    }

    @Test("a script, the app's Go Online (`start --model`) and Autopilot enroll (`start --autopilot`) serve this Mac alone")
    func scriptsAndTheAppServeAlone() throws {
        let stale = pair(running: false)
        #expect(Start.pairStart(stale, solo: false, terminal: false) == .serveAlone(note: staleAlone))
        let goOnline = try Start.parse(["--model", "acme/Alpha-4bit", "--local-endpoint"]).singleMacOptions
        #expect(Start.pairStart(stale, solo: false, terminal: false, singleMacOptions: goOnline) == .serveAlone(note: staleAlone))
        let enroll = try Start.parse(["--autopilot"]).singleMacOptions
        #expect(Start.pairStart(stale, solo: false, terminal: false, singleMacOptions: enroll) == .serveAlone(note: staleAlone))
        // The app's own arguments for Go Online are exactly a `start --model` (`DesktopBackend.arguments`).
        let request = try JSONDecoder().decode(DesktopAction.self, from: Data(#"{"id":"x","action":"start","models":["acme/Alpha-4bit"]}"#.utf8))
        #expect(try DesktopBackend.arguments(for: request, configPath: nil, localActive: false) == ["start", "--model", "acme/Alpha-4bit"])
        // A pair that is merely stopped: the same, in words that say so.
        #expect(Start.pairStart(pair(running: false, started: false), solo: false, terminal: false, singleMacOptions: ["--model"])
            == .serveAlone(note: "This Mac is in a two-Mac cluster with \(otherMac), which is stopped: serving this Mac alone "
                + "(`\(cli) cluster` starts the pair again)."))
    }

    @Test("a pair that runs here keeps today's behaviour")
    func runningPairUnchanged() {
        let running = pair(running: true, reachable: true)
        #expect(Start.pairStart(running, solo: false, terminal: true) == .openScreen)
        #expect(Start.pairStart(running, solo: false, terminal: false) == .startPair)
        if case .refuseOptions = Start.pairStart(running, solo: false, terminal: false, singleMacOptions: ["--model"]) {} else {
            Issue.record("options not refused")
        }
        // A service from before 0.10.9 gives no verdict: its saved start decides, as before.
        #expect(Start.pairStart(pair(running: nil), solo: false, terminal: false) == .startPair)
    }

    @Test("a pair whose other Mac answers but hasn't served yet (a long first load) is never stopped without asking")
    func loadingPairIsNotStoppedUnasked() throws {
        let loading = pair(running: false, reachable: true)
        // The app's Go Online and Autopilot enroll clicked by mistake: refused, as for a pair that runs.
        for arguments in [["--model", "acme/Alpha-4bit"], ["--autopilot"]] {
            let options = try Start.parse(arguments).singleMacOptions
            if case .refuseOptions = Start.pairStart(loading, solo: false, terminal: false, singleMacOptions: options) {} else {
                Issue.record("\(arguments) not refused")
            }
        }
        // A script starts (waits for) the pair, as before.
        #expect(Start.pairStart(loading, solo: false, terminal: false) == .startPair)
        // The person's explicit ways back stay: --solo, and the terminal's choice.
        #expect(Start.pairStart(loading, solo: true, terminal: false) == .serveAlone(note: loading.servingAloneLine))
        #expect(Start.pairStart(loading, solo: false, terminal: true) == .choose(aloneByDefault: false))
        // The app's Restart restarts the pair; it doesn't stop it for single-Mac serving.
        #expect(Restart.pairRestart(loading, singleMacInstalled: true, singleMacRunning: true, solo: false) == .restartPair)
        // Stop stops the pair on both Macs: a follower's own cleared start would come back with the leader's next lease.
        #expect(Stop.pairedStop(loading, solo: false, uninstall: false) == .stopPair)
    }

    @Test("on the following Mac, serving alone says the leading Mac may start its part again, and how to stop that")
    func followerServingAloneIsTruthful() {
        let follower = pair(running: false, reachable: true, role: .member)
        #expect(follower.servingAloneLine == "This Mac is in a two-Mac cluster with \(otherMac), which isn't running here: "
            + "serving this Mac alone, and its saved start is cleared (`\(cli) cluster` starts the pair again). "
            + "While \(otherMac) leads with the pair started, it may start this Mac's part again once single-Mac serving "
            + "stops here: `\(cli) stop` on \(otherMac) stops the pair.")
        #expect(Start.pairStart(follower, solo: true, terminal: false) == .serveAlone(note: follower.servingAloneLine))
        // The leading Mac's line is unchanged.
        #expect(pair(running: false, reachable: true).servingAloneLine.hasSuffix("starts the pair again)."))
    }

    @Test("in a terminal: serve alone (the default when the other Mac isn't answering) or start the pair")
    func terminalChoice() {
        #expect(Start.pairStart(pair(running: false), solo: false, terminal: true) == .choose(aloneByDefault: true))
        let answering = pair(running: false, reachable: true)
        #expect(Start.pairStart(answering, solo: false, terminal: true) == .choose(aloneByDefault: false))
        #expect(Start.choice("", pair: pair(running: false), aloneByDefault: true) == .serveAlone(note: staleAlone))
        #expect(Start.choice("", pair: answering, aloneByDefault: false) == .openScreen)
        #expect(Start.choice("1", pair: answering, aloneByDefault: false) == .serveAlone(note: answering.servingAloneLine))
        #expect(Start.choice("2", pair: pair(running: false), aloneByDefault: true) == .openScreen)
    }

    @Test("stop and restart act on what runs here")
    func stopAndRestart() {
        #expect(Stop.pairedStop(pair(running: false), solo: false, uninstall: false) == .stopHere)
        #expect(Stop.pairedStop(pair(running: true), solo: false, uninstall: false) == .stopPair)
        let nothingServes = "Nothing serves on this Mac, so nothing was restarted: `\(cli) start` serves this Mac alone; "
            + "`\(cli) cluster` starts the pair."
        #expect(Restart.pairRestart(pair(running: false), singleMacInstalled: true, singleMacRunning: true, solo: false)
            == .restartSingleMac)
        #expect(Restart.pairRestart(pair(running: false), singleMacInstalled: false, singleMacRunning: false, solo: false)
            == .refuse([notRunning, nothingServes]))
        #expect(Restart.pairRestart(pair(running: true), singleMacInstalled: true, singleMacRunning: true, solo: false)
            == .restartPair)
        // Single-Mac serving that `stop` stopped keeps its plist: a plain restart never starts it, on a stopped pair too.
        var stopped = pair(running: false, reachable: true, started: false)
        stopped.pairNotRunning = nil
        #expect(Restart.pairRestart(pair(running: false), singleMacInstalled: true, singleMacRunning: false, solo: false)
            == .refuse([notRunning, nothingServes]))
        #expect(Restart.pairRestart(stopped, singleMacInstalled: true, singleMacRunning: false, solo: false)
            == .refuse([stopped.pairSentence, nothingServes]))
        #expect(Restart.pairRestart(stopped, singleMacInstalled: true, singleMacRunning: true, solo: false) == .restartSingleMac)
        // --solo asks for single-Mac serving by name: an installed job starts, as `restart` does on one Mac.
        #expect(Restart.pairRestart(stopped, singleMacInstalled: true, singleMacRunning: false, solo: true) == .restartSingleMac)
    }

    @Test("after a restart of single-Mac serving where the pair doesn't run, the words never send a plain restart to the pair")
    func restartWordsWhereThePairDoesNotRun() {
        // A plain restart never starts a pair that doesn't run here, so "`darkbloom restart` restarts both Macs" is false there.
        var stopped = pair(running: false, reachable: true, started: false)
        stopped.pairNotRunning = nil
        let notStarted = "The pair was not started; `\(cli) cluster` starts it."
        #expect(stopped.restartAddendum == stopped.pairSentence + " " + notStarted)
        #expect(stopped.restartRefusal.last == notStarted)
        #expect(pair(running: false).restartAddendum.hasSuffix(" " + notStarted), "started, the other Mac silent")
        // A pair that runs here, or may still be loading while the other Mac answers, restarts on a plain restart.
        let restartsBoth = "The pair was not restarted; `\(cli) restart` restarts both Macs."
        #expect(pair(running: true, reachable: true).restartAddendum.hasSuffix(" " + restartsBoth))
        #expect(pair(running: false, reachable: true).restartAddendum.hasSuffix(" " + restartsBoth))
    }

    @Test("update: single-Mac serving restarts on a Mac whose pair doesn't run; the pair's protection stays where it runs")
    func updateChoice() {
        // The 0.10.8 → 0.10.9 case: a single-Mac job and a leftover part whose start is still saved.
        #expect(Update.restartChoice(soloJobLoaded: true, soloJobIsMember: false, pairServes: false, leftoverPart: true,
                                     clusterServiceRunning: true) == .singleMac(releaseLeftover: true))
        #expect(Update.restartChoice(soloJobLoaded: true, soloJobIsMember: false, pairServes: false, leftoverPart: false,
                                     clusterServiceRunning: false) == .singleMac(releaseLeftover: false))
        // A pair that runs here: the leftover single-Mac job is left as it is (`solo-provider-blocks-pair`).
        #expect(Update.restartChoice(soloJobLoaded: true, soloJobIsMember: false, pairServes: true, leftoverPart: false,
                                     clusterServiceRunning: true) == .pair)
        #expect(Update.restartChoice(soloJobLoaded: false, soloJobIsMember: false, pairServes: true, leftoverPart: false,
                                     clusterServiceRunning: true) == .clusterService)
        #expect(Update.restartChoice(soloJobLoaded: true, soloJobIsMember: true, pairServes: false, leftoverPart: true,
                                     clusterServiceRunning: true) == .singleMac(releaseLeftover: false))
        #expect(Update.leftoverPartHere(pair(running: false)))
        #expect(!Update.leftoverPartHere(pair(running: true)))
        #expect(!Update.leftoverPartHere(pair(running: false, started: false)))
    }

    @Test("the watchdog revives single-Mac serving unless the pair actually runs here")
    func watchdog() {
        #expect(!Watchdog.pairOwnsServing(providerActive: false, jobIsClusterMember: false, pairServes: false))
        #expect(Watchdog.pairOwnsServing(providerActive: false, jobIsClusterMember: false, pairServes: true))
        #expect(!Watchdog.pairOwnsServing(providerActive: true, jobIsClusterMember: false, pairServes: true))
    }

    @Test("status says the pair isn't running here and the one command to serve alone")
    func status() {
        let stale = pair(running: false)
        #expect(stale.statusLine == "Cluster: " + notRunning)
        #expect(stale.clusterStatusLines.suffix(2) == [notRunning,
            "Next: `\(cli) start` serves this Mac alone; `\(cli) cluster` starts the pair again."])
        #expect(pair(running: true).startedButNotRunningLine == nil)
        #expect(pair(running: false, started: false).startedButNotRunningLine == nil)
    }
}
