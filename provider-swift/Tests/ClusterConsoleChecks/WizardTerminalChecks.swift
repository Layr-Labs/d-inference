import Foundation
import Darwin
@testable import InstalledContract

/// The wizard's run loop on a real pseudo-terminal, on its own thread, with scripted operations.
final class WizardRun: @unchecked Sendable {
    let terminal: PseudoTerminal
    let operations: WizardScriptedOperations
    let initialMode: termios
    private let finished = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var outcome: Result<ClusterConsoleExit, Error>?

    init(_ operations: WizardScriptedOperations, columns: Int = 80, rows: Int = 24,
         options: ClusterSetupState.Options = .init(questionDwellMilliseconds: 0), glyphs: ClusterSetupGlyphs = .unicode,
         color: Bool = true, handlesSignals: Bool = false, custom: ClusterSetupOperations? = nil) throws {
        self.operations = operations
        terminal = try PseudoTerminal(columns: columns, rows: rows)
        initialMode = terminal.mode
        let configuration = ClusterSetupRunLoop.Configuration(options: options, color: color, glyphs: glyphs, idleMilliseconds: 40,
            busyMilliseconds: 20, escapeMilliseconds: 250, handlesSignals: handlesSignals, clock: { "2026-10-10T15:30:00Z" })
        let slave = terminal.slave, scripted = custom ?? operations.operations
        Thread.detachNewThread { [self] in
            let result = Result { try ClusterSetupRunLoop.run(input: slave, output: slave, configuration: configuration, operations: scripted) }
            lock.withLock { outcome = result }
            finished.signal()
        }
    }

    var isRunning: Bool { lock.withLock { outcome == nil } }

    func end(within seconds: Double = 5) -> Result<ClusterConsoleExit, Error>? {
        guard finished.wait(timeout: .now() + seconds) == .success else { return nil }
        finished.signal()
        return lock.withLock { outcome }
    }

    /// Waits for the screen to contain `text`.
    func see(_ text: String, within seconds: Double = 5) -> Bool { terminal.wait(seconds) { $0.contains(text) } }

    /// Waits until the scripted operation was called `times` times.
    func called(_ name: String, times: Int = 1, within seconds: Double = 5) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if operations.count(name) >= times { return true }
            usleep(5_000)
        }
        return operations.count(name) >= times
    }
}

extension ClusterConsoleCheck {
    /// The whole walkthrough on a pseudo-terminal at 80x24: pair, plan,
    /// check, serve with a test prompt, stop, quit; then the failure paths.
    static func wizardOnPseudoTerminal() throws {
        typealias F = WizardFixtures
        let savedA = ClusterSetupSaved(state: .loaded, error: nil, setup: F.setup(leader: true))
        let savedB = ClusterSetupSaved(state: .loaded, error: nil, setup: F.setup(leader: false, digest: String(repeating: "b", count: 64)))
        let ops = WizardScriptedOperations([F.snapshot(F.reportA())])
        ops.set(plans: .ready(F.options))
        let run = try WizardRun(ops)
        defer { if run.isRunning { run.terminal.send([0x03]); run.terminal.send([0x03]); _ = run.end(within: 3) } }
        expect(run.see("482 913"), "it opens at the pairing step and shows the code: \(run.terminal.screenText)")
        expect(isRaw(run.terminal.mode), "the wizard puts the terminal in raw mode")
        expect(run.called("reachPeer"), "it reached the other Mac by itself")
        expect(run.see("Pair") && run.terminal.screenText.contains("Darkbloom cluster setup"), "title and rail")
        let rail = run.terminal.screen.dropFirst().first ?? ""
        expect(rail.contains("✓ 1 This Mac") && rail.contains("✓ 2 Cable"), "steps 1 and 2 are ticked on the rail: \(rail)")
        run.terminal.send("\r")
        expect(run.see("Do both screens show 482 913?"), "enter asks about the code")
        // What the record holds once written, as the next refresh reads it.
        ops.set(F.snapshot(F.reportA(), record: F.confirmed()))
        run.terminal.send("y")
        expect(run.called("recordConfirmation:482913"), "y records the confirmation")
        expect(run.see("Confirmed"), "the confirmation shows after the record is read back: \(run.terminal.screenText)")
        // Step 4: the plan from both Macs' readings.
        run.terminal.send("\u{1B}[C")
        expect(run.called("planModels"), "step 4 plans")
        expect(run.see("Qwen3.5-9B") && run.see("fits now"), "the 9B fits now: \(run.terminal.screenText)")
        run.terminal.send("\r")
        expect(run.see("save this plan here"), "enter asks to adopt the plan")
        ops.set(F.snapshot(F.reportA(saved: savedA), pair: F.savedLeaderPair, record: F.confirmed()))
        ops.set(peer: .reached(F.reportB(saved: savedB), seconds: 0.4))
        run.terminal.send("y")
        expect(run.called("adoptPlan:" + F.models[0].folder), "y adopts the 9B's plan")
        expect(run.see("has saved its matching setup"), "the other Mac's saved setup is seen: \(run.terminal.screenText)")
        // Step 5: the check, end to end, with live progress.
        run.terminal.send("\u{1B}[C")
        expect(run.see("Run the check"), "step 5 offers the check")
        run.terminal.send("c")
        expect(run.see("both Macs load the model briefly"), "c asks first")
        ops.set(live: .init(observed: true, ready: false, members: [
            .init(rank: 0, memberID: "mac-a", ready: true, cleanupObserved: false, releaseAcknowledged: false, termination: nil),
            .init(rank: 1, memberID: "mac-b", ready: false, cleanupObserved: false, releaseAcknowledged: false, termination: nil)]))
        run.terminal.send("y")
        expect(run.called("launchSession"), "the check starts the session")
        expect(run.see("1 of 2 ranks ready"), "progress counts ranks: \(run.terminal.screenText)")
        ops.set(live: F.scriptedLive)
        expect(run.called("sendPrompt"), "both ranks ready: a test generation")
        let deadline = Date().addingTimeInterval(5)
        while ops.launch.session.interrupts == 0, Date() < deadline { usleep(5_000) }
        expectEqual(ops.launch.session.interrupts, 1, "the check stops the session once tokens came back")
        var passed = F.confirmed()
        passed.add(.init(configurationSHA256: F.setup(leader: true).configurationSHA256, at: "t", readySeconds: 1, firstTokenMilliseconds: 720, tokensPerSecond: 53.1))
        ops.set(F.snapshot(F.reportA(saved: savedA), pair: F.savedLeaderPair, record: passed))
        ops.launch.send(.ended(description: "exited with status 0", clean: true))
        expect(run.called("recordCheck"), "the pass is recorded")
        expect(run.see("Check passed"), "the screen says it passed: \(run.terminal.screenText)")
        // Step 6: serve, a test prompt, stop.
        run.terminal.send("\u{1B}[C")
        expect(run.see("Start serving"), "step 6 offers to start")
        run.terminal.send("s")
        expect(run.see("start serving (both Macs load the model)"), "s asks first")
        run.terminal.send("y")
        expect(run.called("launchSession", times: 2), "y starts serving")
        expect(run.see("Serving Qwen3.5-9B"), "the live view: \(run.terminal.screenText)")
        run.terminal.send("t")
        expect(run.see("> _"), "t opens the prompt box")
        run.terminal.send("What is RDMA?")
        expect(run.see("> What is RDMA?_"), "typed text shows in the box")
        run.terminal.send("\r")
        expect(run.see("write into another's memory"), "the reply streams in: \(run.terminal.screenText)")
        expect(run.see("53.1 tok/s"), "its speed shows")
        run.terminal.send("x")
        let stopped = Date().addingTimeInterval(5)
        while ops.launch.session.interrupts < 2, Date() < stopped { usleep(5_000) }
        expectEqual(ops.launch.session.interrupts, 2, "x interrupts the session")
        ops.launch.send(.ended(description: "exited with status 0", clean: true))
        expect(run.see("Clean up"), "the clean-up is shown after the stop: \(run.terminal.screenText)")
        run.terminal.send("q")
        guard case .success(let exit)? = run.end() else { failures.append("q closes the wizard"); return }
        expectEqual(exit.code, 0, "a clean close")
        expect(sameMode(run.terminal.mode, run.initialMode), "the terminal mode is restored")
        expect(run.terminal.output.hasSuffix(leaveScreen) || run.terminal.output.contains(leaveScreen), "the alternate screen is left")
        // Everything the walkthrough asked for, in order, and no change it did not ask for.
        let calls = ops.calls
        expect(!calls.contains("fixLink:apply") && !calls.contains("fixLink:dryRun"), "nothing touched the link: \(calls)")
        expectEqual(calls.filter { $0.hasPrefix("adoptPlan") }.count, 1, "one plan adopted")

        try wizardFailurePathsOnPseudoTerminal()
    }

    static func wizardFailurePathsOnPseudoTerminal() throws {
        typealias F = WizardFixtures
        // The other Mac unreachable, then reachable: p tries again.
        let unreachable = WizardScriptedOperations([F.snapshot(F.reportA())])
        unreachable.set(peer: .failed("the other Mac did not accept this Mac's key"))
        let a = try WizardRun(unreachable)
        expect(a.see("Could not reach mac-b"), "the reason shows: \(a.terminal.screenText)")
        unreachable.set(peer: .reached(F.reportB(), seconds: 0.4))
        a.terminal.send("p")
        expect(a.see("482 913"), "p reaches again and the code shows")
        a.terminal.send([0x03])
        expect(a.end().map { if case .success(let exit) = $0 { return exit.code == 0 } else { return false } } == true, "Ctrl-C closes")

        // RDMA off: step 1 with the Recovery steps, at 80x24, scrollable.
        var off = F.linkA; off.state = "rdmaDisabled"; off.port = nil
        let rdma = WizardScriptedOperations([F.snapshot(F.reportA(link: off), pair: nil, record: .init())])
        let b = try WizardRun(rdma)
        expect(b.see("RDMA over Thunderbolt is turned off"), "step 1 says RDMA is off: \(b.terminal.screenText)")
        b.terminal.send("\u{1B}[6~")
        expect(b.see("rdma_ctl enable"), "page down shows the Recovery command: \(b.terminal.screenText)")
        b.terminal.send("\r")
        expect(b.called("snapshot", times: 2), "enter reads again")
        b.terminal.send("q")
        _ = b.end()

        // The link fix: preview, the commands, cancel; then the window narrows and a question goes away.
        let link = WizardScriptedOperations([F.snapshot(F.reportA(), pair: nil, record: .init())])
        let c = try WizardRun(link, columns: 100, rows: 30, handlesSignals: true)
        expect(c.see("This Mac's pairing code") || c.see("does not know the other Mac"), "a lone leader opens at pairing")
        c.terminal.send("2")
        expect(c.see("Fix link (one approval)"), "step 2 offers the fix: \(c.terminal.screenText)")
        c.terminal.send("f")
        expect(c.called("fixLink:dryRun"), "f runs the dry run")
        expect(c.see("networksetup -createnetworkservice"), "the commands show")
        expect(c.see("y: apply these commands"), "and the question")
        c.terminal.send("n")
        expect(c.see("Cancelled. Nothing was changed."), "any other key cancels")
        expect(link.count("fixLink:apply") == 0, "nothing was applied")
        // A paste is not keys.
        c.terminal.send("\u{1B}[200~fyyy\u{1B}[201~")
        usleep(200_000)
        expect(link.count("fixLink:dryRun") == 1, "a pasted f runs nothing")
        c.terminal.resize(columns: 30, rows: 8)
        kill(getpid(), SIGWINCH)
        expect(c.see("Window too small"), "a tiny window says so: \(c.terminal.screenText)")
        c.terminal.resize(columns: 80, rows: 24)
        kill(getpid(), SIGWINCH)
        expect(c.see("Cable"), "the screen comes back at 80x24")
        c.terminal.send("q")
        _ = c.end()

        // A dry-run wizard in ASCII without colour: nothing applies, nothing but ASCII is drawn.
        let dry = WizardScriptedOperations([F.snapshot(F.reportA(), pair: nil, record: .init())])
        let d = try WizardRun(dry, options: .init(dryRun: true, questionDwellMilliseconds: 0), glyphs: .ascii, color: false)
        expect(d.see("Pair"), "drawn before keys")
        d.terminal.send("2")
        d.terminal.send("f")
        expect(d.see("Dry run"), "the dry run says so: \(d.terminal.screenText)")
        d.terminal.send("y")
        usleep(200_000)
        expect(dry.count("fixLink:apply") == 0, "y applies nothing in a dry run")
        expect(!d.terminal.output.contains("\u{1B}[32m") && !d.terminal.output.contains("\u{1B}[1;36m"), "no colour is sent")
        expect(PseudoTerminal.strippingSequences(d.terminal.output).unicodeScalars.allSatisfy { $0.value < 128 }, "only ASCII is drawn")
        d.terminal.send("q")
        _ = d.end()

        // The terminal going away closes the wizard, and the mode is put back.
        let gone = WizardScriptedOperations([F.snapshot(F.reportA())])
        let e = try WizardRun(gone)
        expect(e.see("Pair"), "drawn")
        e.terminal.closeMaster()
        expect(e.end() != nil, "a closed terminal ends the loop")
    }
}
