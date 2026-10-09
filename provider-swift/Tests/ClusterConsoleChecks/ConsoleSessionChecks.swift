import Foundation
import Darwin
@testable import InstalledContract

extension ClusterConsoleCheck {
    /// Collects what a session process reports.
    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var events = [ClusterConsoleSessionEvent]()
        func record(_ event: ClusterConsoleSessionEvent) { lock.withLock { events.append(event) } }
        var all: [ClusterConsoleSessionEvent] { lock.withLock { events } }
        var output: [String] { all.compactMap { if case .output(let line) = $0 { return line } else { return nil } } }
        var ending: ClusterConsoleSessionEvent? { all.first { if case .ended = $0 { return true } else { return false } } }
        func wait(_ seconds: Double = 8, until condition: (Events) -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline { if condition(self) { return true }; usleep(10_000) }
            return condition(self)
        }
    }

    private static func shell(_ script: String, _ events: Events) throws -> ClusterConsoleSessionProcess {
        try ClusterConsoleSessionProcess.start(.init(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script]),
            events: { events.record($0) })
    }

    static func sessionProcess() throws {
        // Output arrives line by line from both streams, then the real exit status.
        let failing = Events()
        let failed = try shell("echo first; echo second >&2; printf 'no newline'; exit 3", failing)
        expect(failed.processIdentifier > 0, "the session has a process")
        expect(failing.wait { $0.ending != nil }, "the process's end is reported")
        expectEqual(failing.output, ["first", "second", "no newline"], "each line of both streams, in order, an unfinished one included")
        expectEqual(failing.ending, .ended(description: "exited with status 3", clean: false), "a non-zero exit is reported as it was")
        expectEqual(failing.all.last, failing.ending, "the end comes after the last line")
        failed.interrupt()   // The process is gone: nothing is signalled.

        let clean = Events()
        _ = try shell("echo done", clean)
        expect(clean.wait { $0.ending != nil } && clean.ending == .ended(description: "exited with status 0", clean: true), "a clean exit")

        // Lines appear while the process runs, not when it ends.
        let live = Events()
        let running = try shell("trap 'echo stopping; exit 0' INT; echo ready; while :; do sleep 0.05; done", live)
        expect(live.wait { $0.output == ["ready"] }, "output is seen while the process is still running: \(live.output)")
        expect(live.ending == nil, "and it is still running")
        // The interrupt, and only the interrupt, ends it: the process's own handler runs.
        running.interrupt()
        expect(live.wait { $0.ending != nil }, "the interrupt ends the session")
        expectEqual(live.output, ["ready", "stopping"], "the process stopped itself")
        expectEqual(live.ending, .ended(description: "exited with status 0", clean: true), "and exited cleanly")

        // A process that ignores the interrupt is not escalated on: it stays, and is reported as running.
        let stubborn = Events()
        let ignoring = try shell("trap '' INT; echo deaf; sleep 1.2; echo finished", stubborn)
        expect(stubborn.wait { $0.output == ["deaf"] }, "started")
        ignoring.interrupt(); ignoring.interrupt()
        usleep(400_000)
        expect(stubborn.ending == nil, "an ignored interrupt is not followed by anything stronger")
        expect(stubborn.wait { $0.ending != nil } && stubborn.output == ["deaf", "finished"], "it ends when it chooses to: \(stubborn.output)")

        // A signal from elsewhere is reported as a signal.
        let killed = Events()
        _ = try shell("echo victim; kill -TERM $$; sleep 5", killed)
        expect(killed.wait { $0.ending != nil } && killed.ending == .ended(description: "was ended by signal 15", clean: false),
            "a signalled end names the signal: \(String(describing: killed.ending))")

        // A long line arrives whole, in pieces of a bounded size; control bytes travel as text for the renderer to neutralize.
        let long = Events()
        let limit = ClusterConsoleSessionProcess.maximumLineBytes
        _ = try shell("printf '%05000d\\n' 7; printf '%0\(limit)d\\n' 8; printf 'a\\033[2Jb\\r\\n'", long)
        expect(long.wait { $0.ending != nil }, "ended")
        expectEqual(long.output.map(\.utf8.count), [limit, limit, 5000 - 2 * limit, limit, 6], "a very long line is reported in pieces, and none of it is lost")
        expect(long.output.prefix(3).joined().hasSuffix("0007") && long.output.dropFirst(3).first?.hasSuffix("0008") == true, "the pieces are the line, in order")
        expectEqual(long.output.last, "a\u{1B}[2Jb", "a line ending is not part of the line; other bytes are kept for the renderer")
        // Progress rewritten in place arrives as lines, and empty lines stay empty lines.
        let progress = Events()
        _ = try shell("printf 'loading 1 of 3\\rloading 2 of 3\\rloading 3 of 3\\n'; printf 'first\\n\\nthird\\n'; printf 'crlf\\r\\n\\r\\nend\\r\\n'", progress)
        expect(progress.wait { $0.ending != nil }, "ended")
        expectEqual(progress.output, ["loading 1 of 3", "loading 2 of 3", "loading 3 of 3", "first", "", "third", "crlf", "", "end"],
            "a carriage return ends a line; a pair ends one line, not two")

        // The child is started the same whatever the console has done to its own signals: every signal
        // at its default, in a session of its own, so a hangup of the console's terminal does not reach it.
        var ignore = sigaction(), earlier = sigaction()
        ignore.__sigaction_u.__sa_handler = SIG_IGN
        sigaction(SIGHUP, &ignore, &earlier)
        let detached = Events()
        _ = try shell("trap 'echo trapped' HUP; kill -HUP $$; echo after; [ \"$(ps -o pgid= -p $$ | tr -d ' ')\" = \"$$\" ] && echo own-group; "
            + "case \"$(ps -o tty= -p $$ | tr -d ' ')\" in '??'|'-'|'') echo no-terminal;; esac; echo \"term=$TERM color=$NO_COLOR\"; [ -e /dev/fd/3 ] || echo no-other-descriptor", detached)
        expect(detached.wait { $0.ending != nil }, "ended")
        sigaction(SIGHUP, &earlier, nil)
        expectEqual(detached.output, ["trapped", "after", "own-group", "no-terminal", "term=dumb color=1", "no-other-descriptor"],
            "the child handles a hangup itself, leads its own session without a controlling terminal, is asked for plain text, and holds no descriptor of the console's")

        // Something that cannot be started is an error, not a session.
        var refusal = ""
        do { _ = try ClusterConsoleSessionProcess.start(.init(executable: URL(fileURLWithPath: "/nonexistent/darkbloom"), arguments: []), events: { _ in }) }
        catch { refusal = String(describing: error) }
        expect(refusal.hasPrefix("The session process could not be started: ") && refusal.contains("errno 2"), "a missing executable throws, with the reason: \(refusal)")

        // Through the loop: a failed start is shown with its error and nothing is left running.
        let operations = ScriptedOperations([ConsoleFixtures.snapshot(saved: ConsoleFixtures.savedSetup())])
        operations.launch = { events in
            try ClusterConsoleSessionProcess.start(.init(executable: URL(fileURLWithPath: "/nonexistent/darkbloom"), arguments: []), events: events)
        }
        let run = try ConsoleRun(operations)
        expect(run.terminal.wait { $0.contains("Cluster fixture-cluster") }, "drawn")
        run.terminal.send("s")
        expect(run.terminal.wait { $0.contains("y: start the session; both Macs load the model. Any other key cancels.") }, "start asks first")
        expectEqual(operations.count("launchSession"), 0, "nothing is launched by the question")
        run.terminal.send("y")
        expect(run.terminal.wait { $0.contains("06:00:00 Start session") && $0.contains("The session process started from this screen could not be started.") },
            "a failed start is shown: \(run.terminal.screen.suffix(12))")
        run.terminal.send("q")
        guard case .success(let exit)? = run.end() else { return expect(false, "did not close") }
        expectEqual(exit, .init(code: 0, farewell: []), "with nothing running, q closes at once")
    }

    /// Start and stop through the console, against the real installed session
    /// with the fabricated owner and worker children. Not a real pair: no
    /// model, no GPU, no second Mac, no network.
    static func sessionThroughInstalledFixtures() throws {
        let root = scratch.appendingPathComponent("stand-in"), statusFile = scratch.appendingPathComponent("stand-in-status.json")
        let operations = ScriptedOperations([ConsoleFixtures.snapshot(saved: ConsoleFixtures.savedSetup())])
        let standIn = sessionStandIn, arguments = [probe.path, owner.path, worker.path, root.path, statusFile.path]
        operations.launch = { events in
            try ClusterConsoleSessionProcess.start(.init(executable: standIn, arguments: arguments), events: events)
        }
        // The observation the console polls: the stand-in's published status,
        // through the same strict reader `cluster status` uses.
        operations.status = {
            do {
                let bytes = try Data(contentsOf: statusFile)
                let binding = try JSONDecoder().decode(ClusterLiveStatus.self, from: bytes).binding
                let live = try ClusterStatusCodec.decode(bytes, nonce: ConsoleSessionStandInNonce.value, binding: binding,
                    authenticationConfigured: false, port: 8000)
                return ConsoleFixtures.diagnostics(link: ConsoleFixtures.readyLink, live: live, saved: binding)
            } catch {
                return ConsoleFixtures.diagnostics(link: ConsoleFixtures.readyLink, observation: "No status was read: \(error)")
            }
        }
        let run = try ConsoleRun(operations, columns: 132, rows: 90)
        let pty = run.terminal, before = run.initialMode
        expect(pty.wait { $0.contains("No session was started from this screen.") }, "drawn with no session")
        pty.send("s")
        expect(pty.wait { $0.contains("y: start the session") }, "start asks first")
        pty.send("y")
        expect(pty.wait(20) { $0.contains("started from this screen, is running") }, "the session process is running")
        expect(pty.wait(20) { $0.contains("both ranks ready") }, "the process's own output is shown: \(pty.screen.suffix(20))")
        // Readiness is the leader's report of both ranks, not the passage of time.
        expect(pty.wait(20) { $0.contains("Local leader: host serving, session ready, ready, admission available") },
            "the leader's status is shown once it reports serving: \(pty.screen.filter { $0.contains("Local leader") })")
        let serving = pty.screenText
        expect(serving.contains("Rank 0, peer-0: localPipes; native ready;") && serving.contains("Rank 1, peer-1: authenticatedSSH; native ready;"),
            "each rank's readiness comes from its worker")
        expect(serving.contains("admissions remaining 16"), "admissions come from the session")
        expect(serving.contains("Rank 0, peer-0: admitted and loaded, by the leader's status;")
            && serving.contains("Rank 1, peer-1: admitted and loaded, by the leader's status;"),
            "per-rank admission is what each worker reported, read from the leader's status: \(pty.screen.filter { $0.contains("Rank") })")

        // A second start while it runs is refused; quitting asks first.
        pty.send("s")
        expect(pty.wait { $0.contains("already running") }, "no second session")
        expectEqual(operations.count("launchSession"), 1, "one launch")
        pty.send("q")
        expect(pty.wait { $0.contains("Press q again to stop it") }, "q asks before stopping a session")
        pty.send([0x1B])
        usleep(400_000)
        expect(run.isRunning, "Escape stays")

        // Stop: the interrupt, then the session's own cooperative stop, then its exit status.
        pty.send("x")
        expect(pty.wait { $0.contains("was asked to stop and has not ended") || $0.contains("exited with status") }, "stopping is shown as stopping")
        expect(pty.wait(30) { $0.contains("The session process started from this screen exited with status 0.") },
            "the session released both owners and exited cleanly: \(pty.screen.filter { $0.contains("session") })")
        expect(pty.wait { $0.contains("06:00:00 Session ended") && $0.contains("session released") }, "its last lines are listed with its end")
        expect(pty.wait(10) { $0.contains("Local leader: host stopped") || $0.contains("Local leader: not observed") }, "the status follows the session down")
        // Nothing is left behind: no owner or worker of the stand-in is still running.
        let leftovers = Process()
        leftovers.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        leftovers.arguments = ["-f", root.path]
        leftovers.standardOutput = FileHandle.nullDevice
        try leftovers.run(); leftovers.waitUntilExit()
        expectEqual(leftovers.terminationStatus, 1, "no process of the stand-in session is left running")
        pty.send("q")
        guard case .success(let exit)? = run.end() else { return expect(false, "did not close") }
        expectEqual(exit, .init(code: 0, farewell: []), "closes at once after the session ended")
        usleep(50_000)
        expect(sameMode(pty.mode, before), "the terminal is restored")

        // Quitting with a session running: q, q stops it and the screen closes when it has ended.
        let secondRoot = scratch.appendingPathComponent("stand-in-2"), secondStatus = scratch.appendingPathComponent("stand-in-2-status.json")
        let again = ScriptedOperations([ConsoleFixtures.snapshot(saved: ConsoleFixtures.savedSetup())])
        let secondArguments = [probe.path, owner.path, worker.path, secondRoot.path, secondStatus.path]
        again.launch = { events in try ClusterConsoleSessionProcess.start(.init(executable: standIn, arguments: secondArguments), events: events) }
        let leaving = try ConsoleRun(again, columns: 132, rows: 60)
        expect(leaving.terminal.wait { $0.contains("No session was started") }, "drawn")
        leaving.terminal.send("s")
        expect(leaving.terminal.wait { $0.contains("y: start the session") }, "start asks first")
        leaving.terminal.send("y")
        expect(leaving.terminal.wait(20) { $0.contains("both ranks ready") }, "second session ready")
        leaving.terminal.send("q")
        expect(leaving.terminal.wait { $0.contains("Press q again to stop it") }, "q asks before stopping the session")
        leaving.terminal.send("q")
        guard case .success(let closed)? = leaving.end(within: 30) else { return expect(false, "q q did not stop the session and close") }
        expectEqual(closed, .init(code: 0, farewell: []), "the screen closed once the session had ended")
        expect((try? String(contentsOf: secondStatus, encoding: .utf8))?.contains("\"hostPhase\":\"stopped\"") == true,
            "the session stopped through its own stop, not by being killed")
    }
}

enum ConsoleSessionStandInNonce {
    /// The nonce the stand-in publishes its status under.
    static let value = "00000000-0000-4000-8000-000000000001"
}
