import Foundation
import Testing

@testable import ProviderCore
@testable import darkbloom

// 0.10.8: a Mac that stopped clustering was online with no traffic, and every ordinary way back to single-Mac serving
// acted on the pair or was refused. Whether the pair runs here now comes from what runs (`ClusterPairWatch`); a Mac whose
// pair doesn't run serves alone again with `start --solo`. The pair is a fixture; no pairing, cluster service, launchd or
// ~/.darkbloom is read.

private let otherMac = "the other Mac (Apple M5 Max, 128 GB)"
/// The CLI as this build names it (`darkbloom`, or `darkbloom-dev` for DevNet).
private let cli = ClusterPairSummary.cli
private let notRunning = "The other Mac (Apple M5 Max, 128 GB) hasn't answered for 15 min; this Mac's part stopped. Run "
    + "`\(cli) start --solo` to serve this Mac alone, or `\(cli) start` to start the pair again."

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

/// A pair stopped with `darkbloom stop`: no saved start, so no `ClusterPairWatch` line. Both cluster services stay up, so
/// the other Mac answers.
private func stoppedPair() -> ClusterPairSummary {
    var stopped = pair(running: false, reachable: true, started: false)
    stopped.pairNotRunning = nil
    return stopped
}

private let stoppedSentence = "This Mac is in a two-Mac cluster with \(otherMac): it leads; stopped (last model Qwen 3.8 27B)."

private let staleAlone = "This Mac is in a two-Mac cluster with \(otherMac), which isn't running here (\(otherMac) isn't "
    + "answering): serving this Mac alone (`\(cli) start` starts the pair again)."

@Suite("A Mac that stopped clustering serves normally")
struct UnpairedMacServesNormallyTests {
    @Test("start --solo is never refused for a start left from a pair that doesn't run here")
    func soloIsNeverRefusedByAStaleStart() {
        #expect(Start.pairStart(pair(running: false), solo: true, terminal: true) == .serveAlone(note: staleAlone))
        #expect(Start.pairStart(pair(running: false), solo: true, terminal: false) == .serveAlone(note: staleAlone))
        // A pair that runs here keeps its protection.
        if case .refuse = Start.pairStart(pair(running: true), solo: true, terminal: false) {} else { Issue.record("not refused") }
    }

    @Test("the app's Start serving (`start --model`) starts the pair; Autopilot enroll (`start --autopilot`) needs --solo")
    func theAppStartsThePairAndAutopilotNeedsSolo() throws {
        let stale = pair(running: false)
        let appStart = try Start.parse(["--model", "acme/Alpha-4bit", "--local-endpoint"]).singleMacOptions
        #expect(Start.pairStart(stale, solo: false, terminal: false, singleMacOptions: appStart) == .startPair)
        #expect(Start.pairStart(stale, solo: true, terminal: false, singleMacOptions: appStart) == .serveAlone(note: staleAlone))
        let enroll = try Start.parse(["--autopilot"]).singleMacOptions
        #expect(Start.pairStart(stale, solo: false, terminal: false, singleMacOptions: enroll)
            == .refuseOptions(stale.singleMacOptionsRefusal(enroll)))
        // The app's own arguments for Start serving are exactly a `start --model` (`DesktopBackend.arguments`).
        let request = try JSONDecoder().decode(DesktopAction.self, from: Data(#"{"id":"x","action":"start","models":["acme/Alpha-4bit"]}"#.utf8))
        #expect(try DesktopBackend.arguments(for: request, configPath: nil, localActive: false) == ["start", "--model", "acme/Alpha-4bit"])
        // A pair that is merely stopped: --solo serves alone, in words that say so.
        #expect(Start.pairStart(stoppedPair(), solo: true, terminal: false, singleMacOptions: ["--model"])
            == .serveAlone(note: "This Mac is in a two-Mac cluster with \(otherMac), which is stopped: serving this Mac alone "
                + "(`\(cli) start` starts the pair again)."))
    }

    @Test("a pair that runs here keeps today's behaviour")
    func runningPairUnchanged() {
        let running = pair(running: true, reachable: true)
        #expect(Start.pairStart(running, solo: false, terminal: true) == .openScreen)
        #expect(Start.pairStart(running, solo: false, terminal: false) == .startPair)
        // The app's Start (no terminal) starts it, which it already does; a person at a terminal is told about --solo.
        #expect(Start.pairStart(running, solo: false, terminal: false, singleMacOptions: ["--model"]) == .startPair)
        if case .refuseOptions = Start.pairStart(running, solo: false, terminal: true, singleMacOptions: ["--model"]) {} else {
            Issue.record("options not refused")
        }
        // A service from before 0.10.9 gives no verdict: its saved start decides, as before.
        #expect(Start.pairStart(pair(running: nil), solo: false, terminal: false) == .startPair)
    }

    @Test("a pair whose other Mac answers but hasn't served yet (a long first load) is never stopped without asking")
    func loadingPairIsNotStoppedUnasked() throws {
        let loading = pair(running: false, reachable: true)
        // The app's Start serving starts (waits for) the pair, as a script's start does; Autopilot enroll is refused.
        let appStart = try Start.parse(["--model", "acme/Alpha-4bit"]).singleMacOptions
        #expect(Start.pairStart(loading, solo: false, terminal: false, singleMacOptions: appStart) == .startPair)
        let enroll = try Start.parse(["--autopilot"]).singleMacOptions
        if case .refuseOptions = Start.pairStart(loading, solo: false, terminal: false, singleMacOptions: enroll) {} else {
            Issue.record("--autopilot not refused")
        }
        // A script starts (waits for) the pair, as before.
        #expect(Start.pairStart(loading, solo: false, terminal: false) == .startPair)
        // The person's explicit way back stays: --solo. In a terminal, start opens the pair's screen.
        #expect(Start.pairStart(loading, solo: true, terminal: false) == .serveAlone(note: loading.servingAloneLine))
        #expect(Start.pairStart(loading, solo: false, terminal: true) == .openScreen)
        // The app's Restart restarts the pair; it doesn't stop it for single-Mac serving.
        #expect(Restart.pairRestart(loading, singleMacInstalled: true, singleMacRunning: true, solo: false) == .restartPair)
        // Stop stops the pair on both Macs: a follower's own cleared start would come back with the leader's next lease.
        #expect(Stop.pairedStop(loading, solo: false, uninstall: false) == .stopPair)
    }

    @Test("on the following Mac, serving alone says the leading Mac may start its part again, and how to stop that")
    func followerServingAloneIsTruthful() {
        let follower = pair(running: false, reachable: true, role: .member)
        #expect(follower.servingAloneLine == "This Mac is in a two-Mac cluster with \(otherMac), which isn't running here: "
            + "serving this Mac alone (`\(cli) start` starts the pair again). "
            + "While \(otherMac) leads with the pair started, it may start this Mac's part again once single-Mac serving "
            + "stops here: `\(cli) stop` on \(otherMac) stops the pair.")
        // After its leftover part stopped, the line that says so carries the same note.
        #expect(follower.leftoverReleasedLine.hasSuffix(" `\(cli) stop` on \(otherMac) stops the pair."))
        #expect(Start.pairStart(follower, solo: true, terminal: false) == .serveAlone(note: follower.servingAloneLine))
        // The leading Mac's line is unchanged.
        #expect(pair(running: false, reachable: true).servingAloneLine.hasSuffix("starts the pair again)."))
    }

    @Test("stop and restart act on what runs here")
    func stopAndRestart() {
        #expect(Stop.pairedStop(pair(running: false), solo: false, uninstall: false) == .stopHere)
        #expect(Stop.pairedStop(pair(running: true), solo: false, uninstall: false) == .stopPair)
        let nothingServes = "Nothing serves on this Mac, so nothing was restarted: `\(cli) start` starts the pair again; "
            + "`\(cli) start --solo` serves this Mac alone."
        #expect(Restart.pairRestart(pair(running: false), singleMacInstalled: true, singleMacRunning: true, solo: false)
            == .restartSingleMac)
        #expect(Restart.pairRestart(pair(running: false), singleMacInstalled: false, singleMacRunning: false, solo: false)
            == .refuse([notRunning, nothingServes]))
        #expect(Restart.pairRestart(pair(running: true), singleMacInstalled: true, singleMacRunning: true, solo: false)
            == .restartPair)
        // Single-Mac serving that `stop` stopped keeps its plist: a plain restart never starts it, on a stopped pair too.
        #expect(Restart.pairRestart(pair(running: false), singleMacInstalled: true, singleMacRunning: false, solo: false)
            == .refuse([notRunning, nothingServes]))
        #expect(Restart.pairRestart(stoppedPair(), singleMacInstalled: true, singleMacRunning: false, solo: false)
            == .refuse([stoppedSentence, nothingServes]))
        #expect(Restart.pairRestart(stoppedPair(), singleMacInstalled: true, singleMacRunning: true, solo: false)
            == .restartSingleMac)
        // --solo asks for single-Mac serving by name: an installed job starts, as `restart` does on one Mac.
        #expect(Restart.pairRestart(stoppedPair(), singleMacInstalled: true, singleMacRunning: false, solo: true)
            == .restartSingleMac)
    }

    @Test("after a restart of single-Mac serving where the pair doesn't run, the words never send a plain restart to the pair")
    func restartWordsWhereThePairDoesNotRun() {
        // A pair that doesn't run here, stopped or with the other Mac gone, is never started by a plain restart, so
        // "`darkbloom restart` restarts both Macs" is false there.
        let notStarted = "The pair was not started; `\(cli) start` starts it."
        #expect(stoppedPair().restartAddendum == stoppedSentence + " " + notStarted)
        #expect(stoppedPair().restartRefusal == [stoppedSentence,
            "`\(cli) restart --solo` restarts single-Mac serving, and this Mac has none: nothing was restarted.", notStarted])
        #expect(pair(running: false).restartAddendum.hasSuffix(" " + notStarted), "started, the other Mac silent")
        // A pair that runs here, or may still be loading while the other Mac answers, restarts on a plain restart.
        let restartsBoth = "The pair was not restarted; `\(cli) restart` restarts both Macs."
        #expect(pair(running: true, reachable: true).restartAddendum.hasSuffix(" " + restartsBoth))
        #expect(pair(running: false, reachable: true).restartAddendum.hasSuffix(" " + restartsBoth))
    }

    @Test("restart's words never say that a started pair whose other Mac is gone serves")
    func restartWordsWhenTheOtherMacIsGone() {
        // It doesn't run here, and a plain restart has just cleared its saved start: never "This Mac serves …".
        let notStarted = "The pair was not started; `\(cli) start` starts it."
        let gone = pair(running: false)
        let goneSentence = "This Mac is in a two-Mac cluster with \(otherMac), which isn't running here (\(otherMac) isn't answering)."
        #expect(gone.restartAddendum == goneSentence + " " + notStarted)
        #expect(gone.restartRefusal == [goneSentence,
            "`\(cli) restart --solo` restarts single-Mac serving, and this Mac has none: nothing was restarted.", notStarted])
        #expect(gone.idleRestartRefusal.first == notRunning, "the cluster service's own line leads while it runs")
        // This Mac's cluster service down: no line of its own, and nothing known of the other Mac.
        var serviceDown = gone
        serviceDown.serviceRunning = false
        serviceDown.pairNotRunning = nil
        let downSentence = "This Mac is in a two-Mac cluster with \(otherMac), which isn't running here."
        #expect(serviceDown.idleRestartRefusal.first == downSentence)
        #expect(serviceDown.restartAddendum == downSentence + " " + notStarted)
        // Where the pair runs, or may still be loading, it does serve or start here: the words stay.
        #expect(pair(running: true, reachable: true).restartAddendum.hasPrefix("This Mac serves in a two-Mac cluster"))
        #expect(pair(running: false, reachable: true).restartAddendum.hasPrefix("This Mac serves in a two-Mac cluster"))
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
        #expect(pair(running: false).leftoverPartHere)
        #expect(!pair(running: true).leftoverPartHere)
        #expect(!pair(running: false, started: false).leftoverPartHere)
        // With this Mac's cluster service down no part runs here, so there is nothing to stop.
        var serviceDown = pair(running: false)
        serviceDown.serviceRunning = false
        #expect(!serviceDown.leftoverPartHere)
    }

    @Test("the watchdog revives single-Mac serving unless the pair actually runs here")
    func watchdog() {
        #expect(!Watchdog.pairOwnsServing(providerActive: false, jobIsClusterMember: false, pairServes: false))
        #expect(Watchdog.pairOwnsServing(providerActive: false, jobIsClusterMember: false, pairServes: true))
        #expect(!Watchdog.pairOwnsServing(providerActive: true, jobIsClusterMember: false, pairServes: true))
    }

    @Test("the watchdog brings back a single-Mac job launchd lost, never a member's job or one beside a running pair")
    func watchdogAbsentJob() {
        #expect(Watchdog.recoversAbsentJob(jobIsClusterMember: false, pairServes: false))
        #expect(!Watchdog.recoversAbsentJob(jobIsClusterMember: false, pairServes: true))
        #expect(!Watchdog.recoversAbsentJob(jobIsClusterMember: true, pairServes: false))
        #expect(!Watchdog.recoversAbsentJob(jobIsClusterMember: true, pairServes: true))
    }

    @Test("status says the pair isn't running here and the one command to serve alone")
    func status() {
        let stale = pair(running: false)
        #expect(stale.statusLine == "Cluster: " + notRunning)
        // The other Mac isn't taking part: it may have left the pair (`darkbloom cluster leave`), so the way to leave too.
        #expect(stale.clusterStatusLines.suffix(2) == [notRunning,
            "Next: `\(cli) start --solo` serves this Mac alone; `\(cli) start` starts the pair again. If the other Mac left "
                + "the pair, `\(cli) cluster leave` here unpairs this Mac too."])
        #expect(pair(running: true).startedButNotRunningLine == nil)
        #expect(pair(running: false, started: false).startedButNotRunningLine == nil)
    }
}

/// The owner's rule for a paired Mac (2026-11-07): `darkbloom start`, in a terminal or not, starts the pair again, as `stop`
/// and `cluster status` say; `darkbloom start --solo` is the one way to serve this Mac alone.
@Suite("On a paired Mac, `darkbloom start` starts the pair and `start --solo` serves this Mac alone")
struct PairedMacStartTests {
    /// The pair stopped, given up here (the other Mac gone), still loading, and running.
    private var everyPair: [(String, ClusterPairSummary)] {
        [("stopped", stoppedPair()), ("other Mac gone", pair(running: false)), ("loading", pair(running: false, reachable: true)),
         ("running", pair(running: true, reachable: true))]
    }

    @Test("a plain start starts the pair whatever its state: its screen in a terminal, its saved model without one")
    func plainStartStartsThePair() {
        for (state, pair) in everyPair {
            #expect(Start.pairStart(pair, solo: false, terminal: false) == .startPair, "\(state)")
            #expect(Start.pairStart(pair, solo: false, terminal: true) == .openScreen, "\(state)")
        }
    }

    @Test("--solo serves this Mac alone wherever the pair doesn't run here; the app's Start starts the pair; other single-Mac options start nothing")
    func soloIsTheWayToServeAlone() throws {
        for (state, pair) in everyPair where state != "running" {
            #expect(Start.pairStart(pair, solo: true, terminal: false) == .serveAlone(note: pair.servingAloneLine), "\(state)")
        }
        // The app's Start (`start --model <id> [--local-endpoint] --config <path>`, no terminal) starts the pair, never
        // this Mac alone. Autopilot enroll is refused by name, never served alone without --solo nor ignored.
        for arguments in [["--model", "acme/Alpha-4bit", "--config", "/tmp/provider.toml"],
                          ["--model", "acme/Alpha-4bit", "--local-endpoint", "--config", "/tmp/provider.toml"]] {
            let options = try Start.parse(arguments).singleMacOptions
            for (state, pair) in everyPair {
                #expect(Start.pairStart(pair, solo: false, terminal: false, singleMacOptions: options) == .startPair,
                        "\(arguments) \(state)")
            }
        }
        let enroll = try Start.parse(["--autopilot"]).singleMacOptions
        for (state, pair) in everyPair {
            #expect(Start.pairStart(pair, solo: false, terminal: false, singleMacOptions: enroll)
                == .refuseOptions(pair.singleMacOptionsRefusal(enroll)), "\(state)")
        }
    }

    @Test("the words say what start and --solo do now")
    func wordsSayWhatStartDoes() {
        let startsThePair = "`\(cli) start` starts the pair again"
        #expect(stoppedPair().idleRestartRefusal == [stoppedSentence,
            "Nothing serves on this Mac, so nothing was restarted: \(startsThePair); `\(cli) start --solo` serves this Mac alone."])
        #expect(pair(running: false).clusterStatusLines.last
            == "Next: `\(cli) start --solo` serves this Mac alone; \(startsThePair). " + ClusterPairSummary.leftBehindLine)
        #expect(stoppedPair().servingAloneLine == "This Mac is in a two-Mac cluster with \(otherMac), which is stopped: serving "
            + "this Mac alone (\(startsThePair)).")
        // Never "cleared": where a leftover part runs here, `releaseLeftoverPartToServeAlone` says its own lines instead,
        // the cleared one only once it is.
        #expect(pair(running: false).servingAloneLine == "This Mac is in a two-Mac cluster with \(otherMac), which isn't "
            + "running here (\(otherMac) isn't answering): serving this Mac alone (\(startsThePair)).")
    }
}
