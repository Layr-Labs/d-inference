import ArgumentParser
import Foundation
import Testing

@testable import ProviderCore
@testable import darkbloom

// The everyday commands on a Mac in a two-Mac cluster. The pair is a fixture (`ClusterPairSummary.readerForTesting`);
// no pairing, cluster service, launchd or ~/.darkbloom is read. Command runs happen in a child process (an exit test)
// with launchctl recorded and never run.

private let otherMac = "the other Mac (Apple M5 Max, 128 GB)"

private func pair(role: ClusterPairSummary.Role? = .leader, started: Bool = true, serviceRunning: Bool = true,
                  localOnly: Bool = false, model: Bool = true) -> ClusterPairSummary {
    var pair = ClusterPairSummary(paired: true)
    pair.role = role
    pair.thisMacName = "Mac Studio"
    pair.otherMacName = "Apple M5 Max, 128 GB"
    if model {
        pair.modelID = "EigenLabs/Qwen3.8-27B-4bit-mtp"
        pair.modelName = "Qwen 3.8 27B"
        pair.deployment = "Serving Qwen 3.8 27B across both Macs: tensor parallel, M3 Ultra 50% / M5 Max 50%"
    }
    pair.localOnly = localOnly
    pair.started = started
    pair.serviceRunning = serviceRunning
    pair.startsAtLogin = serviceRunning
    return pair
}

private func text(_ bytes: [UInt8]?) -> String { String(decoding: bytes ?? [], as: UTF8.self) }

/// Each launchctl call on standard error as `launchctl: <arguments>`, answered with a failure; nothing is spawned.
private func recordingLaunchctl(_ arguments: [String]) throws -> LaunchctlControl.Output {
    FileHandle.standardError.write(Data("launchctl: \(arguments.joined(separator: " "))\n".utf8))
    return LaunchctlControl.Output(status: 1, stdout: "", stderr: "launchctl is not run in tests")
}

private let changingVerbs: Set<String> = ["bootstrap", "bootout", "kickstart", "enable", "disable", "kill", "load", "unload"]

private func changingLaunchctlCalls(_ stderr: String) -> [String] {
    stderr.split(separator: "\n").map(String.init).filter { line in
        guard line.hasPrefix("launchctl: ") else { return false }
        return changingVerbs.contains(line.dropFirst("launchctl: ".count).split(separator: " ").first.map(String.init) ?? "")
    }
}

/// Runs `body` with `summary` as the pair, launchctl recorded, a temporary LaunchAgents home and an isolated provider
/// state, then exits the child with the command's exit status.
private func exitWithPair(_ summary: ClusterPairSummary, _ body: () async throws -> Void) async throws -> Never {
    try await exitWithPair(summary, actions: nil) { _ in try await body() }
}

/// As above, with the pair's actions (`ClusterPairActions.forTesting`) and the sandbox given to `body`.
private func exitWithPair(_ summary: ClusterPairSummary, actions: ClusterPairActions?,
                          _ body: (CLICommandSandbox) async throws -> Void) async throws -> Never {
    let sandbox = try CLICommandSandbox.enter()
    let home = sandbox.root.appendingPathComponent("home", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    var status: Int32 = 0
    do {
        try await ClusterPairSummary.$readerForTesting.withValue({ _ in summary }) {
            try await ClusterPairActions.$forTesting.withValue(actions) {
                try await LaunchctlControl.$homeDirectoryForTesting.withValue(home) {
                    try await LaunchctlControl.$runnerForTesting.withValue(recordingLaunchctl) { try await body(sandbox) }
                }
            }
        }
    } catch let code as ExitCode {
        status = code.rawValue
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        status = 99
    }
    fflush(stdout)
    sandbox.remove()
    exit(status)
}

@Suite("darkbloom stop, start and restart on a Mac in a two-Mac cluster")
struct ClusterPairHabitCommandsTests {
    @Test("stop on a Mac in a cluster stops the pair; --solo and --uninstall stop single-Mac serving only")
    func stopDecision() {
        #expect(Stop.pairedStop(pair(), solo: false, uninstall: false) == .stopPair)
        #expect(Stop.pairedStop(pair(role: .member), solo: false, uninstall: false) == .stopPair)
        #expect(Stop.pairedStop(pair(started: false), solo: false, uninstall: false) == .stopHere)
        #expect(Stop.pairedStop(pair(), solo: true, uninstall: false) == .stopSingleMac)
        #expect(Stop.pairedStop(pair(), solo: false, uninstall: true) == .stopSingleMac)
        #expect(Stop.pairedStop(.notPaired, solo: false, uninstall: false) == .stopSingleMac)
        // Never plain `stop` here (solo-steps-failed.md §3.3: it stops the pair and leaves single-Mac serving running).
        #expect(pair().soloStopNothing == [
            "`darkbloom stop --solo` stops single-Mac serving, and none runs on this Mac: nothing was stopped.",
            "The pair keeps running. If single-Mac serving blocks it, it runs on \(otherMac): run `darkbloom stop --solo` there.",
        ])
        let found = [ClusterOnboardingSoloServing(mac: "this Mac", pid: nil),
                     ClusterOnboardingSoloServing(mac: "the other Mac (Apple M5 Max, 128 GB)", pid: 68099)]
        #expect(Stop.otherMacSolo(found) == found[1])
        #expect(Stop.otherMacSolo([found[0]]) == nil)
        #expect(Stop.otherMacLines(found[1], cli: "darkbloom-dev") == [
            "Single-Mac serving doesn't run on this Mac; it runs on the other Mac (Apple M5 Max, 128 GB) (process 68099).",
            "Stop it there? `darkbloom-dev stop --solo --yes` does it without asking.",
        ])
        #expect(Stop.otherMacDeclined(found[1], cli: "darkbloom-dev")
            == "Nothing was stopped. On the other Mac (Apple M5 Max, 128 GB), run `darkbloom-dev stop --solo`.")
        #expect(pair().stopAddendum == [
            "This Mac serves in a two-Mac cluster with \(otherMac): it leads; Qwen 3.8 27B through Darkbloom.",
            "The pair was not stopped; `darkbloom stop` stops both Macs.",
        ])
    }

    @Test("the provider state the cluster's part wrote is never drained as single-Mac serving")
    func clusterPartIsNotDrained() {
        let part = DaemonState(pid: 4242, version: "test", writtenAt: 1, startedAt: 0)
        let solo = DaemonState(pid: 777, version: "test", writtenAt: 1, startedAt: 0)
        #expect(ServiceDrain.soloProviderState(part, clusterPart: 4242) == nil)
        #expect(ServiceDrain.soloProviderState(solo, clusterPart: 4242) == solo)
        #expect(ServiceDrain.soloProviderState(part, clusterPart: nil) == part)
    }

    @Test("start on a Mac in a cluster starts the pair: the cluster's screen in a terminal, the saved model otherwise")
    func startDecision() throws {
        #expect(Start.pairStart(pair(), solo: false, terminal: true) == .openScreen)
        // The single-Mac ✗'s "Then run `darkbloom start`", a started pair that doesn't run here (#1793's `pairRunning`
        // false), the other Mac gone, or the pair stopped with this Mac's cluster service off: the pair's start, in every
        // case (`PairedMacStartTests`). Only `--solo` serves this Mac alone.
        var blocked = pair()
        blocked.pairRunning = false
        blocked.otherMacReachable = true
        var silent = blocked
        silent.otherMacReachable = false
        for state in [blocked, silent, pair(role: .member), pair(role: .member, started: false, serviceRunning: false)] {
            for terminal in [true, false] {
                #expect(Start.pairStart(state, solo: false, terminal: terminal) == (terminal ? .openScreen : .startPair))
            }
        }
        #expect(Start.pairStart(pair(), solo: true, terminal: true) == .refuse(soloBesideServingRefusal))
        #expect(Start.pairStart(pair(started: false), solo: true, terminal: false) == .serveAlone(note: "This Mac is in a "
            + "two-Mac cluster with \(otherMac), which is stopped: serving this Mac alone (`darkbloom start` starts the pair again)."))
        #expect(Start.pairStart(.notPaired, solo: false, terminal: true) == .single(note: nil))
        // The cluster's own starts and launchd's child are never asked.
        #expect(try Start.parse([]).startsSingleMacServing)
        #expect(try Start.parse(["--local"]).startsSingleMacServing)
        #expect(try Start.parse(["--solo", "--model", "m"]).solo)
        #expect(try !Start.parse(["--foreground"]).startsSingleMacServing)
        #expect(try !Start.parse(["--cluster-member"]).startsSingleMacServing)
        #expect(try !Start.parse(["--local", "--distributed"]).startsSingleMacServing)
    }

    @Test("restart on a Mac in a cluster restarts the pair; --solo restarts single-Mac serving only")
    func restartDecision() throws {
        #expect(Restart.pairRestart(pair(), singleMacInstalled: false, singleMacRunning: false, solo: false) == .restartPair)
        #expect(Restart.pairRestart(pair(), singleMacInstalled: true, singleMacRunning: true, solo: false) == .restartPair)
        #expect(Restart.pairRestart(pair(), singleMacInstalled: true, singleMacRunning: false, solo: true) == .restartSingleMac)
        #expect(Restart.pairRestart(pair(), singleMacInstalled: false, singleMacRunning: false, solo: true) == .refuse([
            "This Mac serves in a two-Mac cluster with \(otherMac): it leads; Qwen 3.8 27B through Darkbloom.",
            "`darkbloom restart --solo` restarts single-Mac serving, and this Mac has none: nothing was restarted.",
            "The pair was not restarted; `darkbloom restart` restarts both Macs.",
        ]))
        #expect(Restart.pairRestart(.notPaired, singleMacInstalled: false, singleMacRunning: false, solo: false) == .restartSingleMac)
        #expect(pair().restartAddendum == "This Mac serves in a two-Mac cluster with \(otherMac): it leads; Qwen 3.8 27B "
            + "through Darkbloom. The pair was not restarted; `darkbloom restart` restarts both Macs.")
        #expect(try Restart.parse(["--solo"]).solo)
    }

    @Test("status and doctor say the pair in one line and never send a paired Mac to `darkbloom start`")
    func statusAndDoctorLines() {
        var serving = pair()
        serving.state = .serving
        #expect(serving.statusLine == "Cluster: this Mac leads · \(otherMac) · Qwen 3.8 27B through Darkbloom · serving "
            + "(details: `darkbloom cluster status`)")
        var refused = pair(role: .member)
        refused.state = .notServing
        refused.reason = "The other Mac (Apple M5 Max, 128 GB) isn't verified by Apple yet; Darkbloom retries by itself within minutes. Don't restart either Mac until then"
        #expect(refused.statusLine == "Cluster: this Mac follows · \(otherMac) · Qwen 3.8 27B through Darkbloom · not serving: "
            + refused.reason! + " (details: `darkbloom cluster status`)")
        var stopped = pair(started: false, localOnly: true)
        stopped.state = .stopped
        #expect(stopped.statusLine == "Cluster: this Mac leads · \(otherMac) · Qwen 3.8 27B locally only · stopped (details: `darkbloom cluster status`)")
        #expect(Status.daemonNotRunningLine(paired: true) == "Single-Mac serving: off (this Mac serves in its two-Mac cluster: `darkbloom cluster status`)")
        #expect(Status.daemonNotRunningLine(paired: false) == "Daemon: not running (run `\(BuildEnvironment.current.cliName) start`)")
        #expect(Doctor.daemonLine(running: false, paired: true) == "Daemon: single-Mac serving off (this Mac serves in its two-Mac cluster)")
        #expect(Doctor.daemonLine(running: false, paired: false) == "Daemon: NOT running — run `\(BuildEnvironment.current.cliName) start`")
        #expect(Doctor.daemonLine(running: true, paired: true) == "Daemon: running")
    }

    @Test("this Mac's own view: stopped, the other Mac away, or what its part says")
    func ownState() throws {
        let json = #"{"serving":true,"sessionLeader":true,"child":{"running":true,"starts":1,"pair":"stopped (memory_gate_refused)"}}"#
        var own = try JSONDecoder().decode(ClusterServiceStatus.self, from: Data(json.utf8))
        #expect(ClusterPairSummary.ownState(started: false, own: own) == (.stopped, nil))
        #expect(ClusterPairSummary.ownState(started: true, own: own) == (.notServing, "One of the Macs lacks free memory for its share"))
        own.child.pair = "serving (first request in 0.84 s)"
        #expect(ClusterPairSummary.ownState(started: true, own: own) == (.serving, nil))
        own.child.pair = "starting"
        #expect(ClusterPairSummary.ownState(started: true, own: own) == (.loading, nil))
        // A part the coordinator will not pair (its catalog lacks the model): not serving, with the reason, instead of
        // "waiting for the coordinator" (DevNet Gemma pair, 2026-11-05).
        let refusal = ClusterLocalServing.catalogRefusal(modelID: "gemma-4-26b-qat-4bit", catalogIDs: ["glm-5.3-flash"])!
        var refused = own
        refused.child.pair = nil
        refused.child.notice = refusal
        #expect(ClusterPairSummary.ownState(started: true, own: refused) == (.notServing, refusal))
        refused.child.notice = ClusterLocalServing.offeredNotice
        #expect(ClusterPairSummary.ownState(started: true, own: refused) == (.loading, nil))
        // Paired and serving, but under an approval the coordinator serves the owner only from: not ✓ (DevNet Gemma
        // pair, 2026-11-05, 429 `cluster_not_public … (unqualified)`).
        let ownerOnly = "Not serving publicly: the coordinator paired both Macs but doesn't send public requests to this pair "
            + "(it runs under the model approval devnet/gemma-4-26b-qat-4bit/s1, which serves only this account's own requests)"
        var served = own
        served.child.pair = "serving (first request in 0.84 s)"
        served.child.notice = ownerOnly
        #expect(ClusterPairSummary.ownState(started: true, own: served) == (.notServing, ownerOnly))
        own.control = .init(leaderID: "a", leaderName: "Apple M3 Ultra, 256 GB", term: 1, reason: "", leads: true,
                            line: "The other Mac (Apple M5 Max, 128 GB) is gone; …", mode: "waiting")
        #expect(ClusterPairSummary.ownState(started: true, own: own) == (.otherMacAway, "The other Mac (Apple M5 Max, 128 GB) is gone; …"))
        #expect(ClusterPairSummary.ownState(started: true, own: nil) == (.unknown, nil))
    }

    /// The DevNet traffic run (2026-11-04): the leading Mac's own view read its ready local API as serving. Through
    /// Darkbloom, a pair there isn't offered (an offered pair's part reports its pair line): not serving, never exit 0.
    @Test("this Mac's own view: a ready local API serves through Darkbloom only when offered")
    func ownStateOfALocalAPI() throws {
        let json = #"{"serving":true,"sessionLeader":true,"child":{"running":true,"starts":1},"#
            + #""session":{"observed":true,"ready":true,"readyRanks":2,"ranks":2,"port":8001}}"#
        let own = try JSONDecoder().decode(ClusterServiceStatus.self, from: Data(json.utf8))
        let (state, reason) = ClusterPairSummary.ownState(started: true, own: own)
        #expect(state == .notServing)
        #expect(reason == "not offered to Darkbloom (no cluster approval is attached to its setup)")
        // The refactor pass's B2: a part registered as the pair's member before its pair line may still be paired.
        let offered = #"{"serving":true,"sessionLeader":true,"child":{"running":true,"starts":1,"#
            + #""notice":"\#(ClusterLocalServing.offeredNotice)"},"session":{"observed":true,"ready":true,"readyRanks":2,"ranks":2}}"#
        let member = try JSONDecoder().decode(ClusterServiceStatus.self, from: Data(offered.utf8))
        #expect(ClusterPairSummary.ownState(started: true, own: member) == (.loading, nil))
    }
}

@Suite("darkbloom cluster status: a pair set to serve through Darkbloom that isn't offered")
struct ClusterStatusNotOfferedTests {
    static let reason = "not offered to Darkbloom (this Mac's check refused it: Unequal tensor-parallel shares serve local clusters only)"
    static let status = ["Qwen 3.8 27B is not serving yet: \(reason).",
                         "Meanwhile it answers only on the local API at http://localhost:8001 (no Darkbloom traffic).",
                         "Test response in 0.23 s (the leading Mac's test)"]

    /// The DevNet traffic run (2026-11-04): `cluster status --json` said `serving`, exit 0, "earning through Darkbloom"
    /// while the coordinator never had the pair. The leading Mac's status now says it isn't offered: not serving, exit 3,
    /// why, and what to do.
    @Test("not serving, exit 3, the reason, and what to do: plan the model again, or serve locally only")
    func notOfferedIsNotServing() {
        var summary = pair()
        summary.started = true
        summary.read(status: Self.status, leaderMode: "cluster")
        #expect(summary.state == .notServing)
        #expect(summary.exitCode == 3)
        #expect(summary.reason == Self.reason)
        #expect(summary.json.state == "not_serving" && summary.json.exitCode == 3)
        let cli = BuildEnvironment.current.cliName
        #expect(summary.next == "To offer it to Darkbloom: `\(cli) cluster` on this Mac, then choose the model again (it is "
            + "planned for Darkbloom). Or serve locally only: `\(cli) cluster local` on this Mac.")
        #expect(summary.clusterStatusLines.contains("Serves: through Darkbloom (not offered)"))
        #expect(summary.clusterStatusLines.contains("✗ Not serving: \(Self.reason)."))
        #expect(!summary.clusterStatusLines.joined(separator: "\n").contains("earning")
            && !summary.clusterStatusLines.contains { $0.hasPrefix("✓") })
        // `darkbloom start` stops waiting at once: only a new plan or approval changes it.
        #expect(ClusterPairSummary.isFinalReason(Self.reason))
    }
}

@Suite("darkbloom cluster status")
struct ClusterStatusPlainTests {
    @Test("the status lines `darkbloom cluster` shows give the state and the reason, in its own words")
    func stateOfTheStatusLines() {
        typealias S = ClusterPairSummary
        #expect(S.state(ofStatus: ["Serving Qwen 3.8 27B through Darkbloom on both Macs (tensor parallel)."], started: true, leaderMode: "cluster") == (.serving, nil))
        let refused = "Qwen 3.8 27B is not serving yet: The other Mac (Apple M4 Max, 128 GB) isn't verified by Apple yet; Darkbloom retries by itself at about 00:34. Don't restart either Mac until then."
        #expect(S.state(ofStatus: [refused, "Then choose Retry, or serve locally only now."], started: true, leaderMode: nil)
            == (.notServing, "The other Mac (Apple M4 Max, 128 GB) isn't verified by Apple yet; Darkbloom retries by itself at about 00:34. Don't restart either Mac until then"))
        #expect(S.state(ofStatus: ["Qwen 3.8 27B is not serving yet: the coordinator paired both Macs."], started: true, leaderMode: nil) == (.loading, "the coordinator paired both Macs"))
        #expect(S.state(ofStatus: ["Stopped; last model Qwen 3.8 27B."], started: false, leaderMode: nil) == (.stopped, nil))
        #expect(S.state(ofStatus: ["Loading Qwen 3.8 27B: 1 of 2 parts ready."], started: true, leaderMode: nil) == (.loading, nil))
        #expect(S.state(ofStatus: [ClusterOnboardingUpdate.statusLine], started: true, leaderMode: nil) == (.loading, nil))
        #expect(S.state(ofStatus: ["The other Mac (Apple M5 Max, 128 GB) is gone; this Mac serves Qwen 3.8 27B alone in 9 min 59 s unless it returns first."], started: true, leaderMode: "waiting")
            == (.otherMacAway, "The other Mac (Apple M5 Max, 128 GB) is gone; this Mac serves Qwen 3.8 27B alone in 9 min 59 s unless it returns first"))
        #expect(S.state(ofStatus: ["The other Mac (Apple M3 Ultra, 256 GB) did not answer over the cable: timed out"], started: true, leaderMode: nil) == (.otherMacAway, nil))
        #expect(S.state(ofStatus: [], started: false, leaderMode: nil) == (.stopped, nil))
    }

    /// R7-4 (0.10.9 DevNet, MiMo tensor parallel): for 12 minutes the leading Mac's part ended "exit 1: deadline" and
    /// started again while `cluster status --json` said `loading` with `reason: null` on both Macs.
    @Test("a load whose part keeps ending gives that end as the reason, in the start screen's words")
    func loadingThatKeepsEndingGivesTheEnd() throws {
        let ended = try JSONDecoder().decode(ClusterServiceStatus.Child.self,
            from: Data(#"{"running":false,"starts":2,"lastEnd":"exit 1","lastError":"deadline"}"#.utf8))
        let clause = try #require(OnboardingLive.endedClause(mac: "this Mac", child: ended))
        let words = "this Mac's part ended (exit 1: deadline) and starts again by itself"
        #expect(clause == "; " + words)
        let running = try JSONDecoder().decode(ClusterServiceStatus.Child.self, from: Data(#"{"running":true,"starts":2,"lastEnd":"exit 1"}"#.utf8))
        #expect(OnboardingLive.endedClause(mac: "this Mac", child: running) == nil)

        typealias S = ClusterPairSummary
        #expect(S.state(ofStatus: ["Starting Xiaomi: MiMo-V2.6-Flash" + clause + "."], started: true, leaderMode: "cluster") == (.loading, words))
        #expect(S.state(ofStatus: ["Loading Xiaomi: MiMo-V2.6-Flash: 1 of 2 parts ready (rank 1 loading)" + clause + "."], started: true,
                        leaderMode: nil) == (.loading, words))
        #expect(S.state(ofStatus: ["Starting Xiaomi: MiMo-V2.6-Flash."], started: true, leaderMode: "cluster") == (.loading, nil))

        var summary = pair()
        summary.read(status: ["Starting Qwen 3.8 27B" + clause + "."], leaderMode: "cluster")
        #expect(summary.state == .loading && summary.exitCode == 3)
        #expect(summary.json.reason == words)
        #expect(summary.statusLine.contains("loading: " + words))
        #expect(summary.next == "Both Macs keep trying by themselves; `\(BuildEnvironment.current.cliName) cluster` on this Mac shows more.")
    }

    @Test("the exit status: 0 serving, 3 not serving yet, 4 stopped, 5 the other Mac isn't answering, 6 not in a cluster")
    func exitCodes() {
        var summary = pair()
        for (state, code) in [(ClusterPairSummary.State.serving, Int32(0)), (.loading, 3), (.notServing, 3), (.unknown, 3),
                              (.stopped, 4), (.otherMacAway, 5), (.notPaired, 6)] {
            summary.state = state
            #expect(summary.exitCode == code, "\(state)")
        }
    }

    /// 0.10.9 DevNet f1: `Next:` said "Both Macs keep trying by themselves" beside a block that said the pair won't start by
    /// itself while single-Mac serving runs.
    @Test("single-Mac serving blocking the pair: `next` says what to run, on both Macs, and a scripted start stops waiting")
    func soloBlockNext() {
        let cli = BuildEnvironment.current.cliName
        for (role, leading) in [(ClusterPairSummary.Role.leader, "this Mac"), (.member, otherMac)] {
            var blocked = pair(role: role)
            blocked.state = .notServing
            blocked.reason = "The pair can't start: a single-Mac Darkbloom provider (process 68099) is serving on this Mac, and the pair "
                + "can't share a Mac with it"
            let next = blocked.next ?? ""
            #expect(!next.contains("keep trying by themselves"), "\(role): \(next)")
            #expect(next == "Single-Mac serving doesn't stop by itself: run `\(cli) stop --solo` on each Mac named, then `\(cli) start` "
                + "on either Mac. Or `\(cli) cluster` on \(leading) offers to stop it and start the pair.", "\(role): \(next)")
            #expect(ClusterPairSummary.isFinalReason(blocked.reason), "\(role): a scripted `start` doesn't wait 10 minutes for it")
        }
    }

    @Test("a plan that serves without the speculative assistant says why, in one line under how it serves")
    func speculationNoteLine() {
        var serving = pair()
        serving.state = .serving
        serving.lines = ["Serving Qwen 3.8 27B through Darkbloom on both Macs (tensor parallel)."]
        serving.speculationNote = "Qwen's speculative assistant could not be planned (the helper timed out); this plan serves without speculative decoding."
        let lines = serving.clusterStatusLines
        let serves = lines.firstIndex { $0.hasPrefix("Serves: ") }
        #expect(serves.map { lines[$0 + 1] } == serving.speculationNote, "\(lines)")
        serving.speculationNote = nil
        #expect(!serving.clusterStatusLines.contains { $0.contains("speculative") })
    }

    @Test("plain output: who leads, the model and its split, how it serves, the state in the screens' words, what to do")
    func plainLines() {
        var serving = pair()
        serving.state = .serving
        serving.lines = ["Serving Qwen 3.8 27B through Darkbloom on both Macs (tensor parallel)."]
        #expect(serving.clusterStatusLines == [
            "Cluster: this Mac (Mac Studio) leads · \(otherMac) follows",
            "Model: Qwen 3.8 27B · tensor parallel · M3 Ultra 50% / M5 Max 50%",
            "Serves: through Darkbloom",
            "✓ Serving Qwen 3.8 27B through Darkbloom on both Macs (tensor parallel).",
            "Next: To stop or change it: `darkbloom cluster` on this Mac.",
        ])
        var refused = pair(role: .member)
        refused.state = .notServing
        refused.reason = "The other Mac (Apple M5 Max, 128 GB) isn't verified by Apple yet; Darkbloom retries by itself at about 00:34. Don't restart either Mac until then"
        refused.lines = ["Qwen 3.8 27B is not serving yet: \(refused.reason!).", "Then choose Retry, or serve locally only now."]
        #expect(refused.clusterStatusLines == [
            "Cluster: this Mac (Mac Studio) follows · \(otherMac) leads",
            "Model: Qwen 3.8 27B · tensor parallel · M3 Ultra 50% / M5 Max 50%",
            "Serves: through Darkbloom",
            "✗ Not serving: \(refused.reason!).",
            "Next: Leave both Macs running: Darkbloom retries by itself. Or serve locally only: `darkbloom cluster local` on \(otherMac).",
        ])
        var away = pair(role: .member)
        away.state = .otherMacAway
        away.lines = ["The other Mac (Apple M5 Max, 128 GB) did not answer over the cable: connection refused"]
        #expect(away.clusterStatusLines.last == "Next: The other Mac (Apple M5 Max, 128 GB) isn't answering over the cable. Its "
            + "cluster service may have been turned off with `darkbloom cluster stop --service`, or that Mac is asleep, off, "
            + "or waiting for someone to log in. On that Mac, run `darkbloom start` (or `darkbloom cluster`).")
        var stopped = pair(started: false, serviceRunning: false, localOnly: true)
        stopped.state = .stopped
        stopped.lines = ["Stopped; last model Qwen 3.8 27B.", "When it starts: Local only, on this Mac's networks; API key: `darkbloom local`."]
        #expect(stopped.clusterStatusLines.suffix(4) == [
            "Serves: locally only (API key: `darkbloom local` on the Mac that serves it)",
            "■ Stopped; last model Qwen 3.8 27B.",
            "  When it starts: Local only, on this Mac's networks; API key: `darkbloom local`.",
            "Next: `darkbloom start` on either Mac starts the pair again. This Mac's cluster service is off; "
                + "`darkbloom start` here turns it back on.",
        ])
        #expect(ClusterPairSummary.notPaired.clusterStatusLines == ["This Mac isn't in a cluster.",
            "Next: To set up a cluster: `darkbloom cluster` on each Mac."])
    }

    @Test("--json: schema 1, every key present, null when unknown")
    func jsonSchema() throws {
        var refused = pair()
        refused.state = .notServing
        refused.reason = "This Mac isn't logged in to Darkbloom, so the coordinator won't pair it"
        refused.lines = ["Qwen 3.8 27B is not serving yet: \(refused.reason!)."]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let object = try #require(try JSONSerialization.jsonObject(with: encoder.encode(refused.json)) as? [String: Any])
        #expect(Set(object.keys) == ["schema", "paired", "role", "this_mac", "other_mac", "model", "mode", "split", "serves",
                                     "state", "reason", "next", "lines", "service", "exit_code"])
        #expect(object["schema"] as? Int == 1)
        #expect(object["role"] as? String == "leader")
        #expect(object["state"] as? String == "not_serving")
        #expect(object["exit_code"] as? Int == 3)
        #expect(object["serves"] as? String == "darkbloom")
        #expect(object["mode"] as? String == "tensor parallel")
        #expect(object["split"] as? String == "M3 Ultra 50% / M5 Max 50%")
        #expect((object["other_mac"] as? [String: Any])?["name"] as? String == "Apple M5 Max, 128 GB")
        #expect((object["other_mac"] as? [String: Any])?.keys.contains("answers") == true)
        #expect((object["model"] as? [String: Any])?["name"] as? String == "Qwen 3.8 27B")
        #expect((object["service"] as? [String: Any])?["starts_at_login"] as? Bool == true)
        #expect(object["next"] as? String == "Run `darkbloom login` on each Mac named, then `darkbloom cluster` on this Mac. "
            + "Or serve locally only: `darkbloom cluster local` on this Mac.")
        let unpaired = try #require(try JSONSerialization.jsonObject(with: encoder.encode(ClusterPairSummary.notPaired.json)) as? [String: Any])
        #expect(unpaired["state"] as? String == "not_paired" && unpaired["exit_code"] as? Int == 6)
        #expect(unpaired["role"] is NSNull && unpaired["model"] is NSNull && unpaired["other_mac"] is NSNull)
    }

    @Test("`darkbloom cluster status` prints the plain block and exits 3 while the pair does not serve")
    func command() async {
        let result = await #expect(processExitsWith: .exitCode(3), observing: [\.standardOutputContent]) {
            var summary = pair()
            summary.state = .notServing
            summary.reason = "This Mac isn't logged in to Darkbloom, so the coordinator won't pair it"
            summary.lines = ["Qwen 3.8 27B is not serving yet: \(summary.reason!)."]
            try await exitWithPair(summary) { try await runCLICommand(Cluster.Status.self, ["cluster", "status"]) }
        }
        let stdout = text(result?.standardOutputContent)
        #expect(stdout.hasPrefix("Cluster: this Mac (Mac Studio) leads · \(otherMac) follows\n"))
        #expect(stdout.contains("✗ Not serving: This Mac isn't logged in to Darkbloom, so the coordinator won't pair it.\n"))
        #expect(!stdout.contains("Saved setup:"))
    }

    @Test("`--json` prints one object with the same exit status; `--details` keeps the earlier output")
    func jsonCommandAndDetails() async throws {
        let result = await #expect(processExitsWith: .exitCode(4), observing: [\.standardOutputContent]) {
            var summary = pair(started: false)
            summary.state = .stopped
            try await exitWithPair(summary) { try await runCLICommand(Cluster.Status.self, ["cluster", "status", "--json"]) }
        }
        let object = try #require(try JSONSerialization.jsonObject(with: Data((result?.standardOutputContent ?? []))) as? [String: Any])
        #expect(object["state"] as? String == "stopped" && object["exit_code"] as? Int == 4)
        let details = try #require(try Darkbloom.parseAsRoot(["cluster", "status", "--details", "--json"]) as? Cluster.Status)
        #expect(details.details && details.json)
    }
}

@Suite("darkbloom cluster --help, link --remove and cluster stop")
struct ClusterPairClusterCommandsTests {
    @Test("`darkbloom cluster --help` lists the other commands in plain words; a cluster is two Macs")
    func helpListsCommands() {
        func flat(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        let help = flat(Cluster.Setup.helpMessage())
        #expect(help.contains("Set up two Macs to serve one model together. Run it on each Mac and follow the screen."))
        #expect(!help.contains("two or more"))
        for line in ["darkbloom cluster status Is the cluster serving now? If not, why and what to do (--json for scripts).",
                     "darkbloom cluster stop Stop the cluster on both Macs, the same as `darkbloom stop`.",
                     "On a Mac in a cluster, `darkbloom start`, `stop`, `restart` and `status` control the pair (--solo: this Mac alone).",
                     "darkbloom cluster local Serve on the leading Mac's own API only, without Darkbloom.",
                     "darkbloom cluster link Check the Thunderbolt cable and this Mac's port setup.",
                     "darkbloom cluster doctor Check this Mac's cluster files, keys and cable."] {
            #expect(help.contains(line), "\(line)")
        }
    }

    /// Review of #1846: `darkbloom-dev cluster link --remove` took production's cable port setup away with no word.
    @Test("`cluster link --remove` beside the other app that still uses the port names it and asks; --yes never answers for it")
    func linkRemoveBesideTheOtherApp() {
        typealias Link = Cluster.Link
        let others = ["The production Darkbloom on this Mac also uses this cable port for its own pair: removing the port's "
            + "setup stops that pair too, until `darkbloom cluster link --fix` sets the port up again."]
        #expect(ClusterLinkRepair.otherInstallsUsingCableLines([.prod]) == others)
        let refused = others + ["Nothing changed. --yes doesn't answer for the other app: run it in a terminal and confirm there."]
        // Not paired here, with --yes: still asked at a terminal, refused without one or with --json.
        #expect(Link.removalGate(.notPaired, yes: true, dryRun: false, json: false, terminal: true, otherApps: others) == .ask(others))
        #expect(Link.removalGate(.notPaired, yes: true, dryRun: false, json: false, terminal: false, otherApps: others) == .refuse(refused))
        #expect(Link.removalGate(.notPaired, yes: false, dryRun: false, json: true, terminal: true, otherApps: others) == .refuse(refused))
        // On a paired Mac: this pair's warning, then the other app's, one question.
        #expect(Link.removalGate(pair(), yes: false, dryRun: false, json: false, terminal: true, otherApps: others)
            == .ask(pair().linkRemoveWarning + others))
        // A dry run changes nothing, so it asks nothing.
        #expect(Link.removalGate(pair(), yes: false, dryRun: true, json: false, terminal: false, otherApps: others) == .proceed)
    }

    @Test("`cluster link --remove` on a paired Mac says what it undoes and asks once; --yes for scripts")
    func linkRemoveWarns() throws {
        let warning = [
            "This Mac is paired with \(otherMac), and the cable carries their cluster.",
            "--remove undoes the cable port setup that works now: the cluster stops serving on both Macs until the port is set "
                + "up again with `darkbloom cluster` (or `darkbloom cluster link --fix`).",
        ]
        typealias Link = Cluster.Link
        #expect(Link.removalGate(pair(), yes: false, dryRun: false, json: false, terminal: true) == .ask(warning))
        #expect(Link.removalGate(pair(), yes: false, dryRun: false, json: false, terminal: false)
            == .refuse(warning + ["Nothing changed. To remove it anyway without a question, add --yes."]))
        #expect(Link.removalGate(pair(), yes: false, dryRun: false, json: true, terminal: true)
            == .refuse(warning + ["Nothing changed. To remove it anyway without a question, add --yes."]))
        #expect(Link.removalGate(pair(), yes: true, dryRun: false, json: false, terminal: false) == .proceed)
        #expect(Link.removalGate(pair(), yes: false, dryRun: true, json: false, terminal: false) == .proceed)
        #expect(Link.removalGate(.notPaired, yes: false, dryRun: false, json: false, terminal: true) == .proceed)
        #expect(Link.confirmed("y") && Link.confirmed(" YES\n") && !Link.confirmed("") && !Link.confirmed("n") && !Link.confirmed(nil))
        #expect(try Link.parse(["--remove", "--yes"]).yes)
        #expect(try Link.parse(["--remove", "-y", "--device", "rdma_en6"]).yes)
        #expect(throws: (any Error).self) { _ = try Link.parse(["--fix", "--yes"]) }
        #expect(throws: (any Error).self) { _ = try Link.parse(["--yes"]) }
    }

    @Test("`cluster stop` is `darkbloom stop` on a Mac in a cluster; --service and --local-only also turn this Mac's service off")
    func clusterStopIsAnAlias() throws {
        typealias Stop = Cluster.Stop
        #expect(Stop.mode(pair(), localOnly: false, service: false) == .pair)
        #expect(Stop.mode(pair(role: .member), localOnly: false, service: false) == .pair)
        #expect(Stop.mode(pair(), localOnly: false, service: true) == .serviceOff)
        #expect(Stop.mode(pair(), localOnly: true, service: false) == .serviceOff)
        #expect(Stop.mode(.notPaired, localOnly: false, service: false) == .serviceOff)
        #expect(Stop.mode(unreadable(), localOnly: false, service: false) == .refuse)
        #expect(Stop.mode(unreadable(), localOnly: false, service: true) == .serviceOff)
        #expect(try Stop.parse(["--service"]).service)
        // `--local-only` turns this Mac's service off; the other Mac, if it comes back, needs the same (`--service`).
        func flat(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        #expect(flat(Stop.helpMessage()).contains("Run `darkbloom cluster stop --service` there too if it comes back."))
        #expect(try Stop.finishStop(nil, localOnly: true) { ["fixture"] }.last
            == "The other Mac was not asked to stop. If it comes back, run `darkbloom cluster stop --service` there too.")
        #expect(Stop.refusal(unreadable()) == [
            "This Mac's pairing record couldn't be read (\(unreadableReason)), so it may be in a two-Mac cluster.",
            "`darkbloom cluster stop` can't tell which pair to stop, so nothing was stopped.",
            "To stop this Mac's cluster service anyway: `darkbloom cluster stop --service`. Run `darkbloom cluster` on this Mac "
                + "to check it.",
        ])
    }

    @Test("`cluster stop --service` on the Mac that follows a started cluster asks the leading Mac to stop both Macs")
    func memberStopStopsThePair() throws {
        typealias Stop = Cluster.Stop
        #expect(Stop.pairStop(role: .member, serving: true) == .askLeader)
        #expect(Stop.pairStop(role: .member, serving: false) == .stopHere)
        #expect(Stop.pairStop(role: .leader, serving: false) == .leaderStopsBoth)
        #expect(Stop.pairStop(role: nil, serving: true) == .stopHere)
        #expect(ClusterPairSummary.memberStopNote(leader: "the other Mac (Apple M3 Ultra, 256 GB)")
            == "This Mac follows the other Mac (Apple M3 Ultra, 256 GB), which leads: `darkbloom cluster stop` stops the cluster on both Macs.")
        // The leading Mac could not stop it: nothing is removed here, and the way to stop this Mac alone is said.
        var removed = false
        do {
            _ = try Stop.finishStop(.failure(.init("The other Mac (Apple M3 Ultra, 256 GB) did not answer over the cable: timed out")),
                                    forwarded: true) { removed = true; return [] }
            Issue.record("a failed forwarded stop throws")
        } catch let failure as Stop.Failure {
            #expect(failure.lines.suffix(2) == [
                "The leading Mac didn't confirm the stop in time; it may still be finishing. `darkbloom status` shows where both "
                    + "Macs stand.",
                "To stop only this Mac: `darkbloom cluster stop --local-only` (the other Mac then serves alone, or waits for this one)."])
        }
        #expect(!removed)
        #expect(try Stop.finishStop(.success(["Stopping both Macs. Run `darkbloom cluster` to serve again."]), forwarded: true) { ["label"] }
            == ["Stopping both Macs. Run `darkbloom cluster` to serve again.",
                "This Mac's cluster service is stopped and will not start at login. Run `darkbloom cluster` to start it again."])
    }
}

private let unreadableReason = "pairings.json is malformed; nothing is trusted from it"
private let unsureSentence = "This Mac's pairing record couldn't be read (\(unreadableReason)), so it may be in a two-Mac cluster."

/// A Mac whose pairing record can't be read, with its cluster service off and no login agent.
private func unreadable() -> ClusterPairSummary {
    var summary = ClusterPairSummary.membership(.unreadable(unreadableReason), serviceRunning: false,
                                                loginAgentInstalled: false, startsAtLogin: false)
    summary.thisMacName = "Mac Studio"
    return summary
}

private func jsonObject(_ summary: ClusterPairSummary) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(summary.json)) as? [String: Any])
}

private struct StoreError: Error, CustomStringConvertible { let description: String }

@Suite("the paired-Mac commands when unsure, the member's silent leader, and command tests kept off this Mac's cluster")
struct ClusterPairTruthTests {
    @Test("a pairing record that can't be read is never 'not in a cluster'")
    func unreadablePairingIsNeverNotPaired() {
        let summary = unreadable()
        #expect(summary.paired && summary.state == .pairingUnreadable && summary.reason == unreadableReason)
        #expect(summary.exitCode == 7)
        #expect(ClusterPairSummary.membership(.unreadable(nil), serviceRunning: false, loginAgentInstalled: false,
                                              startsAtLogin: false).pairSentence
            == "This Mac's pairing record couldn't be read, so it may be in a two-Mac cluster.")
        // What this Mac holds otherwise is unchanged.
        #expect(ClusterPairSummary.membership(.none, serviceRunning: false, loginAgentInstalled: false, startsAtLogin: false) == .notPaired)
        #expect(!ClusterPairSummary.membership(.none, serviceRunning: true, loginAgentInstalled: false, startsAtLogin: false).paired)
        #expect(ClusterPairSummary.membership(.held, serviceRunning: false, loginAgentInstalled: false, startsAtLogin: false).state == .unknown)
        #expect(ClusterPairSummary.shownReason(StoreError(description: "pairings.json could not be read.")) == "pairings.json could not be read")
        #expect(ClusterPairSummary.shownReason(NSError(domain: "NSCocoaErrorDomain", code: 257)) == nil)
    }

    @Test("cluster status says the record couldn't be read and what to do, exit 7; --json says it with null unknowns")
    func unreadableClusterStatus() throws {
        #expect(unreadable().clusterStatusLines == [unsureSentence, "Next: Run `darkbloom cluster` on this Mac to check it."])
        let object = try jsonObject(unreadable())
        #expect(Set(object.keys) == ["schema", "paired", "role", "this_mac", "other_mac", "model", "mode", "split", "serves",
                                     "state", "reason", "next", "lines", "service", "exit_code"])
        #expect(object["paired"] is NSNull && object["role"] is NSNull && object["other_mac"] is NSNull)
        #expect(object["serves"] is NSNull && object["model"] is NSNull && object["mode"] is NSNull)
        #expect(object["state"] as? String == "pairing_unreadable" && object["exit_code"] as? Int == 7)
        #expect(object["reason"] as? String == unreadableReason)
        #expect(object["next"] as? String == "Run `darkbloom cluster` on this Mac to check it.")
        #expect(object["this_mac"] as? String == "Mac Studio")
        #expect((object["service"] as? [String: Any])?["running"] as? Bool == false)
    }

    @Test("`darkbloom cluster status --json` exits 7 when the pairing record can't be read")
    func unreadableClusterStatusCommand() async throws {
        let result = await #expect(processExitsWith: .exitCode(7), observing: [\.standardOutputContent]) {
            try await exitWithPair(unreadable()) { try await runCLICommand(Cluster.Status.self, ["cluster", "status", "--json"]) }
        }
        let object = try #require(try JSONSerialization.jsonObject(with: Data((result?.standardOutputContent ?? []))) as? [String: Any])
        #expect(object["state"] as? String == "pairing_unreadable" && object["paired"] is NSNull)
    }

    @Test("start and restart stay refused without --solo while unsure, and say why; stop, status, doctor and link say it too")
    func unreadableHabitCommands() throws {
        let startLine = "Single-Mac serving next to a cluster would compete for this Mac's memory. To serve on this Mac alone, run "
            + "`darkbloom cluster` on this Mac to check the pairing first, or pass --solo."
        #expect(Start.pairStart(unreadable(), solo: false, terminal: true) == .refuse([unsureSentence, startLine]))
        #expect(Start.pairStart(unreadable(), solo: false, terminal: false) == .refuse([unsureSentence, startLine]))
        #expect(Start.pairStart(unreadable(), solo: true, terminal: false) == .single(note: "Starting single-Mac serving "
            + "(--solo) although this Mac's pairing record couldn't be read: if it is in a two-Mac cluster, both use this Mac's memory."))
        #expect(Restart.pairRestart(unreadable(), singleMacInstalled: true, singleMacRunning: true, solo: false) == .refuse([unsureSentence,
            "`darkbloom restart` can't tell which pair to restart, so nothing was restarted.",
            "To restart single-Mac serving on this Mac only: `darkbloom restart --solo`. Run `darkbloom cluster` on this Mac to check it."]))
        #expect(Restart.pairRestart(unreadable(), singleMacInstalled: false, singleMacRunning: false, solo: true) == .refuse([unsureSentence,
            "`darkbloom restart --solo` restarts single-Mac serving, and this Mac has none: nothing was restarted.",
            "Run `darkbloom cluster` on this Mac to check it."]))
        #expect(Restart.pairRestart(unreadable(), singleMacInstalled: true, singleMacRunning: false, solo: true) == .restartSingleMac)
        #expect(unreadable().restartAddendum == unsureSentence + " No cluster was restarted.")
        #expect(Stop.pairedStop(unreadable(), solo: false, uninstall: false) == .refuse([unsureSentence,
            "`darkbloom stop` can't tell which pair to stop, so nothing was stopped.",
            "To stop single-Mac serving on this Mac only: `darkbloom stop --solo`. Run `darkbloom cluster` on this Mac to check it."]))
        #expect(Stop.pairedStop(unreadable(), solo: true, uninstall: false) == .stopSingleMac)
        #expect(unreadable().statusLine == "Cluster: this Mac's pairing record couldn't be read (\(unreadableReason)) · run "
            + "`darkbloom cluster` to check it (details: `darkbloom cluster status`)")
        #expect(Status.daemonNotRunningLine(paired: true, unsure: true)
            == "Single-Mac serving: off (this Mac may be in a two-Mac cluster: `darkbloom cluster status`)")
        #expect(Status.daemonNotRunningLine(paired: true, unsure: true, staleStateFile: true)
            == "Single-Mac serving: off (this Mac may be in a two-Mac cluster: `darkbloom cluster status`)")
        #expect(Status.daemonNotRunningLine(paired: false, staleStateFile: true) == "Daemon: not running (stale state file)")
        #expect(Doctor.daemonLine(running: false, paired: true, unsure: true)
            == "Daemon: single-Mac serving off (this Mac may be in a two-Mac cluster)")
        #expect(Cluster.Link.removalGate(unreadable(), yes: false, dryRun: false, json: false, terminal: true) == .ask([unsureSentence,
            "--remove undoes this Mac's cable port setup: a cluster that uses it stops serving on both Macs until the port is set "
                + "up again with `darkbloom cluster` (or `darkbloom cluster link --fix`)."]))
    }

    @Test("on the Mac that follows, a leading Mac that doesn't answer over the cable is away and not answering, in both outputs")
    func memberSilentLeaderAgrees() throws {
        let silent = "The other Mac (Apple M5 Max, 128 GB) doesn't answer over the cable (connection refused); it rejoins by itself."
        var member = pair(role: .member)
        member.read(status: [silent], leaderMode: nil)
        #expect(member.state == .otherMacAway && member.otherMacAnswers == false)
        #expect(member.clusterStatusLines.contains("✗ " + silent))
        #expect(member.clusterStatusLines.last == "Next: The other Mac (Apple M5 Max, 128 GB) isn't answering over the cable. Its "
            + "cluster service may have been turned off with `darkbloom cluster stop --service`, or that Mac is asleep, off, "
            + "or waiting for someone to log in. On that Mac, run `darkbloom start` (or `darkbloom cluster`).")
        let object = try jsonObject(member)
        #expect((object["other_mac"] as? [String: Any])?["answers"] as? Bool == false)
        #expect(object["state"] as? String == "other_mac_away" && object["exit_code"] as? Int == 5)
        var timedOut = pair(role: .member)
        timedOut.read(status: ["The other Mac (Apple M5 Max, 128 GB) did not answer over the cable: timed out"], leaderMode: nil)
        #expect(timedOut.state == .otherMacAway && timedOut.otherMacAnswers == false)
        var serving = pair(role: .member)
        serving.read(status: ["Serving Qwen 3.8 27B through Darkbloom on both Macs (tensor parallel)."], leaderMode: nil)
        #expect(serving.state == .serving && serving.otherMacAnswers == true)
    }

    @Test("a command test's child process never reads this Mac's own cluster: the sandbox says not in a cluster")
    func sandboxKeepsCommandsOffThisMacsCluster() async {
        await #expect(processExitsWith: .success) {
            let sandbox = try CLICommandSandbox.enter()
            // Without the sandbox's pair, each read below would be this Mac's real cluster: stop before any.
            guard ClusterPairSummary.processReaderForTesting != nil else { sandbox.remove(); exit(1) }
            let live = await ClusterPairSummary.live(config: nil)
            let isolated = ClusterPairSummary.local() == .notPaired && live == .notPaired
                && ClusterPairSummary.runningPartPID() == nil && !ClusterPairSummary.startedByClusterService()
            sandbox.remove()
            exit(isolated ? 0 : 2)
        }
    }
}

/// The pair's actions for a test; each call is said on standard error as `pair action: <name>`.
private let freed = ["This Mac: nothing left running", "The other Mac (Apple M5 Max, 128 GB): nothing left running"]
private let stillRunning = ["This Mac: nothing left running",
                            "The other Mac (Apple M5 Max, 128 GB): still running: this Mac's part of the model is still running"]

/// Values handed out in turn; the last one repeats.
private final class Looks<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Value]
    init(_ values: [Value]) { self.values = values }
    func next() -> Value { lock.withLock { values.count > 1 ? values.removeFirst() : values[0] } }
}

private func pairActions(role: ClusterOnboardingRole = .leader, serving: Bool = true,
                         stop: Result<[String], ClusterOnboardingFailure> = .success(["Stopping both Macs. Run `darkbloom cluster` to serve again."]),
                         serve: Result<[String], ClusterOnboardingFailure> = .success(["Started the other Mac's part over the cable."]),
                         teardown: [Result<[String], ClusterOnboardingFailure>] = [.success(freed)], stopDelay: Double = 0)
    -> ClusterPairActions {
    @Sendable func said(_ action: String) { FileHandle.standardError.write(Data("pair action: \(action)\n".utf8)) }
    let teardownLooks = Looks(teardown)
    return ClusterPairActions(
        resume: { ClusterOnboardingResume(role: role, peerName: "Apple M5 Max, 128 GB", serving: serving, modelName: "EigenLabs/Qwen3.8-27B-4bit-mtp") },
        ensureService: { said("ensureService"); return .success(()) },
        serve: { said("serve"); return serve },
        stop: { said("stop"); Thread.sleep(forTimeInterval: stopDelay); return stop },
        verifyTeardown: { said("verifyTeardown"); return teardownLooks.next() })
}

/// The pair as `cluster status` reads a status line (`read(status:)`, the production classifier).
private func observed(_ line: String, role: ClusterPairSummary.Role = .leader) -> ClusterPairSummary {
    var summary = pair(role: role)
    summary.read(status: [line], leaderMode: nil)
    return summary
}

/// A Mac whose saved start is left from a pair whose other Mac stopped taking part (0.10.8: online, no traffic).
private func stalePair() -> ClusterPairSummary {
    var summary = pair()
    summary.pairRunning = false
    summary.pairNotRunning = "The other Mac (Apple M5 Max, 128 GB) hasn't answered for 15 min; this Mac's part stopped. Run "
        + "`darkbloom start --solo` to serve this Mac alone, or `darkbloom start` to start the pair again."
    return summary
}

/// `stalePair()` set up by `darkbloom cluster` for Only me (`[local] mode = "local"` is saved beside it).
private func onlyMeStalePair() -> ClusterPairSummary {
    var summary = stalePair()
    summary.localOnly = true
    return summary
}

/// A pair stopped with `darkbloom stop`: its saved start is off, and both cluster services stay up, so the other Mac answers.
private func stoppedPair() -> ClusterPairSummary {
    var summary = pair(started: false)
    summary.pairRunning = false
    summary.otherMacReachable = true
    return summary
}

/// Single-Mac serving this Mac ran before it was paired, stopped since (`darkbloom stop --solo`, or the cluster screen's
/// consented stop): `stop` unloads and disables its job but keeps its plist on disk. Written in the sandbox's home only.
private func leaveStoppedSingleMacPlist(in sandbox: CLICommandSandbox) throws {
    let path = LaunchAgent.plistPath()
    try #require(path.path.hasPrefix(sandbox.root.path + "/"), "the plist must be the sandbox's, never this Mac's: \(path.path)")
    let plist: [String: Any] = ["Label": LaunchAgent.label, "RunAtLoad": true, "KeepAlive": false,
                                "ProgramArguments": ["/fixture/darkbloom", "start", "--foreground", "--model", "acme/Alpha-4bit"]]
    try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: path)
}

/// launchctl as `recordingLaunchctl`, except that `print` finds single-Mac serving's job loaded with no process: set up
/// here, its process ended (launchd keeps a `KeepAlive` false job loaded after a crash).
private func loadedSingleMacLaunchctl(_ arguments: [String]) throws -> LaunchctlControl.Output {
    let job = LaunchctlControl.target(label: LaunchAgent.label)
    guard arguments == ["print", job] else { return try recordingLaunchctl(arguments) }
    FileHandle.standardError.write(Data("launchctl: \(arguments.joined(separator: " "))\n".utf8))
    return LaunchctlControl.Output(status: 0, stdout: "\(job) = {\n\tstate = not running\n}\n", stderr: "")
}

private func pairActionCalls(_ stderr: String) -> [String] {
    stderr.split(separator: "\n").filter { $0.hasPrefix("pair action: ") }.map { String($0.dropFirst("pair action: ".count)) }
}

private func servingPair(role: ClusterPairSummary.Role = .leader) -> ClusterPairSummary {
    var summary = pair(role: role)
    // Its other Mac answers this Mac's cluster service, as it does while the pair serves.
    summary.otherMacReachable = true
    summary.state = .serving
    summary.lines = ["Serving Qwen 3.8 27B through Darkbloom on both Macs (tensor parallel)."]
    return summary
}

private let resultFooter = ["", "  darkbloom stop     Stop both Macs", "  darkbloom restart  Restart with the current model",
                            "  darkbloom status   Check status"]

/// The first line of a start on a pair that already serves (J2-b), and of one in a terminal that opens the pair's screen
/// (J2-d): neither says "starting".
private let alreadyServes = "This Mac is in a two-Mac cluster with \(otherMac): the pair already serves."
private let openingScreen = "This Mac is in a two-Mac cluster with \(otherMac): opening the pair's screen."

private let servingBlock = ["✓ Serving Qwen 3.8 27B through Darkbloom on both Macs (tensor parallel).",
                            "  Model:   Qwen 3.8 27B · tensor parallel · M3 Ultra 50% / M5 Max 50%",
                            "  Macs:    this Mac (Mac Studio) leads · \(otherMac) follows",
                            "  Serves:  through Darkbloom"] + resultFooter

private func lines(_ bytes: [UInt8]?) -> [String] { text(bytes).split(separator: "\n", omittingEmptySubsequences: false).map(String.init) }

/// Standard input that never answers, as a script's or an agent's can be: a pipe whose write end this process keeps open,
/// so any read waits forever. The alarm ends the process after a minute (SIGALRM), so a start that reads fails its exit
/// test instead of hanging the run. The tools' discovery folder is the sandbox's: no local API runs there.
private func neverAnswering(_ sandbox: CLICommandSandbox) throws {
    var ends: [Int32] = [0, 0]
    guard pipe(&ends) == 0, dup2(ends[0], STDIN_FILENO) >= 0 else { throw POSIXError(.EBADF) }
    clearerr(stdin)
    setenv("DARKBLOOM_LOCAL_DIR", sandbox.root.appendingPathComponent("local", isDirectory: true).path, 1)
    alarm(60)
}

/// No start asks which models to serve without a terminal: it says how to name them instead.
private let modelsWithoutATerminal = "Without a terminal, `darkbloom start` can't ask which models to serve: add --model <id> "
    + "(`darkbloom models list` shows this Mac's models) or --all."

/// A cluster command holds the pair's command lock through the whole wait (`ClusterService.releaseForSingleMac`).
private func commandStillRunning(_ waiting: () -> Void) -> ClusterService.SingleMacRelease {
    waiting()
    return .commandStillRunning
}

/// The app's Start on a paired Mac that asked for another model and a local API (`ClusterPairSummary.appStartLines`):
/// the model the pair serves, and that a pair serving through Darkbloom only gives this Mac no local API.
private let appStartServesLine = "This Mac serves in a pair: the pair serves Qwen 3.8 27B; `darkbloom cluster` changes its model."
private let appStartNoLocalAPILine = "No local API was added on this Mac: a pair's local API comes from how the pair serves "
    + "(`darkbloom cluster` on the leading Mac changes it)."

@Suite("darkbloom start, stop, restart and status control the pair on a Mac in a two-Mac cluster")
struct ClusterPairControlTests {
    @Test("`darkbloom stop` on the leading Mac stops both Macs, keeps them stopped and checks the memory; launchd untouched")
    func stopOnTheLeader() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent, \.standardErrorContent]) {
            try await exitWithPair(servingPair(), actions: pairActions()) { _ in try await runCLICommand(Stop.self, ["stop"]) }
        }
        #expect(lines(result?.standardOutputContent) == [
            "This Mac is in a two-Mac cluster with \(otherMac): stopping both Macs.",
            "Stopped on both Macs. They stay stopped after a restart; `darkbloom start` on either Mac starts the pair again.",
            "Memory freed on both Macs ✓", ""])
        let stderr = text(result?.standardErrorContent)
        #expect(pairActionCalls(stderr) == ["stop", "verifyTeardown"])
        #expect(changingLaunchctlCalls(stderr).isEmpty, "\(changingLaunchctlCalls(stderr))")
    }

    @Test("`darkbloom stop` on the Mac that follows asks the leading Mac to stop both Macs")
    func stopOnTheMember() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent, \.standardErrorContent]) {
            try await exitWithPair(servingPair(role: .member), actions: pairActions(role: .member)) { _ in
                try await runCLICommand(Stop.self, ["stop"])
            }
        }
        let out = lines(result?.standardOutputContent)
        #expect(out.first == "This Mac is in a two-Mac cluster with \(otherMac): stopping both Macs.")
        #expect(out.contains(ClusterPairSummary.stoppedLine))
        #expect(pairActionCalls(text(result?.standardErrorContent)) == ["stop", "verifyTeardown"])
    }

    @Test("`darkbloom stop` when the leading Mac doesn't answer: says so by name and how to stop this Mac alone; exit 1")
    func stopWhenTheLeaderDoesNotAnswer() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardOutputContent, \.standardErrorContent]) {
            try await exitWithPair(servingPair(role: .member), actions: pairActions(role: .member,
                stop: .failure(.init("The other Mac (Apple M5 Max, 128 GB) did not answer over the cable: timed out")))) { _ in
                try await runCLICommand(Stop.self, ["stop"])
            }
        }
        #expect(lines(result?.standardOutputContent) == [
            "This Mac is in a two-Mac cluster with \(otherMac): stopping both Macs.",
            "  The other Mac (Apple M5 Max, 128 GB) did not answer over the cable: timed out",
            "The leading Mac didn't confirm the stop in time; it may still be finishing. `darkbloom status` shows where both "
                + "Macs stand.",
            "To stop only this Mac: `darkbloom cluster stop --local-only` (the other Mac then serves alone, or waits for this one).", ""])
        #expect(pairActionCalls(text(result?.standardErrorContent)) == ["stop"])
    }

    @Test("`darkbloom start --solo` on a Mac whose pair doesn't run: frees the leftover part, then single-Mac serving starts")
    func startSoloOnAStalePair() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardOutputContent, \.standardErrorContent]) {
            try await exitWithPair(stalePair(), actions: pairActions()) { _ in
                try await Start.$releaseForTesting.withValue({ FileHandle.standardError.write(Data("released\n".utf8)); return true }) {
                    try await runCLICommand(Start.self, ["start", "--solo", "--model", "acme/Alpha-4bit"])
                }
            }
        }
        let out = lines(result?.standardOutputContent)
        #expect(Array(out.prefix(2)) == [stalePair().leftoverStopLine, stalePair().leftoverReleasedLine], "\(out)")
        // The single-Mac start went ahead (it ends at this sandbox's missing model, never at a refusal).
        #expect(out.contains("By starting the provider, you agree to the Darkbloom Terms of Service:"), "\(out)")
        let stderr = text(result?.standardErrorContent)
        #expect(stderr.contains("released"))
        #expect(pairActionCalls(stderr).isEmpty)
    }

    /// A terminal `darkbloom cluster` saves the pair's "Only me" (`cluster local`) as `[local] mode = "local"`, which a
    /// single-Mac start on this Mac reads too. A script's `start --solo` runs without a terminal: on a Mac whose pair
    /// doesn't run here (the other Mac asleep or gone, this Mac's part serving alone or waiting), it is refused in
    /// `start`'s one line before this Mac's part is stopped or its saved start cleared, as for one Mac. Before, the part
    /// was stopped and the start cleared first. The desktop app's Start (`start --model <id> --config <path>`) starts the
    /// pair instead, which reads no single-Mac mode.
    @Test("without a terminal, the pair's saved Only me is refused before this Mac's part is stopped")
    func nonTerminalStartWithThePairsOnlyMeLeavesThePart() async {
        let refusal = "error: This Mac is set to Only me, which serves in a terminal. Run `darkbloom start` in one, or name "
            + "how to serve: --local, --network or --me-first."
        let app = await #expect(processExitsWith: .success, observing: [\.standardOutputContent, \.standardErrorContent]) {
            var stale = stalePair()
            stale.localOnly = true
            try await exitWithPair(stale, actions: pairActions()) { sandbox in
                guard case .success = Cluster.Setup.saveServingChoice(.onlyMe, config: sandbox.config.path) else { throw ExitCode(98) }
                try await ClusterPairCommands.$terminalForTesting.withValue(false) {
                    try await Start.$releaseForTesting.withValue({ FileHandle.standardError.write(Data("released\n".utf8)); return true }) {
                        try await ClusterPairSummary.$readerForTesting.withValue({ live in live ? servingPair() : onlyMeStalePair() }) {
                            try await ClusterPairCommands.$waitForTesting.withValue(.init(seconds: 0, interval: 0)) {
                                try await runCLICommand(Start.self, ["start", "--model", "acme/Alpha-4bit", "--config", sandbox.config.path])
                            }
                        }
                    }
                }
            }
        }
        let solo = await #expect(processExitsWith: .failure, observing: [\.standardOutputContent, \.standardErrorContent]) {
            var stale = stalePair()
            stale.localOnly = true
            try await exitWithPair(stale, actions: pairActions()) { sandbox in
                guard case .success = Cluster.Setup.saveServingChoice(.onlyMe, config: sandbox.config.path) else { throw ExitCode(98) }
                try await ClusterPairCommands.$terminalForTesting.withValue(false) {
                    try await Start.$releaseForTesting.withValue({ FileHandle.standardError.write(Data("released\n".utf8)); return true }) {
                        try await runCLICommand(Start.self, ["start", "--solo", "--config", sandbox.config.path])
                    }
                }
            }
        }
        // The app's Start starts the pair (`appStartStartsThePair`): the saved Only me is single-Mac serving's, never read.
        let appStderr = text(app?.standardErrorContent)
        #expect(!appStderr.contains(refusal), "the app's Start: \(appStderr)")
        #expect(pairActionCalls(appStderr) == ["ensureService", "serve"], "the app's Start: \(pairActionCalls(appStderr))")
        let soloStderr = text(solo?.standardErrorContent)
        #expect(soloStderr.components(separatedBy: "\n").filter { $0 == refusal }.count == 1, "--solo: \(soloStderr)")
        #expect(pairActionCalls(soloStderr).isEmpty, "--solo")
        for (name, result) in [("the app's Start", app), ("--solo", solo)] {
            let stderr = text(result?.standardErrorContent), out = text(result?.standardOutputContent)
            #expect(!stderr.contains("released"), "\(name): this Mac's part keeps running")
            #expect(!out.contains("its saved start is cleared"), "\(name): \(out)")
        }
    }

    @Test("a leftover part that doesn't stop: nothing starts beside it, and the one step that always works is named")
    func startSoloWhenTheLeftoverWontStop() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardOutputContent]) {
            try await exitWithPair(stalePair(), actions: pairActions()) { _ in
                try await Start.$releaseForTesting.withValue({ false }) {
                    try await runCLICommand(Start.self, ["start", "--solo", "--model", "acme/Alpha-4bit"])
                }
            }
        }
        #expect(Array(lines(result?.standardOutputContent).suffix(3)) == [
            "This Mac's part of the pair didn't stop in time, so single-Mac serving can't start yet.",
            "To leave the pair on this Mac: `darkbloom cluster pair --status`, then `darkbloom cluster pair --forget <pin>`, then "
                + "`darkbloom start`.", ""])
    }

    /// A cluster command holds the pair's command lock (a person's model change, or the cluster service's own step after
    /// an update): `stop` and `start --solo` on a Mac whose pair doesn't run wait for it, up to 10 minutes. The wait is
    /// said at once, and a command still running at its end is said as such: nothing was stopped, and leaving the pair
    /// isn't the way out. The desktop app's Stop and Start run these commands.
    @Test("a running cluster command: the wait is said at once, and its end as a busy pair, never as a part that didn't stop")
    func stopAndStartSayTheyWaitForARunningClusterCommand() async {
        let stop = await #expect(processExitsWith: .failure, observing: [\.standardOutputContent]) {
            try await exitWithPair(stalePair(), actions: pairActions()) { _ in
                try await Start.$releaseOutcomeForTesting.withValue(commandStillRunning) { try await runCLICommand(Stop.self, ["stop"]) }
            }
        }
        let start = await #expect(processExitsWith: .failure, observing: [\.standardOutputContent]) {
            try await exitWithPair(stalePair(), actions: pairActions()) { _ in
                try await Start.$releaseOutcomeForTesting.withValue(commandStillRunning) {
                    try await runCLICommand(Start.self, ["start", "--solo", "--model", "acme/Alpha-4bit"])
                }
            }
        }
        for (name, result) in [("stop", stop), ("start --solo", start)] {
            let out = lines(result?.standardOutputContent)
            #expect(Array(out.suffix(3)) == [
                "Waiting for the pair's running command to finish (up to 10 minutes; ^C stops waiting and leaves the pair as it is).",
                "The pair's command was still running after 10 minutes, so nothing was stopped or started. Try again, or run "
                    + "`darkbloom cluster` to see what's running.", ""], "\(name): \(out)")
            #expect(!out.contains { $0.contains("--forget") }, "\(name): \(out)")
        }
    }

    @Test("`darkbloom stop` on a Mac whose pair doesn't run stops what runs here and never asks the other Mac")
    func stopOnAStalePair() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent, \.standardErrorContent]) {
            try await exitWithPair(stalePair(), actions: pairActions()) { _ in
                try await Start.$releaseForTesting.withValue({ FileHandle.standardError.write(Data("released\n".utf8)); return true }) {
                    try await runCLICommand(Stop.self, ["stop"])
                }
            }
        }
        #expect(lines(result?.standardOutputContent).first == "This Mac is in a two-Mac cluster with \(otherMac), which isn't "
            + "running here: stopping this Mac's leftover part and clearing its saved start (`darkbloom start` starts the pair again).")
        let stderr = text(result?.standardErrorContent)
        #expect(stderr.contains("released"))
        #expect(pairActionCalls(stderr).isEmpty, "\(pairActionCalls(stderr))")
    }

    @Test("`darkbloom stop --solo` never touches the pair")
    func stopSolo() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent, \.standardErrorContent]) {
            try await exitWithPair(servingPair(), actions: pairActions()) { _ in try await runCLICommand(Stop.self, ["stop", "--solo"]) }
        }
        #expect(lines(result?.standardOutputContent) == [
            "`darkbloom stop --solo` stops single-Mac serving, and none runs on this Mac: nothing was stopped.",
            "The pair keeps running. If single-Mac serving blocks it, it runs on \(otherMac): run `darkbloom stop --solo` there.", ""])
        let calls = pairActionCalls(text(result?.standardErrorContent))
        #expect(calls.isEmpty, "\(calls)")
    }

    /// solo-steps-failed.md §3.3: `stop --solo` run on the wrong Mac finds single-Mac serving on the other Mac and stops it
    /// there with consent (`--yes` here); never plain `stop`, and the pair isn't touched.
    @Test("`darkbloom stop --solo --yes` on the wrong Mac stops single-Mac serving on the other Mac")
    func stopSoloOnTheWrongMac() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent, \.standardErrorContent]) {
            var actions = pairActions()
            actions.soloServing = { [ClusterOnboardingSoloServing(mac: "the other Mac (Apple M5 Max, 128 GB)", pid: 68099)] }
            actions.stopSoloServing = {
                FileHandle.standardError.write(Data("pair action: stopSoloServing\n".utf8))
                return .success(["\u{2713} Stopped single-Mac serving on the other Mac (Apple M5 Max, 128 GB)."])
            }
            try await exitWithPair(servingPair(), actions: actions) { _ in try await runCLICommand(Stop.self, ["stop", "--solo", "--yes"]) }
        }
        #expect(lines(result?.standardOutputContent) == [
            "Single-Mac serving doesn't run on this Mac; it runs on the other Mac (Apple M5 Max, 128 GB) (process 68099).",
            "\u{2713} Stopped single-Mac serving on the other Mac (Apple M5 Max, 128 GB).", ""])
        #expect(pairActionCalls(text(result?.standardErrorContent)) == ["stopSoloServing"])
    }

    @Test("`darkbloom start` in a terminal opens exactly what `darkbloom cluster` runs on this Mac")
    func startInATerminal() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent, \.standardErrorContent]) {
            try await exitWithPair(servingPair(), actions: pairActions()) { _ in
                try await ClusterPairCommands.$terminalForTesting.withValue(true) {
                    try await ClusterPairCommands.$screenForTesting.withValue({ config in
                        print("screen: darkbloom cluster (config \(config ?? "default"))")
                    }) { try await runCLICommand(Start.self, ["start"]) }
                }
            }
        }
        #expect(lines(result?.standardOutputContent) == [openingScreen, "screen: darkbloom cluster (config default)", ""])
        let calls = pairActionCalls(text(result?.standardErrorContent))
        #expect(calls.isEmpty, "\(calls)")
    }

    /// Journey 2a (pair-2, J2-b): a script's `start` on a pair that served said "starting the pair". It keeps the pair as
    /// it is: one look, then the result block, and nothing is asked of either Mac.
    @Test("`darkbloom start` without a terminal on a pair that already serves says so, starts nothing and ends with the result block; exit 0")
    func startWithoutATerminal() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent, \.standardErrorContent]) {
            try await exitWithPair(servingPair(), actions: pairActions()) { _ in try await runCLICommand(Start.self, ["start"]) }
        }
        #expect(lines(result?.standardOutputContent) == [alreadyServes] + servingBlock + [""])
        let calls = pairActionCalls(text(result?.standardErrorContent))
        #expect(calls.isEmpty, "\(calls)")
    }

    @Test("`darkbloom start` with single-Mac options and no --solo on a Mac in a cluster refuses them by name")
    func startRefusesSingleMacOptions() throws {
        #expect(try Start.parse(["--model", "acme/Alpha-4bit"]).singleMacOptions == ["--model"])
        #expect(try Start.parse(["--solo"]).singleMacOptions.isEmpty)
        #expect(try Start.parse(["--config", "/tmp/provider.toml"]).singleMacOptions.isEmpty)
        #expect(try Start.parse(["--coordinator-url", "wss://coordinator.invalid/ws", "--no-autopilot", "--all", "--idle-timeout",
                                 "5", "--schedule", "--local", "--port", "8123", "--bind", "0.0.0.0", "--no-auth", "--timeout",
                                 "30", "--force"]).singleMacOptions
            == ["--coordinator-url", "--no-autopilot", "--all", "--idle-timeout", "--schedule", "--local", "--port", "--bind",
                "--no-auth", "--timeout", "--force"])
        #expect(try Start.parse(["--local-endpoint", "--autopilot"]).singleMacOptions == ["--autopilot", "--local-endpoint"])
        let refusal = [
            "This Mac is in a two-Mac cluster with \(otherMac): `--model` is for single-Mac serving, so nothing was started.",
            "To choose the pair's model, run `darkbloom start` in a terminal; to serve this Mac alone with it, add --solo.",
        ]
        #expect(Start.pairStart(pair(), solo: false, terminal: true, singleMacOptions: ["--model"]) == .refuseOptions(refusal))
        // Without a terminal (the app's Start), `--model` starts the pair with its own model (`appStartStartsThePair`).
        #expect(Start.pairStart(pair(), solo: false, terminal: false, singleMacOptions: ["--model"]) == .startPair)
        #expect(Start.pairStart(pair(started: false), solo: true, terminal: false, singleMacOptions: ["--model"]) == .serveAlone(note:
            "This Mac is in a two-Mac cluster with \(otherMac), which is stopped: serving this Mac alone (`darkbloom start` "
                + "starts the pair again)."))
        #expect(Start.pairStart(.notPaired, solo: false, terminal: false, singleMacOptions: ["--model"]) == .single(note: nil))
        #expect(pair().singleMacOptionsRefusal(["--local", "--port", "--bind"]) == [
            "This Mac is in a two-Mac cluster with \(otherMac): `--local`, `--port` and `--bind` are for single-Mac serving, so "
                + "nothing was started.",
            "To choose the pair's model, run `darkbloom start` in a terminal; to serve this Mac alone with them, add --solo.",
            "To serve the pair on the leading Mac's own API only: `darkbloom cluster local`.",
        ])
    }

    /// In a terminal a person can add --solo; without one (the app's Start) the pair starts (`appStartStartsThePair`).
    @Test("`darkbloom start --model X` in a terminal on a Mac in a cluster starts nothing and says why; exit 64")
    func startWithAModelOnThePair() async {
        let result = await #expect(processExitsWith: .exitCode(64), observing: [\.standardOutputContent, \.standardErrorContent]) {
            try await exitWithPair(servingPair(), actions: pairActions()) { _ in
                try await ClusterPairCommands.$terminalForTesting.withValue(true) {
                    try await runCLICommand(Start.self, ["start", "--model", "acme/Alpha-4bit"])
                }
            }
        }
        #expect(lines(result?.standardOutputContent) == [
            "This Mac is in a two-Mac cluster with \(otherMac): `--model` is for single-Mac serving, so nothing was started.",
            "To choose the pair's model, run `darkbloom start` in a terminal; to serve this Mac alone with it, add --solo.", ""])
        let calls = pairActionCalls(text(result?.standardErrorContent))
        #expect(calls.isEmpty, "\(calls)")
    }

    @Test("`darkbloom start` without a terminal on a pair that never chose a model says how to choose one; the pair is untouched")
    func startWithoutAModel() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardOutputContent, \.standardErrorContent]) {
            try await exitWithPair(pair(started: false, model: false), actions: pairActions(serving: false)) { _ in
                try await runCLICommand(Start.self, ["start"])
            }
        }
        #expect(lines(result?.standardOutputContent) == ["This Mac is in a two-Mac cluster with \(otherMac): starting the pair.",
            ClusterPairSummary.noModelLine, ""])
        let calls = pairActionCalls(text(result?.standardErrorContent))
        #expect(calls.isEmpty, "\(calls)")
    }

    @Test("`darkbloom start` without a terminal that doesn't serve says why and exits with cluster status's code")
    func startThatDoesNotServe() async {
        let result = await #expect(processExitsWith: .exitCode(3), observing: [\.standardOutputContent]) {
            var summary = pair()
            summary.state = .notServing
            summary.reason = "This Mac isn't logged in to Darkbloom, so the coordinator won't pair it"
            summary.lines = ["Qwen 3.8 27B is not serving yet: \(summary.reason!)."]
            try await exitWithPair(summary, actions: pairActions()) { _ in try await runCLICommand(Start.self, ["start"]) }
        }
        let out = lines(result?.standardOutputContent)
        #expect(out.contains("✗ Not serving: This Mac isn't logged in to Darkbloom, so the coordinator won't pair it."))
        #expect(out.contains("  Next:    Run `darkbloom login` on each Mac named, then `darkbloom cluster` on this Mac. Or serve "
            + "locally only: `darkbloom cluster local` on this Mac."))
    }

    @Test("`darkbloom start` on the Mac that follows, with the leading Mac away: says so and exits 5")
    func startWithTheLeaderAway() async {
        let result = await #expect(processExitsWith: .exitCode(5), observing: [\.standardOutputContent, \.standardErrorContent]) {
            var summary = pair(role: .member)
            summary.state = .otherMacAway
            summary.lines = ["The other Mac (Apple M5 Max, 128 GB) did not answer over the cable: connection refused"]
            try await exitWithPair(summary, actions: pairActions(role: .member,
                serve: .failure(.init("The other Mac (Apple M5 Max, 128 GB) did not answer over the cable: connection refused")))) { _ in
                try await ClusterPairCommands.$waitForTesting.withValue(.init(seconds: 0, interval: 0)) {
                    try await runCLICommand(Start.self, ["start"])
                }
            }
        }
        let out = lines(result?.standardOutputContent)
        #expect(out.contains("  The other Mac (Apple M5 Max, 128 GB) did not answer over the cable: connection refused"))
        #expect(out.contains("✗ The other Mac (Apple M5 Max, 128 GB) did not answer over the cable: connection refused"))
        #expect(pairActionCalls(text(result?.standardErrorContent)) == ["ensureService", "serve"])
    }

    @Test("`darkbloom restart` stops the pair, starts it again with its model and ends with the result block")
    func restartThePair() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent, \.standardErrorContent]) {
            try await exitWithPair(servingPair(), actions: pairActions()) { _ in try await runCLICommand(Restart.self, ["restart"]) }
        }
        #expect(lines(result?.standardOutputContent) == [
            "This Mac is in a two-Mac cluster with \(otherMac): restarting both Macs.",
            "  Stopped on both Macs; starting it again."] + servingBlock + [""])
        #expect(pairActionCalls(text(result?.standardErrorContent)) == ["stop", "verifyTeardown", "ensureService", "serve"])
    }

    /// DevNet pair-2, 2026-11-07: `restart` on the stopped pair's leading Mac loaded the single-Mac job it served with
    /// before pairing ("Provider started."), which registered with the coordinator and held the Mac's serving lock.
    @Test("`darkbloom restart` on a Mac whose pair is stopped starts nothing: a single-Mac plist left by `stop` is not started; exit 1")
    func restartOnAStoppedPairStartsNothing() async {
        let result = await #expect(processExitsWith: .exitCode(1), observing: [\.standardOutputContent, \.standardErrorContent]) {
            try await exitWithPair(stoppedPair(), actions: pairActions(serving: false)) { sandbox in
                try leaveStoppedSingleMacPlist(in: sandbox)
                // A restart that starts the pair again would wait up to 10 minutes for it to serve: fail in seconds.
                try await ClusterPairCommands.$waitForTesting.withValue(.init(seconds: 0, interval: 0)) {
                    try await runCLICommand(Restart.self, ["restart"])
                }
            }
        }
        #expect(text(result?.standardOutputContent) == transcript(stoppedPair().idleRestartRefusal))
        let stderr = text(result?.standardErrorContent)
        #expect(changingLaunchctlCalls(stderr).isEmpty, "\(changingLaunchctlCalls(stderr))")
        #expect(pairActionCalls(stderr).isEmpty, "\(pairActionCalls(stderr))")
    }

    /// The other side: single-Mac serving set up here still restarts, also with its process ended (a crash). Its loaded
    /// job is what counts, never a running process: the watchdog recovers such a job the same way.
    @Test("`darkbloom restart` on a Mac whose pair is stopped still restarts single-Mac serving whose job is loaded")
    func restartOnAStoppedPairRestartsLoadedSingleMacServing() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardOutputContent, \.standardErrorContent]) {
            try await DarkbloomCommandLook.$forTesting.withValue(terminalLook()) {
                try await exitWithPair(stoppedPair(), actions: pairActions(serving: false)) { sandbox in
                    try leaveStoppedSingleMacPlist(in: sandbox)
                    try await LaunchctlControl.$runnerForTesting.withValue(loadedSingleMacLaunchctl) {
                        try await ClusterPairCommands.$waitForTesting.withValue(.init(seconds: 0, interval: 0)) {
                            try await runCLICommand(Restart.self, ["restart"])
                        }
                    }
                }
            }
        }
        // It goes ahead (only a restart that does opens with the mark) into single-Mac serving's drain, where the harness
        // stops it: no update lease beside the test runner, and every launchctl change refused.
        let stream = text(result?.standardOutputContent)
        #expect(stream.hasPrefix("\n" + DarkbloomCommandLook.mark("Darkbloom restart", revealed: Int.max, colour: "38;5;27") + "\n"),
                "\(stream.debugDescription)")
        #expect(stream.contains("\u{1B}[2mDraining accepted requests\u{2026}\u{1B}[0m"), "\(stream.debugDescription)")
        #expect(!stream.contains("Nothing serves on this Mac"), "\(stream.debugDescription)")
        let calls = pairActionCalls(text(result?.standardErrorContent))
        #expect(calls.isEmpty, "\(calls)")
    }

    /// `stop` says "`darkbloom start` on either Mac starts the pair again", and a script (or an agent following
    /// `cluster status`'s `next`) now finds that true: on DevNet pair-2 it served this Mac alone and stopped at the model
    /// picker.
    @Test("`darkbloom start` without a terminal on a stopped pair starts it again with its saved model; exit 0")
    func startWithoutATerminalStartsAStoppedPair() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent, \.standardErrorContent]) {
            try await exitWithPair(stoppedPair(), actions: pairActions(serving: false)) { _ in
                try replaceStandardInput(with: "")
                try await ClusterPairSummary.$readerForTesting.withValue({ live in live ? servingPair() : stoppedPair() }) {
                    try await ClusterPairCommands.$waitForTesting.withValue(.init(seconds: 0, interval: 0)) {
                        try await runCLICommand(Start.self, ["start"])
                    }
                }
            }
        }
        #expect(lines(result?.standardOutputContent) == ["This Mac is in a two-Mac cluster with \(otherMac): starting the pair."]
            + servingBlock + [""])
        #expect(pairActionCalls(text(result?.standardErrorContent)) == ["ensureService", "serve"])
    }

    @Test("`darkbloom start` in a terminal on a stopped pair opens the pair's screen, with no question first")
    func startInATerminalOpensAStoppedPairsScreen() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent, \.standardErrorContent]) {
            try await exitWithPair(stoppedPair(), actions: pairActions(serving: false)) { _ in
                try replaceStandardInput(with: "")
                try await ClusterPairCommands.$terminalForTesting.withValue(true) {
                    try await ClusterPairCommands.$screenForTesting.withValue({ config in
                        print("screen: darkbloom cluster (config \(config ?? "default"))")
                    }) { try await runCLICommand(Start.self, ["start"]) }
                }
            }
        }
        // Journey 2a (J2-d): it said "starting the pair", then waited at the list; nothing starts before Enter.
        #expect(lines(result?.standardOutputContent) == [
            "This Mac is in a two-Mac cluster with \(otherMac), which is stopped. Press Enter to start it with Qwen 3.8 27B "
                + "(last used), or choose another model.",
            "screen: darkbloom cluster (config default)", ""])
        let calls = pairActionCalls(text(result?.standardErrorContent))
        #expect(calls.isEmpty, "\(calls)")
    }

    /// The desktop app's Start runs `DesktopBackend.arguments` (`start --model <id> [--local-endpoint] --config <path>`)
    /// in its worker, standard input `/dev/null` (`DesktopWorker`). The app has no --solo, so on a paired Mac its Start
    /// starts the pair, as a plain start does, and never serves this Mac alone. When it asked for another model than the
    /// pair's, a line the app shows names the model the pair serves, and where to change it; another says when the local
    /// API it asked for wasn't added (`ClusterPairSummary.appStartLines`).
    @Test("the app's Start on a paired Mac starts the pair with the pair's model, says so when it asked for another, and never serves alone")
    func appStartStartsThePair() async {
        let other = await #expect(processExitsWith: .success, observing: [\.standardOutputContent, \.standardErrorContent]) {
            try await exitWithPair(stoppedPair(), actions: pairActions(serving: false)) { sandbox in
                try neverAnswering(sandbox)
                let request = try JSONDecoder().decode(DesktopAction.self, from: Data(
                    #"{"id":"x","action":"start","models":["acme/Alpha-4bit"],"endpoint":true}"#.utf8))
                let arguments = try DesktopBackend.arguments(for: request, configPath: sandbox.config.path, localActive: false)
                guard arguments == ["start", "--model", "acme/Alpha-4bit", "--local-endpoint", "--config", sandbox.config.path]
                else { throw ExitCode(97) }
                try await ClusterPairSummary.$readerForTesting.withValue({ live in live ? servingPair() : stoppedPair() }) {
                    try await ClusterPairCommands.$waitForTesting.withValue(.init(seconds: 0, interval: 0)) {
                        try await runCLICommand(Start.self, arguments)
                    }
                }
            }
        }
        let same = await #expect(processExitsWith: .success, observing: [\.standardOutputContent, \.standardErrorContent]) {
            try await exitWithPair(stoppedPair(), actions: pairActions(serving: false)) { sandbox in
                try neverAnswering(sandbox)
                let request = try JSONDecoder().decode(DesktopAction.self, from: Data(
                    #"{"id":"x","action":"start","models":["EigenLabs/Qwen3.8-27B-4bit-mtp"]}"#.utf8))
                let arguments = try DesktopBackend.arguments(for: request, configPath: sandbox.config.path, localActive: false)
                try await ClusterPairSummary.$readerForTesting.withValue({ live in live ? servingPair() : stoppedPair() }) {
                    try await ClusterPairCommands.$waitForTesting.withValue(.init(seconds: 0, interval: 0)) {
                        try await runCLICommand(Start.self, arguments)
                    }
                }
            }
        }
        let starting = "This Mac is in a two-Mac cluster with \(otherMac): starting the pair."
        // The app also asked for a local API (`--local-endpoint`); a pair that serves through Darkbloom only gives none.
        #expect(lines(other?.standardOutputContent) == [starting] + servingBlock + [appStartServesLine, appStartNoLocalAPILine, ""])
        #expect(lines(same?.standardOutputContent) == [starting] + servingBlock + [""])
        for (name, result) in [("another model", other), ("the pair's model", same)] {
            let stderr = text(result?.standardErrorContent)
            #expect(pairActionCalls(stderr) == ["ensureService", "serve"], "\(name): \(pairActionCalls(stderr))")
            #expect(changingLaunchctlCalls(stderr).isEmpty, "\(name): \(changingLaunchctlCalls(stderr))")
        }
    }

    /// In a terminal a person can add --solo, so there `start --model` on a paired Mac is still refused by name.
    @Test("`start --model` in a terminal on a paired Mac is refused by name, and Autopilot enroll without one too")
    func modelInATerminalAndAutopilotAreRefused() throws {
        for (state, summary) in [("stopped", stoppedPair()), ("not running here", stalePair()), ("serving", servingPair())] {
            #expect(Start.pairStart(summary, solo: false, terminal: true, singleMacOptions: ["--model"])
                == .refuseOptions(summary.singleMacOptionsRefusal(["--model"])), "\(state)")
            let enroll = try Start.parse(["--autopilot"]).singleMacOptions
            #expect(Start.pairStart(summary, solo: false, terminal: false, singleMacOptions: enroll)
                == .refuseOptions(summary.singleMacOptionsRefusal(enroll)), "\(state)")
            // The app's Start, without a terminal: the pair.
            #expect(Start.pairStart(summary, solo: false, terminal: false, singleMacOptions: ["--model", "--local-endpoint"])
                == .startPair, "\(state)")
        }
    }

    /// `servingAloneLine` for a started pair is said only where no leftover part runs here: with this Mac's cluster service
    /// down. Nothing asked the other Mac then, so nothing may say it isn't answering.
    @Test("a started pair whose cluster service is down here never says the other Mac isn't answering: nothing asked it")
    func servingAloneSaysOnlyWhatItKnows() {
        let down = pair(serviceRunning: false)
        #expect(Start.pairStart(down, solo: true, terminal: false) == .serveAlone(note: down.servingAloneLine))
        #expect(down.servingAloneLine == "This Mac is in a two-Mac cluster with \(otherMac), which isn't running here: "
            + "serving this Mac alone (`darkbloom start` starts the pair again).")
        // With the service up, it asked: the other Mac's silence is said.
        var silent = pair()
        silent.pairRunning = false
        #expect(silent.servingAloneLine.contains("(\(otherMac) isn't answering)"), "\(silent.servingAloneLine)")
    }

    /// `start --solo`, `restart` and `update` stop a started pair's leftover part before serving alone. That may wait for a
    /// running cluster command and end with nothing changed, so "its saved start is cleared" is said only once it is.
    @Test("`start --solo` on a Mac whose pair isn't running says its saved start is cleared only once it is")
    func soloStartSaysClearedOnlyOnceItIs() async {
        let busy = await #expect(processExitsWith: .failure, observing: [\.standardOutputContent]) {
            try await exitWithPair(stalePair(), actions: pairActions()) { _ in
                try await Start.$releaseOutcomeForTesting.withValue(commandStillRunning) {
                    try await runCLICommand(Start.self, ["start", "--solo", "--model", "acme/Alpha-4bit"])
                }
            }
        }
        let busyOut = lines(busy?.standardOutputContent)
        #expect(!busyOut.contains { $0.contains("saved start is cleared") }, "\(busyOut)")
        #expect(Array(busyOut.prefix(2)) == [stalePair().leftoverStopLine, ClusterPairSummary.releaseWaitLine], "\(busyOut)")
        let released = await #expect(processExitsWith: .failure, observing: [\.standardOutputContent]) {
            try await exitWithPair(stalePair(), actions: pairActions()) { _ in
                try await Start.$releaseOutcomeForTesting.withValue({ _ in .released }) {
                    try await runCLICommand(Start.self, ["start", "--solo", "--model", "acme/Alpha-4bit"])
                }
            }
        }
        // Then the single-Mac start goes on (it ends at this sandbox's missing model, never at a refusal).
        let releasedOut = lines(released?.standardOutputContent)
        #expect(Array(releasedOut.prefix(2)) == [stalePair().leftoverStopLine,
            "This Mac's leftover part of the pair stopped, and its saved start is cleared: serving this Mac alone."], "\(releasedOut)")
    }

    @Test("`restart` of single-Mac serving on a Mac whose pair isn't running never says the saved start is cleared before it is")
    func restartSaysClearedOnlyOnceItIs() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardOutputContent]) {
            try await exitWithPair(stalePair(), actions: pairActions()) { sandbox in
                try leaveStoppedSingleMacPlist(in: sandbox)
                try await LaunchctlControl.$runnerForTesting.withValue(loadedSingleMacLaunchctl) {
                    try await Start.$releaseOutcomeForTesting.withValue(commandStillRunning) {
                        try await ClusterPairCommands.$waitForTesting.withValue(.init(seconds: 0, interval: 0)) {
                            try await runCLICommand(Restart.self, ["restart"])
                        }
                    }
                }
            }
        }
        #expect(lines(result?.standardOutputContent) == [stalePair().leftoverStopLine, ClusterPairSummary.releaseWaitLine]
            + ClusterPairSummary.releaseBusyLines + [""])
    }

    /// On DevNet pair-2 a `darkbloom start --opencode` that got no answer hung on "Serve on this Mac alone / Start the
    /// pair". No start asks a question without a terminal: on a paired Mac one starts the pair, with or without the tool
    /// flags, and never reads standard input (`neverAnswering`).
    @Test("a start without a terminal on a paired Mac starts the pair and never reads standard input, with or without --opencode or --hermes")
    func nonTerminalStartsStartThePairAndAskNothing() async {
        let plain = await #expect(processExitsWith: .success, observing: [\.standardOutputContent, \.standardErrorContent]) {
            try await exitWithPair(stoppedPair(), actions: pairActions(serving: false)) { sandbox in
                try neverAnswering(sandbox)
                try await ClusterPairSummary.$readerForTesting.withValue({ live in live ? servingPair() : stoppedPair() }) {
                    try await ClusterPairCommands.$waitForTesting.withValue(.init(seconds: 0, interval: 0)) {
                        try await runCLICommand(Start.self, ["start"])
                    }
                }
            }
        }
        let opencode = await #expect(processExitsWith: .failure, observing: [\.standardOutputContent, \.standardErrorContent]) {
            try await exitWithPair(stoppedPair(), actions: pairActions(serving: false)) { sandbox in
                try neverAnswering(sandbox)
                try await ClusterPairSummary.$readerForTesting.withValue({ live in live ? servingPair() : stoppedPair() }) {
                    try await ClusterPairCommands.$waitForTesting.withValue(.init(seconds: 0, interval: 0)) {
                        try await runCLICommand(Start.self, ["start", "--opencode"])
                    }
                }
            }
        }
        let hermes = await #expect(processExitsWith: .failure, observing: [\.standardOutputContent, \.standardErrorContent]) {
            try await exitWithPair(stoppedPair(), actions: pairActions(serving: false)) { sandbox in
                try neverAnswering(sandbox)
                try await ClusterPairSummary.$readerForTesting.withValue({ live in live ? servingPair() : stoppedPair() }) {
                    try await ClusterPairCommands.$waitForTesting.withValue(.init(seconds: 0, interval: 0)) {
                        try await runCLICommand(Start.self, ["start", "--hermes"])
                    }
                }
            }
        }
        let starting = "This Mac is in a two-Mac cluster with \(otherMac): starting the pair."
        #expect(lines(plain?.standardOutputContent) == [starting] + servingBlock + [""])
        // The pair serves through Darkbloom only, so no local API on this Mac takes the tool: one line names the way.
        #expect(lines(opencode?.standardOutputContent) == [starting] + servingBlock
            + [ToolIntegrationStep.noPairAPI([.opencode]), ToolIntegrationStep.keepsServing, ""])
        #expect(lines(hermes?.standardOutputContent) == [starting] + servingBlock
            + [ToolIntegrationStep.noPairAPI([.hermes]), ToolIntegrationStep.keepsServing, ""])
        for (name, result) in [("start", plain), ("--opencode", opencode), ("--hermes", hermes)] {
            let calls = pairActionCalls(text(result?.standardErrorContent))
            #expect(calls == ["ensureService", "serve"], "\(name): \(calls)")
        }
    }

    @Test("`start --solo` without a terminal and without --model asks nothing: one line, before this Mac's part is touched")
    func soloWithoutATerminalNamesItsModels() async {
        let result = await #expect(processExitsWith: .exitCode(64), observing: [\.standardOutputContent, \.standardErrorContent]) {
            try await exitWithPair(stalePair(), actions: pairActions()) { sandbox in
                try neverAnswering(sandbox)
                try await Start.$releaseForTesting.withValue({ FileHandle.standardError.write(Data("released\n".utf8)); return true }) {
                    try await runCLICommand(Start.self, ["start", "--solo", "--config", sandbox.config.path])
                }
            }
        }
        let stderr = text(result?.standardErrorContent)
        #expect(stderr.components(separatedBy: "\n").filter { $0 == modelsWithoutATerminal }.count == 1, "\(stderr)")
        #expect(!stderr.contains("released"), "this Mac's part keeps running: \(stderr)")
        #expect(lines(result?.standardOutputContent) == [""], "\(text(result?.standardOutputContent))")
        #expect(pairActionCalls(stderr).isEmpty)
    }

    @Test("a start without a terminal and without --model on a Mac that isn't paired names its models instead of asking")
    func singleMacStartWithoutATerminalNamesItsModels() async {
        let result = await #expect(processExitsWith: .exitCode(64), observing: [\.standardOutputContent, \.standardErrorContent]) {
            try await exitWithPair(.notPaired, actions: nil) { sandbox in
                try neverAnswering(sandbox)
                try await runCLICommand(Start.self, ["start", "--config", sandbox.config.path])
            }
        }
        let stderr = text(result?.standardErrorContent)
        #expect(stderr.components(separatedBy: "\n").filter { $0 == modelsWithoutATerminal }.count == 1, "\(stderr)")
        let calls = changingLaunchctlCalls(stderr)
        #expect(calls.isEmpty, "\(calls)")
    }

    /// Only me serves the models already on this Mac, and launchd's `--foreground` child the ones its job names: neither
    /// reaches the model picker, so neither is refused for naming no models.
    @Test("without a terminal, Only me and launchd's child go on without naming models")
    func onlyMeAndTheLaunchdChildNeedNoModels() async {
        await #expect(processExitsWith: .success) {
            try replaceStandardInput(with: "")
            try Start.parse([]).requireModelsNamedWithoutTerminal(mode: .local)
            try Start.parse(["--foreground"]).requireModelsNamedWithoutTerminal(mode: .network)
            try Start.parse(["--foreground"]).requireModelsNamedWithoutTerminal(mode: .both)
        }
    }

    @Test("`darkbloom status` leads with the pair block, then this Mac's fields, and no single-Mac Daemon/Traffic lines")
    func statusShowsThePair() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            try await exitWithPair(servingPair(), actions: nil) { sandbox in
                try await runCLICommand(Status.self, ["status", "--config", sandbox.config.path])
            }
        }
        let stdout = text(result?.standardOutputContent)
        #expect(stdout.hasPrefix("""
            Cluster: this Mac (Mac Studio) leads · \(otherMac) follows
            Model: Qwen 3.8 27B · tensor parallel · M3 Ultra 50% / M5 Max 50%
            Serves: through Darkbloom
            ✓ Serving Qwen 3.8 27B through Darkbloom on both Macs (tensor parallel).
            Next: To stop or change it: `darkbloom cluster` on this Mac.

            \(BuildEnvironment.current.cliName) \(ProviderCore.version)

            """), "\(stdout)")
        #expect(stdout.contains("\nHardware: "))
        #expect(!stdout.contains("Daemon:") && !stdout.contains("Traffic:"))
    }

    @Test("`darkbloom status --solo` shows single-Mac serving on this Mac, with the pair in one line")
    func statusSolo() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            try await exitWithPair(servingPair(), actions: nil) { sandbox in
                try await runCLICommand(Status.self, ["status", "--solo", "--config", sandbox.config.path])
            }
        }
        let stdout = text(result?.standardOutputContent)
        #expect(stdout.hasPrefix("\(BuildEnvironment.current.cliName) \(ProviderCore.version)\n"))
        #expect(stdout.contains("\nCluster: this Mac leads · \(otherMac) · Qwen 3.8 27B through Darkbloom · serving "
            + "(details: `darkbloom cluster status`)\n"))
        #expect(stdout.contains("\nSingle-Mac serving: off (this Mac serves in its two-Mac cluster: `darkbloom cluster status`)\n"))
    }

    /// On DevNet pair-2 a paired Mac whose pair was stopped served alone, and `status` said only "Single-Mac serving:
    /// running beside the pair (`darkbloom-dev status --solo` shows it)", 27 lines down, without its `Serving:` line.
    @Test("`darkbloom status` on a paired Mac that serves alone says so under the pair, then single-Mac serving's own lines")
    func statusSaysThisMacServesAlone() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            try await exitWithPair(stoppedPair(), actions: nil) { sandbox in
                sandbox.writeState(try CLICommandSandbox.runningState(now: Date().timeIntervalSince1970))
                try await runCLICommand(Status.self, ["status", "--config", sandbox.config.path])
            }
        }
        let out = lines(result?.standardOutputContent)
        let block = stoppedPair().clusterStatusLines
        #expect(Array(out.prefix(block.count)) == block, "\(out)")
        let said = out.dropFirst(block.count).first ?? ""
        #expect(said.hasPrefix("This Mac serves alone (single-Mac serving, process ")
                    && said.hasSuffix("), not the pair; its status is below."), "\(out)")
        #expect(out.contains { $0.hasPrefix("Daemon: running") }, "\(out)")
        #expect(!out.contains { $0.contains("beside the pair") }, "\(out)")
    }
}

private let soloBesideServingRefusal = [
    "This Mac serves in a two-Mac cluster with \(otherMac): it leads; Qwen 3.8 27B through Darkbloom.",
    "This Mac's part of the pair holds its serving lock, so single-Mac serving can't start beside it. Stop the pair first "
        + "(`darkbloom stop`), then `darkbloom start --solo`.",
]

private let askedLine = "Asked both Macs to stop; they stay stopped after a restart, and `darkbloom start` on either Mac starts the pair again."

@Suite("the validator's findings: rollback advice, the pairing wait, stop output that is true, leftovers and the app")
struct ClusterPairValidatorFindingsTests {
    @Test("`update --rollback` says to turn the cluster service off with `cluster stop --service`")
    func rollbackAdviceTurnsTheServiceOff() {
        #expect(UpdateRollback.clusterRefusal.contains("Stop this Mac's cluster service (`darkbloom cluster stop --service`)"))
    }

    @Test("the coordinator's pairing wait and the registering line are loading, not a reason")
    func coordinatorWaitIsLoading() {
        #expect(observed("Qwen 3.8 27B is not serving yet: waiting for the coordinator to pair both Macs.").state == .loading)
        #expect(observed("Qwen 3.8 27B: registering both Macs with the coordinator for pairing.").state == .loading)
        // Journey 2a (J2-c): Apple's check of a part that just started, as the leading Mac's status says it while it goes
        // as usual (`ClusterOnboardingAppleCheck`): loading, on both Macs, with no ✗.
        for checking in ["checking both Macs with Apple", "checking the other Mac (Apple M5 Max, 128 GB) with Apple"] {
            let summary = observed("Qwen 3.8 27B is not serving yet: \(checking).")
            #expect(summary.state == .loading && summary.reason == checking && summary.exitCode == 3, "\(checking)")
            #expect(summary.clusterStatusLines.contains("\u{2026} Qwen 3.8 27B is not serving yet: \(checking)."), "\(summary.clusterStatusLines)")
            #expect(!summary.clusterStatusLines.contains { $0.hasPrefix("\u{2717}") }, "\(summary.clusterStatusLines)")
            #expect(!ClusterPairSummary.isFinalReason(checking))
        }
        #expect(observed("Qwen 3.8 27B is not serving yet: This Mac isn't logged in to Darkbloom, so the coordinator won't pair it.")
            .state == .notServing)
    }

    @Test("a script start waits through the coordinator's pairing and an Apple verification retry until it serves; exit 0")
    func startWaitsThroughThePairingWait() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent, \.standardErrorContent]) {
            let looks = Looks([
                observed("Qwen 3.8 27B: registering both Macs with the coordinator for pairing."),
                observed("Qwen 3.8 27B is not serving yet: waiting for the coordinator to pair both Macs."),
                observed("Qwen 3.8 27B is not serving yet: The other Mac (Apple M5 Max, 128 GB) isn't verified by Apple yet; "
                    + "Darkbloom retries by itself within minutes. Don't restart either Mac until then."),
                observed("Serving Qwen 3.8 27B through Darkbloom on both Macs (tensor parallel)."),
            ])
            try await exitWithPair(pair(), actions: pairActions()) { _ in
                try await ClusterPairSummary.$readerForTesting.withValue({ live in live ? looks.next() : pair() }) {
                    try await ClusterPairCommands.$waitForTesting.withValue(.init(seconds: 60, interval: 0)) {
                        try await runCLICommand(Start.self, ["start"])
                    }
                }
            }
        }
        let out = lines(result?.standardOutputContent)
        #expect(out.contains("  Qwen 3.8 27B is not serving yet: waiting for the coordinator to pair both Macs."))
        #expect(out.contains("✓ Serving Qwen 3.8 27B through Darkbloom on both Macs (tensor parallel)."))
    }

    @Test("stop says \"Stopped on both Macs\" only once both parts ended, after waiting for the other Mac's part")
    func stopSaysStoppedOnlyOnceBothPartsEnded() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent, \.standardErrorContent]) {
            try await exitWithPair(servingPair(role: .member),
                                   actions: pairActions(role: .member, teardown: [.success(stillRunning), .success(freed)])) { _ in
                try await ClusterPairCommands.$waitForTesting.withValue(.init(seconds: 30, interval: 0)) {
                    try await runCLICommand(Stop.self, ["stop"])
                }
            }
        }
        #expect(lines(result?.standardOutputContent) == ["This Mac is in a two-Mac cluster with \(otherMac): stopping both Macs.",
            "  Waiting for both Macs' parts to end (up to 30 s).", ClusterPairSummary.stoppedLine, "Memory freed on both Macs ✓", ""])
        #expect(pairActionCalls(text(result?.standardErrorContent)) == ["stop", "verifyTeardown", "verifyTeardown"])
    }

    @Test("a stop whose parts haven't ended says it asked, shows what is left, and exits 1")
    func stopThatHasNotEndedSaysAsked() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardOutputContent]) {
            try await exitWithPair(servingPair(), actions: pairActions(teardown: [.success(stillRunning)])) { _ in
                try await ClusterPairCommands.$waitForTesting.withValue(.init(seconds: 0, interval: 0)) {
                    try await runCLICommand(Stop.self, ["stop"])
                }
            }
        }
        #expect(lines(result?.standardOutputContent) == ["This Mac is in a two-Mac cluster with \(otherMac): stopping both Macs.",
            askedLine, "Memory:"] + stillRunning.map { "  " + $0 } + [""])
    }

    @Test("the follower's stop never ends without a memory line: a check that didn't answer is said")
    func stopWithoutAMemoryCheckSaysSo() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardOutputContent]) {
            try await exitWithPair(servingPair(role: .member), actions: pairActions(role: .member,
                teardown: [.failure(.init("The other Mac (Apple M5 Max, 128 GB) did not answer over the cable: timed out"))])) { _ in
                try await ClusterPairCommands.$waitForTesting.withValue(.init(seconds: 0, interval: 0)) {
                    try await runCLICommand(Stop.self, ["stop"])
                }
            }
        }
        #expect(lines(result?.standardOutputContent) == ["This Mac is in a two-Mac cluster with \(otherMac): stopping both Macs.",
            askedLine, "Memory: not checked (The other Mac (Apple M5 Max, 128 GB) did not answer over the cable: timed out)", ""])
    }

    @Test("a failed stop on the follower says what is known: refused, timed out, or stopped there but not here")
    func stopFailureSaysWhatIsKnown() {
        let localOnly = "To stop only this Mac: `darkbloom cluster stop --local-only` (the other Mac then serves alone, or waits for this one)."
        #expect(ClusterPairSummary.memberStopFailureLines(["The other Mac (Apple M5 Max, 128 GB) did not answer over the cable: connection refused"])
            == ["Nothing was stopped on this Mac. " + localOnly])
        #expect(ClusterPairSummary.memberStopFailureLines(["The other Mac (Apple M5 Max, 128 GB) did not answer over the cable: timed out"])
            == ["The leading Mac didn't confirm the stop in time; it may still be finishing. `darkbloom status` shows where both "
                + "Macs stand.", localOnly])
        #expect(ClusterPairSummary.memberStopFailureLines(["The other Mac (Apple M5 Max, 128 GB) stopped serving; this Mac did not "
            + "answer (connection reset). Its cluster service tells it to stop as soon as it answers again."]) == [localOnly])
    }

    @Test("the follower's stop always asks the leading Mac, even when its own record says stopped")
    func memberStopAlwaysAsksTheLeader() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent, \.standardErrorContent]) {
            try await exitWithPair(servingPair(role: .member), actions: pairActions(role: .member, serving: false)) { _ in
                try await runCLICommand(Stop.self, ["stop"])
            }
        }
        let out = lines(result?.standardOutputContent)
        #expect(out.contains(ClusterPairSummary.stoppedLine))
        #expect(pairActionCalls(text(result?.standardErrorContent)) == ["stop", "verifyTeardown"])
    }

    @Test("restart doesn't start again until both parts have ended; exit 1 when they haven't")
    func restartWaitsForBothPartsToEnd() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardOutputContent, \.standardErrorContent]) {
            try await exitWithPair(servingPair(), actions: pairActions(teardown: [.success(stillRunning)])) { _ in
                try await ClusterPairCommands.$waitForTesting.withValue(.init(seconds: 0, interval: 0)) {
                    try await runCLICommand(Restart.self, ["restart"])
                }
            }
        }
        let out = lines(result?.standardOutputContent)
        #expect(out.contains("Not started again: run `darkbloom restart` once both parts have ended (`darkbloom status`)."))
        #expect(pairActionCalls(text(result?.standardErrorContent)) == ["stop", "verifyTeardown"])
    }

    @Test("a cluster service without any pairing is a leftover, not a cluster")
    func leftoverServiceIsNotACluster() {
        let leftover = ClusterPairSummary.membership(.none, serviceRunning: true, loginAgentInstalled: true, startsAtLogin: true)
        #expect(!leftover.paired && leftover.exitCode == 6)
        #expect(leftover.clusterStatusLines == [
            "This Mac isn't in a cluster, but a cluster service is still set up on it (left from an earlier pairing).",
            "Next: To remove it: `darkbloom cluster stop --service`. To set up a cluster: `darkbloom cluster` on each Mac.",
        ])
        #expect(Stop.pairedStop(leftover, solo: false, uninstall: false) == .stopSingleMac)
    }

    @Test("--solo can't start beside this Mac's serving part of the pair: refused, and said why")
    func soloRefusedWhileThisMacsPartServes() {
        #expect(Start.pairStart(pair(), solo: true, terminal: false) == .refuse(soloBesideServingRefusal))
        #expect(Start.pairStart(pair(started: false), solo: true, terminal: false) == .serveAlone(note: "This Mac is in a two-Mac "
            + "cluster with \(otherMac), which is stopped: serving this Mac alone (`darkbloom start` starts the pair again)."))
    }

    @Test("the app's local mode on a paired Mac refuses plainly instead of reporting a start")
    func desktopLocalModeRefusesOnAPairedMac() {
        #expect(Desktop.StartLocal.pairRefusal(pair()) == [
            "This Mac is in a two-Mac cluster with \(otherMac): the app's local mode serves this Mac alone, so nothing was started.",
            "To serve the pair locally: `darkbloom cluster local` on the leading Mac. To serve this Mac alone: stop the pair "
                + "(`darkbloom stop`), then `darkbloom start --solo --local --model <id>`.",
        ])
        #expect(Desktop.StartLocal.pairRefusal(.notPaired) == nil)
    }
}

@Suite("commands built in code are parsed: their options read without ArgumentParser's fatal error")
struct ParsedInCodeTests {
    @Test("`desktop start-local`'s drain options read as `darkbloom stop`'s defaults")
    func desktopLocalStartDrainOptionsAreParsed() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            let options = try Desktop.StartLocal.drainOptions()
            print("timeout \(options.timeout) force \(options.force)")
        }
        #expect(text(result?.standardOutputContent) == "timeout \(DrainOptions.defaultTimeout) force false\n")
    }

    @Test("unenrollment's stop is `darkbloom stop --solo`, parsed")
    func unenrollStopIsParsed() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            let stop = try Unenroll.stopCommand()
            print("solo \(stop.solo) uninstall \(stop.uninstall) timeout \(stop.drain.timeout)")
        }
        #expect(text(result?.standardOutputContent) == "solo true uninstall false timeout \(DrainOptions.defaultTimeout)\n")
    }
}

// MARK: - The Darkbloom look in a terminal

/// A look as a 120-column UTF-8 terminal gives it (`DarkbloomCommandLook.forTesting`), still, so the stream is exact.
private func terminalLook() -> DarkbloomCommandLook {
    DarkbloomCommandLook(mode: .init(decorates: true, animates: false, columns: 120),
                         environment: ["TERM": "xterm-256color", "LANG": "en_US.UTF-8"], pause: { _ in })
}

/// Lines as a command prints them, each ended by a newline.
private func transcript(_ lines: [String]) -> String { lines.map { $0 + "\n" }.joined() }

/// Runs a command and ends it as the CLI does: an `ExitCode` as thrown, any other error by ArgumentParser's mapping
/// (a `ValidationError` is exit 64).
private func runAsCLI<Command: AsyncParsableCommand>(_ type: Command.Type, _ arguments: [String]) async throws {
    do { try await runCLICommand(type, arguments) } catch let code as ExitCode { throw code } catch { throw type.exitCode(for: error) }
}

/// #1774's pair outcomes said while the live line shows, run plain or with a terminal's look: 0 `stop` with a part still
/// running, 1 `stop` whose memory check didn't answer, 2 `restart` with a part still running, 3 `restart` through the
/// coordinator's registering wait.
private func runPairOutcome(_ outcome: Int, decorated: Bool) async throws -> Never {
    let teardown: [Result<[String], ClusterOnboardingFailure>] = switch outcome {
    case 0, 2: [.success(stillRunning)]
    case 1: [.failure(.init("The other Mac (Apple M5 Max, 128 GB) did not answer over the cable: timed out"))]
    default: [.success(freed)]
    }
    let looks = Looks([observed("Qwen 3.8 27B: registering both Macs with the coordinator for pairing."),
                       observed("Serving Qwen 3.8 27B through Darkbloom on both Macs (tensor parallel).")])
    try await DarkbloomCommandLook.$forTesting.withValue(decorated ? terminalLook() : DarkbloomCommandLook(mode: .plain)) {
        try await exitWithPair(servingPair(), actions: pairActions(teardown: teardown)) { _ in
            try await ClusterPairSummary.$readerForTesting.withValue({ live in live && outcome == 3 ? looks.next() : servingPair() }) {
                try await ClusterPairCommands.$waitForTesting.withValue(.init(seconds: outcome == 3 ? 60 : 0, interval: 0)) {
                    if outcome < 2 { try await runCLICommand(Stop.self, ["stop"]) } else { try await runCLICommand(Restart.self, ["restart"]) }
                }
            }
        }
    }
}

/// `darkbloom autopilot <subcommand>` on a Mac not in a cluster, plain or with a terminal's look. Its config can't be
/// read, so the `start` it runs inside itself ends right after the terms notice, before any other work.
private func runAutopilotStart(_ subcommand: String, decorated: Bool) async throws -> Never {
    try await DarkbloomCommandLook.$forTesting.withValue(decorated ? terminalLook() : DarkbloomCommandLook(mode: .plain)) {
        try await exitWithPair(.notPaired, actions: nil) { sandbox in
            let broken = sandbox.root.appendingPathComponent("broken.toml")
            try Data("[[[ not toml".utf8).write(to: broken)
            let arguments = ["autopilot", subcommand, "--config", broken.path]
            if subcommand == "enable" {
                try await runAsCLI(Autopilot.Enable.self, arguments)
            } else {
                try await runAsCLI(Autopilot.Models.self, arguments)
            }
        }
    }
}

/// The decorated stream less the mark block and the live line: what a transcript would have had.
private func withoutLook(_ stream: String, title: String) -> String {
    let mark = "\n" + DarkbloomCommandLook.mark(title, revealed: Int.max, colour: "38;5;27") + "\n"
    let rest = stream.hasPrefix(mark) ? String(stream.dropFirst(mark.count)) : stream
    // The live row is written with line wrap off and on again around it (`ClusterOnboardingBrand.noWrap`).
    let live = try! NSRegularExpression(pattern: "\r\u{1B}\\[J(\u{1B}\\[\\?7l  \u{1B}\\[[0-9;]+m.\u{1B}\\[0m \u{1B}\\[2m[^\u{1B}]*\u{2026}\u{1B}\\[0m\u{1B}\\[\\?7h)?")
    return live.stringByReplacingMatches(in: rest, range: NSRange(rest.startIndex..., in: rest), withTemplate: "")
}

@Suite("the everyday commands in a terminal: the Darkbloom mark and the live line, the plain transcript's lines unchanged")
struct DarkbloomCommandLookRunTests {
    @Test("`darkbloom stop` opens with the mark beside its title, shows the live line, and says every plain line in order")
    func stop() async {
        let plain = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            try await exitWithPair(servingPair(), actions: pairActions()) { _ in try await runCLICommand(Stop.self, ["stop"]) }
        }
        let decorated = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            try await DarkbloomCommandLook.$forTesting.withValue(terminalLook()) {
                try await exitWithPair(servingPair(), actions: pairActions()) { _ in try await runCLICommand(Stop.self, ["stop"]) }
            }
        }
        let stream = text(decorated?.standardOutputContent)
        #expect(stream.hasPrefix("\n" + DarkbloomCommandLook.mark("Darkbloom stop", revealed: Int.max, colour: "38;5;27") + "\n"),
                "\(stream.debugDescription)")
        #expect(stream.contains("\u{1B}[2mStopping both Macs\u{2026}\u{1B}[0m"))
        #expect(withoutLook(stream, title: "Darkbloom stop") == text(plain?.standardOutputContent))
        #expect(lines(plain?.standardOutputContent) == [
            "This Mac is in a two-Mac cluster with \(otherMac): stopping both Macs.",
            "Stopped on both Macs. They stay stopped after a restart; `darkbloom start` on either Mac starts the pair again.",
            "Memory freed on both Macs ✓", ""])
        #expect(!stream.contains("\u{1B}[?25l"))
    }

    @Test("`darkbloom restart` opens with the mark and keeps every plain line in order")
    func restart() async {
        let plain = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            try await exitWithPair(servingPair(), actions: pairActions()) { _ in try await runCLICommand(Restart.self, ["restart"]) }
        }
        let decorated = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            try await DarkbloomCommandLook.$forTesting.withValue(terminalLook()) {
                try await exitWithPair(servingPair(), actions: pairActions()) { _ in try await runCLICommand(Restart.self, ["restart"]) }
            }
        }
        let stream = text(decorated?.standardOutputContent)
        #expect(stream.hasPrefix("\n" + DarkbloomCommandLook.mark("Darkbloom restart", revealed: Int.max, colour: "38;5;27") + "\n"),
                "\(stream.debugDescription)")
        #expect(stream.contains("\u{1B}[2mRestarting both Macs\u{2026}\u{1B}[0m"))
        #expect(withoutLook(stream, title: "Darkbloom restart") == text(plain?.standardOutputContent))
        #expect(lines(plain?.standardOutputContent) == ["This Mac is in a two-Mac cluster with \(otherMac): restarting both Macs.",
            "  Stopped on both Macs; starting it again."] + servingBlock + [""])
    }

    @Test("`darkbloom status` opens with the mark, then the pair block as without it")
    func status() async {
        let decorated = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            try await DarkbloomCommandLook.$forTesting.withValue(terminalLook()) {
                try await exitWithPair(servingPair(), actions: nil) { sandbox in
                    try await runCLICommand(Status.self, ["status", "--config", sandbox.config.path])
                }
            }
        }
        let stream = text(decorated?.standardOutputContent)
        #expect(stream.hasPrefix("\n" + DarkbloomCommandLook.mark("Darkbloom status", revealed: Int.max, colour: "38;5;27") + "\n"
            + "Cluster: this Mac (Mac Studio) leads · \(otherMac) follows\n"), "\(stream.debugDescription)")
    }

    @Test("`darkbloom start` on a paired Mac in a terminal opens the cluster's screen, which draws the mark: never twice")
    func startOpensTheScreen() async {
        let decorated = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            try await DarkbloomCommandLook.$forTesting.withValue(terminalLook()) {
                try await exitWithPair(servingPair(), actions: pairActions()) { _ in
                    try await ClusterPairCommands.$terminalForTesting.withValue(true) {
                        try await ClusterPairCommands.$screenForTesting.withValue({ _ in print("screen") }) {
                            try await runCLICommand(Start.self, ["start"])
                        }
                    }
                }
            }
        }
        #expect(lines(decorated?.standardOutputContent) == [openingScreen, "screen", ""])
    }

    @Test("`darkbloom start` refused on a paired Mac (single-Mac options: exit 64; an unreadable pairing: exit 1) draws no mark")
    func refusalsDrawNoMark() async {
        let options = await #expect(processExitsWith: .exitCode(64), observing: [\.standardOutputContent]) {
            try await DarkbloomCommandLook.$forTesting.withValue(terminalLook()) {
                try await exitWithPair(servingPair(), actions: pairActions()) { _ in
                    try await ClusterPairCommands.$terminalForTesting.withValue(true) {
                        try await runCLICommand(Start.self, ["start", "--model", "acme/Alpha-4bit"])
                    }
                }
            }
        }
        #expect(text(options?.standardOutputContent) == pair().singleMacOptionsRefusal(["--model"]).map { $0 + "\n" }.joined())
        let unsure = await #expect(processExitsWith: .failure, observing: [\.standardOutputContent]) {
            try await DarkbloomCommandLook.$forTesting.withValue(terminalLook()) {
                try await exitWithPair(unreadable(), actions: pairActions()) { _ in try await runCLICommand(Start.self, ["start"]) }
            }
        }
        #expect(text(unsure?.standardOutputContent) == unreadable().startRefusal.map { $0 + "\n" }.joined())
    }

    @Test("`darkbloom stop` and `restart` refused while unsure (exit 1) draw no mark")
    func unsureStopAndRestartDrawNoMark() async {
        let stop = await #expect(processExitsWith: .failure, observing: [\.standardOutputContent]) {
            try await DarkbloomCommandLook.$forTesting.withValue(terminalLook()) {
                try await exitWithPair(unreadable(), actions: pairActions()) { _ in try await runAsCLI(Stop.self, ["stop"]) }
            }
        }
        #expect(text(stop?.standardOutputContent) == transcript(unreadable().unsureRefusal("stop", "stopped")))
        let restart = await #expect(processExitsWith: .failure, observing: [\.standardOutputContent]) {
            try await DarkbloomCommandLook.$forTesting.withValue(terminalLook()) {
                try await exitWithPair(unreadable(), actions: pairActions()) { _ in try await runAsCLI(Restart.self, ["restart"]) }
            }
        }
        #expect(text(restart?.standardOutputContent) == transcript(unreadable().unsureRefusal("restart", "restarted")))
    }

    @Test("`darkbloom restart` with nothing to restart draws no mark: --solo on a paired Mac (exit 1), nothing installed (exit 64)")
    func restartWithNothingDrawsNoMark() async {
        let solo = await #expect(processExitsWith: .failure, observing: [\.standardOutputContent]) {
            try await DarkbloomCommandLook.$forTesting.withValue(terminalLook()) {
                try await exitWithPair(servingPair(), actions: pairActions()) { _ in try await runAsCLI(Restart.self, ["restart", "--solo"]) }
            }
        }
        #expect(text(solo?.standardOutputContent) == transcript(servingPair().restartRefusal))
        let nothing = await #expect(processExitsWith: .exitCode(64), observing: [\.standardOutputContent]) {
            try await DarkbloomCommandLook.$forTesting.withValue(terminalLook()) {
                try await exitWithPair(.notPaired, actions: nil) { _ in try await runAsCLI(Restart.self, ["restart"]) }
            }
        }
        #expect(text(nothing?.standardOutputContent) == "")
    }

    @Test("`darkbloom start` whose flags refuse it draws no mark: --local with --local-endpoint (exit 1), --schedule with --local (exit 64)")
    func startFlagRefusalsDrawNoMark() async {
        let terms = "By starting the provider, you agree to the Darkbloom Terms of Service:\n  \(Start.termsURL)\n\n"
        let endpoints = await #expect(processExitsWith: .failure, observing: [\.standardOutputContent]) {
            try await DarkbloomCommandLook.$forTesting.withValue(terminalLook()) {
                try await exitWithPair(.notPaired, actions: nil) { _ in
                    try await runAsCLI(Start.self, ["start", "--local", "--local-endpoint"])
                }
            }
        }
        #expect(text(endpoints?.standardOutputContent) == terms)
        let schedule = await #expect(processExitsWith: .exitCode(64), observing: [\.standardOutputContent]) {
            try await DarkbloomCommandLook.$forTesting.withValue(terminalLook()) {
                try await exitWithPair(.notPaired, actions: nil) { _ in try await runAsCLI(Start.self, ["start", "--schedule", "--local"]) }
            }
        }
        #expect(text(schedule?.standardOutputContent) == terms)
    }

    @Test("`darkbloom stop --solo` with no single-Mac serving did nothing, so it draws no mark; exit 0")
    func soloStopWithNothingDrawsNoMark() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            try await DarkbloomCommandLook.$forTesting.withValue(terminalLook()) {
                try await exitWithPair(servingPair(), actions: pairActions()) { _ in try await runAsCLI(Stop.self, ["stop", "--solo"]) }
            }
        }
        #expect(text(result?.standardOutputContent) == transcript(servingPair().soloStopNothing))
    }

    @Test("`darkbloom start --local --autopilot` (exit 64) and an --idle-timeout out of range (exit 1) draw no mark")
    func startLaterFlagRefusalsDrawNoMark() async throws {
        let terms = "By starting the provider, you agree to the Darkbloom Terms of Service:\n  \(Start.termsURL)\n\n"
        let autopilot = await #expect(processExitsWith: .exitCode(64), observing: [\.standardOutputContent]) {
            try await DarkbloomCommandLook.$forTesting.withValue(terminalLook()) {
                try await exitWithPair(.notPaired, actions: nil) { sandbox in
                    try await runAsCLI(Start.self, ["start", "--local", "--autopilot", "--config", sandbox.config.path])
                }
            }
        }
        #expect(text(autopilot?.standardOutputContent) == terms)
        let idle = await #expect(processExitsWith: .failure, observing: [\.standardOutputContent]) {
            try await DarkbloomCommandLook.$forTesting.withValue(terminalLook()) {
                try await exitWithPair(.notPaired, actions: nil) { sandbox in
                    try await runAsCLI(Start.self, ["start", "--idle-timeout", "\(IdleUnloadPolicy.maxMinutes + 1)",
                                                    "--config", sandbox.config.path])
                }
            }
        }
        #expect(text(idle?.standardOutputContent) == terms)
        #expect(try Start.parse(["--schedule", "--idle-timeout", "\(IdleUnloadPolicy.maxMinutes + 1)"]).flagsRefuseStart == false,
                "with --schedule the wizard runs before the idle check")
    }

    @Test("#1774's later refusals draw no mark: start --solo beside the pair's part, the app's local mode, a leftover service")
    func laterPairRefusalsDrawNoMark() async {
        let solo = await #expect(processExitsWith: .failure, observing: [\.standardOutputContent]) {
            try await DarkbloomCommandLook.$forTesting.withValue(terminalLook()) {
                try await exitWithPair(servingPair(), actions: pairActions()) { _ in try await runAsCLI(Start.self, ["start", "--solo"]) }
            }
        }
        #expect(text(solo?.standardOutputContent) == transcript(servingPair().soloBesideServingRefusal))
        let desktop = await #expect(processExitsWith: .failure, observing: [\.standardOutputContent, \.standardErrorContent]) {
            try await DarkbloomCommandLook.$forTesting.withValue(terminalLook()) {
                try await exitWithPair(servingPair(), actions: pairActions()) { _ in
                    try await runAsCLI(Desktop.StartLocal.self, ["desktop", "start-local", "--model", "acme/Alpha-4bit"])
                }
            }
        }
        #expect(text(desktop?.standardOutputContent) == "")
        let desktopError = text(desktop?.standardErrorContent)
        #expect(desktopError.contains("the app's local mode serves this Mac alone, so nothing was started."))
        let leftover = await #expect(processExitsWith: .exitCode(64), observing: [\.standardOutputContent]) {
            try await DarkbloomCommandLook.$forTesting.withValue(terminalLook()) {
                let summary = ClusterPairSummary.membership(.none, serviceRunning: true, loginAgentInstalled: true, startsAtLogin: true)
                try await exitWithPair(summary, actions: nil) { _ in try await runAsCLI(Restart.self, ["restart"]) }
            }
        }
        #expect(text(leftover?.standardOutputContent) == "")
    }

    @Test("#1774's stop and restart outcomes said during the live line keep their bytes: a part still running, an unanswered memory check, a pairing wait")
    func pairOutcomeLinesKeepTheirBytes() async {
        let stopRunningPlain = await #expect(processExitsWith: .failure, observing: [\.standardOutputContent]) {
            try await runPairOutcome(0, decorated: false)
        }
        let stopRunning = await #expect(processExitsWith: .failure, observing: [\.standardOutputContent]) {
            try await runPairOutcome(0, decorated: true)
        }
        let stopUncheckedPlain = await #expect(processExitsWith: .failure, observing: [\.standardOutputContent]) {
            try await runPairOutcome(1, decorated: false)
        }
        let stopUnchecked = await #expect(processExitsWith: .failure, observing: [\.standardOutputContent]) {
            try await runPairOutcome(1, decorated: true)
        }
        let restartRunningPlain = await #expect(processExitsWith: .failure, observing: [\.standardOutputContent]) {
            try await runPairOutcome(2, decorated: false)
        }
        let restartRunning = await #expect(processExitsWith: .failure, observing: [\.standardOutputContent]) {
            try await runPairOutcome(2, decorated: true)
        }
        let restartWaitPlain = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            try await runPairOutcome(3, decorated: false)
        }
        let restartWait = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            try await runPairOutcome(3, decorated: true)
        }
        let cases: [(plain: String, decorated: String, title: String, live: String, line: String)] = [
            (text(stopRunningPlain?.standardOutputContent), text(stopRunning?.standardOutputContent), "Darkbloom stop",
             "Stopping both Macs", askedLine),
            (text(stopUncheckedPlain?.standardOutputContent), text(stopUnchecked?.standardOutputContent), "Darkbloom stop",
             "Stopping both Macs", "Memory: not checked (The other Mac (Apple M5 Max, 128 GB) did not answer over the cable: timed out)"),
            (text(restartRunningPlain?.standardOutputContent), text(restartRunning?.standardOutputContent), "Darkbloom restart",
             "Restarting both Macs", ClusterPairSummary.restartNotStartedLine),
            (text(restartWaitPlain?.standardOutputContent), text(restartWait?.standardOutputContent), "Darkbloom restart",
             "Restarting both Macs", "  Qwen 3.8 27B: registering both Macs with the coordinator for pairing."),
        ]
        for each in cases {
            #expect(each.plain.contains(each.line + "\n"), "\(each.plain)")
            #expect(each.decorated.contains("\u{1B}[2m\(each.live)\u{2026}\u{1B}[0m"))
            #expect(withoutLook(each.decorated, title: each.title) == each.plain, "\(each.decorated.debugDescription)")
        }
    }

    @Test("a command run inside another draws no mark and no live line: the mark is the outer command's, once, at the top")
    func nestedRunDrawsNoMark() async {
        let nested = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            try await DarkbloomCommandLook.$forTesting.withValue(terminalLook()) {
                try await exitWithPair(servingPair(), actions: pairActions()) { _ in
                    try await DarkbloomCommandLook.runNested { try await runAsCLI(Stop.self, ["stop"]) }
                }
            }
        }
        #expect(lines(nested?.standardOutputContent) == [
            "This Mac is in a two-Mac cluster with \(otherMac): stopping both Macs.",
            "Stopped on both Macs. They stay stopped after a restart; `darkbloom start` on either Mac starts the pair again.",
            "Memory freed on both Macs ✓", ""])
    }

    @Test("`autopilot enable` and `autopilot models` run `start` inside themselves: no mark, the same bytes as plain")
    func autopilotStartDrawsNoMark() async {
        let terms = "By starting the provider, you agree to the Darkbloom Terms of Service:\n  \(Start.termsURL)\n\n"
        let enablePlain = await #expect(processExitsWith: .failure, observing: [\.standardOutputContent]) {
            try await runAutopilotStart("enable", decorated: false)
        }
        let enable = await #expect(processExitsWith: .failure, observing: [\.standardOutputContent]) {
            try await runAutopilotStart("enable", decorated: true)
        }
        let modelsPlain = await #expect(processExitsWith: .failure, observing: [\.standardOutputContent]) {
            try await runAutopilotStart("models", decorated: false)
        }
        let models = await #expect(processExitsWith: .failure, observing: [\.standardOutputContent]) {
            try await runAutopilotStart("models", decorated: true)
        }
        #expect(text(enablePlain?.standardOutputContent) == terms)
        #expect(text(enable?.standardOutputContent) == terms)
        #expect(text(modelsPlain?.standardOutputContent) == terms)
        #expect(text(models?.standardOutputContent) == terms)
    }

    @Test("unenrollment's `stop --solo` and bare `darkbloom sandbox` draw no mark: the same bytes as plain")
    func unenrollStopAndBareSandboxDrawNoMark() async {
        let unenroll = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            try await DarkbloomCommandLook.$forTesting.withValue(terminalLook()) {
                try await exitWithPair(servingPair(), actions: pairActions()) { _ in try await Unenroll.stopProviderBeforeUnenrollment() }
            }
        }
        #expect(text(unenroll?.standardOutputContent) == transcript(servingPair().soloStopNothing))
        let sandboxPlain = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            try await exitWithPair(.notPaired, actions: nil) { _ in try await runAsCLI(Sandbox.self, ["sandbox"]) }
        }
        let sandbox = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            try await DarkbloomCommandLook.$forTesting.withValue(terminalLook()) {
                try await exitWithPair(.notPaired, actions: nil) { _ in try await runAsCLI(Sandbox.self, ["sandbox"]) }
            }
        }
        // Bare `sandbox` runs the add-on's own status (`Sandbox.Status`), never `darkbloom status`: no mark, its own bytes.
        let sandboxText = text(sandbox?.standardOutputContent)
        #expect(sandboxText == text(sandboxPlain?.standardOutputContent))
        #expect(!sandboxText.contains("\u{2588}") && !sandboxText.contains("\u{1B}[1mDarkbloom\u{1B}[0m"))
    }

    @Test("`darkbloom update --rollback` as root (exit 64) draws no mark; its first lines stay")
    func rollbackAsRootDrawsNoMark() async {
        let result = await #expect(processExitsWith: .exitCode(64), observing: [\.standardOutputContent]) {
            try await DarkbloomCommandLook.$forTesting.withValue(terminalLook()) {
                try await exitWithPair(.notPaired, actions: nil) { sandbox in
                    try await Update.$runsAsRootForTesting.withValue(true) {
                        try await runAsCLI(Update.self, ["update", "--rollback", "--config", sandbox.config.path])
                    }
                }
            }
        }
        #expect(text(result?.standardOutputContent)
            == "\(BuildEnvironment.current.cliName) update\nCurrent version: \(ProviderCore.version)\n\n")
    }

    @Test("NO_COLOR, TERM=dumb, CI, DARKBLOOM_NO_ANIMATION and a narrow window: plain or still; --json never decorated")
    func plainAndStill() async throws {
        for environment in [["NO_COLOR": "1"], ["TERM": "dumb"], ["LANG": "C"]] {
            let mode = DarkbloomCommandLook.Mode.of(inputIsTerminal: true, outputIsTerminal: true, columns: 120,
                environment: ["TERM": "xterm-256color", "LANG": "en_US.UTF-8"].merging(environment) { $1 })
            #expect(mode == .init(decorates: false, animates: false, columns: 120), "\(environment)")
        }
        #expect(!DarkbloomCommandLook.Mode.of(inputIsTerminal: true, outputIsTerminal: true, columns: 39,
            environment: ["TERM": "xterm-256color", "LANG": "en_US.UTF-8"]).decorates)
        for environment in [["CI": "true"], ["DARKBLOOM_NO_ANIMATION": "1"]] {
            let mode = DarkbloomCommandLook.Mode.of(inputIsTerminal: true, outputIsTerminal: true, columns: 120,
                environment: ["TERM": "xterm-256color", "LANG": "en_US.UTF-8"].merging(environment) { $1 })
            #expect(mode == .init(decorates: true, animates: false, columns: 120), "\(environment)")
        }
        // A plain look in a command: the transcript's bytes exactly.
        let plainLook = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            try await DarkbloomCommandLook.$forTesting.withValue(DarkbloomCommandLook(mode: .of(inputIsTerminal: true,
                outputIsTerminal: true, columns: 120, environment: ["TERM": "dumb", "LANG": "en_US.UTF-8"]))) {
                try await exitWithPair(servingPair(), actions: pairActions()) { _ in try await runCLICommand(Stop.self, ["stop"]) }
            }
        }
        #expect(lines(plainLook?.standardOutputContent) == [
            "This Mac is in a two-Mac cluster with \(otherMac): stopping both Macs.",
            "Stopped on both Macs. They stay stopped after a restart; `darkbloom start` on either Mac starts the pair again.",
            "Memory freed on both Macs ✓", ""])
        // --json: one object, no terminal code, even with a terminal's look.
        let json = await #expect(processExitsWith: .exitCode(4), observing: [\.standardOutputContent]) {
            var summary = pair(started: false)
            summary.state = .stopped
            try await DarkbloomCommandLook.$forTesting.withValue(terminalLook()) {
                try await exitWithPair(summary) { try await runCLICommand(Cluster.Status.self, ["cluster", "status", "--json"]) }
            }
        }
        let bytes = json?.standardOutputContent ?? []
        #expect(!bytes.contains(0x1B))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any])
        #expect(object["state"] as? String == "stopped")
    }
}

@Suite("DevNet findings, CLI side: names, waits that say so, incidents per install, a quieter control log")
struct ClusterDevNetFindingsTests {
    @Test("A-1: the DevNet app's start card names `darkbloom-dev`, never `darkbloom`")
    func startCardNamesTheIdentity() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            ClusterOnboardingCommand.use("darkbloom-dev")
            try await exitWithPair(servingPair(), actions: pairActions()) { _ in try await runCLICommand(Start.self, ["start"]) }
        }
        let out = text(result?.standardOutputContent)
        #expect(out.contains("  darkbloom-dev stop     Stop both Macs\n") && out.contains("  darkbloom-dev status   Check status\n"), "\(out)")
        #expect(!out.contains("darkbloom "), "\(out)")
    }

    @Test("A-1: cluster stop --service, its refusal and cluster local name the DevNet identity")
    func clusterTextsNameTheIdentity() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            ClusterOnboardingCommand.use("darkbloom-dev")
            var lines = try Cluster.Stop.finishStop(nil, localOnly: true) { ["agent"] }
            lines += Cluster.Stop.refusal(unreadable()) + [Cluster.Local.needsTerminalLine]
            for line in lines { print(line) }
        }
        let out = text(result?.standardOutputContent)
        #expect(out.contains("`darkbloom-dev cluster stop --service` there too") && out.contains("`darkbloom-dev cluster local`"), "\(out)")
        #expect(!out.contains("`darkbloom "), "\(out)")
    }

    @Test("The follower writes the words the cluster service reads in its log, and its refusal names the app macOS lists")
    func followerWritesTheWordsTheServiceReads() async throws {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            Cluster.LinkFollower.emit(.linkRefused("connectFailed (unreachable)"))
            Cluster.LinkFollower.emit(.connected)
            Cluster.LinkFollower.emit(.opened)
        }
        let out = text(result?.standardOutputContent)
        let lines = out.split(separator: "\n").map { String($0.drop { $0 != " " }.dropFirst()) }
        // R4-4: the row macOS lists for either app is "Darkbloom" (one bundle ID); the DevNet app says that row is its own.
        let app = BuildEnvironment.current.appDisplayName
        #expect(lines == ["link-follower: link refused: connectFailed (unreachable)",
                          "link-follower: this process may not reach the local network: macOS refused the dial before the cable was tried. "
                              + "Turn on “Darkbloom” under System Settings > Privacy & Security > Local Network"
                              + (app == "Darkbloom" ? "" : " (macOS lists \(app) as “Darkbloom”)")
                              + "; if it isn't listed, click Allow when macOS asks on this Mac's screen at the next dial. "
                              + "Or start the follower from a session that has that access.",
                          "link-follower: connected", "link-follower: session opened"], "\(out)")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("follower-words-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let refused = directory.appendingPathComponent("refused.log"), opened = directory.appendingPathComponent("opened.log")
        try (out.split(separator: "\n").prefix(2).joined(separator: "\n") + "\n").write(to: refused, atomically: true, encoding: .utf8)
        try out.write(to: opened, atomically: true, encoding: .utf8)
        let reason = ClusterService.followerRefusal(in: refused)
        #expect(reason?.hasPrefix(ClusterService.localNetworkReasonPrefix + ": macOS refused the dial") == true, "\(String(describing: reason))")
        #expect(ClusterService.followerRefusal(in: opened) == nil, "a link opened after the refusal clears it")
    }

    @Test("A-11: restart says what it waits for, and for how long at most, instead of hanging silently")
    func restartSaysWhatItWaitsFor() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            try await exitWithPair(servingPair(), actions: pairActions(teardown: [.success(stillRunning), .success(freed)], stopDelay: 0.5)) { _ in
                try await ClusterPairCommands.$progressAfterForTesting.withValue(0.05) {
                    try await ClusterPairCommands.$waitForTesting.withValue(.init(seconds: 30, interval: 0)) {
                        try await runCLICommand(Restart.self, ["restart"])
                    }
                }
            }
        }
        let out = lines(result?.standardOutputContent)
        #expect(out.contains("  Waiting for both Macs to stop; accepted requests finish first (up to about 6 min)."), "\(out)")
        #expect(out.contains("  Waiting for both Macs' parts to end (up to 30 s)."), "\(out)")
    }

    @Test("A-11: a script start that keeps reading the same status says it is still waiting, and its bound")
    func startSaysItIsStillWaiting() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            let loading = observed("Loading Qwen 3.8 27B: 1 of 2 parts ready.")
            let looks = Looks([loading, loading, loading, observed("Serving Qwen 3.8 27B through Darkbloom on both Macs (tensor parallel).")])
            try await exitWithPair(pair(), actions: pairActions()) { _ in
                try await ClusterPairSummary.$readerForTesting.withValue({ live in live ? looks.next() : pair() }) {
                    try await ClusterPairCommands.$waitForTesting.withValue(.init(seconds: 30, interval: 0, heartbeat: 0)) {
                        try await runCLICommand(Start.self, ["start"])
                    }
                }
            }
        }
        let out = lines(result?.standardOutputContent)
        #expect(out.contains("  Waiting until the pair serves (up to 30 s)."), "\(out)")
        #expect(out.contains("  Still waiting (up to 30 s in all): Loading Qwen 3.8 27B: 1 of 2 parts ready."), "\(out)")
    }

    @Test("A-12: the leader logs a following window's status requests once a minute, every other command each time")
    func controlStatusLogIsRateLimited() {
        let now = Date()
        #expect(ClusterService.logsControl(.status, lastStatusLog: nil, now: now))
        #expect(!ClusterService.logsControl(.status, lastStatusLog: now.addingTimeInterval(-1), now: now))
        #expect(ClusterService.logsControl(.status, lastStatusLog: now.addingTimeInterval(-61), now: now))
        #expect(ClusterService.logsControl(.stop, lastStatusLog: now.addingTimeInterval(-1), now: now))
    }
}

private final class SaidLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}

@Suite("Pair-2 findings, CLI side: the remaining names, a truthful other Mac, a bounded answer from the leading Mac")
struct ClusterPairTwoFindingsTests {
    @Test("P2-2: no-terminal `cluster`, the cluster service status lines and the Ctrl-C line name the DevNet CLI")
    func remainingTextsNameTheIdentity() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            ClusterOnboardingCommand.use("darkbloom-dev")
            var lines = [Cluster.Setup.needsTerminalLine, ClusterOnboardingTerminal.stoppedLine]
            let cases: [([(label: String, loaded: Bool)], Bool)] = [([], true), ([], false), ([("agent", false), ("old", true)], true)]
            for (agents, running) in cases {
                lines += Status.clusterServiceLines(agents: agents, serviceRunning: running, paired: true,
                                                    supervisor: nil, now: 0, bootTime: 0)
            }
            for line in lines { print(line) }
        }
        let out = text(result?.standardOutputContent)
        #expect(out.contains("Run `darkbloom-dev cluster` in a Terminal window on this Mac."), "\(out)")
        #expect(out.contains("Stopped. Run `darkbloom-dev cluster` again to continue where it was."), "\(out)")
        #expect(out.contains("(run `darkbloom-dev cluster` to set that up)") && out.contains("login (run `darkbloom-dev cluster`)"), "\(out)")
        #expect(out.contains("(`darkbloom-dev cluster` keeps one)"), "\(out)")
        #expect(!out.contains("`darkbloom "), "\(out)")
    }

    @Test("P2-2: the onboarding's Local Network hint and the lines its live operations write name the DevNet CLI and app")
    func onboardingTextsNameTheIdentity() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            ClusterOnboardingCommand.use("darkbloom-dev")
            print(OnboardingLive.localNetworkHint("the other Mac"))
            print("cli " + OnboardingLive.cli)
        }
        let out = text(result?.standardOutputContent)
        let app = BuildEnvironment.current.appDisplayName
        #expect(out.contains("If you denied the Local Network prompt on the other Mac, turn on “Darkbloom”"
            + (app == "Darkbloom" ? "" : " (macOS lists \(app) as “Darkbloom”)")
            + " in System Settings → Privacy & Security → Local Network there, then run `darkbloom-dev cluster` again.\n"), "\(out)")
        #expect(out.hasSuffix("cli darkbloom-dev\n"), "every command the live operations name: \(out)")
        #expect(!out.contains("`darkbloom "), "\(out)")
    }

    @Test("P2-13: the leading Mac says the other Mac answers while they run the cluster, false while it is away, else unknown")
    func leaderSaysWhetherTheOtherMacAnswers() {
        var serving = pair(role: .leader)
        serving.read(status: ["Serving Qwen 3.8 27B through Darkbloom on both Macs (tensor parallel)."], leaderMode: "cluster")
        #expect(serving.otherMacAnswers == true)
        #expect(serving.json.otherMac?.answers == true)
        var stopped = pair(role: .leader, started: false)
        stopped.read(status: ["Stopped; last model Qwen 3.8 27B."], leaderMode: "idle")
        #expect(stopped.otherMacAnswers == nil)
        var away = pair(role: .leader)
        away.read(status: ["The other Mac doesn't answer over the cable; this Mac serves alone."], leaderMode: "alone")
        #expect(away.otherMacAnswers == false)
    }

    @Test("P2-8: the leading Mac's answer is waited for at most its bound, and a slow one is said")
    func slowLeaderAnswerIsBoundedAndSaid() {
        let said = SaidLines()
        let late = ClusterPairSummary.boundedStatus(within: 1, noticeAfter: 0.05, slow: { said.add($0) }) {
            Thread.sleep(forTimeInterval: 2); return ["late"]
        }
        #expect(late == nil)
        #expect(said.all == ["  Waiting for the leading Mac's answer (up to 1 s).",
                             "  The leading Mac didn't answer in 1 s; this is this Mac's own view."])
        let quiet = SaidLines()
        let prompt = ClusterPairSummary.boundedStatus(within: 1, noticeAfter: 0.5, slow: { quiet.add($0) }) { ["Serving"] }
        #expect(prompt == ["Serving"])
        #expect(quiet.all.isEmpty)
    }
}

@Suite("Review closures: the bounded wait only for a person's status on the Mac that follows")
struct ClusterBoundedWaitScopeTests {
    @Test("the leading Mac's status and a script start's looks wait as long as the answer takes, and say nothing")
    func onlyAFollowersStatusIsBounded() {
        let leader = SaidLines()
        let own = ClusterPairSummary.statusLines(leads: true, slow: { leader.add($0) }, within: 1, noticeAfter: 0.05) {
            Thread.sleep(forTimeInterval: 1.3); return ["Serving"]
        }
        #expect(own == ["Serving"], "the leading Mac's own status is never cut short")
        #expect(leader.all.isEmpty, "\(leader.all)")
        let looks = ClusterPairSummary.statusLines(leads: false, slow: nil, within: 1, noticeAfter: 0.05) {
            Thread.sleep(forTimeInterval: 1.3); return ["Loading"]
        }
        #expect(looks == ["Loading"], "a script start's look is never cut short")
        let follower = SaidLines()
        let late = ClusterPairSummary.statusLines(leads: false, slow: { follower.add($0) }, within: 1, noticeAfter: 0.05) {
            Thread.sleep(forTimeInterval: 1.3); return ["late"]
        }
        #expect(late == nil)
        #expect(follower.all == ["  Waiting for the leading Mac's answer (up to 1 s).",
                                 "  The leading Mac didn't answer in 1 s; this is this Mac's own view."])
    }

    @Test("a script start's looks never ask for the bounded wait; cluster status does")
    func scriptStartNeverAsksForTheBoundedWait() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            try await exitWithPair(servingPair(), actions: pairActions()) { _ in
                try await ClusterPairSummary.$liveReadForTesting.withValue({ print("live read: " + ($0 ? "bounded" : "unbounded")) }) {
                    try await runCLICommand(Start.self, ["start"])
                    print("-- cluster status --")
                    try await runCLICommand(Cluster.Status.self, ["cluster", "status"])
                }
            }
        }
        let out = text(result?.standardOutputContent).components(separatedBy: "-- cluster status --")
        #expect(out.count == 2, "\(out)")
        let start = out.first ?? "", status = out.last ?? ""
        #expect(start.contains("live read: unbounded") && !start.contains("live read: bounded"), "\(start)")
        #expect(status.contains("live read: bounded") && !status.contains("live read: unbounded"), "\(status)")
    }
}

@Suite("Status truths: a Local Network refusal is said, and a stopped pair reads stopped")
struct ClusterStatusTruthTests {
    private static let app = ClusterService.appName
    private static let starting = ["Starting Qwen 3.8 27B."]

    @Test("R-1: the Mac macOS keeps off the local network reads not serving, in the joining screen's words")
    func refusedFollowerIsNotServingOnTheMember() {
        var member = pair(role: .member)
        member.read(status: Self.starting, leaderMode: nil)
        #expect(member.state == .loading)
        member.read(localNetworkRefused: .thisMac)
        let cli = ClusterPairSummary.cli
        let blocked = ClusterOnboardingDriver.localNetworkBlockedLines(app: Self.app,
            then: "then run `\(cli) start` here, or choose Retry in `\(cli) cluster` on the other Mac")
        #expect(member.state == .notServing && member.exitCode == 3)
        #expect(member.reason == "This Mac can't reach the other Mac over the cable: macOS keeps \(Self.app) off the local network")
        #expect(member.reason.map { $0 + "." } == blocked[0])
        #expect(member.next == blocked[1])
        let json = member.json
        #expect(json.state == "not_serving" && json.reason == member.reason && json.next == member.next && json.exitCode == 3)
    }

    @Test("R-1: the leading Mac reads not serving once the other Mac's refusal counts, in the ✗'s words")
    func refusedFollowerIsNotServingOnTheLeader() {
        var leader = pair(role: .leader)
        leader.read(status: Self.starting, leaderMode: "cluster")
        leader.read(localNetworkRefused: .otherMac)
        let cli = ClusterPairSummary.cli
        #expect(leader.state == .notServing && leader.exitCode == 3)
        #expect(leader.reason == "The other Mac can't reach this Mac over the cable: macOS keeps \(Self.app) there off the local network")
        #expect(leader.next == "The other Mac (Apple M5 Max, 128 GB): System Settings → Privacy & Security → Local Network → "
            + "turn on “Darkbloom”" + (Self.app == "Darkbloom" ? "" : " (macOS lists \(Self.app) as “Darkbloom”)")
            + "; if it isn't listed, click Allow when macOS asks on that Mac's screen, the next time \(Self.app) dials over the cable "
            + "(on a Mac with no display, through Screen Sharing). Then run `\(cli) start` here, or choose Retry in `\(cli) cluster`.")
        #expect(leader.clusterStatusLines.contains("✗ Not serving: \(leader.reason ?? "")."), "\(leader.clusterStatusLines)")
        // Never over a pair that serves, or one that stopped.
        var serving = pair(role: .leader)
        serving.read(status: ["Serving Qwen 3.8 27B through Darkbloom on both Macs (tensor parallel)."], leaderMode: "cluster")
        serving.read(localNetworkRefused: .otherMac)
        #expect(serving.state == .serving && serving.reason == nil)
        var stopped = pair(role: .member, started: false)
        stopped.read(status: ["Stopped; last model Qwen 3.8 27B."], leaderMode: nil)
        stopped.read(localNetworkRefused: .thisMac)
        #expect(stopped.state == .stopped && stopped.reason == nil)
    }

    @Test("R-1: a script start on the leading Mac ends its wait on the other Mac's refusal, with its steps, and exits 3")
    func leaderStartEndsItsWaitOnTheRefusal() async {
        let result = await #expect(processExitsWith: .exitCode(3), observing: [\.standardOutputContent]) {
            var refused = observed(Self.starting[0])
            refused.read(localNetworkRefused: .otherMac)
            // A wait that went on would read the next look, which serves.
            let looks = Looks([observed(Self.starting[0]), refused,
                               observed("Serving Qwen 3.8 27B through Darkbloom on both Macs (tensor parallel).")])
            try await exitWithPair(pair(), actions: pairActions()) { _ in
                try await ClusterPairSummary.$readerForTesting.withValue({ live in live ? looks.next() : pair() }) {
                    try await ClusterPairCommands.$waitForTesting.withValue(.init(seconds: 60, interval: 0)) {
                        try await runCLICommand(Start.self, ["start"])
                    }
                }
            }
        }
        let out = lines(result?.standardOutputContent)
        let cli = ClusterPairSummary.cli
        #expect(out.contains("✗ Not serving: The other Mac can't reach this Mac over the cable: macOS keeps \(Self.app) there off the "
            + "local network."), "\(out)")
        #expect(out.contains { $0.hasPrefix("  Next:    The other Mac (Apple M5 Max, 128 GB): System Settings → ")
            && $0.hasSuffix(" Then run `\(cli) start` here, or choose Retry in `\(cli) cluster`.") }, "\(out)")
        #expect(!out.contains { $0.contains("Serving Qwen") }, "the wait ended at the refusal: \(out)")
    }

    @Test("R-1: the other Mac's refusal counts by the ✗'s rule: its running part reports it, and this Mac's part has run 20 s")
    func otherMacRefusalFollowsTheScreensRule() {
        let now = Date().timeIntervalSince1970
        let refused = ClusterServiceStatus.Child(running: true, starts: 1,
                                                 lastError: ClusterService.localNetworkReasonPrefix + ": macOS refused the dial")
        let own = ClusterServiceStatus.Child(running: true, starts: 1, startedAt: now - 25)
        #expect(OnboardingLive.refusalIsCurrent(own: own, now: now))
        #expect(ClusterLocalNetworkAccess.otherMacRefused(member: refused, own: own, now: now))
        let young = ClusterServiceStatus.Child(running: true, starts: 1, startedAt: now - 5)
        #expect(!OnboardingLive.refusalIsCurrent(own: young, now: now))
        #expect(!ClusterLocalNetworkAccess.otherMacRefused(member: refused, own: young, now: now), "before one more dial it may be stale")
        var ended = refused
        ended.running = false
        #expect(!ClusterLocalNetworkAccess.otherMacRefused(member: ended, own: own, now: now), "an ended part's refusal is history")
    }

    @Test("R-7: a status read keeps the other Mac's refusal across this Mac's part restarts; a start's own wait doesn't")
    func refusalHoldsAcrossTheLeadersPartRestarts() {
        // The pair-2 re-test of the DevNet build: while the other Mac is refused, this Mac's part waits 32 s for the link,
        // ends (exit 1) and starts again 6-25 s later. A stand-in for its published status at each moment of four parts.
        let parts: [(start: Double, end: Double)] = [(0, 32), (38, 70), (83, 115), (140, 172)]
        func own(at t: Double) -> ClusterServiceStatus.Child {
            let lastRun = parts.last(where: { $0.end <= t }).map { $0.end - $0.start }
            if let part = parts.first(where: { $0.start <= t && t < $0.end }) {
                return .init(running: true, starts: 1, startedAt: part.start, lastRunSeconds: lastRun)
            }
            return .init(running: false, starts: 1, lastEnd: "exit 1", restartInSeconds: 5, lastRunSeconds: lastRun)
        }
        let refused = ClusterServiceStatus.Child(running: true, starts: 1,
                                                 lastError: ClusterService.localNetworkReasonPrefix + ": macOS refused the dial")
        let samples = Array(stride(from: 0.0, through: 170, by: 5))
        func says(_ member: ClusterServiceStatus.Child, acrossRestarts: Bool) -> [Double] {
            samples.filter { ClusterLocalNetworkAccess.otherMacRefused(member: member, own: own(at: $0), now: $0, acrossRestarts: acrossRestarts) }
        }
        #expect(says(refused, acrossRestarts: true) == Array(stride(from: 20.0, through: 170, by: 5)),
                "a status read: not serving from 20 s into the first part, through every restart")
        #expect(says(refused, acrossRestarts: false) == [20, 25, 30, 60, 65, 105, 110, 160, 165, 170],
                "a start's own wait: only while the current part has run 20 s, as before")
        // The other Mac's follower got through once the setting was on: its part no longer reports the refusal.
        let through = ClusterServiceStatus.Child(running: true, starts: 1)
        #expect(says(through, acrossRestarts: true).isEmpty, "a refusal the follower got past never counts")
        // A first part that never ran 20 s carries nothing: its listener may never have had the follower's next dial.
        let short = ClusterServiceStatus.Child(running: false, starts: 1, lastEnd: "exit 1", lastRunSeconds: 8)
        #expect(!ClusterLocalNetworkAccess.otherMacRefused(member: refused, own: short, now: 100, acrossRestarts: true))
    }

    @Test("R-9: during the refusal, --json lines agree with the state, as the plain output does")
    func refusalLinesAgreeWithTheState() {
        var leader = pair(role: .leader)
        leader.read(status: Self.starting, leaderMode: "cluster")
        let plainBefore = leader.clusterStatusLines
        leader.read(localNetworkRefused: .otherMac)
        let title = "Not serving: The other Mac can't reach this Mac over the cable: macOS keeps \(Self.app) there off the local network."
        #expect(leader.json.lines == [title], "\(leader.json.lines)")
        #expect(leader.clusterStatusLines.contains("✗ " + title) && !leader.clusterStatusLines.contains { $0.contains("Starting") },
                "the plain output, as before: \(leader.clusterStatusLines)")
        #expect(plainBefore.contains("… Starting Qwen 3.8 27B."), "\(plainBefore)")
        var member = pair(role: .member)
        member.read(status: Self.starting, leaderMode: nil)
        member.read(localNetworkRefused: .thisMac)
        #expect(member.json.lines == ["Not serving: This Mac can't reach the other Mac over the cable: macOS keeps \(Self.app) off the "
                                      + "local network."], "\(member.json.lines)")
    }

    @Test("R-8: a stopped local-only pair's line, and the API line of a pair the other Mac serves, name this build's command")
    func servingLinesNameThisBuildsCommand() {
        let cli = ClusterPairSummary.cli
        #expect(ClusterServingScope.localOnly(bind: ClusterServingScope.localOnlyDefaultBind).line
                == "Local only, on this Mac's networks; API key: `\(cli) local`")
        let ready = ClusterOnboardingReady(servedBy: ClusterOnboardingMacName.other(named: "Apple M5 Max, 128 GB"), port: 8000, network: true)
        #expect(ready.apiLine.hasSuffix("; this Mac answers too (`\(cli) local` shows its address)"), "\(ready.apiLine)")
        print("R-8 in this build: " + ClusterServingScope.localOnly(bind: ClusterServingScope.localOnlyDefaultBind).line)
    }

    @Test("R-5: a stopped pair reads stopped whatever the other Mac's presence, and says it isn't answering")
    func stoppedPairStaysStopped() {
        var leader = pair(role: .leader, started: false)
        leader.read(status: ["The other Mac (Apple M5 Max, 128 GB) is gone; this Mac cannot serve Qwen 3.8 27B alone, so nothing "
                             + "of it runs after 9 min 58 s unless it returns first."], leaderMode: "cannotServe")
        #expect(leader.state == .stopped && leader.exitCode == 4)
        #expect(leader.otherMacAnswers == false)
        #expect(leader.lines == ["Stopped; last model Qwen 3.8 27B.", "The other Mac (Apple M5 Max, 128 GB) isn't answering over the cable."])
        var member = pair(role: .member, started: false)
        member.read(status: ["The other Mac (Apple M5 Max, 128 GB) did not answer over the cable: timed out"], leaderMode: nil)
        #expect(member.state == .stopped && member.exitCode == 4 && member.otherMacAnswers == false)
        // A pair that was started and lost the other Mac still reads away.
        var away = pair(role: .leader)
        away.read(status: ["The other Mac (Apple M5 Max, 128 GB) is gone; this Mac serves alone."], leaderMode: "waiting")
        #expect(away.state == .otherMacAway && away.exitCode == 5)
    }

    @Test("R-1: the refusal's words name this build's app and command (a dev-identity build shows the DevNet wording)")
    func refusalWordsNameThisBuild() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            ClusterOnboardingCommand.use(BuildEnvironment.current.cliName)
            var member = pair(role: .member)
            member.read(status: Self.starting, leaderMode: nil)
            member.read(localNetworkRefused: .thisMac)
            var leader = pair(role: .leader)
            leader.read(status: Self.starting, leaderMode: "cluster")
            leader.read(localNetworkRefused: .otherMac)
            for line in [member.reason, member.next, leader.reason, leader.next] { print(line ?? "none") }
        }
        let out = lines(result?.standardOutputContent).filter { !$0.isEmpty }
        for line in out { print("refusal words (\(BuildEnvironment.current.rawValue)): " + line) }
        let app = BuildEnvironment.current.appDisplayName, cli = BuildEnvironment.current.cliName
        #expect(out.count == 4, "\(out)")
        #expect(out.allSatisfy { $0.contains(app) }, "\(out)")
        // R4-4: the row macOS shows, "Darkbloom" in both identities, and what to do where there is none.
        #expect(out.count == 4 && [out[1], out[3]].allSatisfy { $0.contains("turn on “Darkbloom”") && $0.contains("if it isn't listed, click Allow") }
                && out[1].contains("`\(cli) start`") && out[3].contains("`\(cli) cluster`"), "\(out)")
        #expect(app == "Darkbloom" || [out[1], out[3]].allSatisfy { $0.contains("(macOS lists \(app) as “Darkbloom”)") && !$0.contains("turn on “\(app)”") },
                "\(out)")
    }

    @Test("R4-4: the follower's refusal names the row macOS shows in both identities, and the prompt where there is none")
    func followerRefusalNamesTheRowMacOSShows() {
        let tail = "; if it isn't listed, click Allow when macOS asks on this Mac's screen at the next dial. "
            + "Or start the follower from a session that has that access."
        let head = "this process may not reach the local network: macOS refused the dial before the cable was tried. "
            + "Turn on “Darkbloom” under System Settings > Privacy & Security > Local Network"
        #expect(Cluster.LinkFollower.refusalLine(app: "Darkbloom", row: "Darkbloom") == head + tail)
        #expect(Cluster.LinkFollower.refusalLine(app: "Darkbloom Dev", row: "Darkbloom") == head + " (macOS lists Darkbloom Dev as “Darkbloom”)" + tail)
    }
}

@Suite("Status names the serving mode and split for every mode, as the ✓ line does")
struct ClusterStatusModeTests {
    private static let glm = "Z.ai: GLM-5.3-Flash"

    private static func glmPair(mode: String?, status: [String]) -> ClusterPairSummary {
        var summary = pair(role: .leader)
        summary.modelID = "glm-5.3-flash"
        summary.modelName = glm
        summary.deployment = mode.map { mode in
            ClusterOnboardingDeployment.line(model: glm, mode: mode, shares: [
                .init(name: "Apple M3 Ultra, 256 GB", layers: 30, weightsBytes: 150),
                .init(name: "Apple M5 Ultra, 256 GB", layers: 17, weightsBytes: 150)])
        }
        summary.read(status: status, leaderMode: "cluster")
        return summary
    }

    @Test("R3-4: a GLM pipeline pair, whose name holds \": \", says its mode and split in the JSON and the Model line")
    func glmPipelineSaysItsMode() {
        let summary = Self.glmPair(mode: "pipeline",
            status: ["Serving \(Self.glm) (pipeline) at http://localhost:8000 and on the network (local only)."])
        #expect(summary.state == .serving)
        let json = summary.json
        #expect(json.mode == "pipeline" && json.split == "M3 Ultra 30 layers / M5 Ultra 17 layers", "\(String(describing: json.mode)) \(String(describing: json.split))")
        #expect(summary.clusterStatusLines.contains("Model: \(Self.glm) · pipeline · M3 Ultra 30 layers / M5 Ultra 17 layers"),
                "\(summary.clusterStatusLines)")
    }

    @Test("R3-4: every serving mode's words come back from the deployment line, whatever the model's name")
    func everyModeComesBack() {
        for raw in ["tensor", "pipeline", "pipeline_mtp", "prefill_tensor_decode", "phase_split"] {
            let summary = Self.glmPair(mode: raw, status: ["Serving \(Self.glm) at http://localhost:8000."])
            let words = ClusterOnboardingDeployment.modeWords(raw)
            #expect(summary.json.mode == words, "\(raw): \(String(describing: summary.json.mode))")
            #expect(summary.json.split != nil, "\(raw)")
        }
        #expect(Self.glmPair(mode: "tensor", status: ["Serving \(Self.glm) at http://localhost:8000."]).json.split
                == "M3 Ultra 50% / M5 Ultra 50%")
    }

    @Test("R3-4: without a recorded deployment line, the mode comes from the ✓ line's own marker")
    func modeFromTheServingLineWithoutADeployment() {
        let summary = Self.glmPair(mode: nil, status: ["Serving \(Self.glm) (pipeline) at http://localhost:8000 on the other Mac."])
        #expect(summary.json.mode == "pipeline" && summary.json.split == nil, "\(String(describing: summary.json.mode))")
        #expect(summary.clusterStatusLines.contains("Model: \(Self.glm) · pipeline"), "\(summary.clusterStatusLines)")
        let unmarked = Self.glmPair(mode: nil, status: ["Serving \(Self.glm) at http://localhost:8000."])
        #expect(unmarked.json.mode == nil && unmarked.json.split == nil)
    }
}

/// The desktop app on a paired Mac. Its onboarding starts with Autopilot, which serves one Mac: on a paired Mac it
/// downloaded a model first and then showed the CLI's three lines, again at each Retry. The app needs to hear that before
/// anything runs, in its own words, and the snapshot it reads must let it offer Start serving, which starts the pair. Its
/// Start's own lines say what happened.
@Suite("the desktop app on a paired Mac")
struct DesktopAppOnAPairedMacTests {
    private static let autopilotRefusal = "This Mac serves in a pair; Autopilot isn't available for pairs yet. Use Start serving."
    private static let starting = "This Mac is in a two-Mac cluster with \(otherMac): starting the pair."

    @Test("the app's Autopilot enroll and its model refresh on a paired Mac are refused in its words, before any download; its Start is not")
    func autopilotIsRefusedFirst() async {
        let paired = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            try await exitWithPair(stoppedPair(), actions: nil) { sandbox in
                let backend = DesktopBackend(configPath: sandbox.config.path)
                for action in ["autopilot", "autopilot_models", "start"] {
                    let request = DesktopAction(id: "x", action: action, models: ["acme/Alpha-4bit"], downloads: ["acme/Alpha-4bit"],
                                                endpoint: true)
                    // The arguments come before `runAutopilot`'s downloads: a refusal here downloads nothing.
                    do {
                        let argv = try await backend.arguments(for: request)
                        print("\(action): \(argv.prefix(2).joined(separator: " "))")
                    } catch { print("\(action): refused: \(error)") }
                }
            }
        }
        #expect(lines(paired?.standardOutputContent) == ["autopilot: refused: \(Self.autopilotRefusal)",
                                                         "autopilot_models: refused: \(Self.autopilotRefusal)",
                                                         "start: start --model", ""])
        let single = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            try await exitWithPair(.notPaired, actions: nil) { sandbox in
                let request = DesktopAction(id: "x", action: "autopilot", models: ["acme/Alpha-4bit"])
                let argv = try await DesktopBackend(configPath: sandbox.config.path).arguments(for: request)
                print("autopilot: \(argv.prefix(2).joined(separator: " "))")
            }
        }
        #expect(lines(single?.standardOutputContent) == ["autopilot: start --autopilot", ""])
    }

    @Test("the app's snapshot on a paired Mac offers no Autopilot and names the pair's model, so the app offers Start serving")
    func snapshotOffersStartServing() async {
        let paired = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            try await exitWithPair(stoppedPair(), actions: nil) { sandbox in try await printSnapshotAutopilotAndPair(sandbox) }
        }
        #expect(lines(paired?.standardOutputContent) == ["autopilot: false", #"pair: {"model":"Qwen 3.8 27B"}"#, ""])
        let single = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            try await exitWithPair(.notPaired, actions: nil) { sandbox in try await printSnapshotAutopilotAndPair(sandbox) }
        }
        #expect(lines(single?.standardOutputContent) == ["autopilot: true", "pair: null", ""])
    }

    /// The app's Start on a paired Mac names no model (`startPlan.startAction`). As its main process posts it, through the
    /// desktop API's own decode and `submit`: taken only on a paired Mac, where `start` starts the pair.
    @Test("the app's Start as the app posts it: on a paired Mac `start` runs and starts the pair; elsewhere it is refused, and a pair with no model says so in one line")
    func appStartAsPosted() async {
        // A paired Mac: `start` runs with the pair's arguments, no model and no local API of its own, and starts the pair.
        let paired = await #expect(processExitsWith: .success, observing: [\.standardOutputContent, \.standardErrorContent]) {
            try await exitWithPair(stoppedPair(), actions: pairActions(serving: false)) { sandbox in
                let posted = try await postAppStart(sandbox)
                print("posted: \(posted)")
                guard posted == "succeeded: start --config <config>" else { return }
                try await ClusterPairSummary.$readerForTesting.withValue({ live in live ? servingPair() : stoppedPair() }) {
                    try await runAppStart(sandbox, [])
                }
            }
        }
        #expect(lines(paired?.standardOutputContent) == ["posted: succeeded: start --config <config>", Self.starting]
            + servingBlock + [""])
        let pairedStderr = text(paired?.standardErrorContent)
        #expect(pairActionCalls(pairedStderr) == ["ensureService", "serve"], "\(pairActionCalls(pairedStderr))")
        #expect(changingLaunchctlCalls(pairedStderr).isEmpty, "\(changingLaunchctlCalls(pairedStderr))")
        // A Mac that isn't paired: refused at once, as before.
        let single = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            try await exitWithPair(.notPaired, actions: nil) { sandbox in print("posted: \(try await postAppStart(sandbox))") }
        }
        #expect(lines(single?.standardOutputContent)
            == ["posted: refused (400 Bad Request), nothing ran: Choose at least one model", ""])
        // A pair with no model yet: refused at once with the CLI's line for it, never "starting the pair".
        let noModel = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            try await exitWithPair(pair(started: false, model: false), actions: nil) { sandbox in
                print("posted: \(try await postAppStart(sandbox))")
            }
        }
        #expect(lines(noModel?.standardOutputContent) == ["posted: refused (400 Bad Request), nothing ran: "
            + "No model was chosen for the pair yet: run `darkbloom start` in a terminal to choose one.", ""])
    }

    @Test("only a plain start may name no models, and only where it starts the pair: `start`'s own test of a paired Mac")
    func startWithoutModelsOnlyStartsAPair() throws {
        #expect(try !DesktopBackend.startsThePair(.notPaired))
        #expect(try DesktopBackend.startsThePair(stoppedPair()))
        // An unreadable pairing record counts as paired, as in `start`, which then refuses without --solo.
        #expect(try DesktopBackend.startsThePair(unreadable()))
        let noModel = #expect(throws: ValidationError.self) { try DesktopBackend.startsThePair(pair(started: false, model: false)) }
        #expect(noModel?.message == ClusterPairSummary.noModelLine)
        // Local mode and a switch still name their models, paired or not.
        for request in [DesktopAction(id: UUID().uuidString, action: "start", models: [], local: true),
                        DesktopAction(id: UUID().uuidString, action: "switch", models: [])] {
            let refused = #expect(throws: ValidationError.self) { try request.validate(startsThePair: { true }) }
            #expect(refused?.message == "Choose at least one model", "\(request.action)")
        }
    }

    @Test("the app's Start says what happened: the pair serves its model, or was asked to start and isn't serving, and no local API was added")
    func appStartLinesAreTrue() async {
        // A pair that already serves: it "serves" its model; nothing was "started", and this Mac doesn't serve alone.
        let serving = await #expect(processExitsWith: .success, observing: [\.standardOutputContent, \.standardErrorContent]) {
            try await exitWithPair(servingPair(), actions: pairActions()) { sandbox in
                try await runAppStart(sandbox, ["--model", "acme/Alpha-4bit", "--local-endpoint"])
            }
        }
        #expect(lines(serving?.standardOutputContent) == [alreadyServes] + servingBlock + [appStartServesLine, appStartNoLocalAPILine, ""])
        let servingStderr = text(serving?.standardErrorContent)
        #expect(changingLaunchctlCalls(servingStderr).isEmpty, "\(changingLaunchctlCalls(servingStderr))")
        // Still loading when the wait ends (exit 3): asked to start, not serving.
        let loading = await #expect(processExitsWith: .exitCode(3), observing: [\.standardOutputContent]) {
            try await exitWithPair(stoppedPair(), actions: pairActions(serving: false)) { sandbox in
                try await ClusterPairSummary.$readerForTesting.withValue({ live in live ? loadingPair() : stoppedPair() }) {
                    try await runAppStart(sandbox, ["--model", "acme/Alpha-4bit", "--local-endpoint"])
                }
            }
        }
        let loadingOut = lines(loading?.standardOutputContent)
        #expect(Array(loadingOut.suffix(3)) == ["This Mac is in a pair: the pair was asked to start with Qwen 3.8 27B, and "
            + "isn't serving (above); `darkbloom cluster` changes its model.", appStartNoLocalAPILine, ""], "\(loadingOut)")
        #expect(!loadingOut.contains { $0.hasPrefix("This Mac serves in a pair") }, "\(loadingOut)")
        // A pair that serves Only me answers on its local API from this Mac too: nothing to say about one.
        let onlyMe = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            try await exitWithPair(onlyMeServingPair(), actions: pairActions()) { sandbox in
                try await runAppStart(sandbox, ["--local-endpoint"])
            }
        }
        let onlyMeOut = lines(onlyMe?.standardOutputContent)
        #expect(!onlyMeOut.contains(appStartNoLocalAPILine), "\(onlyMeOut)")
        #expect(!onlyMeOut.contains { $0.hasPrefix("This Mac serves in a pair") || $0.hasPrefix("This Mac is in a pair") },
                "\(onlyMeOut)")
    }

    @Test("the app's Start adds nothing after another outcome, and says no local API was added only where the pair gives none")
    func appStartLinesOnlyWhereTrue() {
        // Away (5), stopped (4), refused or failed (1, 64): the pair's own lines say what happened.
        for code: Int32 in [1, 4, 5, 64] {
            #expect(pair().appStartLines(named: ["acme/Alpha-4bit"], localEndpoint: true, code: code).isEmpty, "exit \(code)")
        }
        // Both, me first gives a local API on the leading Mac only: its role says so before the pair runs, while its part
        // doesn't run rank 0 yet. Only me gives one on both Macs.
        for role in [ClusterPairSummary.Role.leader, .member] {
            var meFirst = pair(role: role)
            meFirst.localAPI = ClusterPairLocalAPI(runsRankZero: false, listening: nil, meFirst: nil)
            #expect(meFirst.appStartLines(named: [], localEndpoint: true, code: 0)
                == (role == .leader ? [String]() : [appStartNoLocalAPILine]), "\(role)")
            #expect(pair(role: role, localOnly: true).appStartLines(named: [], localEndpoint: true, code: 0).isEmpty, "\(role)")
        }
    }

    @Test("a pair whose other Mac is away and whose part was given up here also names `start --solo`")
    func otherMacAwayNamesSolo() {
        var givenUp = pair()
        givenUp.state = .otherMacAway
        givenUp.pairRunning = false
        #expect(givenUp.next?.hasSuffix(" Or serve this Mac alone: `darkbloom start --solo`.") == true, "\(givenUp.next ?? "")")
        // Still inside its 15 minutes: the part holds the lock, so --solo would be refused; it isn't named.
        var waiting = pair()
        waiting.state = .otherMacAway
        #expect(waiting.next?.contains("--solo") == false, "\(waiting.next ?? "")")
    }
}

/// The app's snapshot on the sandbox's Mac (`DesktopBackend.state()`): whether it offers Autopilot, and its `pair`.
private func printSnapshotAutopilotAndPair(_ sandbox: CLICommandSandbox) async throws {
    let state = try await DesktopBackend(configPath: sandbox.config.path).state()
    guard case .array(let capabilities) = state.field("capabilities") else { throw ExitCode(97) }
    print("autopilot: \(capabilities.contains(.string("autopilot")))")
    print("pair: \(String(decoding: try JSONEncoder().encode(state.field("pair")), as: UTF8.self))")
}

/// The app's Start as its main process posts it on a paired Mac: `startPlan.startAction`'s action with an id
/// (`backend.ts`'s `act`; the app's backend test pins this JSON), through the desktop API's own decode and `submit`, with
/// `echo` in place of the CLI. What came of it: the finished operation's state and the arguments it ran, or the API's
/// refusal and whether anything ran.
private func postAppStart(_ sandbox: CLICommandSandbox) async throws -> String {
    setenv("DARKBLOOM_DESKTOP_DIR", sandbox.root.appendingPathComponent("desktop", isDirectory: true).path, 1)
    setenv("DARKBLOOM_LOCAL_DIR", sandbox.root.appendingPathComponent("local", isDirectory: true).path, 1)
    let body = #"{"action":"start","models":[],"local":false,"id":"\#(UUID().uuidString)"}"#
    let backend = DesktopBackend(configPath: sandbox.config.path, executable: URL(fileURLWithPath: "/bin/echo"))
    let operation: DesktopOperation
    do {
        operation = try await backend.submit(DesktopHTTP.decodeAction(Data(body.utf8)))
    } catch {
        let refusal = DesktopHTTP.errorResponse(for: error)
        let ran = await backend.operations.isEmpty ? "nothing ran" : "an operation was recorded"
        return "refused (\(refusal.status)), \(ran): \(refusal.message)"
    }
    for _ in 0..<500 {
        if let done = await backend.operations.first(where: { $0.id == operation.id }), done.state != "running" {
            let ran = done.message.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(done.state): " + ran.replacingOccurrences(of: sandbox.config.path, with: "<config>")
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    return "still running after 5 s"
}

/// The app's Start as its worker runs it on a paired Mac: `start` with `options` and the sandbox's config, no terminal,
/// standard input that never answers, and the pair's wait cut to nothing.
private func runAppStart(_ sandbox: CLICommandSandbox, _ options: [String]) async throws {
    try neverAnswering(sandbox)
    try await ClusterPairCommands.$waitForTesting.withValue(.init(seconds: 0, interval: 0)) {
        try await runCLICommand(Start.self, ["start"] + options + ["--config", sandbox.config.path])
    }
}

/// A pair still loading its model when a start's wait ends (`cluster status` exit 3).
private func loadingPair() -> ClusterPairSummary {
    var summary = pair()
    summary.state = .loading
    summary.lines = ["Loading Qwen 3.8 27B on both Macs."]
    return summary
}

/// A pair that serves Only me: its local API answers on this Mac too (the other Mac relays its own port).
private func onlyMeServingPair() -> ClusterPairSummary {
    var summary = pair(localOnly: true)
    summary.state = .serving
    summary.lines = ["Serving Qwen 3.8 27B at http://localhost:8000."]
    return summary
}

/// Journey 2a on pair-2 (DevNet `.144`, `validation-evidence/journey-2a.md`, step 3): every paired `start` said "starting
/// the pair" first. A script's start on a pair that served kept it (J2-b), and one in a terminal on a stopped pair waited
/// at the model list until Enter (J2-d). The first line now says what the start does.
@Suite("journey 2a: a paired start's first line says what it does")
struct PairStartFirstLineTests {
    /// In a terminal, the words for the screen that opens: the leading Mac's list, where Enter starts the last model;
    /// with none chosen yet, the choice; the Mac that follows shows the pair, which the leading Mac's screen starts.
    @Test("in a terminal, a stopped pair's first line says how its screen starts it, and nothing else says starting")
    func terminalWordsMatchTheScreen() async {
        let noModel = await #expect(processExitsWith: .success, observing: [\.standardOutputContent, \.standardErrorContent]) {
            try await exitWithPair(noModelStoppedPair(), actions: pairActions(serving: false)) { _ in try await runStartInATerminal() }
        }
        let member = await #expect(processExitsWith: .success, observing: [\.standardOutputContent, \.standardErrorContent]) {
            try await exitWithPair(memberPair(stoppedPair()), actions: pairActions(role: .member, serving: false)) { _ in
                try await runStartInATerminal()
            }
        }
        let memberLoading = await #expect(processExitsWith: .success, observing: [\.standardOutputContent, \.standardErrorContent]) {
            try await exitWithPair(memberPair(loadingPair()), actions: pairActions(role: .member, serving: false)) { _ in
                try await runStartInATerminal()
            }
        }
        #expect(lines(noModel?.standardOutputContent) == ["This Mac is in a two-Mac cluster with \(otherMac), which is stopped. "
            + "Choose its model to start it.", "screen", ""])
        // The Mac that follows: its screen shows the pair and where it is changed; it starts nothing itself.
        #expect(lines(member?.standardOutputContent) == [openingScreen, "screen", ""])
        #expect(lines(memberLoading?.standardOutputContent) == [openingScreen, "screen", ""])
        for result in [noModel, member, memberLoading] {
            let calls = pairActionCalls(text(result?.standardErrorContent))
            #expect(calls.isEmpty, "\(calls)")
        }
    }

    /// Without a terminal, the pair's own look decides: one that serves is kept on either Mac; one that runs here and
    /// doesn't serve yet is started as before. The look is asked only while the other Mac answers this Mac's cluster
    /// service: one whose other Mac is away starts at once, as before, without waiting on a look first.
    @Test("without a terminal, a pair that serves is kept on either Mac; one still loading, or whose other Mac is away, starts as before")
    func scriptWordsMatchWhatHappens() async {
        let member = await #expect(processExitsWith: .success, observing: [\.standardOutputContent, \.standardErrorContent]) {
            try await exitWithPair(servingPair(role: .member), actions: pairActions(role: .member)) { sandbox in
                try neverAnswering(sandbox)
                try await runCLICommand(Start.self, ["start"])
            }
        }
        let memberOut = lines(member?.standardOutputContent)
        #expect(memberOut.first == alreadyServes, "\(memberOut)")
        #expect(memberOut.contains("✓ Serving Qwen 3.8 27B through Darkbloom on both Macs (tensor parallel)."), "\(memberOut)")
        let memberCalls = pairActionCalls(text(member?.standardErrorContent))
        #expect(memberCalls.isEmpty, "\(memberCalls)")
        // Started here, and the pair's look says it still loads: asked to start, and waited for.
        let loading = await #expect(processExitsWith: .success, observing: [\.standardOutputContent, \.standardErrorContent]) {
            try await exitWithPair(answeringPair(), actions: pairActions()) { sandbox in
                try neverAnswering(sandbox)
                // The first look is before the start, the others the start's wait.
                let looks = Looks([loadingPair(), loadingPair(), servingPair()])
                try await ClusterPairSummary.$readerForTesting.withValue({ live in live ? looks.next() : answeringPair() }) {
                    try await ClusterPairCommands.$waitForTesting.withValue(.init(seconds: 60, interval: 0)) {
                        try await runCLICommand(Start.self, ["start"])
                    }
                }
            }
        }
        let loadingOut = lines(loading?.standardOutputContent)
        #expect(loadingOut.first == "This Mac is in a two-Mac cluster with \(otherMac): starting the pair.", "\(loadingOut)")
        #expect(loadingOut.contains("  Loading Qwen 3.8 27B on both Macs."), "\(loadingOut)")
        #expect(loadingOut.contains("✓ Serving Qwen 3.8 27B through Darkbloom on both Macs (tensor parallel)."), "\(loadingOut)")
        #expect(pairActionCalls(text(loading?.standardErrorContent)) == ["ensureService", "serve"])
        // Its other Mac doesn't answer this Mac's cluster service: no look first, and the start goes on as before.
        let away = await #expect(processExitsWith: .success, observing: [\.standardOutputContent, \.standardErrorContent]) {
            try await exitWithPair(pair(), actions: pairActions()) { sandbox in
                try neverAnswering(sandbox)
                try await ClusterPairSummary.$readerForTesting.withValue({ live in live ? servingPair() : pair() }) {
                    try await ClusterPairSummary.$liveReadForTesting.withValue({ _ in print("live read") }) {
                        try await runCLICommand(Start.self, ["start"])
                    }
                }
            }
        }
        let awayOut = lines(away?.standardOutputContent)
        #expect(Array(awayOut.prefix(2)) == ["This Mac is in a two-Mac cluster with \(otherMac): starting the pair.", "live read"],
                "\(awayOut)")
        #expect(pairActionCalls(text(away?.standardErrorContent)) == ["ensureService", "serve"])
    }
}

/// A started pair whose other Mac answers this Mac's cluster service (its own view; the live status is the test's).
private func answeringPair() -> ClusterPairSummary {
    var summary = pair()
    summary.otherMacReachable = true
    return summary
}

/// `darkbloom start` in a terminal, its input closed, with the screen standing in as one line ("screen").
private func runStartInATerminal() async throws {
    try replaceStandardInput(with: "")
    try await ClusterPairCommands.$terminalForTesting.withValue(true) {
        try await ClusterPairCommands.$screenForTesting.withValue({ _ in print("screen") }) {
            try await runCLICommand(Start.self, ["start"])
        }
    }
}

/// A stopped pair whose leading Mac never chose a model.
private func noModelStoppedPair() -> ClusterPairSummary {
    var summary = stoppedPair()
    summary.modelID = nil
    summary.modelName = nil
    summary.deployment = nil
    return summary
}

/// `summary` as the Mac that follows reads it.
private func memberPair(_ summary: ClusterPairSummary) -> ClusterPairSummary {
    var summary = summary
    summary.role = .member
    return summary
}
