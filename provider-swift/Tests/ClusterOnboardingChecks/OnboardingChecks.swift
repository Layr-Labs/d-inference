import Foundation
import Darwin

/// Model-free checks of the leader-first onboarding (`darkbloom cluster`):
/// the discovery and pairing state machine, and the whole flow on a real
/// pseudo-terminal for both sides with scripted operations, word for word
/// and key for key. Built with plain swiftc by run.sh; no provider, no
/// network, no model.
@main enum OnboardingChecks {
    nonisolated(unsafe) static var passed = 0
    nonisolated(unsafe) static var failures = [String]()

    static func expect(_ condition: Bool, _ message: @autoclosure () -> String, line: Int = #line) {
        if condition { passed += 1 } else { failures.append("line \(line): \(message())") }
    }

    static func main() {
        signal(SIGALRM) { _ in Darwin._exit(124) }; alarm(120); defer { alarm(0) }
        pairingStateMachine()
        leaderFromScratch()
        memberFromScratch()
        bothWaitingAtOnce()
        cancelWhileWaiting()
        declinedCode()
        linkNotReady()
        memberAgain()
        memberChangesModel()
        memberVerifiesTeardown()
        leaderAgainServing()
        leaderPairedNotServing()
        noModelOffered()
        servingLineNamesTheMac()
        leaderKeepsMembersInStep()
        print("onboarding checks: \(passed) passed, \(failures.count) failed")
        for failure in failures { print("FAIL " + failure) }
        exit(failures.isEmpty ? 0 : 1)
    }

    // MARK: - State machine

    static func pairingStateMachine() {
        var machine = ClusterOnboardingPairing()
        expect(machine.role == nil, "no role before the pairing moves")
        expect(machine.handle(.searching) == ["Looking for a Mac waiting on the cable…"], "searching line")
        let wait = machine.handle(.waitingAsLeader)
        expect(machine.role == .leader && machine.phase == .waiting, "listening makes this Mac the leader-to-be")
        expect(wait.contains("    On your other Mac, run `darkbloom cluster`."), "the other-Mac instruction, word for word: \(wait)")
        expect(wait.contains { $0.contains("press q to cancel") }, "the cancel key is named")
        expect(machine.handle(.waitingAsLeader).isEmpty, "the wait is announced once (idempotent)")
        let code = machine.handle(.code("123456", peer: ["Apple M5 Ultra, 256 GB", "macOS 27.0.1"]))
        expect(machine.asking == "123 456", "the code waits for an answer")
        expect(code.contains("Does the other Mac show 123 456? Press y if it does, n if it does not."), "the question: \(code)")
        expect(code.contains("The other Mac: Apple M5 Ultra, 256 GB"), "the other Mac is named by its hardware, never a host name")
        expect(machine.answered(true) == ["Confirmed here; waiting for the other Mac…"], "answer y")
        expect(machine.answered(true).isEmpty, "a second y answers nothing")
        expect(machine.finished(.paired(role: .leader, peerName: "Apple M5 Ultra, 256 GB")).last
            == "Paired with Apple M5 Ultra, 256 GB. This Mac leads the cluster.", "leader's paired line")

        var joiner = ClusterOnboardingPairing()
        _ = joiner.handle(.searching)
        expect(joiner.handle(.joining) == ["Found a Mac waiting on the cable: this Mac joins its cluster."], "a waiting leader is found")
        expect(joiner.role == .member, "dialing a waiting Mac makes this one a member")
        expect(joiner.finished(.paired(role: .member, peerName: "Apple M3 Ultra, 256 GB")).last
            == "Paired with Apple M3 Ultra, 256 GB. Continue on Apple M3 Ultra, 256 GB.", "member's paired line, word for word")

        var tie = ClusterOnboardingPairing()
        _ = tie.handle(.waitingAsLeader)
        expect(tie.handle(.joining) == ["The other Mac started waiting at the same moment and leads; this Mac joins it."], "a tie is explained")
        expect(tie.role == .member, "the Mac that yields joins")

        var failed = ClusterOnboardingPairing()
        expect(failed.finished(.failed(["The code was declined."])) == ["Not paired.", "The code was declined.",
            "Run `darkbloom cluster` again to try again."], "a failed pairing says how to retry")
        expect(ClusterOnboardingPairing.spaced("654321") == "654 321", "code spacing")
    }

    // MARK: - Pseudo-terminal flows

    static let leaderHardware = [ClusterOnboardingMachine(name: "Apple M5 Ultra, 256 GB", memoryGB: 256, gpuCores: 80, leads: true, models: 2),
                                 ClusterOnboardingMachine(name: "Apple M3 Ultra, 256 GB", memoryGB: 256, gpuCores: 80, leads: false, models: 2)]
    static let choices = [
        ClusterOnboardingModelChoice(title: "Qwen3.5-9B", lines: ["rank 0: Apple M3 Ultra, 256 GB, layers 0-15", "rank 1 (decodes): Apple M5 Ultra, 256 GB (this Mac), layers 16-31"], blocker: nil),
        ClusterOnboardingModelChoice(title: "Qwen3.8-27B-4bit-mtp", lines: ["rank 0: Apple M3 Ultra, 256 GB, layers 0-31"], blocker: nil),
        ClusterOnboardingModelChoice(title: "gpt-oss-20b", lines: [], blocker: "not granted for this pair of chips")]

    final class Recorder: @unchecked Sendable {
        let lock = NSLock()
        var calls = [String]()
        var answers = [Bool]()
        var adopted: Int?
        func note(_ call: String) { lock.lock(); calls.append(call); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return calls }
    }

    static func operations(_ recorder: Recorder, resume: ClusterOnboardingResume = .init(), linkReady: Bool = true,
                           pairEvents: [ClusterOnboardingPairEvent], pairResult: ClusterOnboardingPairResult,
                           choices: [ClusterOnboardingModelChoice] = choices) -> ClusterOnboardingOperations {
        let answered = DispatchSemaphore(value: 0)
        return ClusterOnboardingOperations(
            resume: { resume },
            checkLink: { say in
                recorder.note("checkLink")
                say("RDMA setup detected: RDMA over Thunderbolt is enabled on this Mac.")
                say("Connection detected: rdma_en5 (en5) is active.")
                if linkReady {
                    say("Address ready: rdma_en5 (en5) has its own IPv4 address and publishes the GID RDMA needs.")
                    say("This Mac's link is ready.")
                    say("Run `darkbloom cluster` on the other Mac too.")
                } else {
                    say("Thunderbolt port en5 has no IPv4 address of its own, which RDMA needs.")
                }
                return .init(ready: linkReady, exitCode: linkReady ? 0 : 1)
            },
            pair: { events in
                recorder.note("pair")
                var asked = false
                for event in pairEvents {
                    events(event)
                    if case .code = event { asked = true; _ = answered.wait(timeout: .now() + 10) }
                    usleep(20_000)
                }
                _ = asked
                if case .failed = pairResult { return pairResult }
                recorder.lock.lock(); let last = recorder.answers.last; recorder.lock.unlock()
                if asked, last == false { return .failed(["The code was declined on this Mac."]) }
                return pairResult
            },
            answerCode: { accept in
                recorder.lock.lock(); recorder.answers.append(accept); recorder.lock.unlock()
                recorder.note("answer \(accept ? "y" : "n")"); answered.signal()
            },
            ensureService: { recorder.note("ensureService"); return .success("This Mac's cluster service is running.") },
            reachMembers: { say in recorder.note("reachMembers"); say("Apple M3 Ultra, 256 GB answered in 0.4 s."); return .success(leaderHardware) },
            planModels: { recorder.note("planModels"); return .success(choices) },
            adopt: { index in recorder.note("adopt \(index)"); return .success(["Saved this Mac's setup.", "Synced Apple M3 Ultra, 256 GB's setup over the cable; it applied it."]) },
            serve: { recorder.note("serve"); return .success(["Started Apple M3 Ultra, 256 GB's part over the cable."]) },
            waitReady: { progress in
                recorder.note("waitReady"); progress("1 of 2 parts ready"); usleep(50_000); progress("2 of 2 parts ready")
                return .success(.init(servedBy: "Apple M3 Ultra, 256 GB", port: 8000))
            },
            testRequest: { recorder.note("testRequest"); return .success(["\"Red, Blue, Green\" (6 tokens, first token 0.61 s)"]) },
            status: { recorder.note("status"); return ["Serving Qwen3.5-9B from Apple M3 Ultra, 256 GB at 127.0.0.1:8000 (2 of 2 parts ready)."] },
            stop: { recorder.note("stop"); return .success(["Both Macs stopped serving."]) },
            verifyTeardown: { recorder.note("verifyTeardown")
                return .success(["Apple M3 Ultra, 256 GB: teardown verified, nothing left", "Apple M5 Ultra, 256 GB: teardown verified, nothing left"]) })
    }

    /// One driver run on a pseudo-terminal: the keys are typed only once the text before them is on screen.
    final class TerminalRun: @unchecked Sendable {
        let master: Int32
        let slave: Int32
        private let lock = NSLock()
        private var captured = [UInt8]()
        private var exitCode: Int32?
        private(set) var keys = 0
        let done = DispatchSemaphore(value: 0)

        init(_ operations: ClusterOnboardingOperations) {
            var primary: Int32 = -1, secondary: Int32 = -1
            var window = winsize(ws_row: 50, ws_col: 132, ws_xpixel: 0, ws_ypixel: 0)
            precondition(openpty(&primary, &secondary, nil, nil, &window) == 0)
            master = primary; slave = secondary
            _ = fcntl(primary, F_SETFL, fcntl(primary, F_GETFL) | O_NONBLOCK)
            let reader = primary
            Thread.detachNewThread { [self] in
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    var descriptor = pollfd(fd: reader, events: Int16(POLLIN), revents: 0)
                    guard Darwin.poll(&descriptor, 1, 20) >= 0 else { return }
                    let count = Darwin.read(reader, &buffer, buffer.count)
                    if count > 0 { lock.lock(); captured.append(contentsOf: buffer.prefix(count)); lock.unlock() }
                    if lock.withLock({ exitCode != nil }) && count <= 0 { return }
                }
            }
            let slaveFD = secondary
            Thread.detachNewThread { [self] in
                let console = ClusterOnboardingTerminal(input: slaveFD, output: slaveFD)
                let code = ClusterOnboardingDriver.run(operations, console: console)
                console.restore()
                usleep(100_000)
                lock.lock(); exitCode = code; lock.unlock()
                done.signal()
            }
        }

        var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: captured, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n") }
        var code: Int32? { lock.lock(); defer { lock.unlock() }; return exitCode }

        func waitFor(_ needle: String, seconds: Double = 10) -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline { if text.contains(needle) { return true }; usleep(10_000) }
            return text.contains(needle)
        }

        func type(_ keys: String) {
            self.keys += keys.count
            let bytes = Array(keys.utf8)
            _ = bytes.withUnsafeBytes { Darwin.write(master, $0.baseAddress, $0.count) }
        }

        func finish(seconds: Double = 10) -> Int32? {
            _ = done.wait(timeout: .now() + seconds)
            return code
        }
    }

    static func leaderFromScratch() {
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, pairEvents: [.searching, .waitingAsLeader, .connected,
            .code("123456", peer: ["Apple M3 Ultra, 256 GB"]), .peerDecided(true)],
            pairResult: .paired(role: .leader, peerName: "Apple M3 Ultra, 256 GB")))
        expect(run.waitFor("    On your other Mac, run `darkbloom cluster`.\n"), "leader: the instruction for the other Mac, on its own line")
        expect(run.waitFor("Does the other Mac show 123 456? Press y if it does, n if it does not."), "leader: the code question")
        run.type("y")
        expect(run.waitFor("Choose a model [1-2, enter = 1]: "), "leader: the model choice (two offered, one not)")
        expect(run.text.contains("  Apple M5 Ultra, 256 GB · 256 GB · 80-core GPU · 2 models · leads (this Mac)"), "leader: its own hardware")
        expect(run.text.contains("  Apple M3 Ultra, 256 GB · 256 GB · 80-core GPU · 2 models · member"), "leader: the member's hardware")
        expect(run.text.contains("       rank 1 (decodes): Apple M5 Ultra, 256 GB (this Mac), layers 16-31"), "leader: the planner's placement")
        expect(run.text.contains("     gpt-oss-20b: not granted for this pair of chips"), "leader: a blocked model with its reason")
        run.type("\r")
        expect(run.waitFor("Serve Qwen3.5-9B on both Macs? Press y to start, n to stop here."), "leader: the start question")
        run.type("y")
        let code = run.finish()
        expect(code == 0, "leader: exit 0, got \(String(describing: code))")
        let text = run.text
        expect(text.contains("Serving Qwen3.5-9B from Apple M3 Ultra, 256 GB, at 127.0.0.1:8000 on that Mac."),
            "leader: serving line names the Mac whose loopback serves")
        expect(!text.contains("256 GB at 127.0.0.1"), "leader: never shows the other Mac's loopback as if it were this Mac's")
        expect(text.contains("Nothing else is needed on the other Mac. After a Mac restarts, run `darkbloom cluster` on it once (it asks nothing)."), "leader: the member needs nothing, and the restart gap is said")
        expect(!text.contains("Run `darkbloom cluster` on the other Mac too."), "leader: the link flow's own ending is not repeated")
        expect(run.keys == 3, "leader: three keys (y, enter, y), got \(run.keys)")
        expect(recorder.all == ["checkLink", "pair", "answer y", "ensureService", "reachMembers", "planModels", "adopt 0", "serve",
            "waitReady", "testRequest"], "leader: operations in order: \(recorder.all)")
        expect(!text.lowercased().contains("ssh") && !text.contains("10.219"), "leader: no SSH and no address on screen")
        transcript("leader-from-scratch", text, keys: run.keys)
    }

    /// The serving API listens on loopback on the Mac that runs rank 0: the line says which Mac that is.
    static func servingLineNamesTheMac() {
        expect(ClusterOnboardingReady(servedBy: "this Mac", port: 8000).servingLine(model: "Qwen3.5-9B")
            == "Serving Qwen3.5-9B from this Mac at 127.0.0.1:8000", "serving here: this Mac's loopback")
        expect(ClusterOnboardingReady(servedBy: "Apple M3 Ultra, 256 GB", port: 8100).servingLine(model: "Qwen3.5-9B")
            == "Serving Qwen3.5-9B from Apple M3 Ultra, 256 GB, at 127.0.0.1:8100 on that Mac", "serving there: that Mac's loopback")
    }

    /// The leader's cluster service keeps each member on the leader's serving state (serve or stop, and the model),
    /// so a member that missed a start or a stop (asleep, restarting, cable out) follows once it answers again.
    static func leaderKeepsMembersInStep() {
        typealias Sync = ClusterOnboardingSync
        expect(Sync.action(leaderServing: true, leaderModel: "9B", memberServing: nil, memberModel: nil) == .none,
            "sync: a member that does not answer is asked again later, nothing sent now")
        expect(Sync.action(leaderServing: true, leaderModel: "9B", memberServing: false, memberModel: nil) == .serve("9B"),
            "sync: a member that missed the start is started")
        expect(Sync.action(leaderServing: true, leaderModel: "27B", memberServing: true, memberModel: "9B") == .serve("27B"),
            "sync: a member on another model is told the leader's")
        expect(Sync.action(leaderServing: true, leaderModel: "9B", memberServing: true, memberModel: "9B") == .none,
            "sync: a member in step is left alone")
        expect(Sync.action(leaderServing: false, leaderModel: "9B", memberServing: true, memberModel: "9B") == .stop,
            "sync: a member that missed the stop is stopped")
        expect(Sync.action(leaderServing: false, leaderModel: nil, memberServing: false, memberModel: nil) == .none,
            "sync: nothing serving, nothing sent (a leader that has not chosen a model yet)")
        expect(Sync.dueEverySeconds > 0 && Sync.dueEverySeconds <= 30, "sync: checked often enough that a member follows within half a minute")
    }

    static func memberFromScratch() {
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, pairEvents: [.searching, .joining, .connected,
            .code("123456", peer: ["Apple M5 Ultra, 256 GB"]), .peerDecided(true)],
            pairResult: .paired(role: .member, peerName: "Apple M5 Ultra, 256 GB")))
        expect(run.waitFor("Found a Mac waiting on the cable: this Mac joins its cluster."), "member: finds the waiting leader by itself")
        expect(run.waitFor("Press y if it does"), "member: the code question")
        run.type("y")
        let code = run.finish()
        expect(code == 0, "member: exit 0")
        let text = run.text
        expect(text.contains("Paired with Apple M5 Ultra, 256 GB. Continue on Apple M5 Ultra, 256 GB.\n"), "member: where to continue, word for word")
        expect(text.contains("This Mac's cluster service is running."), "member: its service runs with no manual start")
        expect(!text.contains("On your other Mac"), "member: never told to go to another Mac to run anything")
        expect(run.keys == 1, "member: one key (y)")
        expect(recorder.all == ["checkLink", "pair", "answer y", "ensureService"], "member: operations \(recorder.all)")
        transcript("member-from-scratch", text, keys: run.keys)
    }

    static func bothWaitingAtOnce() {
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, pairEvents: [.searching, .waitingAsLeader, .joining, .code("111222", peer: ["Apple M3 Ultra, 256 GB"])],
            pairResult: .paired(role: .member, peerName: "Apple M3 Ultra, 256 GB")))
        expect(run.waitFor("The other Mac started waiting at the same moment and leads; this Mac joins it."), "tie: explained")
        expect(run.waitFor("111 222"), "tie: code shown"); run.type("y")
        expect(run.finish() == 0, "tie: joins and ends")
        expect(run.text.contains("Continue on Apple M3 Ultra, 256 GB."), "tie: continue on the leader")
    }

    static func cancelWhileWaiting() {
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, pairEvents: [.searching, .waitingAsLeader, .note("still waiting"), .note("still waiting"),
            .note("still waiting"), .note("still waiting"), .note("still waiting"), .note("still waiting"), .note("still waiting")] + Array(repeating: .note(""), count: 200),
            pairResult: .failed(["expired"])))
        expect(run.waitFor("press q to cancel"), "cancel: the wait is on screen")
        run.type("q")
        expect(run.finish() == 130, "cancel: q ends with 130")
        expect(run.text.contains("Cancelled: nothing was paired. Run `darkbloom cluster` again to start over."), "cancel: says nothing was paired")
    }

    static func declinedCode() {
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, pairEvents: [.searching, .joining, .code("123456", peer: ["Apple M5 Ultra, 256 GB"])],
            pairResult: .paired(role: .member, peerName: "x")))
        expect(run.waitFor("Press y if it does"), "declined: code shown"); run.type("n")
        expect(run.finish() == 1, "declined: exit 1")
        expect(run.text.contains("Declined here: nothing is paired."), "declined: said")
        expect(run.text.contains("Run `darkbloom cluster` again to try again."), "declined: how to retry")
        expect(!recorder.all.contains("ensureService"), "declined: no service started")
    }

    static func linkNotReady() {
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, linkReady: false, pairEvents: [], pairResult: .failed([])))
        expect(run.finish() == 1, "link not ready: stops")
        expect(run.text.contains("The cluster link is not ready, so pairing waits."), "link not ready: said")
        expect(recorder.all == ["checkLink"], "link not ready: nothing else ran")
    }

    /// A member is not sent elsewhere: its commands run on the derived control leader (forwarded by the live operations).
    static func memberResume(serving: Bool = true) -> ClusterOnboardingResume {
        var resume = ClusterOnboardingResume(role: .member, peerName: "Apple M3 Ultra, 256 GB", serving: serving, modelName: "Qwen3.5-9B")
        resume.leaderName = "Apple M3 Ultra, 256 GB"
        resume.leaderReason = "rank 0 of the adopted plan: requests enter there and the coordinator registers it as the head"
        resume.term = 2
        return resume
    }

    static func memberAgain() {
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, resume: memberResume(), pairEvents: [], pairResult: .failed([])))
        expect(run.waitFor("Press enter to leave it as it is, t to send a test request, m to choose another model, s to stop serving, v to verify teardown."),
               "member again: the same menu as the leader")
        let text = run.text
        expect(text.contains("This Mac is a member of the cluster led by Apple M3 Ultra, 256 GB."), "member again: who leads")
        expect(text.contains("The control leader is derived, not chosen: rank 0 of the adopted plan"), "member again: why it leads")
        expect(text.contains("Commands typed here run on Apple M3 Ultra, 256 GB over the cable."), "member again: forwarding said")
        expect(text.contains("  Serving Qwen3.5-9B from Apple M3 Ultra, 256 GB at 127.0.0.1:8000 (2 of 2 parts ready)."), "member again: the leader's status")
        run.type("s")
        expect(run.finish() == 0, "member again: stop from the member")
        expect(run.text.contains("Both Macs stopped serving."), "member again: the leader's answer shown")
        expect(recorder.all == ["ensureService", "status", "stop"], "member again: status then stop, no pairing: \(recorder.all)")
        expect(run.keys == 1, "member again: one key")
        transcript("member-again", run.text, keys: run.keys)
    }

    static func memberChangesModel() {
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, resume: memberResume(), pairEvents: [], pairResult: .failed([])))
        expect(run.waitFor("v to verify teardown."), "member model change: menu")
        run.type("m")
        expect(run.waitFor("Choose a model [1-2, enter = 1]: "), "member model change: the leader's choices")
        run.type("2\r")
        expect(run.waitFor("Serve Qwen3.8-27B-4bit-mtp on both Macs?"), "member model change: second model")
        run.type("y")
        expect(run.finish() == 0, "member model change: served")
        expect(recorder.all == ["ensureService", "status", "reachMembers", "planModels", "adopt 1", "serve", "waitReady", "testRequest"],
               "member model change: every step through the operations (forwarded live): \(recorder.all)")
        expect(run.text.contains("Done. Run `darkbloom cluster` on any of these Macs"), "member model change: any Mac")
        transcript("member-changes-model", run.text, keys: run.keys)
    }

    static func memberVerifiesTeardown() {
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, resume: memberResume(serving: false), pairEvents: [], pairResult: .failed([])))
        expect(run.waitFor("Not serving. Press m to choose a model and serve, v to verify teardown, enter to leave it as it is."), "teardown: menu when stopped")
        run.type("v")
        expect(run.finish() == 0, "teardown: exit 0")
        expect(run.text.contains("  Apple M5 Ultra, 256 GB: teardown verified, nothing left"), "teardown: each Mac's summary")
        expect(recorder.all == ["ensureService", "status", "verifyTeardown"], "teardown: \(recorder.all)")
    }

    static func leaderAgainServing() {
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, resume: .init(role: .leader, peerName: "Apple M3 Ultra, 256 GB", serving: true, modelName: "Qwen3.5-9B"),
            pairEvents: [], pairResult: .failed([])))
        expect(run.waitFor("Press enter to leave it as it is, t to send a test request, m to choose another model, s to stop serving, v to verify teardown."), "leader again: the menu")
        run.type("t")
        expect(run.finish() == 0, "leader again: test request")
        expect(recorder.all == ["ensureService", "status", "testRequest"], "leader again: no pairing, no plan: \(recorder.all)")
        transcript("leader-again", run.text, keys: run.keys)
    }

    static func leaderPairedNotServing() {
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, resume: .init(role: .leader, peerName: "Apple M3 Ultra, 256 GB", serving: false),
            pairEvents: [], pairResult: .failed([])))
        expect(run.waitFor("Choose a model"), "leader resumed before a model was chosen: goes to the choice")
        run.type("2\r")
        expect(run.waitFor("Serve Qwen3.8-27B-4bit-mtp on both Macs?"), "leader resumed: the second model chosen by number")
        run.type("n")
        expect(run.finish() == 0, "leader resumed: n stops with nothing changed")
        expect(!recorder.all.contains("adopt 1"), "leader resumed: nothing adopted after n")
    }

    static func noModelOffered() {
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, resume: .init(role: .leader, peerName: "Apple M3 Ultra, 256 GB"), pairEvents: [], pairResult: .failed([]),
            choices: [ClusterOnboardingModelChoice(title: "big", lines: [], blocker: "too large for this pair")]))
        expect(run.finish() == 1, "no model: exit 1")
        expect(run.text.contains("No model can be served by these Macs now; the reasons are above."), "no model: said")
    }

    /// The exact text and key count of a flow, for the evidence.
    static func transcript(_ name: String, _ text: String, keys: Int) {
        guard let directory = ProcessInfo.processInfo.environment["ONBOARDING_TRANSCRIPTS"] else { return }
        try? (text + "\n[keys typed: \(keys)]\n").write(toFile: directory + "/" + name + ".txt", atomically: true, encoding: .utf8)
    }
}
