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
        #expect(Stop.pairedStop(pair(started: false), solo: false, uninstall: false) == .stopPair)
        #expect(Stop.pairedStop(pair(), solo: true, uninstall: false) == .stopSingleMac)
        #expect(Stop.pairedStop(pair(), solo: false, uninstall: true) == .stopSingleMac)
        #expect(Stop.pairedStop(.notPaired, solo: false, uninstall: false) == .stopSingleMac)
        #expect(pair().soloStopNothing == [
            "`darkbloom stop --solo` stops single-Mac serving, and none runs on this Mac: nothing was stopped.",
            "The pair was not stopped; `darkbloom stop` stops both Macs.",
        ])
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
        #expect(Start.pairStart(pair(role: .member, started: false, serviceRunning: false), solo: false, terminal: false) == .startPair)
        #expect(Start.pairStart(pair(), solo: true, terminal: true) == .single(note:
            "Starting single-Mac serving beside the two-Mac cluster with \(otherMac) (--solo): both use this Mac's memory."))
        #expect(Start.pairStart(pair(started: false), solo: true, terminal: false) == .single(note: "This Mac is in a "
            + "two-Mac cluster with \(otherMac), which is stopped. Stop single-Mac serving (`darkbloom stop --solo`) before "
            + "you start the pair again (`darkbloom start`)."))
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
        #expect(Restart.pairRestart(pair(), singleMacInstalled: false, solo: false) == .restartPair)
        #expect(Restart.pairRestart(pair(), singleMacInstalled: true, solo: false) == .restartPair)
        #expect(Restart.pairRestart(pair(), singleMacInstalled: true, solo: true) == .restartSingleMac)
        #expect(Restart.pairRestart(pair(), singleMacInstalled: false, solo: true) == .refuse([
            "This Mac serves in a two-Mac cluster with \(otherMac): it leads; Qwen 3.8 27B through Darkbloom.",
            "`darkbloom restart --solo` restarts single-Mac serving, and this Mac has none: nothing was restarted.",
            "The pair was not restarted; `darkbloom restart` restarts both Macs.",
        ]))
        #expect(Restart.pairRestart(.notPaired, singleMacInstalled: false, solo: false) == .restartSingleMac)
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
        own.control = .init(leaderID: "a", leaderName: "Apple M3 Ultra, 256 GB", term: 1, reason: "", leads: true,
                            line: "The other Mac (Apple M5 Max, 128 GB) is gone; …", mode: "waiting")
        #expect(ClusterPairSummary.ownState(started: true, own: own) == (.otherMacAway, "The other Mac (Apple M5 Max, 128 GB) is gone; …"))
        #expect(ClusterPairSummary.ownState(started: true, own: nil) == (.unknown, nil))
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

    @Test("the exit status: 0 serving, 3 not serving yet, 4 stopped, 5 the other Mac isn't answering, 6 not in a cluster")
    func exitCodes() {
        var summary = pair()
        for (state, code) in [(ClusterPairSummary.State.serving, Int32(0)), (.loading, 3), (.notServing, 3), (.unknown, 3),
                              (.stopped, 4), (.otherMacAway, 5), (.notPaired, 6)] {
            summary.state = state
            #expect(summary.exitCode == code, "\(state)")
        }
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
            "Next: To start it again: `darkbloom cluster` on this Mac, then choose the model. This Mac's cluster service is "
                + "off; `darkbloom cluster` starts it again.",
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
            #expect(failure.lines.last == "Nothing was stopped on this Mac. To stop only this Mac: `darkbloom cluster stop "
                + "--local-only` (the other Mac then serves alone, or waits for this one).")
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
        #expect(ClusterPairSummary.membership(.none, serviceRunning: true, loginAgentInstalled: false, startsAtLogin: false).paired)
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
        #expect(Restart.pairRestart(unreadable(), singleMacInstalled: true, solo: false) == .refuse([unsureSentence,
            "`darkbloom restart` can't tell which pair to restart, so nothing was restarted.",
            "To restart single-Mac serving on this Mac only: `darkbloom restart --solo`. Run `darkbloom cluster` on this Mac to check it."]))
        #expect(Restart.pairRestart(unreadable(), singleMacInstalled: false, solo: true) == .refuse([unsureSentence,
            "`darkbloom restart --solo` restarts single-Mac serving, and this Mac has none: nothing was restarted.",
            "Run `darkbloom cluster` on this Mac to check it."]))
        #expect(Restart.pairRestart(unreadable(), singleMacInstalled: true, solo: true) == .restartSingleMac)
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
private func pairActions(role: ClusterOnboardingRole = .leader, serving: Bool = true,
                         stop: Result<[String], ClusterOnboardingFailure> = .success(["Stopping both Macs. Run `darkbloom cluster` to serve again."]),
                         serve: Result<[String], ClusterOnboardingFailure> = .success(["Started the other Mac's part over the cable."]),
                         teardown: [String] = ["This Mac: nothing left running", "The other Mac (Apple M5 Max, 128 GB): nothing left running"])
    -> ClusterPairActions {
    @Sendable func said(_ action: String) { FileHandle.standardError.write(Data("pair action: \(action)\n".utf8)) }
    return ClusterPairActions(
        resume: { ClusterOnboardingResume(role: role, peerName: "Apple M5 Max, 128 GB", serving: serving, modelName: "EigenLabs/Qwen3.8-27B-4bit-mtp") },
        ensureService: { said("ensureService"); return .success(()) },
        serve: { said("serve"); return serve },
        stop: { said("stop"); return stop },
        verifyTeardown: { said("verifyTeardown"); return .success(teardown) })
}

private func pairActionCalls(_ stderr: String) -> [String] {
    stderr.split(separator: "\n").filter { $0.hasPrefix("pair action: ") }.map { String($0.dropFirst("pair action: ".count)) }
}

private func servingPair(role: ClusterPairSummary.Role = .leader) -> ClusterPairSummary {
    var summary = pair(role: role)
    summary.state = .serving
    summary.lines = ["Serving Qwen 3.8 27B through Darkbloom on both Macs (tensor parallel)."]
    return summary
}

private let resultFooter = ["", "  darkbloom stop     Stop both Macs", "  darkbloom restart  Restart with the current model",
                            "  darkbloom status   Check status"]

private let servingBlock = ["✓ Serving Qwen 3.8 27B through Darkbloom on both Macs (tensor parallel).",
                            "  Model:   Qwen 3.8 27B · tensor parallel · M3 Ultra 50% / M5 Max 50%",
                            "  Macs:    this Mac (Mac Studio) leads · \(otherMac) follows",
                            "  Serves:  through Darkbloom"] + resultFooter

private func lines(_ bytes: [UInt8]?) -> [String] { text(bytes).split(separator: "\n", omittingEmptySubsequences: false).map(String.init) }

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
            "Nothing was stopped on this Mac. To stop only this Mac: `darkbloom cluster stop --local-only` (the other Mac then "
                + "serves alone, or waits for this one).", ""])
        #expect(pairActionCalls(text(result?.standardErrorContent)) == ["stop"])
    }

    @Test("`darkbloom stop --solo` never touches the pair")
    func stopSolo() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent, \.standardErrorContent]) {
            try await exitWithPair(servingPair(), actions: pairActions()) { _ in try await runCLICommand(Stop.self, ["stop", "--solo"]) }
        }
        #expect(lines(result?.standardOutputContent) == [
            "`darkbloom stop --solo` stops single-Mac serving, and none runs on this Mac: nothing was stopped.",
            "The pair was not stopped; `darkbloom stop` stops both Macs.", ""])
        let calls = pairActionCalls(text(result?.standardErrorContent))
        #expect(calls.isEmpty, "\(calls)")
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
        #expect(lines(result?.standardOutputContent) == [
            "This Mac is in a two-Mac cluster with \(otherMac): starting the pair.",
            "screen: darkbloom cluster (config default)", ""])
        let calls = pairActionCalls(text(result?.standardErrorContent))
        #expect(calls.isEmpty, "\(calls)")
    }

    @Test("`darkbloom start` without a terminal starts the saved model on both Macs and ends with a result block; exit 0")
    func startWithoutATerminal() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent, \.standardErrorContent]) {
            try await exitWithPair(servingPair(), actions: pairActions()) { _ in try await runCLICommand(Start.self, ["start"]) }
        }
        #expect(lines(result?.standardOutputContent) == ["This Mac is in a two-Mac cluster with \(otherMac): starting the pair."]
            + servingBlock + [""])
        #expect(pairActionCalls(text(result?.standardErrorContent)) == ["ensureService", "serve"])
    }

    @Test("`darkbloom start` without a terminal and no model ever chosen says how to choose one; exit 1")
    func startWithoutAModel() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardOutputContent, \.standardErrorContent]) {
            try await exitWithPair(pair(started: false, model: false), actions: pairActions(serving: false)) { _ in
                try await runCLICommand(Start.self, ["start"])
            }
        }
        #expect(lines(result?.standardOutputContent) == [
            "This Mac is in a two-Mac cluster with \(otherMac): starting the pair.",
            "No model was chosen for the pair yet: run `darkbloom start` in a terminal to choose one.", ""])
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
        #expect(pairActionCalls(text(result?.standardErrorContent)) == ["stop", "ensureService", "serve"])
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
}
