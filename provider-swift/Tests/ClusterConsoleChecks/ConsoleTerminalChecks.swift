import Foundation
import Darwin
@testable import InstalledContract

/// The console on a real pseudo-terminal. Operations are scripted; the
/// terminal modes, the bytes, the signals and the threads are real.
extension ClusterConsoleCheck {
    static func terminalMode() throws {
        // Not a terminal: refused before anything is changed.
        var ends: [Int32] = [-1, -1]
        expect(pipe(&ends) == 0, "pipe")
        defer { close(ends[0]); close(ends[1]) }
        var refusal: ClusterConsoleTerminal.Failure?
        do { _ = try ClusterConsoleTerminal(input: ends[0], output: ends[1]) } catch let error as ClusterConsoleTerminal.Failure { refusal = error }
        expectEqual(refusal, .notATerminal, "a pipe is not a terminal")
        var loopRefusal: ClusterConsoleTerminal.Failure?
        do {
            _ = try ClusterConsoleRunLoop.run(input: ends[0], output: ends[1], configuration: .init(darkbloomVersion: "0"),
                operations: ScriptedOperations([ConsoleFixtures.snapshot()]).operations)
        } catch let error as ClusterConsoleTerminal.Failure { loopRefusal = error }
        expectEqual(loopRefusal, .notATerminal, "the loop refuses a pipe instead of waiting on it")

        let pty = try PseudoTerminal(columns: 80, rows: 24)
        let before = pty.mode
        expect(!isRaw(before), "a fresh terminal echoes and edits lines")
        let terminal = try ClusterConsoleTerminal(input: pty.slave, output: pty.slave)
        expect(sameMode(pty.mode, before), "opening changes nothing")
        try terminal.enter()
        expect(isRaw(pty.mode) && pty.mode.c_oflag & tcflag_t(OPOST) == 0, "the console's mode: no echo, no line editing, no signals, no output rewriting")
        expectEqual(terminal.size(), .init(columns: 80, rows: 24), "the terminal reports its size")
        try terminal.write(Array("frame".utf8))
        terminal.leave()
        expect(sameMode(pty.mode, before), "leaving restores the mode it found")
        terminal.leave()
        expect(sameMode(pty.mode, before), "leaving twice is harmless")
        usleep(50_000)
        let written = pty.output
        expect(written.hasPrefix(enterScreen) && written.contains("frame") && written.hasSuffix(leaveScreen),
            "the alternate screen is entered first and left last")
        expect(written.contains("\u{1B}[?25l") && written.contains("\u{1B}[?25h"), "the cursor is hidden and shown again")
        expect(written.contains("\u{1B}[?2004h") && written.contains("\u{1B}[?2004l"), "pastes are marked while the screen is open, and no longer afterwards")

        // A terminal object that is dropped without `leave` restores too.
        do {
            let dropped = try ClusterConsoleTerminal(input: pty.slave, output: pty.slave)
            try dropped.enter()
            expect(isRaw(pty.mode), "entered")
        }
        expect(sameMode(pty.mode, before), "a dropped terminal is restored")

        // A terminal that stops reading: the write gives up after its allowance, and leaving does not wait on it either.
        let stalled = try PseudoTerminal(columns: 80, rows: 24, reads: false)
        let stalledBefore = stalled.mode
        let slow = try ClusterConsoleTerminal(input: stalled.slave, output: stalled.slave, writeAllowanceMilliseconds: 150)
        try slow.enter()
        expect(isRaw(stalled.mode), "entered the stalled terminal")
        var stall: ClusterConsoleTerminal.Failure?
        let started = Date()
        do { try slow.write([UInt8](repeating: UInt8(ascii: "x"), count: 4 * 1024 * 1024)) } catch let error as ClusterConsoleTerminal.Failure { stall = error }
        expectEqual(stall, .cannotWrite(ETIMEDOUT), "a terminal that stopped reading fails the write instead of holding the console")
        slow.leave()
        expect(Date().timeIntervalSince(started) < 3, "neither the write nor leaving waits on it: \(Date().timeIntervalSince(started)) s")
        expect(sameModeApartFromPendingInput(stalled.mode, stalledBefore) && !isRaw(stalled.mode), "and its mode is back although it took nothing more")
        expect(ClusterConsoleTerminal.writeAllowanceMilliseconds == 5_000, "the installed allowance is five seconds")
    }

    static func runLoopOnPseudoTerminal() throws {
        let operations = ScriptedOperations([ConsoleFixtures.snapshot()])
        let run = try ConsoleRun(operations)
        let pty = run.terminal, before = run.initialMode
        expect(pty.wait { $0.contains("Readiness: link ready") }, "the first reading is drawn: \(pty.screen.prefix(3))")
        expect(isRaw(pty.mode), "the terminal is in the console's mode while it runs")
        expectEqual(pty.screen.count, 100, "the frame fills the window")
        expect(pty.screen.last?.contains("r read") == true && pty.screen.first?.hasPrefix("Darkbloom cluster") == true, "header and key line")
        expectEqual(operations.count("snapshot"), 1, "one reading at launch, none invented afterwards")

        // Help, then an arrow key that arrives one byte at a time: it must not be read as Escape.
        pty.send("?")
        expect(pty.wait { $0.contains("? back") }, "? opens help")
        for byte in [UInt8(0x1B), UInt8(ascii: "["), UInt8(ascii: "B")] { pty.send([byte]); usleep(30_000) }
        usleep(400_000)
        expect(pty.screenText.contains("? back"), "a split arrow sequence is an arrow, not Escape: help is still open")
        pty.send([0x1B])
        expect(pty.wait { $0.contains("r read") }, "a lone escape byte is the Escape key once nothing follows")

        // Keys with no meaning, a paste and non-ASCII input change nothing and break nothing.
        let shown = pty.screenText
        pty.send([0x00, 0x01, 0x1A]); pty.send("z1~"); pty.send("é日😀")
        // A paste is one event whatever it holds, and these words are full of keys that act.
        pty.send("\u{1B}[200~today say quit, fix, export, recover and help?\u{1B}[201~")
        pty.send("\u{1B}[1;5C\u{1B}[<0;1;1M")
        usleep(400_000)
        expectEqual(pty.screenText, shown, "meaningless input leaves the screen as it was")
        expect(run.isRunning, "and the console is still running")
        expectEqual(operations.count("fixLink") + operations.count("exportDiagnostics") + operations.count("recoverJournal"), 0, "nothing in a paste ran")
        // A paste whose end is split across reads is still one paste.
        pty.send("\u{1B}[200~quit\u{1B}[20"); usleep(120_000); pty.send("1~")
        usleep(300_000)
        expect(run.isRunning && pty.screenText == shown, "a paste split across reads is not read as keys")
        // A paste whose end never comes does not swallow the keyboard for good.
        pty.send("\u{1B}[200~no end marker follows q")
        usleep(1_400_000)
        expect(run.isRunning && pty.screenText == shown, "the unfinished paste did nothing")
        pty.send("?")
        expect(pty.wait { $0.contains("? back") }, "after its allowance, keys are read again")
        pty.send("?")
        expect(pty.wait { $0.contains("r read") }, "and help closes again")

        // An action through the loop: the export receives what the screen holds.
        pty.send("e")
        expect(pty.wait { $0.contains("06:00:00 Export diagnostics") && $0.contains("Wrote fixture export.") }, "the export's result is listed")
        expect(operations.exported?.snapshot.schema == ClusterConsoleSnapshot.schemaName && operations.exported?.darkbloomVersion == "0.0.0-check",
            "the export was handed the snapshot on screen")
        expect(operations.count("snapshot") == 2, "the state is read again after an action: \(operations.count("snapshot"))")

        // r reads again; the next scripted reading is what is shown.
        pty.send("q")
        guard case .success(let exit)? = run.end() else { return expect(false, "q did not close the screen") }
        expectEqual(exit, .init(code: 0, farewell: []), "q closes with status 0")
        usleep(50_000)
        expect(sameMode(pty.mode, before), "the terminal mode is restored after q")
        expect(pty.output.hasSuffix(leaveScreen), "the alternate screen is left last")

        // Every byte written was either a known sequence or printable text.
        let remainder = PseudoTerminal.strippingSequences(pty.output).replacingOccurrences(of: "\r\n", with: "")
        expect(!remainder.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }, "nothing but text and the console's own sequences reached the terminal")

        // A changed reading replaces the old one: nothing is remembered from before.
        let changing = ScriptedOperations([ConsoleFixtures.snapshot(link: ConsoleFixtures.unpluggedLink), ConsoleFixtures.snapshot()])
        changing.link = ConsoleFixtures.unpluggedLink
        let second = try ConsoleRun(changing)
        expect(second.terminal.wait { $0.contains("Readiness: link noActivePort") && $0.contains("Watching for a connection") }, "no cable: the wait is shown")
        expect(second.terminal.wait { _ in changing.count("inspectLink") >= 2 }, "the link is read again while waiting: \(changing.count("inspectLink"))")
        expectEqual(changing.count("snapshot"), 1, "an unchanged link starts no full refresh")
        changing.link = ConsoleFixtures.readyLink
        expect(second.terminal.wait { $0.contains("Readiness: link ready") }, "the cable arrives: the new state is read and shown")
        let polls = changing.count("inspectLink")
        usleep(300_000)
        expect(changing.count("inspectLink") <= polls + 1, "a ready link is no longer polled")
        second.terminal.send("q")
        expect(second.end() != nil, "the second console closes")
    }

    static func resize() throws {
        // An empty journal: with one that is not empty the approval this check asks for would be refused, not asked.
        let operations = ScriptedOperations([ConsoleFixtures.snapshot(link: ConsoleFixtures.bridgedLink, saved: ConsoleFixtures.savedSetup(),
            candidate: ConsoleFixtures.candidate(), journal: .emptyJournal)])
        // What each signal did before the screen opened, to compare with afterwards.
        func disposition(_ number: Int32) -> Int {
            var action = sigaction()
            sigaction(number, nil, &action)
            return unsafeBitCast(action.__sigaction_u.__sa_handler, to: Int.self)
        }
        let taken = [SIGINT, SIGTERM, SIGHUP, SIGWINCH], dispositions = taken.map(disposition)
        // The console takes the window-change signal itself, as it does in a terminal.
        let run = try ConsoleRun(operations, columns: 100, rows: 30, candidate: ConsoleFixtures.candidateInputs, handlesSignals: true)
        let pty = run.terminal, before = run.initialMode
        expect(pty.wait { $0.contains("Readiness: link portBridgedWithoutAddress") }, "drawn at 100x30")
        expect(taken.dropLast().allSatisfy { disposition($0) == 1 }, "while the screen is open, a signal to end is taken as an event")
        func resized(_ columns: Int, _ rows: Int, until condition: @escaping ([String]) -> Bool) -> Bool {
            pty.resize(columns: columns, rows: rows)
            kill(getpid(), SIGWINCH)
            return pty.wait { _ in
                let screen = pty.screen
                return condition(screen) && screen.count <= max(rows, 1) && screen.allSatisfy { $0.count <= columns }
            }
        }
        expect(resized(10, 3) { $0 == ["darkbloom ", "The window", "q closes."] }, "10x3 shows the short notice, clipped: \(pty.screen)")
        // Nothing can be asked where the question cannot be read, so nothing can be answered there.
        pty.send("a"); usleep(150_000); pty.send("y"); usleep(150_000)
        expect(resized(1, 1) { $0 == ["d"] }, "1x1 shows one character: \(pty.screen)")
        expect(resized(27, 5) { $0.count == 3 && $0[0] == "darkbloom cluster" }, "one column short of the minimum is still the notice: \(pty.screen)")
        expect(resized(28, 6) { $0.count == 6 && $0[0].hasPrefix("Darkbloom") && $0[0].hasSuffix("lines 1-3 of \($0[0].split(separator: " ").last ?? "")") },
            "the smallest full screen keeps its header, its place and its key line: \(pty.screen)")
        expect(resized(500, 200) { $0.count == 200 && $0.contains { $0.contains("Not available in this build") } },
            "500x200 fills the window and shows everything: \(pty.screen.count) rows")
        expect(resized(80, 24) { $0.count == 24 && $0[0].contains("lines 1-21 of") }, "back to 80x24, scrollable again: \(pty.screen.first ?? "")")
        // A question that is open when the window stops showing all of it is withdrawn, and y then approves nothing.
        pty.send("a")
        expect(pty.wait { $0.contains("y: save setup eeeeeeeeeeee and trust its pinned keys. Any other key cancels.") }, "at 80 columns the whole question is on the screen: \(pty.screen.suffix(2))")
        expect(resized(70, 24) { $0.contains { $0.hasPrefix("The window became too small to show the question") } }, "at 70 columns it is withdrawn: \(pty.screen.suffix(2))")
        pty.send("y"); usleep(200_000)
        expect(resized(80, 24) { $0.count == 24 }, "back to 80 columns")
        pty.send("y"); usleep(200_000)
        expectEqual(operations.count("approveSetup"), 0, "no y approved a setup whose question was not on the screen")
        // Scrolled to the end, then a window that fits less, then more: the view stays inside the body.
        pty.send("G")
        expect(pty.wait { $0.contains("Not available in this build") }, "scrolled to the end")
        expect(resized(60, 10) { $0.count == 10 }, "smaller while scrolled")
        expect(resized(132, 300) { $0.count == 300 && $0[1].hasPrefix("Readiness") }, "a window that shows everything starts at the top: \(pty.screen.prefix(2))")
        // A window change repaints even when the frame is the same: the terminal may have redrawn or clipped it.
        let painted = pty.output.utf8.count
        kill(getpid(), SIGWINCH)
        expect(pty.wait { _ in pty.output.utf8.count > painted }, "the same frame is written again after a window change")
        // A terminal that reports no size at all keeps the last size it had.
        pty.resize(columns: 0, rows: 0); kill(getpid(), SIGWINCH)
        usleep(200_000)
        expect(pty.screen.count == 300 && run.isRunning, "an unsized terminal leaves the screen as it was: \(pty.screen.count) rows")
        // A burst of changes ends on the last size.
        for (columns, rows) in [(40, 12), (200, 5), (3, 3), (90, 28), (0, 0), (64, 20)] { pty.resize(columns: columns, rows: rows); kill(getpid(), SIGWINCH) }
        expect(pty.wait { _ in pty.screen.count == 20 && pty.screen.allSatisfy { $0.count <= 64 } }, "a burst of resizes settles on the last size")
        expect(run.isRunning, "the console survived every size")
        let remainder = PseudoTerminal.strippingSequences(pty.output).replacingOccurrences(of: "\r\n", with: "")
        expect(!remainder.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }, "no stray bytes at any size")
        pty.send("q")
        expect(run.end() != nil, "closes after the resizes")
        usleep(50_000)
        expect(sameMode(pty.mode, before), "the mode is restored")
        // The signals the console took for the screen's lifetime are given back as they were.
        expectEqual(taken.map(disposition), dispositions, "a signal was left changed after the screen closed")
    }

    static func cancellation() throws {
        let narrate = ProcessInfo.processInfo.environment["CLUSTER_CONSOLE_CHECK_VERBOSE"] != nil
        func step(_ name: String) { if narrate { FileHandle.standardError.write(Data("  \(name)\n".utf8)) } }
        func closing(_ what: String, handlesSignals: Bool = false, _ act: (ConsoleRun) -> Void) throws -> ClusterConsoleExit? {
            step(what)
            let run = try ConsoleRun(ScriptedOperations([ConsoleFixtures.snapshot()]), handlesSignals: handlesSignals)
            let before = run.initialMode
            expect(!isRaw(before), "\(what): the terminal started out of the console's mode")
            expect(run.terminal.wait { $0.contains("Readiness") }, "\(what): drawn")
            expect(isRaw(run.terminal.mode), "\(what): in the console's mode")
            act(run)
            guard case .success(let exit)? = run.end() else {
                expect(false, "\(what): the console did not close")
                return nil
            }
            usleep(50_000)
            expect(sameMode(run.terminal.mode, before), "\(what): the terminal mode is restored")
            expect(run.terminal.output.hasSuffix(leaveScreen), "\(what): the alternate screen is left")
            return exit
        }
        expectEqual(try closing("q") { $0.terminal.send("q") }, .init(code: 0, farewell: []), "q")
        expectEqual(try closing("Ctrl-C") { $0.terminal.send([0x03]) }, .init(code: 0, farewell: []), "Ctrl-C arrives as a key and closes")
        expectEqual(try closing("Ctrl-D") { $0.terminal.send([0x04]) }, .init(code: 0, farewell: []), "Ctrl-D closes")
        // Signals sent to the process, as `kill` or a closing terminal window would.
        expectEqual(try closing("SIGTERM", handlesSignals: true) { _ in kill(getpid(), SIGTERM) }?.code, 128 + SIGTERM, "SIGTERM")
        expectEqual(try closing("SIGINT", handlesSignals: true) { _ in kill(getpid(), SIGINT) }?.code, 128 + SIGINT, "SIGINT")
        expectEqual(try closing("SIGHUP", handlesSignals: true) { _ in kill(getpid(), SIGHUP) }?.code, 128 + SIGHUP, "SIGHUP")

        // A thrown error: the screen can no longer be written. The input terminal is still restored.
        step("thrown error")
        let screenSide = try PseudoTerminal(columns: 80, rows: 24)
        let broken = try ConsoleRun(ScriptedOperations([ConsoleFixtures.snapshot()]), output: screenSide)
        let before = broken.initialMode
        expect(screenSide.wait { $0.contains("Readiness") }, "drawn on the second terminal")
        expect(isRaw(broken.terminal.mode), "the input terminal is in the console's mode")
        screenSide.closeMaster()
        broken.terminal.send("?")
        guard case .failure(let error)? = broken.end() else { return expect(false, "a write failure did not end the loop with an error") }
        let failure = error as? ClusterConsoleRunLoop.Failure
        if case .cannotWrite? = failure?.underlying as? ClusterConsoleTerminal.Failure {} else { expect(false, "unexpected error: \(error)") }
        expect(failure?.interruptedSession == nil && failure?.description.hasPrefix("The terminal could not be written to") == true,
            "the error says what failed and names no session, as none was running: \(failure?.description ?? "")")
        expect(sameMode(broken.terminal.mode, before), "after a thrown error the terminal mode is restored")

        // The same with a session this screen started: it is asked to stop on the way out, once, and the error says so.
        step("thrown error with a session running")
        let launch = ScriptedSessionLaunch(processIdentifier: 4242)
        let serving = ScriptedOperations([ConsoleFixtures.snapshot(saved: ConsoleFixtures.savedSetup())])
        serving.launch = { launch.launch($0) }
        let servingScreen = try PseudoTerminal(columns: 132, rows: 60)
        let failing = try ConsoleRun(serving, output: servingScreen)
        let failingBefore = failing.initialMode
        expect(servingScreen.wait { $0.contains("Cluster fixture-cluster") }, "drawn")
        failing.terminal.send("s")
        expect(servingScreen.wait { $0.contains("y: start the session; both Macs load the model. Any other key cancels.") }, "the start question is drawn")
        failing.terminal.send("y")
        expect(servingScreen.wait { $0.contains("Process 4242, started from this screen, is running.") }, "the session is running")
        servingScreen.closeMaster()
        failing.terminal.send("?")
        guard case .failure(let sessionError)? = failing.end() else { return expect(false, "a write failure with a session running did not end the loop with an error") }
        let sessionFailure = sessionError as? ClusterConsoleRunLoop.Failure
        expect(sessionFailure?.interruptedSession == 4242 && launch.session.interrupts == 1, "the session was asked to stop exactly once: \(launch.session.interrupts)")
        expect(sessionFailure?.description.contains("process 4242") == true && sessionFailure?.description.contains("`darkbloom cluster status`") == true,
            "and the error names it and where to look: \(sessionFailure?.description ?? "")")
        expect(sameMode(failing.terminal.mode, failingBefore), "the terminal mode is restored here too")

        // The terminal goes away while the screen is open.
        step("vanished terminal")
        let vanished = try ConsoleRun(ScriptedOperations([ConsoleFixtures.snapshot()]))
        expect(vanished.terminal.wait { $0.contains("Readiness") }, "drawn before the terminal goes away")
        vanished.terminal.closeMaster()
        guard case .success(let gone)? = vanished.end() else { return expect(false, "a vanished terminal did not end the console in an orderly way") }
        expectEqual(gone, .init(code: 1, farewell: []), "a vanished terminal ends the console with a failure status, and nothing is drawn at it on the way out")

        // Closing while an action is in flight: waited for, unless the operator insists.
        step("action in flight")
        let gate = DispatchSemaphore(value: 0)
        let waiting = ScriptedOperations([ConsoleFixtures.snapshot()])
        waiting.hold("fixLink", at: gate)
        let patient = try ConsoleRun(waiting)
        expect(patient.terminal.wait { $0.contains("Readiness") }, "drawn")
        patient.terminal.send("f")
        expect(patient.terminal.wait { $0.contains("Fix link is running") }, "the fix is in flight")
        patient.terminal.send("q")
        expect(patient.terminal.wait { $0.contains("The screen closes when it reports") }, "q waits for the action")
        expect(patient.end(within: 0.3) == nil, "and the screen stays open meanwhile")
        gate.signal()
        guard case .success(let afterAction)? = patient.end() else { return expect(false, "the console did not close after the action") }
        expectEqual(afterAction, .init(code: 0, farewell: []), "it closes once the action has reported")

        let insistGate = DispatchSemaphore(value: 0)
        let insisting = ScriptedOperations([ConsoleFixtures.snapshot()])
        insisting.hold("fixLink", at: insistGate)
        let impatient = try ConsoleRun(insisting)
        let impatientBefore = impatient.initialMode
        expect(impatient.terminal.wait { $0.contains("Readiness") }, "drawn")
        impatient.terminal.send("f")
        expect(impatient.terminal.wait { $0.contains("Fix link is running") }, "in flight")
        impatient.terminal.send("q")
        expect(impatient.terminal.wait { $0.contains("Press q again to close now") }, "first q explains")
        impatient.terminal.send([0x03])
        guard case .success(let forced)? = impatient.end() else { return expect(false, "a second quit did not close the screen") }
        expect(forced.code == 0 && forced.farewell.first?.contains("macOS prompt") == true, "closing now says what may still be open")
        expect(sameMode(impatient.terminal.mode, impatientBefore), "and the terminal is restored although the action never reported")
        insistGate.signal()   // the abandoned action reports into a closed mailbox, harmlessly
        usleep(100_000)

        // A second request to end before the first was read: the loop is taken to be stuck, and the
        // forced way out is called once, with the signal. What it does there, it does to the session too.
        step("second signal")
        final class Forced: @unchecked Sendable {
            private let lock = NSLock()
            private var numbers = [Int32]()
            func record(_ number: Int32) { lock.withLock { numbers.append(number) } }
            var all: [Int32] { lock.withLock { numbers } }
        }
        let mail = try ClusterConsoleMailbox(), forcedOut = Forced()
        let twice = ClusterConsoleSignals(mailbox: mail) { forcedOut.record($0) }
        func settle(_ condition: () -> Bool) -> Bool {
            for _ in 0..<300 { if condition() { return true }; usleep(10_000) }
            return condition()
        }
        var received = [ClusterConsoleMailbox.Mail]()
        kill(getpid(), SIGTERM)
        expect(settle { received += mail.take(); return !received.isEmpty }, "the first signal arrives as mail")
        expect(forcedOut.all.isEmpty, "and is not the forced way out")
        kill(getpid(), SIGHUP)
        expect(settle { forcedOut.all == [SIGHUP] }, "a second request to end takes the forced way out, once: \(forcedOut.all)")
        usleep(50_000)
        received += mail.take()
        expectEqual(received.count, 1, "and is not queued behind the first")
        if case .event(.terminationSignal(let number))? = received.first { expectEqual(number, SIGTERM, "the mail is the first signal") }
        else { expect(false, "the first signal was not delivered as a request to end") }
        twice.close(); mail.close()
        let slot = ClusterConsoleSessionSlot(), slotted = ScriptedSession(processIdentifier: 7)
        expect(!slot.interruptOnce(), "with no session there is nothing to ask")
        slot.set(slotted)
        expect(slot.interruptOnce() && slotted.interrupts == 1, "a session that has not ended is asked to stop")
        expect(!slot.interruptOnce() && slotted.interrupts == 1, "and is not asked a second time, whichever way out asks")
        slot.set(nil)
        expect(!slot.interruptOnce() && slotted.interrupts == 1, "one that has ended is not asked at all")
        let flag = ClusterConsoleFlag()
        expect(!flag.isSet, "the loop has not ended")
        flag.set()
        expect(flag.isSet, "once it has, the forced way out stands down")
        // What the forced way out writes: the leave sequence, and only to a terminal that takes it at once.
        let leaving = try PseudoTerminal(columns: 80, rows: 24)
        ClusterConsoleTerminal.Restore(input: leaving.slave, output: leaving.slave, saved: leaving.mode).leaveScreenIfWritable()
        expect(leaving.wait { _ in leaving.output.hasSuffix(leaveScreen) }, "a terminal that is reading is left: \(leaving.output.count) bytes")
        let deaf = try PseudoTerminal(columns: 80, rows: 24, reads: false)
        let filler = try ClusterConsoleTerminal(input: deaf.slave, output: deaf.slave, writeAllowanceMilliseconds: 50)
        _ = try? filler.write([UInt8](repeating: UInt8(ascii: "x"), count: 1024 * 1024))
        let deafStart = Date()
        ClusterConsoleTerminal.Restore(input: deaf.slave, output: deaf.slave, saved: deaf.mode).leaveScreenIfWritable()
        expect(Date().timeIntervalSince(deafStart) < 0.5, "a terminal that stopped reading is not waited on")

        // A session this screen started is never left running by a way out: each one asks it to stop.
        func runningSession(_ what: String, handlesSignals: Bool = false) throws -> (ConsoleRun, ScriptedSessionLaunch)? {
            step(what)
            let launch = ScriptedSessionLaunch(processIdentifier: 5151)
            let operations = ScriptedOperations([ConsoleFixtures.snapshot(saved: ConsoleFixtures.savedSetup())])
            operations.launch = { launch.launch($0) }
            let run = try ConsoleRun(operations, columns: 132, rows: 60, handlesSignals: handlesSignals)
            guard run.terminal.wait(until: { $0.contains("Cluster fixture-cluster") }) else { expect(false, "\(what): the saved setup was not drawn"); return nil }
            run.terminal.send("s")
            guard run.terminal.wait(until: { $0.contains("y: start the session") }) else { expect(false, "\(what): the start question was not drawn"); return nil }
            run.terminal.send("y")
            guard run.terminal.wait(until: { $0.contains("Process 5151, started from this screen, is running.") }) else {
                expect(false, "\(what): the session did not start")
                return nil
            }
            return (run, launch)
        }
        if let (run, launch) = try runningSession("session: q, q, then its end") {
            run.terminal.send("q")
            expect(run.terminal.wait { $0.contains("Press q again to stop it and close once it has stopped") }, "q asks before stopping the session")
            expectEqual(launch.session.interrupts, 0, "and has not stopped it yet")
            run.terminal.send("q")
            expect(run.terminal.wait { _ in launch.session.interrupts == 1 }, "q again sends one interrupt")
            expect(run.end(within: 0.4) == nil, "and the screen waits for the session to end")
            launch.send(.ended(description: "exited with status 0", clean: true))
            guard case .success(let exit)? = run.end() else { return expect(false, "the screen did not close when the session ended") }
            expectEqual(exit, .init(code: 0, farewell: []), "it closes once the session has ended, with nothing left to say")
            expectEqual(launch.session.interrupts, 1, "the session was interrupted once and never again")
        }
        if let (run, launch) = try runningSession("session: SIGTERM", handlesSignals: true) {
            kill(getpid(), SIGTERM)
            guard case .success(let exit)? = run.end() else { return expect(false, "SIGTERM did not close the screen") }
            expect(exit.code == 128 + SIGTERM && launch.session.interrupts == 1, "SIGTERM closes with its status and asks the session to stop: \(launch.session.interrupts)")
            expect(exit.farewell.count == 1 && exit.farewell[0].contains("process 5151") && exit.farewell[0].contains("finishing by itself"),
                "and says on the restored terminal that the session is finishing: \(exit.farewell)")
            usleep(50_000)
            expect(sameMode(run.terminal.mode, run.initialMode), "and the terminal has the mode it started with")
        }
        if let (run, launch) = try runningSession("session: the terminal goes away") {
            run.terminal.closeMaster()
            guard case .success(let exit)? = run.end() else { return expect(false, "a vanished terminal with a session running did not end the console in an orderly way") }
            expect(exit.code == 1 && exit.farewell.count == 1 && exit.farewell[0].contains("process 5151"), "a vanished terminal closes with a failure and names the session: \(exit)")
            expectEqual(launch.session.interrupts, 1, "and the session was asked to stop, once")
        }
    }

    static func reentrancy() throws {
        let gate = DispatchSemaphore(value: 0)
        let operations = ScriptedOperations([ConsoleFixtures.snapshot(saved: ConsoleFixtures.savedSetup(role: .follower))])
        operations.hold("fixLink", at: gate)
        let run = try ConsoleRun(operations, columns: 132, rows: 120)
        let pty = run.terminal
        expect(pty.wait { $0.contains("Readiness") }, "drawn")

        // One action at a time: further action keys start nothing while the first is out.
        pty.send("f")
        expect(pty.wait { $0.contains("Fix link is running") }, "the fix is in flight")
        pty.send("f")
        expect(pty.wait { $0.contains("Fix link is still running. Wait for its result") }, "a second f is refused with the reason")
        pty.send("fcfe")
        usleep(300_000)
        expectEqual(operations.count("fixLink"), 1, "the fix ran once")
        expectEqual(operations.count("recoverJournal") + operations.count("exportDiagnostics"), 0, "no other action started meanwhile")
        // The screen is not frozen by the action: keys that only move the view still work.
        pty.send("?")
        expect(pty.wait { $0.contains("? back") }, "help opens while an action runs")
        pty.send("?")
        expect(pty.wait { $0.contains("r read") }, "and closes")
        gate.signal()
        expect(pty.wait { $0.contains("06:00:00 Fix link") && $0.contains("fixture fix sentence") }, "the first action's result arrives")
        operations.hold("fixLink", at: nil)
        pty.send("f")
        expect(pty.wait { _ in operations.count("fixLink") == 2 }, "afterwards the action can run again")
        expect(pty.wait { _ in operations.count("snapshot") == 3 }, "each finished action is followed by one reading: \(operations.count("snapshot"))")

        // A burst of refresh keys while a refresh is out: one runs, one waits, the rest are dropped.
        let reading = DispatchSemaphore(value: 0)
        operations.hold("snapshot", at: reading)
        pty.send("r")
        expect(pty.wait { _ in operations.count("snapshot") == 4 }, "a refresh is out")
        pty.send("rrrrrrrrrr")
        usleep(300_000)
        expectEqual(operations.count("snapshot"), 4, "no second refresh starts while one is out")
        operations.hold("snapshot", at: nil)
        reading.signal()
        expect(pty.wait { _ in operations.count("snapshot") == 5 }, "exactly one queued refresh follows")
        usleep(300_000)
        expectEqual(operations.count("snapshot"), 5, "and no more")

        // A follower's start is refused on the screen.
        pty.send("s")
        expect(pty.wait { $0.contains("This Mac is the follower") }, "a follower's start is refused on the screen")
        expectEqual(operations.count("launchSession"), 0, "and nothing was launched")
        pty.send("q")
        expect(run.end() != nil, "closes")

        // Keys that arrive with the key that asks: typed ahead, pasted, or in one write.
        let trusting = ScriptedOperations([ConsoleFixtures.snapshot(candidate: ConsoleFixtures.candidate())])
        let approval = try ConsoleRun(trusting, candidate: ConsoleFixtures.candidateInputs)
        let screen = approval.terminal
        expect(screen.wait { $0.contains("Setup passed in for approval:") }, "the setup to approve is shown")
        screen.send("\u{1B}[200~ay\u{1B}[201~")
        usleep(300_000)
        expect(!screen.screenText.contains("y: save setup") && trusting.approved.isEmpty, "a pasted a and y neither ask nor approve")
        screen.send("ay")
        expect(screen.wait { $0.contains("y: save setup eeeeeeeeeeee and trust its pinned keys. Any other key cancels.") }, "a opens the question, and it is drawn")
        usleep(300_000)
        expect(trusting.approved.isEmpty && trusting.count("approveSetup") == 0, "the y that arrived with the a approved nothing")
        expect(screen.screenText.contains("y: save setup"), "and the question is still there to be read")
        screen.send("y")
        expect(screen.wait { _ in trusting.approved == [ConsoleFixtures.candidateSHA256] },
            "a y after the question is on the screen approves the setup that was shown: \(trusting.approved)")
        expect(screen.wait { $0.contains("06:00:00 Approve setup") && $0.contains("Saved cluster setup fixture.") }, "and the save's own result is listed")
        screen.send("ayyyy")
        expect(screen.wait { $0.contains("y: save setup") }, "asked again")
        screen.send("n")
        expect(screen.wait { $0.contains("Cancelled. Nothing was changed.") }, "any other key cancels")
        screen.send("yyyy"); usleep(200_000)
        expectEqual(trusting.approved.count, 1, "and no stray y approved a second time")
        screen.send("q")
        expect(approval.end() != nil, "closes")

        // With the installed dwell, a y that follows the question at once is not an answer; one after the dwell is.
        let dwellOperations = ScriptedOperations([ConsoleFixtures.snapshot(candidate: ConsoleFixtures.candidate())])
        let dwelling = try ConsoleRun(dwellOperations, options: .init(onboarding: false, questionDwellMilliseconds: 600), candidate: ConsoleFixtures.candidateInputs)
        expect(dwelling.terminal.wait { $0.contains("Setup passed in for approval:") }, "drawn")
        dwelling.terminal.send("a")
        expect(dwelling.terminal.wait { $0.contains("y: save setup") }, "the question is on the screen")
        dwelling.terminal.send("y")
        usleep(250_000)
        expect(dwellOperations.approved.isEmpty && dwelling.terminal.screenText.contains("y: save setup"), "a y right after it appeared approved nothing, and the question stays")
        usleep(500_000)
        dwelling.terminal.send("y")
        expect(dwelling.terminal.wait { _ in dwellOperations.approved == [ConsoleFixtures.candidateSHA256] }, "a y after the dwell approves")
        dwelling.terminal.send("q")
        expect(dwelling.end() != nil, "closes")

        // A leader: the start is asked, cancelled by an action key that then does not act, confirmed once, and guards the rest.
        let launch = ScriptedSessionLaunch(processIdentifier: 6262)
        let leading = ScriptedOperations([ConsoleFixtures.snapshot(saved: ConsoleFixtures.savedSetup())])
        leading.launch = { launch.launch($0) }
        let leader = try ConsoleRun(leading, columns: 132, rows: 70)
        let view = leader.terminal
        expect(view.wait { $0.contains("Cluster fixture-cluster") }, "drawn")
        view.send("s")
        expect(view.wait { $0.contains("y: start the session; both Macs load the model. Any other key cancels.") }, "start asks first")
        view.send("f")
        expect(view.wait { $0.contains("Cancelled. Nothing was changed.") }, "an action key inside a question only cancels the question")
        usleep(150_000)
        expectEqual(leading.count("fixLink") + leading.count("launchSession"), 0, "and neither the fix nor the session started")
        view.send("s")
        expect(view.wait { $0.contains("y: start the session") }, "asked again")
        view.send("y")
        expect(view.wait { $0.contains("Process 6262, started from this screen, is running.") }, "y starts it")
        view.send("s")
        expect(view.wait { $0.contains("already running") }, "a second start is refused")
        view.send("f")
        expect(view.wait { $0.contains("Stop it with x and wait for it to end before fix link.") }, "the link is not touched under a running session: \(view.screen.suffix(2))")
        view.send("c")
        expect(view.wait { $0.contains("before recover journal.") }, "nor the journal")
        usleep(150_000)
        expectEqual(leading.count("launchSession"), 1, "one launch")
        expectEqual(leading.count("fixLink") + leading.count("recoverJournal"), 0, "and nothing else ran beside the session")
        view.send("xx")
        expect(view.wait { $0.contains("Process 6262 was asked to stop and has not ended.") }, "x asks it to stop and the screen says it has not ended")
        usleep(150_000)
        expectEqual(launch.session.interrupts, 1, "two x send one interrupt")
        launch.send(.output("session released"))
        launch.send(.ended(description: "exited with status 0", clean: true))
        expect(view.wait { $0.contains("The session process started from this screen exited with status 0.") && $0.contains("session released") },
            "its end is the process's own, with its last line")
        view.send("q")
        guard case .success(let closed)? = leader.end() else { return expect(false, "did not close") }
        expectEqual(closed, .init(code: 0, farewell: []), "with the session ended, q closes at once")
    }

    static func secondInstance() throws {
        let directory = scratch.appendingPathComponent("instance")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var first: ClusterConsoleInstanceLock? = try ClusterConsoleInstanceLock.acquire(directory: directory)
        expect(first != nil, "the first screen takes the lock")
        var information = stat()
        let file = directory.appendingPathComponent("darkbloom-cluster-console.lock")
        expect(lstat(file.path, &information) == 0 && information.st_mode & 0o777 == 0o600 && information.st_size == 0, "the lock is an empty owner-only file")
        var refusal = ""
        do { _ = try ClusterConsoleInstanceLock.acquire(directory: directory) } catch { refusal = String(describing: error) }
        expect(refusal.contains("Another `darkbloom cluster` screen is open") && refusal.contains("--plain"),
            "a second screen is refused and told what it can do instead: \(refusal)")
        // Another process is refused the same way: the lock is the kernel's, not this process's.
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/bin/sh")
        probe.arguments = ["-c", "exec /usr/bin/lockf -k -s -t 0 \"$1\" /usr/bin/true", "sh", file.path]
        try probe.run(); probe.waitUntilExit()
        expect(probe.terminationStatus != 0, "another process cannot take the lock while a screen holds it")
        first = nil
        let again = try ClusterConsoleInstanceLock.acquire(directory: directory)
        withExtendedLifetime(again) {}
        expect(lstat(file.path, &information) == 0 && information.st_size == 0, "a closed screen releases the lock and leaves it empty")

        // The real lock lives in the user's own temporary directory, not in the home directory.
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        expect(confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) > 0, "the user temporary directory is known")

        // A lock file that is not what the console would have made is refused, not replaced.
        let loose = scratch.appendingPathComponent("instance-loose")
        try FileManager.default.createDirectory(at: loose, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Data().write(to: loose.appendingPathComponent("darkbloom-cluster-console.lock"))
        chmod(loose.appendingPathComponent("darkbloom-cluster-console.lock").path, 0o644)
        var unsafe = ""
        do { _ = try ClusterConsoleInstanceLock.acquire(directory: loose) } catch { unsafe = String(describing: error) }
        expect(unsafe.contains("owner-only"), "a lock file others can read is refused: \(unsafe)")
        // A directory others can write to is not trusted to hold the lock.
        let shared = scratch.appendingPathComponent("instance-shared")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: false)
        chmod(shared.path, 0o777)
        var foreign = ""
        do { _ = try ClusterConsoleInstanceLock.acquire(directory: shared) } catch { foreign = String(describing: error) }
        expect(foreign.contains("not this user's own") && !FileManager.default.fileExists(atPath: shared.appendingPathComponent("darkbloom-cluster-console.lock").path),
            "a directory others can write to is refused and nothing is created in it: \(foreign)")
    }
}
