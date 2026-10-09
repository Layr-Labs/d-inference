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

        // A terminal object that is dropped without `leave` restores too.
        do {
            let dropped = try ClusterConsoleTerminal(input: pty.slave, output: pty.slave)
            try dropped.enter()
            expect(isRaw(pty.mode), "entered")
        }
        expect(sameMode(pty.mode, before), "a dropped terminal is restored")
    }

    static func runLoopOnPseudoTerminal() throws {
        let operations = ScriptedOperations([ConsoleFixtures.snapshot()])
        let run = try ConsoleRun(operations)
        let pty = run.terminal, before = pty.mode
        expect(pty.wait { $0.contains("Readiness: link ready") }, "the first reading is drawn: \(pty.screen.prefix(3))")
        expect(isRaw(pty.mode), "the terminal is in the console's mode while it runs")
        expectEqual(pty.screen.count, 100, "the frame fills the window")
        expect(pty.screen.last?.contains("r refresh") == true && pty.screen.first?.hasPrefix("Darkbloom cluster") == true, "header and key line")
        expectEqual(operations.count("snapshot"), 1, "one reading at launch, none invented afterwards")

        // Help, then an arrow key that arrives one byte at a time: it must not be read as Escape.
        pty.send("?")
        expect(pty.wait { $0.contains("? back") }, "? opens help")
        for byte in [UInt8(0x1B), UInt8(ascii: "["), UInt8(ascii: "B")] { pty.send([byte]); usleep(30_000) }
        usleep(400_000)
        expect(pty.screenText.contains("? back"), "a split arrow sequence is an arrow, not Escape: help is still open")
        pty.send([0x1B])
        expect(pty.wait { $0.contains("r refresh") }, "a lone escape byte is the Escape key once nothing follows")

        // Keys with no meaning, a paste and non-ASCII input change nothing and break nothing.
        let shown = pty.screenText
        pty.send([0x00, 0x01, 0x1A]); pty.send("z1~"); pty.send("é日😀"); pty.send("\u{1B}[200~pasted\u{1B}[201~".replacingOccurrences(of: "pasted", with: "ZZZ"))
        pty.send("\u{1B}[1;5C\u{1B}[<0;1;1M")
        usleep(400_000)
        expectEqual(pty.screenText, shown, "meaningless input leaves the screen as it was")
        expect(run.isRunning, "and the console is still running")

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
        let operations = ScriptedOperations([ConsoleFixtures.snapshot(link: ConsoleFixtures.bridgedLink, saved: ConsoleFixtures.savedSetup(),
            candidate: ConsoleFixtures.candidate(), journal: .ownershipUnproven)])
        // What each signal did before the screen opened, to compare with afterwards.
        func disposition(_ number: Int32) -> Int {
            var action = sigaction()
            sigaction(number, nil, &action)
            return unsafeBitCast(action.__sigaction_u.__sa_handler, to: Int.self)
        }
        let taken = [SIGINT, SIGTERM, SIGHUP, SIGWINCH], dispositions = taken.map(disposition)
        // The console takes the window-change signal itself, as it does in a terminal.
        let run = try ConsoleRun(operations, columns: 100, rows: 30, handlesSignals: true)
        let pty = run.terminal, before = pty.mode
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
        expect(resized(1, 1) { $0 == ["d"] }, "1x1 shows one character: \(pty.screen)")
        expect(resized(27, 5) { $0.count == 3 && $0[0] == "darkbloom cluster" }, "one column short of the minimum is still the notice: \(pty.screen)")
        expect(resized(28, 6) { $0.count == 6 && $0[0].hasPrefix("Darkbloom") && $0[0].hasSuffix("lines 1-3 of \($0[0].split(separator: " ").last ?? "")") },
            "the smallest full screen keeps its header, its place and its key line: \(pty.screen)")
        expect(resized(500, 200) { $0.count == 200 && $0.contains { $0.contains("Not available in this build") } },
            "500x200 fills the window and shows everything: \(pty.screen.count) rows")
        expect(resized(80, 24) { $0.count == 24 && $0[0].contains("lines 1-21 of") }, "back to 80x24, scrollable again: \(pty.screen.first ?? "")")
        // Scrolled to the end, then a window that fits less, then more: the view stays inside the body.
        pty.send("G")
        expect(pty.wait { $0.contains("Not available in this build") }, "scrolled to the end")
        expect(resized(60, 10) { $0.count == 10 }, "smaller while scrolled")
        expect(resized(132, 300) { $0.count == 300 && $0[1].hasPrefix("Readiness") }, "a window that shows everything starts at the top: \(pty.screen.prefix(2))")
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
            let before = run.terminal.mode
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
        let before = broken.terminal.mode
        expect(screenSide.wait { $0.contains("Readiness") }, "drawn on the second terminal")
        expect(isRaw(broken.terminal.mode), "the input terminal is in the console's mode")
        screenSide.closeMaster()
        broken.terminal.send("?")
        guard case .failure(let error)? = broken.end() else { return expect(false, "a write failure did not end the loop with an error") }
        if case .cannotWrite = error as? ClusterConsoleTerminal.Failure {} else { expect(false, "unexpected error: \(error)") }
        expect(sameMode(broken.terminal.mode, before), "after a thrown error the terminal mode is restored")

        // The terminal goes away while the screen is open.
        step("vanished terminal")
        let vanished = try ConsoleRun(ScriptedOperations([ConsoleFixtures.snapshot()]))
        expect(vanished.terminal.wait { $0.contains("Readiness") }, "drawn before the terminal goes away")
        vanished.terminal.closeMaster()
        guard let ended = vanished.end() else { return expect(false, "the console kept running without a terminal") }
        switch ended {
        case .success(let exit): expectEqual(exit.code, 1, "a vanished terminal ends the console with a failure status")
        case .failure(let error): expect(error is ClusterConsoleTerminal.Failure, "a vanished terminal ended the loop with \(error)")
        }

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
        let impatientBefore = impatient.terminal.mode
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
        expect(pty.wait { $0.contains("r refresh") }, "and closes")
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

        // A start asked for twice, and keys during the question.
        pty.send("s")
        expect(pty.wait { $0.contains("This Mac is the follower") }, "a follower's start is refused on the screen")
        expectEqual(operations.count("launchSession"), 0, "and nothing was launched")
        pty.send("q")
        expect(run.end() != nil, "closes")
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
