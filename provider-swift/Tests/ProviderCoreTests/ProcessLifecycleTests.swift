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

    @Test("stopProcessGracefully can stop a spawned subprocess")
    func gracefulStopStopsSubprocess() async throws {
        // Spawn a long-lived child process (`sleep`) that we can gracefully stop.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["300"]
        try process.run()
        let pid = Int32(process.processIdentifier)

        // Give the kernel a moment to register the process.
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(ProcessLifecycle.processIsAlive(pid))

        let outcome = await ProcessLifecycle.stopProcessGracefully(pid: pid, timeout: 2.0)

        #expect(outcome == .stoppedGracefully)
        #expect(!ProcessLifecycle.processIsAlive(pid))
    }
}
