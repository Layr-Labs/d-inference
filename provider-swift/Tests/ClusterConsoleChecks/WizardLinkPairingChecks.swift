import Foundation
import Darwin
@testable import InstalledContract

/// Step 3's pairing over the link (S17): the reducer with no terminal, then
/// the run loop on a real pseudo-terminal with a scripted ceremony.
extension ClusterConsoleCheck {
    static func wizardLinkPairing() throws {
        typealias F = WizardFixtures
        let paired = ClusterSetupLinkPairings(localPin: "1111222233334444", pairings: [
            .init(peerPin: "aaaabbbbccccdddd", peerName: "Apple M5 Max, 128 GB", clusterID: "pair-0123456789ab", generation: 1,
                  pairedAt: "2026-10-11T20:00:00Z")])
        @Sendable func lone(_ pairings: ClusterSetupLinkPairings? = nil) -> ClusterSetupSnapshot {
            var report = F.reportB(); report.linkPairings = pairings
            return F.snapshot(report, pair: nil, record: .init())
        }

        // Progress: a pairing stored by the ceremony settles step 3 with no SSH code and no pair description.
        var progress = ClusterSetupState(size: .init(columns: 80, rows: 24))
        progress.snapshot = lone()
        expectEqual(progress.status(of: .pair), .waiting, "never paired and no pair: step 3 waits, as before")
        progress.snapshot = lone(paired)
        expectEqual(progress.status(of: .pair), .done, "a pairing over the link settles step 3")
        expect(progress.pairingConfirmed, "and counts as the confirmed pairing")
        var broken = paired; broken.pairings = []; broken.error = "pairings.json is not private to this user"
        progress.snapshot = lone(broken)
        expectEqual(progress.status(of: .pair), .waiting, "an unreadable store pairs nothing")

        // l: listen; the code; y after the dwell; the other Mac; the stored result.
        var d = WizardDrive(size: .init(columns: 100, rows: 40))
        _ = d.state.begin(); d.send(.snapshot(lone()))
        expectEqual(d.state.step, .pair, "a lone Mac opens at step 3")
        expect(d.text.contains("Pair over the link (no SSH)") && d.text.contains("Pair: press l on both Macs"), "step 3 offers the link: \(d.text)")
        expectEqual(d.key(.character("l")), [.pairOverLink(connect: nil)], "l starts the ceremony as listener")
        expectEqual(d.key(.character("l")), [], "a second l does not start another")
        expect(d.state.notice?.contains("already running") == true, "and says why")
        d.send(.linkPairing(.waiting("Listening on en7 for 10 minutes: on the other Mac press c and type 10.219.4.7.")))
        expect(d.text.contains("press c and type 10.219.4.7"), "the screen says what to type on the other Mac: \(d.text)")
        expect(d.state.animating, "a running ceremony keeps the screen moving")
        d.send(.linkPairing(.code("482913", peer: ["The other Mac:  Apple M5 Max, 128 GB"])))
        expectEqual(d.state.asking, .confirmLinkCode(code: "482913"), "the code asks the question")
        expect(d.text.contains("482 913") && d.text.contains("Apple M5 Max, 128 GB"), "code and the other Mac show: \(d.text)")
        expectEqual(d.key(.character("y")), [], "y before the question was drawn does nothing")
        d.draw()
        expectEqual(d.key(.character("y")), [], "y inside the dwell does nothing")
        expectEqual(d.key(.character("x")), [], "another key does not answer")
        expectEqual(d.state.asking, .confirmLinkCode(code: "482913"), "and does not withdraw the question: the other Mac waits")
        expectEqual(d.key(.character("3")), [], "a digit does not move the screen away from the question")
        expectEqual(d.yes(), [.answerLinkCode(accept: true)], "y after the dwell confirms")
        expectEqual(d.state.linkPairing, .confirmedHere(peerConfirmed: false), "confirmed here, waiting for the other Mac")
        d.send(.linkPairing(.peerDecided(true)))
        expectEqual(d.state.linkPairing, .confirmedHere(peerConfirmed: true), "both confirmed")
        expect(d.text.contains("Both Macs confirmed"), "the screen says so: \(d.text)")
        let effects = d.send(.linkPairing(.finished(succeeded: true, lines: ["Paired. This Mac pins the other Mac's Secure Enclave key aaaabbbbccccdddd\u{2026}"])))
        expect(effects.contains(.refresh), "the store is read back")
        expect(d.state.activity.contains { $0.title == "Pairing over the link" && !$0.failed }, "the activity log records it")
        d.send(.snapshot(lone(paired)))
        expectEqual(d.state.status(of: .pair), .done, "step 3 is done")
        expect(d.text.contains("Paired with Apple M5 Max, 128 GB") && d.text.contains("pair-0123456789ab, generation 1"),
               "the pinned key and the roster show: \(d.text)")
        expect(!d.text.contains("the leader's screen showed this code"), "a link pairing does not claim the SSH code was confirmed")

        // n declines; the other Mac declining withdraws the question.
        var n = WizardDrive(size: .init(columns: 100, rows: 40))
        _ = n.state.begin(); n.send(.snapshot(lone()))
        n.key(.character("l")); n.send(.linkPairing(.code("111111", peer: [])))
        n.draw()
        expectEqual(n.key(.character("n")), [.answerLinkCode(accept: false)], "n declines")
        expect(n.state.notice?.contains("nothing was paired") == true, "and says nothing was paired: \(n.state.notice ?? "")")
        n.send(.linkPairing(.finished(succeeded: false, lines: ["Not paired: the codes were not confirmed on this Mac. Nothing was stored."])))
        expect(n.text.contains("Not paired"), "the result shows: \(n.text)")
        expectEqual(n.key(.character("l")), [.pairOverLink(connect: nil)], "a finished ceremony can be started again")
        n.send(.linkPairing(.code("222222", peer: [])))
        n.send(.linkPairing(.peerDecided(false)))
        expect(n.state.asking == nil, "the other Mac declining withdraws the question")
        expect(n.state.notice?.contains("did not confirm") == true, "and says so")

        // c: the other Mac's address, typed.
        var c = WizardDrive(size: .init(columns: 100, rows: 40))
        _ = c.state.begin(); c.send(.snapshot(lone()))
        expectEqual(c.key(.character("c")), [], "c opens the address entry")
        c.type("10.219.4.77")
        expectEqual(c.state.step, .pair, "digits go to the address, not the step rail")
        expect(c.text.contains("10.219.4.77_"), "the typed address shows: \(c.text)")
        c.key(.backspace)
        c.type("x;")
        expectEqual(c.state.linkPairing, .enteringAddress("10.219.4.7"), "only digits and dots are taken")
        c.key(.unknown)
        expect(c.state.notice?.contains("Pasted text") == true, "a paste is refused")
        var short = c
        short.state.linkPairing = .enteringAddress("10.219")
        expectEqual(short.key(.enter), [], "an incomplete address does not dial")
        expect(short.state.notice?.contains("Type the address") == true, "and says what to type")
        expectEqual(c.key(.enter), [.pairOverLink(connect: "10.219.4.7")], "enter dials the address")
        var cancelled = WizardDrive(size: .init(columns: 100, rows: 40))
        _ = cancelled.state.begin(); cancelled.send(.snapshot(lone()))
        cancelled.key(.character("c")); cancelled.type("10"); cancelled.key(.escape)
        expectEqual(cancelled.state.linkPairing, .idle, "escape cancels the entry")
        expect(!WizardDrive.isAddress("010.1.1.1") && !WizardDrive.isAddress("10.1.1") && !WizardDrive.isAddress("256.1.1.1")
               && WizardDrive.isAddress("192.168.2.1"), "address syntax")

        // Nothing starts beside a session; ctrl-C on the question declines and quits.
        var busy = WizardDrive(size: .init(columns: 100, rows: 40))
        _ = busy.state.begin(); busy.send(.snapshot(lone()))
        busy.state.session = .running(processIdentifier: 7, since: 0)
        expectEqual(busy.key(.character("l")), [], "no pairing beside a running session")
        expect(busy.state.notice?.contains("Serving is running") == true, "and says why: \(busy.state.notice ?? "")")
        var quit = WizardDrive(size: .init(columns: 100, rows: 40))
        _ = quit.state.begin(); quit.send(.snapshot(lone()))
        quit.key(.character("l")); quit.send(.linkPairing(.code("333333", peer: [])))
        quit.draw()
        let interrupted = quit.key(.interrupt)
        expect(interrupted.first == .answerLinkCode(accept: false), "ctrl-C answers no first: \(interrupted)")
        expect(quit.state.exit != nil, "and leaves")
        for size in [ClusterConsoleSize(columns: 40, rows: 12), .init(columns: 80, rows: 24), .init(columns: 200, rows: 60)] {
            var s = d; s.state.size = size
            for line in ClusterSetupScreen.frame(s.state).lines { expect(line.text.count <= size.columns, "\(size): no line wider than the window") }
        }

        // The run loop on a pseudo-terminal, with a scripted ceremony.
        let ops = WizardScriptedOperations([lone()])
        let answers = WizardLinkAnswers()
        var operations = ops.operations
        operations.pairOverLink = { connect, events in
            answers.started(connect)
            events(.waiting("Listening on en7 for 10 minutes: on the other Mac press c and type 10.219.4.7."))
            events(.code("482913", peer: ["The other Mac:  Apple M5 Max, 128 GB"]))
            let accepted = answers.wait()
            ops.set(lone(paired))
            events(.peerDecided(true))
            events(.finished(succeeded: accepted, lines: [accepted ? "Paired. This Mac pins the other Mac's Secure Enclave key aaaabbbbccccdddd\u{2026}"
                                                                   : "Not paired: the codes were not confirmed on this Mac. Nothing was stored."]))
        }
        operations.answerLinkCode = { answers.answer($0) }
        let run = try WizardRun(ops, columns: 100, rows: 40, options: .init(questionDwellMilliseconds: 300), custom: operations)
        defer { if run.isRunning { run.terminal.send([0x03]); run.terminal.send([0x03]); _ = run.end(within: 3) } }
        expect(run.see("Pair over the link (no SSH)"), "the pseudo-terminal shows step 3's link pairing: \(run.terminal.screenText)")
        run.terminal.send("l")
        expect(run.see("Do both screens show 482 913? y: yes, n: no."), "the question with the code: \(run.terminal.screenText)")
        expect(answers.connect == .some(nil), "l started a listener")
        run.terminal.send("y")
        run.terminal.send("\u{1B}[200~y\u{1B}[201~")
        usleep(100_000)
        expect(answers.answered == nil, "a y inside the dwell and a pasted y do not answer")
        usleep(400_000)
        run.terminal.send("y")
        expect(run.see("Paired with Apple M5 Max, 128 GB", within: 5), "the stored pairing shows after y: \(run.terminal.screenText)")
        expectEqual(answers.answered, true, "the ceremony got the person's yes")
        run.terminal.send("q")
        if case .success(let exit)? = run.end(within: 5) { expectEqual(exit.code, 0, "q leaves cleanly") } else { expect(false, "the wizard ended") }
        expect(!isRaw(run.terminal.mode), "the terminal is restored")
    }
}

/// The scripted ceremony's side of the person's answer.
final class WizardLinkAnswers: @unchecked Sendable {
    private let lock = NSLock()
    private let signal = DispatchSemaphore(value: 0)
    private var _connect: String??
    private var _answered: Bool?
    var connect: String?? { lock.withLock { _connect } }
    var answered: Bool? { lock.withLock { _answered } }
    func started(_ connect: String?) { lock.withLock { _connect = .some(connect) } }
    func answer(_ accept: Bool) { lock.withLock { _answered = accept }; signal.signal() }
    func wait() -> Bool { _ = signal.wait(timeout: .now() + 10); return answered ?? false }
}

extension WizardDrive {
    static func isAddress(_ text: String) -> Bool { ClusterSetupState.isIPv4(text) }
}
