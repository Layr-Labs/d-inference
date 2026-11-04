import ArgumentParser
import Foundation
import Testing

@testable import ProviderCore
@testable import darkbloom

// The everyday commands on a Mac in a two-Mac cluster (UX audit 2026-11-04, P4/P5/P11/P12). The pair is a fixture
// (`ClusterPairSummary.readerForTesting`); no pairing, cluster service, launchd or ~/.darkbloom is read. Command runs
// happen in a child process (an exit test) with launchctl recorded and never run.

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
    let sandbox = try CLICommandSandbox.enter()
    let home = sandbox.root.appendingPathComponent("home", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    var status: Int32 = 0
    do {
        try await ClusterPairSummary.$readerForTesting.withValue({ _ in summary }) {
            try await LaunchctlControl.$homeDirectoryForTesting.withValue(home) {
                try await LaunchctlControl.$runnerForTesting.withValue(recordingLaunchctl) { try await body() }
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
    @Test("stop without single-Mac serving says the cluster serves and how to stop it; nothing is drained")
    func stopRefusesWithoutSingleMacServing() {
        #expect(Stop.pairedStop(pair(), singleMacLoaded: false, uninstall: false) == .refuse(lines: [
            "This Mac serves in a two-Mac cluster with \(otherMac): it leads; Qwen 3.8 27B through Darkbloom.",
            "`darkbloom stop` stops single-Mac serving, and none runs on this Mac: nothing was stopped.",
            "To stop the cluster: `darkbloom cluster stop` (both Macs stop), or Stop in `darkbloom cluster` on this Mac.",
        ], exitCode: 1))
        // The Mac that follows is pointed at the leading Mac; a stopped cluster is said, and nothing failed.
        guard case .refuse(let member, 1) = Stop.pairedStop(pair(role: .member), singleMacLoaded: false, uninstall: false) else {
            Issue.record("the member's stop is refused"); return
        }
        #expect(member.first == "This Mac serves in a two-Mac cluster with \(otherMac): it follows; Qwen 3.8 27B through Darkbloom.")
        #expect(member.last == "To stop the cluster: `darkbloom cluster stop` (both Macs stop), or Stop in `darkbloom cluster` on \(otherMac).")
        #expect(Stop.pairedStop(pair(started: false), singleMacLoaded: false, uninstall: false) == .refuse(lines: [
            "This Mac is in a two-Mac cluster with \(otherMac): it leads; stopped (last model Qwen 3.8 27B).",
            "`darkbloom stop` stops single-Mac serving, and none runs on this Mac: nothing was stopped.",
            "The cluster is stopped; `darkbloom cluster` on this Mac starts it again.",
        ], exitCode: 0))
        // Single-Mac serving, or --uninstall, is stopped as on any Mac.
        #expect(Stop.pairedStop(pair(), singleMacLoaded: true, uninstall: false) == .stopSingleMac)
        #expect(Stop.pairedStop(pair(), singleMacLoaded: false, uninstall: true) == .stopSingleMac)
    }

    @Test("`darkbloom stop` on a serving pair's leader: the pair's words, exit 1, launchd untouched (the end user's session 2)")
    func stopCommandOnAServingPair() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardOutputContent, \.standardErrorContent]) {
            try await exitWithPair(pair()) { try await runCLICommand(Stop.self, ["stop"]) }
        }
        let stdout = text(result?.standardOutputContent), stderr = text(result?.standardErrorContent)
        #expect(result?.exitStatus == .exitCode(1))
        #expect(stdout == """
            This Mac serves in a two-Mac cluster with \(otherMac): it leads; Qwen 3.8 27B through Darkbloom.
            `darkbloom stop` stops single-Mac serving, and none runs on this Mac: nothing was stopped.
            To stop the cluster: `darkbloom cluster stop` (both Macs stop), or Stop in `darkbloom cluster` on this Mac.

            """)
        #expect(!stdout.contains("not running"))
        #expect(changingLaunchctlCalls(stderr).isEmpty, "\(changingLaunchctlCalls(stderr))")
    }

    @Test("the provider state the cluster's part wrote is never drained as single-Mac serving")
    func clusterPartIsNotDrained() {
        let part = DaemonState(pid: 4242, version: "test", writtenAt: 1, startedAt: 0)
        let solo = DaemonState(pid: 777, version: "test", writtenAt: 1, startedAt: 0)
        #expect(ServiceDrain.soloProviderState(part, clusterPart: 4242) == nil)
        #expect(ServiceDrain.soloProviderState(solo, clusterPart: 4242) == solo)
        #expect(ServiceDrain.soloProviderState(part, clusterPart: nil) == part)
    }

    @Test("start beside a running cluster service is refused without --solo; said in one line otherwise")
    func startGuard() throws {
        let refusal = try #require(Start.pairGuard(pair(), solo: false))
        #expect(refusal.refuse)
        #expect(refusal.lines == [
            "This Mac serves in a two-Mac cluster with \(otherMac): it leads; Qwen 3.8 27B through Darkbloom.",
            "Single-Mac serving next to it would compete for this Mac's memory. To serve on this Mac alone, stop the "
                + "cluster first (`darkbloom cluster stop`), or pass --solo.",
        ])
        let solo = try #require(Start.pairGuard(pair(), solo: true))
        #expect(!solo.refuse && solo.lines == [
            "Starting single-Mac serving beside the two-Mac cluster with \(otherMac) (--solo): both use this Mac's memory."])
        let serviceOff = try #require(Start.pairGuard(pair(started: false, serviceRunning: false), solo: false))
        #expect(!serviceOff.refuse && serviceOff.lines == ["This Mac is in a two-Mac cluster with \(otherMac), which is "
            + "stopped. Stop single-Mac serving (`darkbloom stop`) before you start the cluster again."])
        #expect(Start.pairGuard(.notPaired, solo: false) == nil)
        // The cluster's own starts and launchd's child are never asked.
        #expect(try Start.parse([]).startsSingleMacServing)
        #expect(try Start.parse(["--local"]).startsSingleMacServing)
        #expect(try Start.parse(["--solo", "--model", "m"]).solo)
        #expect(try !Start.parse(["--foreground"]).startsSingleMacServing)
        #expect(try !Start.parse(["--cluster-member"]).startsSingleMacServing)
        #expect(try !Start.parse(["--local", "--distributed"]).startsSingleMacServing)
    }

    @Test("restart: nothing to restart without single-Mac serving; beside a running cluster service only with --solo")
    func restartGuard() throws {
        #expect(Restart.pairRefusal(pair(), singleMacInstalled: false, solo: false) == [
            "This Mac serves in a two-Mac cluster with \(otherMac): it leads; Qwen 3.8 27B through Darkbloom.",
            "`darkbloom restart` restarts single-Mac serving, and this Mac has none: nothing was restarted.",
            "To restart the cluster: Stop, then start the model again in `darkbloom cluster` on this Mac.",
        ])
        #expect(Restart.pairRefusal(pair(), singleMacInstalled: true, solo: false) == pair().startRefusal)
        #expect(Restart.pairRefusal(pair(), singleMacInstalled: true, solo: true) == nil)
        #expect(Restart.pairRefusal(.notPaired, singleMacInstalled: false, solo: false) == nil)
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
            + "cluster service is probably off (it was stopped with `darkbloom cluster stop`), or that Mac is asleep, off, or "
            + "waiting for someone to log in. On that Mac, run `darkbloom cluster`.")
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
                     "darkbloom cluster stop Stop the cluster on both Macs (`darkbloom cluster` starts it again).",
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

    @Test("`cluster stop` on the Mac that follows a started cluster asks the leading Mac to stop both Macs")
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
