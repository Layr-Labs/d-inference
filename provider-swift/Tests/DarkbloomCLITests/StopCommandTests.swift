import ArgumentParser
import Foundation
import Testing
@testable import darkbloom
@testable import ProviderCore

// MARK: - Flag parsing & registration

@Suite("Stop command flags")
struct StopCommandFlagTests {
    @Test("stop is registered under Darkbloom and parses with defaults")
    func stopParsesDefaults() throws {
        let cmd = try Darkbloom.parseAsRoot(["stop"]) as? Stop
        #expect(cmd != nil)
        #expect(cmd?.uninstall == false)
        #expect(cmd?.force == false)
        #expect(cmd?.timeout == 60)
    }

    @Test("stop --force parses")
    func stopForce() throws {
        let cmd = try Stop.parse(["--force"])
        #expect(cmd.force == true)
        #expect(cmd.timeout == 60)
        #expect(cmd.uninstall == false)
    }

    @Test("stop --timeout custom value parses")
    func stopTimeout() throws {
        let cmd = try Stop.parse(["--timeout", "120"])
        #expect(cmd.timeout == 120)
        #expect(cmd.force == false)
    }

    @Test("stop --timeout 0 parses (immediate refuse mode)")
    func stopTimeoutZero() throws {
        let cmd = try Stop.parse(["--timeout", "0"])
        #expect(cmd.timeout == 0)
    }

    @Test("stop --uninstall parses")
    func stopUninstall() throws {
        let cmd = try Stop.parse(["--uninstall"])
        #expect(cmd.uninstall == true)
        #expect(cmd.force == false)
        #expect(cmd.timeout == 60)
    }

    @Test("stop --force --timeout --uninstall combine")
    func stopCombined() throws {
        let cmd = try Stop.parse(["--force", "--timeout", "0", "--uninstall"])
        #expect(cmd.force == true)
        #expect(cmd.timeout == 0)
        #expect(cmd.uninstall == true)
    }

    @Test("stop --timeout negative fails validation")
    func stopNegativeTimeoutFailsValidation() throws {
        // `parse` runs `validate()` itself and wraps the ValidationError in
        // a CommandError, so check the rendered message end-to-end. The
        // attached `=` form is required: a bare `-5` after `--timeout` is
        // tokenised as the short option `-5` and never reaches validate().
        for argv in [["--timeout=-5"], ["--timeout=-1"]] {
            do {
                _ = try Stop.parse(argv)
                Issue.record("expected \(argv) to fail validation")
            } catch {
                #expect(Stop.message(for: error).contains("--timeout must be >= 0"))
            }
        }

        // validate() on its own surfaces the ValidationError directly.
        var cmd = try Stop.parse(["--timeout", "0"])
        cmd.timeout = -5
        do {
            try cmd.validate()
            Issue.record("expected validate() to reject a negative timeout")
        } catch let error as ValidationError {
            #expect(error.message == "--timeout must be >= 0")
        }
    }

    @Test("stop help contains new flags and guard discussion")
    func stopHelp() {
        #expect(Stop.configuration.abstract.contains("Stop"))
        #expect(Stop.configuration.discussion.contains("in-flight"))
        #expect(Stop.configuration.discussion.contains("--force"))
        #expect(Stop.configuration.discussion.contains("--timeout"))
    }

    @Test("stop configuration command name")
    func stopCommandName() {
        // AsyncParsableCommand default commandName is type name lowercased.
        // Verify the registration is correct by round-tripping through Darkbloom.
        #expect(throws: Never.self) {
            _ = try Darkbloom.parseAsRoot(["stop"])
        }
        #expect(throws: (any Error).self) {
            _ = try Darkbloom.parseAsRoot(["nonexistent-stop-xyz"])
        }
    }
}

// MARK: - Drain guard pure logic

@Suite("Stop drain guard shouldWait")
struct StopDrainGuardTests {
    private func state(
        pid: Int32 = 12345,
        inferenceActive: Bool,
        writtenAt: Double,
        now: Double
    ) -> DaemonState {
        DaemonState(
            pid: pid,
            version: "0.8.0",
            writtenAt: writtenAt,
            startedAt: writtenAt - 600,
            warmModels: [],
            inferenceActive: inferenceActive
        )
    }

    @Test("returns false when state is nil")
    func nilState() {
        #expect(StopDrainGuard.shouldWait(state: nil, now: 1000) == false)
    }

    @Test("returns false when not active even if fresh and pid alive")
    func notActive() {
        let pid = Int32(ProcessInfo.processInfo.processIdentifier)
        let now = Date().timeIntervalSince1970
        let s = state(pid: pid, inferenceActive: false, writtenAt: now, now: now)
        #expect(StopDrainGuard.shouldWait(state: s, now: now) == false)
    }

    @Test("returns false when stale even if active and pid alive")
    func stale() {
        let pid = Int32(ProcessInfo.processInfo.processIdentifier)
        let now = 10_000.0
        // 100s old > 90s stale threshold
        let s = state(pid: pid, inferenceActive: true, writtenAt: now - 100, now: now)
        #expect(StopDrainGuard.shouldWait(state: s, now: now) == false)
        // Fresh (30s) should be waitable if active and pid alive
        let fresh = state(pid: pid, inferenceActive: true, writtenAt: now - 30, now: now)
        #expect(StopDrainGuard.shouldWait(state: fresh, now: now) == true)
    }

    @Test("stale boundary: 90s not stale, 91s stale")
    func staleBoundary() {
        let pid = Int32(ProcessInfo.processInfo.processIdentifier)
        let now = 10_000.0
        // isStale is > 90, so 90s is fresh, 91s is stale
        let at90 = state(pid: pid, inferenceActive: true, writtenAt: now - 90, now: now)
        #expect(StopDrainGuard.shouldWait(state: at90, now: now) == true)
        let at91 = state(pid: pid, inferenceActive: true, writtenAt: now - 91, now: now)
        #expect(StopDrainGuard.shouldWait(state: at91, now: now) == false)
    }

    @Test("returns false when pid not alive")
    func pidNotAlive() {
        let now = Date().timeIntervalSince1970
        // Use a pid very unlikely to be alive (Int32.max)
        let s = state(pid: Int32.max, inferenceActive: true, writtenAt: now, now: now)
        #expect(StopDrainGuard.shouldWait(state: s, now: now) == false)
    }

    @Test("returns false for pid 0 and negative pid")
    func invalidPid() {
        let now = Date().timeIntervalSince1970
        for pid: Int32 in [0, -1, -999] {
            let s = state(pid: pid, inferenceActive: true, writtenAt: now, now: now)
            #expect(StopDrainGuard.shouldWait(state: s, now: now) == false, "pid \(pid) should be not alive")
        }
    }

    @Test("returns true when fresh, active, and pid alive")
    func shouldWaitTrue() {
        let pid = Int32(ProcessInfo.processInfo.processIdentifier)
        let now = Date().timeIntervalSince1970
        let s = state(pid: pid, inferenceActive: true, writtenAt: now, now: now)
        #expect(StopDrainGuard.shouldWait(state: s, now: now) == true)
    }

    @Test("not active wins over fresh pid alive")
    func notActiveOverridesFresh() {
        let pid = Int32(ProcessInfo.processInfo.processIdentifier)
        let now = Date().timeIntervalSince1970
        // Even with fresh timestamp and alive pid, inactive => false
        let s = state(pid: pid, inferenceActive: false, writtenAt: now - 1, now: now)
        #expect(StopDrainGuard.shouldWait(state: s, now: now) == false)
    }
}

// MARK: - waitForDrain core with injected dependencies

@Suite("Stop waitForDrain")
struct StopWaitForDrainTests {
    private func makeState(
        pid: Int32 = Int32(ProcessInfo.processInfo.processIdentifier),
        inferenceActive: Bool,
        age: Double = 0
    ) -> DaemonState {
        let now = Date().timeIntervalSince1970
        return DaemonState(
            pid: pid,
            version: "0.8.0",
            writtenAt: now - age,
            startedAt: now - 600,
            warmModels: [],
            inferenceActive: inferenceActive
        )
    }

    @Test("no-ops when no initial state")
    func noInitialState() async throws {
        var sleeps = 0
        try await Stop.waitForDrain(
            timeoutSeconds: 5,
            readState: { nil },
            sleep: { sleeps += 1 },
            now: { Date().timeIntervalSince1970 }
        )
        #expect(sleeps == 0)
    }

    @Test("no-ops when not active")
    func notActive() async throws {
        let state = makeState(inferenceActive: false)
        var sleeps = 0
        try await Stop.waitForDrain(
            timeoutSeconds: 5,
            readState: { state },
            sleep: { sleeps += 1 },
            now: { Date().timeIntervalSince1970 }
        )
        #expect(sleeps == 0)
    }

    @Test("no-ops when initial state stale")
    func staleInitial() async throws {
        let pid = Int32(ProcessInfo.processInfo.processIdentifier)
        let now = Date().timeIntervalSince1970
        let stale = DaemonState(pid: pid, version: "0.8.0", writtenAt: now - 100, startedAt: now - 600, warmModels: [], inferenceActive: true)
        var sleeps = 0
        try await Stop.waitForDrain(
            timeoutSeconds: 5,
            readState: { stale },
            sleep: { sleeps += 1 },
            now: { now }
        )
        #expect(sleeps == 0)
    }

    @Test("no-ops when pid not alive")
    func pidNotAlive() async throws {
        let now = Date().timeIntervalSince1970
        let dead = DaemonState(pid: Int32.max, version: "0.8.0", writtenAt: now, startedAt: now - 600, warmModels: [], inferenceActive: true)
        var sleeps = 0
        try await Stop.waitForDrain(
            timeoutSeconds: 5,
            readState: { dead },
            sleep: { sleeps += 1 },
            now: { now }
        )
        #expect(sleeps == 0)
    }

    @Test("waits until active becomes inactive")
    func waitsUntilInactive() async throws {
        // Simulate: active for 2 polls, then inactive
        var calls = 0
        let pid = Int32(ProcessInfo.processInfo.processIdentifier)
        let nowBase = Date().timeIntervalSince1970
        // Use a mutable clock that advances 1s per sleep
        var now = nowBase
        let readState: () -> DaemonState? = {
            calls += 1
            // First 2 reads: active, then inactive. Note waitForDrain reads once before loop + each iteration
            // Calls sequence: 1=initial active, 2=after 1st sleep active, 3=after 2nd sleep inactive
            if calls <= 2 {
                return DaemonState(pid: pid, version: "0.8.0", writtenAt: now, startedAt: now - 600, warmModels: [], inferenceActive: true)
            } else {
                return DaemonState(pid: pid, version: "0.8.0", writtenAt: now, startedAt: now - 600, warmModels: [], inferenceActive: false)
            }
        }
        var sleeps = 0
        try await Stop.waitForDrain(
            timeoutSeconds: 5,
            readState: readState,
            sleep: {
                sleeps += 1
                now += 1
            },
            now: { now }
        )
        #expect(sleeps == 2)
    }

    @Test("exits early when state becomes stale mid-wait")
    func staleMidWait() async throws {
        var calls = 0
        let pid = Int32(ProcessInfo.processInfo.processIdentifier)
        var now = Date().timeIntervalSince1970
        let readState: () -> DaemonState? = {
            calls += 1
            if calls == 1 {
                return DaemonState(pid: pid, version: "0.8.0", writtenAt: now, startedAt: now - 600, warmModels: [], inferenceActive: true)
            }
            // Second read: stale (100s old) even though active — should be treated as drained
            return DaemonState(pid: pid, version: "0.8.0", writtenAt: now - 100, startedAt: now - 700, warmModels: [], inferenceActive: true)
        }
        var sleeps = 0
        try await Stop.waitForDrain(
            timeoutSeconds: 5,
            readState: readState,
            sleep: { sleeps += 1; now += 1 },
            now: { now }
        )
        // Should have slept once then seen stale and returned
        #expect(sleeps == 1)
    }

    @Test("exits early when pid dies mid-wait")
    func pidDiesMidWait() async throws {
        var calls = 0
        let pidAlive = Int32(ProcessInfo.processInfo.processIdentifier)
        var now = Date().timeIntervalSince1970
        let readState: () -> DaemonState? = {
            calls += 1
            if calls == 1 {
                return DaemonState(pid: pidAlive, version: "0.8.0", writtenAt: now, startedAt: now - 600, warmModels: [], inferenceActive: true)
            }
            // Second read: pid dead
            return DaemonState(pid: Int32.max, version: "0.8.0", writtenAt: now, startedAt: now - 600, warmModels: [], inferenceActive: true)
        }
        var sleeps = 0
        try await Stop.waitForDrain(
            timeoutSeconds: 5,
            readState: readState,
            sleep: { sleeps += 1; now += 1 },
            now: { now }
        )
        #expect(sleeps == 1)
    }

    @Test("throws on timeout when still active")
    func timeoutThrows() async throws {
        let pid = Int32(ProcessInfo.processInfo.processIdentifier)
        var now = Date().timeIntervalSince1970
        let state = DaemonState(pid: pid, version: "0.8.0", writtenAt: now, startedAt: now - 600, warmModels: [], inferenceActive: true)
        var threw = false
        do {
            try await Stop.waitForDrain(
                timeoutSeconds: 2,
                readState: { state },
                sleep: { now += 1 },
                now: { now }
            )
        } catch {
            threw = true
        }
        #expect(threw == true)
    }

    @Test("succeeds when drains just before deadline")
    func drainsBeforeDeadline() async throws {
        let pid = Int32(ProcessInfo.processInfo.processIdentifier)
        var now = Date().timeIntervalSince1970
        var calls = 0
        let readState: () -> DaemonState? = {
            calls += 1
            // Active for timeout-1 sleeps, then inactive on last check
            if calls < 3 {
                return DaemonState(pid: pid, version: "0.8.0", writtenAt: now, startedAt: now - 600, warmModels: [], inferenceActive: true)
            }
            return DaemonState(pid: pid, version: "0.8.0", writtenAt: now, startedAt: now - 600, warmModels: [], inferenceActive: false)
        }
        // timeout 2: deadline = now+2, loop runs while now < deadline (2 iterations max)
        try await Stop.waitForDrain(
            timeoutSeconds: 2,
            readState: readState,
            sleep: { now += 1 },
            now: { now }
        )
        // Should not throw
    }

    @Test("timeout 0 with active throws immediately")
    func zeroTimeoutThrows() async throws {
        let pid = Int32(ProcessInfo.processInfo.processIdentifier)
        let now = Date().timeIntervalSince1970
        let state = DaemonState(pid: pid, version: "0.8.0", writtenAt: now, startedAt: now - 600, warmModels: [], inferenceActive: true)
        var threw = false
        var sleeps = 0
        do {
            try await Stop.waitForDrain(
                timeoutSeconds: 0,
                readState: { state },
                sleep: { sleeps += 1 },
                now: { now }
            )
        } catch {
            threw = true
        }
        #expect(threw == true)
        #expect(sleeps == 0)
    }

    @Test("timeout 0 with inactive does not throw")
    func zeroTimeoutWithInactiveDoesNotThrow() async throws {
        let pid = Int32(ProcessInfo.processInfo.processIdentifier)
        let now = Date().timeIntervalSince1970
        let state = DaemonState(pid: pid, version: "0.8.0", writtenAt: now, startedAt: now - 600, warmModels: [], inferenceActive: false)
        var sleeps = 0
        try await Stop.waitForDrain(
            timeoutSeconds: 0,
            readState: { state },
            sleep: { sleeps += 1 },
            now: { now }
        )
        #expect(sleeps == 0)
    }

    @Test("returns immediately when state becomes nil (daemon stopped)")
    func stateBecomesNil() async throws {
        var calls = 0
        let pid = Int32(ProcessInfo.processInfo.processIdentifier)
        var now = Date().timeIntervalSince1970
        let readState: () -> DaemonState? = {
            calls += 1
            if calls == 1 {
                return DaemonState(pid: pid, version: "0.8.0", writtenAt: now, startedAt: now - 600, warmModels: [], inferenceActive: true)
            }
            return nil
        }
        var sleeps = 0
        try await Stop.waitForDrain(
            timeoutSeconds: 5,
            readState: readState,
            sleep: { sleeps += 1; now += 1 },
            now: { now }
        )
        #expect(sleeps == 1)
    }

    @Test("throws when sleep is cancelled (Ctrl-C)")
    func sleepCancellationThrows() async throws {
        let pid = Int32(ProcessInfo.processInfo.processIdentifier)
        let now = Date().timeIntervalSince1970
        let state = DaemonState(pid: pid, version: "0.8.0", writtenAt: now, startedAt: now - 600, warmModels: [], inferenceActive: true)
        var threw = false
        struct CancelError: Error {}
        do {
            try await Stop.waitForDrain(
                timeoutSeconds: 5,
                readState: { state },
                sleep: { throw CancelError() },
                now: { now }
            )
        } catch {
            threw = true
            #expect(error is CancelError || "\(type(of: error))".contains("ExitCode"))
        }
        #expect(threw == true)
    }
}
