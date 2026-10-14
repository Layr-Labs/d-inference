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
        leaderCopiesAMissingModelOverTheCable()
        leaderChoosesTheCatalogInstead()
        leaderDownloadsAModelNoMacHas()
        copyDeclined()
        copyBlockedByDisk()
        copyInterrupted()
        // Finish 2026-10-13 night: failing first on c35897c36.
        shortCopyStartsWithAStatedLine()
        shortCopyStillStopsWithN()
        // One-command fixes 2026-10-14: failing first on 265648289.
        deploymentWords()
        cableLinesStreamBeforeTheApproval()
        twoCablesAreAskedOnScreen()
        fittingChoicesComeFirst()
        fitRecheckedBeforeTheStart()
        timeoutOffersADiagnosticsFile()
        restartLineAtTheEnd()
        restartWords()
        updateNoticed()
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
                           choices: [ClusterOnboardingModelChoice] = choices,
                           replanned: [ClusterOnboardingModelChoice]? = nil,
                           provisionResult: Result<[String], ClusterOnboardingFailure> = .success(["Apple M3 Ultra, 256 GB has Qwen3.5-9B now: 12 files verified against the catalog manifest."]),
                           linkPorts: [String] = [],
                           approvalGate: DispatchSemaphore? = nil,
                           recheck: String? = nil,
                           afterRestart: String? = nil,
                           readyResult: Result<ClusterOnboardingReady, ClusterOnboardingFailure> = .success(.init(servedBy: "Apple M3 Ultra, 256 GB", port: 8000,
                               deployment: "Serving Qwen3.5-9B across both Macs: pipeline, M3 Ultra 16 layers / M5 Ultra 16 layers"))) -> ClusterOnboardingOperations {
        let answered = DispatchSemaphore(value: 0)
        let chosenPort = Recorder()
        return ClusterOnboardingOperations(
            resume: { resume },
            checkLink: { say in
                recorder.note("checkLink")
                if let approvalGate {
                    // The approval line must be on screen while the macOS prompt is up (checkLink still running).
                    say("Darkbloom needs network access for the cluster cable: approve the macOS prompt (once per Mac).")
                    _ = approvalGate.wait(timeout: .now() + 5)
                }
                if linkPorts.count > 1, chosenPort.all.isEmpty {
                    say("Cable found on \(linkPorts.count) ports.")
                    return .init(ready: false, exitCode: 1, ports: linkPorts)
                }
                say("Cable found.")
                if linkReady {
                    say("Cable ready.")
                    say("Run `darkbloom cluster` on the other Mac too.")
                } else {
                    say("The cable is not ready: RDMA is off on this Mac.")
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
            planModels: {
                recorder.note("planModels")
                let again = recorder.all.filter { $0 == "planModels" }.count > 1
                return .success(again ? (replanned ?? choices) : choices)
            },
            adopt: { index in recorder.note("adopt \(index)"); return .success(["Saved this Mac's setup.", "Synced Apple M3 Ultra, 256 GB's setup over the cable; it applied it."]) },
            serve: { recorder.note("serve"); return .success(["Started Apple M3 Ultra, 256 GB's part over the cable."]) },
            waitReady: { progress in
                recorder.note("waitReady"); progress("1 of 2 parts ready"); usleep(50_000); progress("2 of 2 parts ready")
                return readyResult
            },
            testRequest: { recorder.note("testRequest"); return .success(["\"Red, Blue, Green\" (6 tokens, first token 0.61 s)"]) },
            status: { recorder.note("status"); return ["Serving Qwen3.5-9B across both Macs: pipeline, M3 Ultra 16 layers / M5 Ultra 16 layers.",
                                                       "API at http://localhost:8000 on Apple M3 Ultra, 256 GB (2 of 2 parts ready)."] },
            stop: { recorder.note("stop"); return .success(["Both Macs stopped serving."]) },
            provision: { index, download, progress in
                recorder.note("provision \(index) \(download ? "download" : "copy")")
                progress("Copying Qwen3.5-9B to Apple M3 Ultra, 256 GB over the cable: 3.1 of 6.1 GB, 2.40 GB/s, about 1 s left")
                usleep(30_000)
                progress("Copied 6.1 GB in 2.6 s (2.35 GB/s); every file matched its manifest digest.")
                return provisionResult
            },
            verifyTeardown: { recorder.note("verifyTeardown")
                return .success(["Apple M3 Ultra, 256 GB: nothing left running", "Apple M5 Ultra, 256 GB: nothing left running"]) },
            useLinkPort: { port in chosenPort.note(port); recorder.note("useLinkPort \(port)") },
            recheckFit: { index in recorder.note("recheckFit \(index)"); return recheck },
            afterRestart: { afterRestart },
            saveDiagnostics: { recorder.note("saveDiagnostics"); return .success(["Saved a diagnostics file (no keys, addresses or names in it): darkbloom-cluster-diagnostics.json in your home folder."]) })
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
        // The choice is the start: one stated line with a moment to stop, no second question.
        expect(run.waitFor("Starting Qwen3.5-9B on both Macs in 3 s; press n to stop here."), "leader: the timed start")
        let code = run.finish()
        expect(code == 0, "leader: exit 0, got \(String(describing: code))")
        let text = run.text
        expect(!text.contains("Press y to start"), "leader: no second y/n after the model choice")
        expect(text.contains("Serving Qwen3.5-9B across both Macs: pipeline, M3 Ultra 16 layers / M5 Ultra 16 layers.\n"),
            "leader: the deployment in one plain line")
        expect(text.contains("API at http://localhost:8000 on Apple M3 Ultra, 256 GB.\n"), "leader: the API place names the Mac")
        expect(!text.contains("127.0.0.1"), "leader: no bare loopback address")
        expect(text.contains("Nothing else is needed on the other Mac.\n"), "leader: the member needs nothing")
        expect(!text.contains("After a Mac restarts, run `darkbloom cluster`"), "leader: no command needed after a restart")
        expect(!text.contains("Run `darkbloom cluster` on the other Mac too."), "leader: the link flow's own ending is not repeated")
        expect(text.contains(ClusterOnboardingDriver.localNetworkLine), "leader: the Local Network prompt is announced")
        expect(text.contains("Working out the fastest way to split each model across both Macs…"), "leader: the planning line")
        expect(!text.contains("which one decodes"), "leader: no phase-split wording in the planning line")
        expect(run.keys == 2, "leader: two keys (y, enter), got \(run.keys)")
        expect(recorder.all == ["checkLink", "pair", "answer y", "ensureService", "reachMembers", "planModels", "recheckFit 0", "adopt 0", "serve",
            "waitReady", "testRequest"], "leader: operations in order: \(recorder.all)")
        expect(!text.lowercased().contains("ssh") && !text.contains("10.219"), "leader: no SSH and no address on screen")
        transcript("leader-from-scratch", text, keys: run.keys)
    }

    /// The serving API listens on loopback on the Mac that runs rank 0: the line says which Mac that is.
    static func servingLineNamesTheMac() {
        expect(ClusterOnboardingReady(servedBy: "this Mac", port: 8000).apiLine == "API at http://localhost:8000 on this Mac", "serving here")
        expect(ClusterOnboardingReady(servedBy: "Apple M3 Ultra, 256 GB", port: 8100).apiLine
            == "API at http://localhost:8100 on Apple M3 Ultra, 256 GB", "serving there: that Mac named")
        expect(ClusterOnboardingReady(servedBy: "this Mac", port: 8000).lines(model: "Qwen3.5-9B")
            == ["Serving Qwen3.5-9B across both Macs", "API at http://localhost:8000 on this Mac"], "no plan known: still one plain line")
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
        expect(text.contains(ClusterOnboardingDriver.localNetworkLine + "\nNothing else to do on this Mac"),
            "member: the Local Network prompt is announced before 'Nothing else to do'")
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
        expect(run.text.contains("The cable is not ready yet, so pairing waits."), "link not ready: said")
        expect(!run.text.contains("cluster link"), "link not ready: no developer command named")
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
        expect(run.waitFor("Press enter to leave it as it is, t to send a test request, m to choose another model, s to stop serving, v to check both Macs released their memory."),
               "member again: the same menu as the leader")
        let text = run.text
        expect(text.contains("This Mac is a member of the cluster led by Apple M3 Ultra, 256 GB."), "member again: who leads")
        expect(!text.contains("derived") && !text.contains("term ") && !text.contains("rank 0"), "member again: no leadership jargon")
        expect(text.contains("Commands typed here run on Apple M3 Ultra, 256 GB over the cable."), "member again: forwarding said")
        expect(text.contains("  Serving Qwen3.5-9B across both Macs: pipeline, M3 Ultra 16 layers / M5 Ultra 16 layers.\n"), "member again: the deployment line first")
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
        expect(run.waitFor("v to check both Macs released their memory."), "member model change: menu")
        run.type("m")
        expect(run.waitFor("Choose a model [1-2, enter = 1]: "), "member model change: the leader's choices")
        run.type("2\r")
        expect(run.waitFor("Starting Qwen3.8-27B-4bit-mtp on both Macs in 3 s"), "member model change: second model")
        expect(run.finish() == 0, "member model change: served")
        expect(recorder.all == ["ensureService", "status", "reachMembers", "planModels", "recheckFit 1", "adopt 1", "serve", "waitReady", "testRequest"],
               "member model change: every step through the operations (forwarded live): \(recorder.all)")
        expect(run.text.contains("Done. Run `darkbloom cluster` on any of these Macs"), "member model change: any Mac")
        transcript("member-changes-model", run.text, keys: run.keys)
    }

    static func memberVerifiesTeardown() {
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, resume: memberResume(serving: false), pairEvents: [], pairResult: .failed([])))
        expect(run.waitFor("Not serving. Press m to choose a model and serve, v to check both Macs released their memory, enter to leave it as it is."), "teardown: menu when stopped")
        run.type("v")
        expect(run.finish() == 0, "teardown: exit 0")
        expect(run.text.contains("  Apple M5 Ultra, 256 GB: nothing left running"), "teardown: each Mac's summary")
        expect(recorder.all == ["ensureService", "status", "verifyTeardown"], "teardown: \(recorder.all)")
    }

    static func leaderAgainServing() {
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, resume: .init(role: .leader, peerName: "Apple M3 Ultra, 256 GB", serving: true, modelName: "Qwen3.5-9B"),
            pairEvents: [], pairResult: .failed([])))
        expect(run.waitFor("Press enter to leave it as it is, t to send a test request, m to choose another model, s to stop serving, v to check both Macs released their memory."), "leader again: the menu")
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
        expect(run.waitFor("Starting Qwen3.8-27B-4bit-mtp on both Macs in 3 s; press n to stop here."), "leader resumed: the second model chosen by number")
        run.type("n")
        expect(run.finish() == 0, "leader resumed: n stops with nothing changed")
        expect(run.text.contains("Nothing was changed. Run `darkbloom cluster` here again to choose."), "leader resumed: n said")
        expect(!recorder.all.contains("adopt 1"), "leader resumed: nothing adopted after n")
    }

    static func noModelOffered() {
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, resume: .init(role: .leader, peerName: "Apple M3 Ultra, 256 GB"), pairEvents: [], pairResult: .failed([]),
            choices: [ClusterOnboardingModelChoice(title: "big", lines: [], blocker: "too large for this pair")]))
        expect(run.finish() == 1, "no model: exit 1")
        expect(run.text.contains("No model can be served by these Macs now; the reasons are above."), "no model: said")
    }


    // MARK: - Provisioning: no manual model downloads

    static let copyOffer = ClusterOnboardingProvisionOffer(
        lines: ["Apple M3 Ultra, 256 GB: copy from Apple M5 Ultra, 256 GB (this Mac) over the Thunderbolt cable (6.1 GB, about 3 s)"],
        downloadAlternative: true, leaderDownloads: false)
    static let copyChoices = [
        ClusterOnboardingModelChoice(title: "Qwen3.5-9B", lines: ["rank 0: Apple M3 Ultra, 256 GB, layers 0-15"], blocker: nil, provision: copyOffer),
        ClusterOnboardingModelChoice(title: "Qwen3.8-27B-4bit-mtp", lines: ["rank 0: Apple M3 Ultra, 256 GB, layers 0-31"], blocker: nil)]

    static func leaderCopiesAMissingModelOverTheCable() {
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, resume: .init(role: .leader, peerName: "Apple M3 Ultra, 256 GB"), pairEvents: [], pairResult: .failed([]),
            choices: copyChoices))
        expect(run.waitFor("Choose a model [1-2, enter = 1]: "), "copy: the choice")
        expect(run.text.contains("       needs: Apple M3 Ultra, 256 GB: copy from Apple M5 Ultra, 256 GB (this Mac) over the Thunderbolt cable (6.1 GB, about 3 s)"),
            "copy: the list says what the model needs, with size and time")
        run.type("\r")
        expect(run.waitFor("Qwen3.5-9B is not on every Mac yet. No download by hand is needed:"), "copy: what is missing, said")
        expect(run.waitFor("Press enter to copy it over the Thunderbolt cable (recommended), d to download it from Darkbloom's catalog instead, n to stop here."),
            "copy: the cable is the default")
        run.type("\r")
        expect(run.waitFor("  Copying Qwen3.5-9B to Apple M3 Ultra, 256 GB over the cable: 3.1 of 6.1 GB, 2.40 GB/s, about 1 s left"), "copy: progress on the leader")
        expect(run.waitFor("every file matched its manifest digest."), "copy: verified")
        expect(run.waitFor("Starting Qwen3.5-9B on both Macs in 3 s; press n to stop here."), "copy: then the timed start")
        expect(run.finish() == 0, "copy: served")
        expect(recorder.all == ["ensureService", "reachMembers", "planModels", "provision 0 copy", "recheckFit 0", "adopt 0", "serve", "waitReady", "testRequest"],
            "copy: copied before the setup is synced: \(recorder.all)")
        expect(run.keys == 2, "copy: enter (model), enter (copy); got \(run.keys)")
        expect(!run.text.lowercased().contains("ssh") && !run.text.contains("--model-dir"), "copy: no SSH, no model folder to type")
        transcript("leader-copies-missing-model", run.text, keys: run.keys)
    }

    static func leaderChoosesTheCatalogInstead() {
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, resume: .init(role: .leader, peerName: "Apple M3 Ultra, 256 GB"), pairEvents: [], pairResult: .failed([]),
            choices: copyChoices))
        expect(run.waitFor("Choose a model"), "catalog: the choice"); run.type("\r")
        expect(run.waitFor("d to download it"), "catalog: the alternative is offered"); run.type("d")
        expect(run.waitFor("Starting Qwen3.5-9B on both Macs in 3 s"), "catalog: then the timed start"); run.type("n")
        expect(run.finish() == 0, "catalog: n stops after the download")
        expect(recorder.all.contains("provision 0 download") && !recorder.all.contains("adopt 0"), "catalog: downloaded, nothing adopted: \(recorder.all)")
    }

    static func leaderDownloadsAModelNoMacHas() {
        let recorder = Recorder()
        let offer = ClusterOnboardingProvisionOffer(lines: ["Apple M5 Ultra, 256 GB (this Mac): download from Darkbloom's catalog (16.3 GB)",
            "Apple M3 Ultra, 256 GB: copy from Apple M5 Ultra, 256 GB (this Mac) over the Thunderbolt cable (16.3 GB)"],
            downloadAlternative: false, leaderDownloads: true)
        let before = [ClusterOnboardingModelChoice(title: "Qwen3.8-27B-4bit-mtp", lines: ["not on these Macs yet: planned once it is on this Mac"], blocker: nil, provision: offer)]
        let after = [ClusterOnboardingModelChoice(title: "Qwen3.8-27B-4bit-mtp", lines: ["rank 0: Apple M3 Ultra, 256 GB, layers 0-31", "rank 1 (decodes): Apple M5 Ultra, 256 GB (this Mac), layers 32-63"], blocker: nil)]
        let run = TerminalRun(operations(recorder, resume: .init(role: .leader, peerName: "Apple M3 Ultra, 256 GB"), pairEvents: [], pairResult: .failed([]),
            choices: before, replanned: after))
        expect(run.waitFor("Choose a model [1-1, enter = 1]: "), "download: a catalog model is offered"); run.type("\r")
        expect(run.waitFor("Qwen3.8-27B-4bit-mtp is not on this Mac yet. No download by hand is needed:"), "download: said")
        expect(run.waitFor("Press enter to get it, n to stop here."), "download: one key"); run.type("\r")
        expect(run.waitFor("Planning Qwen3.8-27B-4bit-mtp now that it is on this Mac…"), "download: planned after")
        expect(run.waitFor("  rank 1 (decodes): Apple M5 Ultra, 256 GB (this Mac), layers 32-63"), "download: the plan shown")
        expect(run.waitFor("Starting Qwen3.8-27B-4bit-mtp on both Macs in 3 s"), "download: timed start")
        expect(run.finish() == 0, "download: served")
        expect(recorder.all == ["ensureService", "reachMembers", "planModels", "provision 0 copy", "planModels", "recheckFit 0", "adopt 0", "serve", "waitReady", "testRequest"],
            "download: downloaded, planned again, then adopted: \(recorder.all)")
        transcript("leader-downloads-model", run.text, keys: run.keys)
    }

    static func copyDeclined() {
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, resume: .init(role: .leader, peerName: "Apple M3 Ultra, 256 GB"), pairEvents: [], pairResult: .failed([]),
            choices: copyChoices))
        expect(run.waitFor("Choose a model"), "declined copy: choice"); run.type("\r")
        expect(run.waitFor("n to stop here."), "declined copy: offer"); run.type("n")
        expect(run.finish() == 0, "declined copy: exit 0")
        expect(run.text.contains("Nothing was copied or downloaded. Run `darkbloom cluster` here again to choose."), "declined copy: said")
        expect(!recorder.all.contains { $0.hasPrefix("provision") || $0.hasPrefix("adopt") }, "declined copy: nothing moved or adopted")
    }

    static func copyBlockedByDisk() {
        let recorder = Recorder()
        let blocked = [ClusterOnboardingModelChoice(title: "Qwen3.5-9B", lines: [], blocker: nil, provision: .init(lines: ["Apple M3 Ultra, 256 GB: copy from Apple M5 Ultra, 256 GB (this Mac) over the Thunderbolt cable (6.1 GB) — cannot start: Apple M3 Ultra, 256 GB has 3.0 GB free; the model needs 6.1 GB and 2.1 GB to spare"],
            downloadAlternative: true, leaderDownloads: false, blocker: "Apple M3 Ultra, 256 GB has 3.0 GB free; the model needs 6.1 GB and 2.1 GB to spare"))]
        let run = TerminalRun(operations(recorder, resume: .init(role: .leader, peerName: "Apple M3 Ultra, 256 GB"), pairEvents: [], pairResult: .failed([]),
            choices: blocked))
        expect(run.waitFor("Choose a model"), "disk: choice"); run.type("\r")
        expect(run.finish() == 1, "disk: exit 1")
        expect(run.text.contains("It cannot start: Apple M3 Ultra, 256 GB has 3.0 GB free; the model needs 6.1 GB and 2.1 GB to spare. Free some space and run `darkbloom cluster` here again."),
            "disk: the free-disk refusal in words")
        expect(!recorder.all.contains { $0.hasPrefix("provision") }, "disk: nothing started")
    }

    static func copyInterrupted() {
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, resume: .init(role: .leader, peerName: "Apple M3 Ultra, 256 GB"), pairEvents: [], pairResult: .failed([]),
            choices: copyChoices, provisionResult: .failure(.init("The copy to Apple M3 Ultra, 256 GB stopped at 2.0 of 6.1 GB: the cable connection ended."))))
        expect(run.waitFor("Choose a model"), "interrupted: choice"); run.type("\r")
        expect(run.waitFor("n to stop here."), "interrupted: offer"); run.type("\r")
        expect(run.finish() == 1, "interrupted: exit 1")
        expect(run.text.contains("Run `darkbloom cluster` here again: a copy or download resumes where it stopped."), "interrupted: resumes next time")
        expect(!recorder.all.contains("adopt 0"), "interrupted: no setup synced for a model a Mac lacks")
    }

    // MARK: - Only large copies are asked for

    static let quickOffer = ClusterOnboardingProvisionOffer(
        lines: ["Apple M3 Ultra, 256 GB: copy from Apple M5 Ultra, 256 GB (this Mac) over the Thunderbolt cable (6.1 GB, about 3 s)"],
        downloadAlternative: true, leaderDownloads: false, quickSeconds: 3.05)

    /// A copy predicted under 30 s (from the copy rate measured on these Macs) starts with a stated line: no key.
    static func shortCopyStartsWithAStatedLine() {
        let recorder = Recorder()
        let choices = [ClusterOnboardingModelChoice(title: "Qwen3.5-9B", lines: ["rank 0: Apple M3 Ultra, 256 GB, layers 0-15"], blocker: nil, provision: quickOffer)]
        let run = TerminalRun(operations(recorder, resume: .init(role: .leader, peerName: "Apple M3 Ultra, 256 GB"), pairEvents: [], pairResult: .failed([]),
            choices: choices))
        expect(run.waitFor("Choose a model [1-1, enter = 1]: "), "short copy: the choice"); run.type("\r")
        expect(run.waitFor("Copying it over the Thunderbolt cable now (about 3 s at the speed measured on these Macs); press n in the next 3 s to stop here, d to download it from Darkbloom's catalog instead."),
            "short copy: a stated line, n still visible")
        expect(run.waitFor("Starting Qwen3.5-9B on both Macs in 3 s; press n to stop here."), "short copy: copied without a key, then the timed start")
        expect(run.finish() == 0, "short copy: served")
        expect(!run.text.contains("Press enter to copy it over the Thunderbolt cable"), "short copy: not asked")
        expect(recorder.all == ["ensureService", "reachMembers", "planModels", "provision 0 copy", "recheckFit 0", "adopt 0", "serve", "waitReady", "testRequest"],
            "short copy: copied before the setup is synced: \(recorder.all)")
        expect(run.keys == 1, "short copy: enter (model) only; got \(run.keys)")
        transcript("leader-short-copy-not-asked", run.text, keys: run.keys)
    }

    static func shortCopyStillStopsWithN() {
        let recorder = Recorder()
        let choices = [ClusterOnboardingModelChoice(title: "Qwen3.5-9B", lines: [], blocker: nil, provision: quickOffer)]
        let run = TerminalRun(operations(recorder, resume: .init(role: .leader, peerName: "Apple M3 Ultra, 256 GB"), pairEvents: [], pairResult: .failed([]),
            choices: choices))
        expect(run.waitFor("Choose a model"), "short copy n: choice"); run.type("\r")
        expect(run.waitFor("press n in the next 3 s to stop here"), "short copy n: the stated line"); run.type("n")
        expect(run.finish() == 0, "short copy n: exit 0")
        expect(run.text.contains("Nothing was copied or downloaded. Run `darkbloom cluster` here again to choose."), "short copy n: said")
        expect(!recorder.all.contains { $0.hasPrefix("provision") || $0.hasPrefix("adopt") }, "short copy n: nothing moved: \(recorder.all)")
    }


    // MARK: - One-command fixes (2026-10-14)

    static func deploymentWords() {
        typealias D = ClusterOnboardingDeployment
        expect(D.shortName("Apple M5 Ultra, 256 GB") == "M5 Ultra", "short name: chip only")
        let pipeline = [D.Share(name: "Apple M3 Ultra, 256 GB", layers: 40), D.Share(name: "Apple M5 Ultra, 256 GB", layers: 24)]
        expect(D.line(model: "Qwen3.8-27B", mode: "pipeline_v1", shares: pipeline)
            == "Serving Qwen3.8-27B across both Macs: pipeline, M3 Ultra 40 layers / M5 Ultra 24 layers", "pipeline line: \(D.line(model: "Qwen3.8-27B", mode: "pipeline_v1", shares: pipeline))")
        expect(D.line(model: "Qwen3.8-27B", mode: "pipeline_compact_decode_v1", shares: pipeline).contains(": pipeline, "), "compact decode is pipeline")
        let tp = [D.Share(name: "Apple M3 Ultra, 256 GB", layers: nil, weightsBytes: 6_000), D.Share(name: "Apple M5 Ultra, 256 GB", layers: nil, weightsBytes: 4_000)]
        expect(D.line(model: "Qwen3.8-27B", mode: "tensor_parallel_v1", shares: tp)
            == "Serving Qwen3.8-27B across both Macs: tensor parallel, M3 Ultra 60% / M5 Ultra 40%", "TP line, automatic from the plan's mode")
        expect(D.line(model: "Qwen3.8-27B", mode: "pipeline_prefill_tensor_decode_v1", shares: tp)
            == "Serving Qwen3.8-27B across both Macs: pipeline prefill, tensor parallel decode, M3 Ultra 60% / M5 Ultra 40%", "the hybrid in words")
        let same = [D.Share(name: "Apple M2 Max, 64 GB", layers: 16), D.Share(name: "Apple M2 Max, 96 GB", layers: 16)]
        expect(D.sharesWords(mode: "pipeline_v1", shares: same) == "Apple M2 Max, 64 GB 16 layers / Apple M2 Max, 96 GB 16 layers", "two Macs of one kind: full names")
        let three = pipeline + [D.Share(name: "Apple M4 Pro, 48 GB", layers: 8)]
        expect(D.line(model: "m", mode: "pipeline_v1", shares: three).hasPrefix("Serving m across 3 Macs: pipeline, "), "three Macs")
        expect(D.modeWords("something_new_v2") == "split across the Macs", "an unknown mode is never shown raw")
        expect(D.modeWords("phase_split_mtp_v1") == "prompt split, then one Mac decodes", "phase split in words, never claimed as an opt-in")
        expect(D.choiceLine(size: "6.1 GB", mode: "pipeline_v1", shares: pipeline, speed: "about 90 tokens/s")
            == "6.1 GB · pipeline · M3 Ultra 40 layers / M5 Ultra 24 layers · about 90 tokens/s", "choice line: one line, no ranks")
    }

    /// The approval line is on screen while checkLink still runs (the macOS prompt is up then), not after it returns.
    static func cableLinesStreamBeforeTheApproval() {
        let recorder = Recorder()
        let gate = DispatchSemaphore(value: 0)
        let run = TerminalRun(operations(recorder, pairEvents: [.searching, .joining, .code("123456", peer: ["Apple M5 Ultra, 256 GB"])],
            pairResult: .paired(role: .member, peerName: "Apple M5 Ultra, 256 GB"), approvalGate: gate))
        expect(run.waitFor("approve the macOS prompt (once per Mac).", seconds: 3), "cable: the approval line shows while the prompt is up")
        gate.signal()
        expect(run.waitFor("Press y if it does"), "cable: then pairing"); run.type("y")
        expect(run.finish() == 0, "cable: member done")
        expect(run.text.contains("  Cable found.\n") && run.text.contains("  Cable ready.\n"), "cable: plain lines")
    }

    static func twoCablesAreAskedOnScreen() {
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, pairEvents: [.searching, .joining, .code("123456", peer: ["Apple M5 Ultra, 256 GB"])],
            pairResult: .paired(role: .member, peerName: "Apple M5 Ultra, 256 GB"), linkPorts: ["en5", "en6"]))
        expect(run.waitFor("Two cables found: 1) en5 2) en6 [enter = 1]: "), "two cables: asked on screen")
        run.type("2\r")
        expect(run.waitFor("Using en6 for the cluster."), "two cables: the choice said")
        expect(run.waitFor("Press y if it does"), "two cables: pairing goes on"); run.type("y")
        expect(run.finish() == 0, "two cables: done")
        expect(recorder.all.prefix(3) == ["checkLink", "useLinkPort en6", "checkLink"], "two cables: the chosen port is set up: \(recorder.all)")
        expect(!run.text.contains("cluster link") && !run.text.contains("--device"), "two cables: no developer command")
        transcript("two-cables", run.text, keys: run.keys)
    }

    static func fittingChoicesComeFirst() {
        let recorder = Recorder()
        let choices = [
            ClusterOnboardingModelChoice(title: "Qwen3.8-27B-4bit-mtp", lines: ["16.3 GB · pipeline · M3 Ultra 40 layers / M5 Ultra 24 layers"], blocker: nil,
                fitRemedy: "Quit apps on Apple M3 Ultra, 256 GB first."),
            ClusterOnboardingModelChoice(title: "Qwen3.5-9B", lines: ["6.1 GB · pipeline · M3 Ultra 16 layers / M5 Ultra 16 layers"], blocker: nil)]
        let run = TerminalRun(operations(recorder, resume: .init(role: .leader, peerName: "Apple M3 Ultra, 256 GB"), pairEvents: [], pairResult: .failed([]),
            choices: choices))
        expect(run.waitFor("Choose a model [1-2, enter = 1]: "), "fit: the choice")
        expect(run.text.contains("  1. Qwen3.5-9B\n") && run.text.contains("  2. Qwen3.8-27B-4bit-mtp\n"), "fit: the one that fits is 1")
        expect(run.text.contains("       does not fit now: Quit apps on Apple M3 Ultra, 256 GB first.\n"), "fit: the remedy in plain words")
        run.type("\r")
        expect(run.finish() == 0, "fit: served")
        expect(recorder.all.contains("adopt 1") && !recorder.all.contains("adopt 0"), "fit: enter chose the fitting model: \(recorder.all)")
    }

    static func fitRecheckedBeforeTheStart() {
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, resume: .init(role: .leader, peerName: "Apple M3 Ultra, 256 GB"), pairEvents: [], pairResult: .failed([]),
            recheck: "Restart Apple M3 Ultra, 256 GB to free memory."))
        expect(run.waitFor("Choose a model"), "recheck: choice"); run.type("\r")
        expect(run.finish() == 1, "recheck: stops at once")
        expect(run.text.contains("Qwen3.5-9B does not fit in the Macs' free memory now: Restart Apple M3 Ultra, 256 GB to free memory."), "recheck: the same remedy line")
        expect(!recorder.all.contains { $0.hasPrefix("adopt") || $0 == "serve" || $0 == "waitReady" }, "recheck: nothing adopted or started: \(recorder.all)")
    }

    static func timeoutOffersADiagnosticsFile() {
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, resume: .init(role: .leader, peerName: "Apple M3 Ultra, 256 GB"), pairEvents: [], pairResult: .failed([]),
            readyResult: .failure(.init(["The cluster did not report ready within 15 minutes.", "Apple M3 Ultra, 256 GB: its part ended: out of memory.",
                                         "This Mac: loading layers 16-31."]))))
        expect(run.waitFor("Choose a model"), "timeout: choice"); run.type("\r")
        expect(run.waitFor("Press d to save a diagnostics file to send to Darkbloom, enter to leave."), "timeout: one key for diagnostics")
        run.type("d")
        expect(run.finish() == 1, "timeout: exit 1")
        expect(run.text.contains("Apple M3 Ultra, 256 GB: its part ended: out of memory."), "timeout: each Mac's last error on screen")
        expect(run.text.contains("Saved a diagnostics file"), "timeout: the file is saved")
        expect(!run.text.contains("rank.log"), "timeout: no log path")
        expect(recorder.all.contains("saveDiagnostics"), "timeout: saved through the operation")
    }

    static func restartLineAtTheEnd() {
        let recorder = Recorder()
        let run = TerminalRun(operations(recorder, resume: .init(role: .leader, peerName: "Apple M3 Ultra, 256 GB"), pairEvents: [], pairResult: .failed([]),
            afterRestart: "After a restart or power cut, this Mac serves again once someone logs in."))
        expect(run.waitFor("Choose a model"), "restart line: choice"); run.type("\r")
        expect(run.finish() == 0, "restart line: served")
        expect(run.text.contains("Nothing else is needed on the other Mac. After a restart or power cut, this Mac serves again once someone logs in.\n"),
            "restart line: what happens after a restart, from the service's real state")
    }

    /// What happens after a restart, from the Mac's own settings (A9): never a promise a FileVault Mac cannot keep.
    static func restartWords() {
        typealias R = ClusterOnboardingRestart
        expect(R.line(mac: "this Mac", autoLogin: true, fileVault: false)
            == "After a restart or power cut, this Mac comes back by itself and serves again (automatic login is on).", "restart: auto-login on")
        expect(R.line(mac: "this Mac", autoLogin: false, fileVault: true)
            == "After a restart or power cut, this Mac serves again once someone logs in (FileVault keeps the disk locked until then).", "restart: FileVault on")
        expect(R.line(mac: "this Mac", autoLogin: false, fileVault: false).hasSuffix("To make it automatic, turn on automatic login (System Settings → Users & Groups; needs FileVault off)."),
            "restart: auto-login off, the plain remedy")
        expect(R.line(mac: "this Mac", autoLogin: false, fileVault: nil).contains("once someone logs in"), "restart: FileVault unknown, no promise")
        for line in [R.line(mac: "x", autoLogin: false, fileVault: true), R.line(mac: "x", autoLogin: false, fileVault: false)] {
            expect(!line.contains("by itself"), "restart: no 'by itself' promise without auto-login: \(line)")
        }
    }

    /// The control leader notices a Darkbloom update (A4): a changed worker digest on either Mac; an unknown one is no reason.
    static func updateNoticed() {
        typealias U = ClusterOnboardingUpdate
        let pinned = ["mac-a": "aaaa", "mac-b": "bbbb"]
        expect(U.changed(pinned: pinned, current: ["mac-a": "aaaa", "mac-b": "bbbb"]).isEmpty, "update: nothing changed")
        expect(U.changed(pinned: pinned, current: ["mac-a": "a2a2", "mac-b": "bbbb"]) == ["mac-a"], "update: this Mac updated")
        expect(U.changed(pinned: pinned, current: ["mac-a": "a2a2", "mac-b": "b2b2"]) == ["mac-a", "mac-b"], "update: both updated")
        expect(U.changed(pinned: pinned, current: ["mac-a": "aaaa", "mac-b": nil]).isEmpty, "update: a Mac that did not answer is no reason")
        expect(U.changed(pinned: pinned, current: [:]).isEmpty, "update: nothing known, nothing re-planned")
        expect(U.statusLine == "Updating the cluster setup after a Darkbloom update.", "update: the status line")
        expect(U.checkEverySeconds <= 60 && U.retryAfterFailureSeconds >= 300, "update: noticed within a minute, a failure not retried in a loop")
    }

    /// The exact text and key count of a flow, for the evidence.
    static func transcript(_ name: String, _ text: String, keys: Int) {
        guard let directory = ProcessInfo.processInfo.environment["ONBOARDING_TRANSCRIPTS"] else { return }
        try? (text + "\n[keys typed: \(keys)]\n").write(toFile: directory + "/" + name + ".txt", atomically: true, encoding: .utf8)
    }
}
