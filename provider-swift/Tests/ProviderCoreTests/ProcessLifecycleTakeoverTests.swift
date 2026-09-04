// Copyright © 2026 Eigen Labs.
//
// Single-instance lock takeover now that SIGTERM drains instead of killing:
// a predecessor that is already draining (its daemon-state file says so) must
// not receive a second SIGTERM — that is the trap's "exit now" path, which
// cuts the drain and loses the goingAway frame — and a predecessor that is
// not draining gets exactly one SIGTERM and the full drain bound before any
// SIGKILL. Live-isolated: real child shells that trap TERM, a temp PID file,
// a temp daemon-state file.

import Foundation
import Testing

@testable import ProviderCore

/// A stand-in provider: `sh` that records every TERM it receives in `log`,
/// then "drains" for a moment and exits 0. `ignoresTerm` models a wedged
/// process that never exits on its own.
private final class FakePredecessor {
    let process = Process()
    let log: URL

    init(ignoresTerm: Bool = false) throws {
        log = FileManager.default.temporaryDirectory
            .appendingPathComponent("predecessor-\(UUID().uuidString).log")
        let trap = ignoresTerm
            ? "trap 'echo TERM >> \"$0\"' TERM"
            : "trap 'echo TERM >> \"$0\"; sleep 0.5; exit 0' TERM"
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c", "\(trap); echo ready > \"$0\"; while :; do sleep 0.05; done", log.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, !lines.contains("ready") {
            Thread.sleep(forTimeInterval: 0.02)
        }
        try #require(lines.contains("ready"), "fake predecessor never came up")
    }

    var pid: Int32 { process.processIdentifier }

    var lines: [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    var termsReceived: Int { lines.filter { $0 == "TERM" }.count }

    func cleanup() {
        if process.isRunning { process.terminate(); kill(pid, SIGKILL) }
        try? FileManager.default.removeItem(at: log)
    }
}

private func tempFile(_ name: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("\(name)-\(UUID().uuidString)")
}

private func drainingState(pid: Int32) -> DaemonState {
    DaemonState(
        pid: pid, version: ProviderCore.version,
        writtenAt: Date().timeIntervalSince1970, startedAt: Date().timeIntervalSince1970,
        shuttingDown: true)
}

@Suite("ProcessLifecycle predecessor takeover", .serialized)
struct ProcessLifecycleTakeoverTests {

    /// launchd (or an operator) already SIGTERM'd the old daemon and it is
    /// draining: the newcomer waits for it and never signals it again.
    @Test("a draining predecessor gets no second SIGTERM and is waited for")
    func drainingPredecessorIsNotSignalled() throws {
        let old = try FakePredecessor()
        defer { old.cleanup() }
        let pidFile = tempFile("pid")
        let stateFile = tempFile("state")
        defer {
            ProcessLifecycle.releaseSingleInstanceLock(at: pidFile)
            try? FileManager.default.removeItem(at: stateFile)
        }
        try "\(old.pid)\n".write(to: pidFile, atomically: true, encoding: .utf8)
        // The old daemon's own drain: it stamps shuttingDown and drains.
        DaemonStateFile.write(drainingState(pid: old.pid), to: stateFile)
        kill(old.pid, SIGTERM)

        let started = Date()
        try ProcessLifecycle.acquireSingleInstanceLock(
            at: pidFile, predecessorExitBound: 30, daemonStateFile: stateFile)
        let waited = Date().timeIntervalSince(started)

        old.process.waitUntilExit()
        #expect(old.termsReceived == 1, "the newcomer re-signalled a draining predecessor")
        #expect(old.process.terminationReason == .exit)
        #expect(old.process.terminationStatus == 0, "the predecessor was killed, not drained")
        #expect(waited >= 0.4, "did not wait for the predecessor to exit (\(waited)s)")
        let written = try String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(written == "\(ProcessInfo.processInfo.processIdentifier)")
    }

    /// No drain in progress: one SIGTERM, then the drain bound — never the
    /// old 2 s SIGKILL.
    @Test("an idle predecessor gets exactly one SIGTERM and drains to a clean exit")
    func idlePredecessorIsSignalledOnce() throws {
        let old = try FakePredecessor()
        defer { old.cleanup() }
        let pidFile = tempFile("pid")
        let stateFile = tempFile("state")  // absent: nothing says it is draining
        defer { ProcessLifecycle.releaseSingleInstanceLock(at: pidFile) }
        try "\(old.pid)\n".write(to: pidFile, atomically: true, encoding: .utf8)

        try ProcessLifecycle.acquireSingleInstanceLock(
            at: pidFile, predecessorExitBound: 30, daemonStateFile: stateFile)

        old.process.waitUntilExit()
        #expect(old.termsReceived == 1)
        #expect(old.process.terminationReason == .exit)
        #expect(old.process.terminationStatus == 0, "SIGKILLed inside the drain bound")
    }

    /// A stale draining record from a DIFFERENT pid proves nothing about the
    /// live predecessor: it is signalled like an idle one.
    @Test("a draining record for another pid does not suppress the SIGTERM")
    func foreignDrainingRecordIsIgnored() throws {
        let old = try FakePredecessor()
        defer { old.cleanup() }
        let pidFile = tempFile("pid")
        let stateFile = tempFile("state")
        defer {
            ProcessLifecycle.releaseSingleInstanceLock(at: pidFile)
            try? FileManager.default.removeItem(at: stateFile)
        }
        try "\(old.pid)\n".write(to: pidFile, atomically: true, encoding: .utf8)
        DaemonStateFile.write(drainingState(pid: old.pid &+ 100_000), to: stateFile)

        try ProcessLifecycle.acquireSingleInstanceLock(
            at: pidFile, predecessorExitBound: 30, daemonStateFile: stateFile)
        old.process.waitUntilExit()
        #expect(old.termsReceived == 1)
        #expect(old.process.terminationStatus == 0)
    }

    /// Past the bound the predecessor is wedged (it never honoured the
    /// SIGTERM): SIGKILL remains the last resort.
    @Test("a predecessor that ignores SIGTERM is SIGKILLed only past the bound")
    func wedgedPredecessorIsKilledPastBound() throws {
        let old = try FakePredecessor(ignoresTerm: true)
        defer { old.cleanup() }
        let pidFile = tempFile("pid")
        defer { ProcessLifecycle.releaseSingleInstanceLock(at: pidFile) }
        try "\(old.pid)\n".write(to: pidFile, atomically: true, encoding: .utf8)

        let started = Date()
        try ProcessLifecycle.acquireSingleInstanceLock(
            at: pidFile, predecessorExitBound: 1, daemonStateFile: tempFile("state"))
        let waited = Date().timeIntervalSince(started)
        old.process.waitUntilExit()
        #expect(old.termsReceived == 1)
        #expect(old.process.terminationReason == .uncaughtSignal)
        #expect(waited >= 1, "SIGKILL landed before the bound (\(waited)s)")
    }

    @Test("the default bound covers launchd's ExitTimeOut for the old job")
    func defaultBoundCoversExitTimeOut() {
        #expect(ProcessLifecycle.defaultPredecessorExitBound
            >= TimeInterval(LaunchAgent.exitTimeOutSeconds))
    }
}
