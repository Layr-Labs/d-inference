import Foundation
import Testing

@testable import ProviderCore

@Suite("ProcessLifecycle PID lock")
struct ProcessLifecyclePIDLockTests {

    private func tempPIDFile() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test-darkbloom-pid-\(UUID().uuidString).pid")
    }

    @Test("acquire writes our PID")
    func acquireWritesPID() throws {
        let pidFile = tempPIDFile()
        defer { ProcessLifecycle.releaseSingleInstanceLock(at: pidFile) }

        try ProcessLifecycle.acquireSingleInstanceLock(at: pidFile)
        let written = try String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(written == "\(ProcessInfo.processInfo.processIdentifier)")
    }

    @Test("release deletes the PID file")
    func releaseDeletesFile() throws {
        let pidFile = tempPIDFile()
        try ProcessLifecycle.acquireSingleInstanceLock(at: pidFile)
        #expect(FileManager.default.fileExists(atPath: pidFile.path))

        ProcessLifecycle.releaseSingleInstanceLock(at: pidFile)
        #expect(!FileManager.default.fileExists(atPath: pidFile.path))
    }

    @Test("acquire over a stale PID file overwrites it")
    func acquireOverStalePIDOverwrites() throws {
        let pidFile = tempPIDFile()
        defer { ProcessLifecycle.releaseSingleInstanceLock(at: pidFile) }

        // Write a clearly-stale PID: 1 (init) is alive, but won't be us.
        try "999999\n".write(to: pidFile, atomically: true, encoding: .utf8)
        // 999999 won't be alive -- kill(999999, 0) returns ESRCH -- so the
        // acquire path skips the kill and just overwrites.
        try ProcessLifecycle.acquireSingleInstanceLock(at: pidFile)

        let written = try String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(written == "\(ProcessInfo.processInfo.processIdentifier)")
    }

    @Test("acquire is idempotent for the running process")
    func acquireIdempotent() throws {
        let pidFile = tempPIDFile()
        defer { ProcessLifecycle.releaseSingleInstanceLock(at: pidFile) }

        try ProcessLifecycle.acquireSingleInstanceLock(at: pidFile)
        try ProcessLifecycle.acquireSingleInstanceLock(at: pidFile)
        // Should not throw, file should still contain our PID.
        let written = try String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(written == "\(ProcessInfo.processInfo.processIdentifier)")
    }
}

/// Tests for `ProcessLifecycle` process-signalling helpers.
@Suite("ProcessLifecycle graceful stop")
struct ProcessLifecycleGracefulStopTests {

    @Test("processIsAlive returns true for the current process")
    func currentProcessIsAlive() {
        let pid = ProcessInfo.processInfo.processIdentifier
        #expect(ProcessLifecycle.processIsAlive(pid))
    }

    @Test("processIsAlive returns false for a clearly non-existent PID")
    func nonExistentProcessIsNotAlive() {
        // PID 1 is launchd on macOS and is alive, so pick an implausibly high
        // PID that cannot exist in a normal user session.
        #expect(!ProcessLifecycle.processIsAlive(999_999))
    }

    @Test("stopProcessGracefully returns notRunning for a dead PID")
    func gracefulStopReturnsNotRunningForDeadPid() async {
        let outcome = await ProcessLifecycle.stopProcessGracefully(pid: 999_999, timeout: 1.0)
        #expect(outcome == .notRunning)
    }

    @Test("stopProcessGracefully rejects nonpositive PIDs")
    func gracefulStopRejectsNonpositivePids() async {
        #expect(await ProcessLifecycle.stopProcessGracefully(pid: 0, timeout: 1.0) == .notRunning)
        #expect(await ProcessLifecycle.stopProcessGracefully(pid: -1, timeout: 1.0) == .notRunning)
    }

    @Test("stopProcessGracefully can stop a spawned subprocess")
    func gracefulStopStopsSubprocess() async throws {
        // Spawn a long-lived child process (`sleep`) that we can gracefully stop.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["300"]
        try process.run()
        let pid = Int32(process.processIdentifier)

        // Reap the child as soon as it exits. `processIsAlive` is `kill(pid, 0)`,
        // which still succeeds for an un-reaped zombie — so without an active
        // `waitpid`, a SIGTERM'd `/bin/sleep` would look "alive" for the full
        // timeout and `stopProcessGracefully` would escalate to SIGKILL and
        // report `.forceKilled`. Blocking a background task on `waitUntilExit()`
        // keeps a reaper running so liveness reflects the real process state.
        let reaper = Task.detached { process.waitUntilExit() }
        defer { reaper.cancel() }

        // Give the kernel a moment to register the process.
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(ProcessLifecycle.processIsAlive(pid))

        let outcome = await ProcessLifecycle.stopProcessGracefully(pid: pid, timeout: 2.0)
        await reaper.value

        #expect(outcome == .stoppedGracefully)
        #expect(!ProcessLifecycle.processIsAlive(pid))
    }

    @Test("stopProcessGracefully reports force kill when SIGTERM is ignored")
    func gracefulStopReportsForceKill() async throws {
        // Spawn a shell that ignores SIGTERM and then execs sleep, so the helper
        // has to escalate to SIGKILL. `trap '' TERM` sets SIGTERM to ignored,
        // and `exec` preserves the ignored disposition across the replacement.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "trap '' TERM; exec /bin/sleep 300"]
        try process.run()
        let pid = Int32(process.processIdentifier)

        // Reap the child once SIGKILL lands so the post-kill liveness check sees
        // ESRCH instead of a lingering zombie (see the graceful-stop test above).
        let reaper = Task.detached { process.waitUntilExit() }
        defer { reaper.cancel() }

        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(ProcessLifecycle.processIsAlive(pid))

        let outcome = await ProcessLifecycle.stopProcessGracefully(pid: pid, timeout: 0.5)
        await reaper.value

        #expect(outcome == .forceKilled(pid))
        #expect(!ProcessLifecycle.processIsAlive(pid))
    }
}
