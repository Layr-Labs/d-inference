/// ProcessLifecycle -- single-instance enforcement and OS-level helpers
/// that every long-running provider process needs (PID file, caffeinate
/// sleep prevention).
///
/// On `darkbloom serve` these helpers write a PID file, kill any existing
/// provider that matches, and spawn `caffeinate -s -i -w <pid>` so the
/// system doesn't sleep mid-inference.

import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum ProcessLifecycle {

    /// Default PID file location: `~/.darkbloom/provider.pid`.
    /// Override with `DARKBLOOM_PID_FILE` env var (useful for multi-instance testing).
    public static func defaultPIDFile() -> URL {
        if let override = ProcessInfo.processInfo.environment["DARKBLOOM_PID_FILE"] {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".darkbloom/provider.pid")
    }

    /// Acquire the single-instance lock. If an older provider is already
    /// running, send it SIGTERM, wait briefly, then SIGKILL if it didn't
    /// exit. Always writes our own PID to the file at the end.
    ///
    /// Returns the path of the PID file on success, throws on inability to
    /// write.
    @discardableResult
    public static func acquireSingleInstanceLock(
        at pidFile: URL = ProcessLifecycle.defaultPIDFile(),
        terminationGracePeriod: TimeInterval = 2.0
    ) throws -> URL {
        let myPID = ProcessInfo.processInfo.processIdentifier
        let fm = FileManager.default

        // Best-effort kill of any previous instance.
        if let existing = readPID(at: pidFile),
           existing != myPID,
           processIsAlive(existing)
        {
            sendSignal(SIGTERM, to: existing)
            // Spin-wait up to `terminationGracePeriod` for graceful shutdown.
            let deadline = Date().addingTimeInterval(terminationGracePeriod)
            while Date() < deadline, processIsAlive(existing) {
                Thread.sleep(forTimeInterval: 0.1)
            }
            if processIsAlive(existing) {
                sendSignal(SIGKILL, to: existing)
            }
        }

        // Make the parent directory.
        let parent = pidFile.deletingLastPathComponent()
        try fm.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )

        // Write our PID.
        try "\(myPID)\n".write(to: pidFile, atomically: true, encoding: .utf8)
        return pidFile
    }

    /// Remove the PID file. Best-effort -- it's never an error if the file
    /// is gone.
    public static func releaseSingleInstanceLock(
        at pidFile: URL = ProcessLifecycle.defaultPIDFile()
    ) {
        try? FileManager.default.removeItem(at: pidFile)
    }

    /// Spawn `/usr/bin/caffeinate -s -i -w <pid>` in the background so the
    /// system doesn't sleep while we're serving. Caffeinate exits on its
    /// own when our PID dies, so we don't need to track its handle.
    ///
    /// Returns true if the helper was spawned, false otherwise.
    @discardableResult
    public static func preventSystemSleep() -> Bool {
        let myPID = ProcessInfo.processInfo.processIdentifier
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        process.arguments = ["-s", "-i", "-w", "\(myPID)"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            return true
        } catch {
            return false
        }
    }

    /// Replace this process image with the current executable and argv.
    /// Used after startup auto-update so launchd keeps the same service
    /// lifecycle while the provider begins serving with the new binary.
    public static func execCurrentProcess() throws -> Never {
        #if canImport(Darwin)
        guard let executablePath = Bundle.main.executablePath else {
            throw NSError(
                domain: "ProcessLifecycle",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "could not determine current executable path"]
            )
        }

        let argvStrings = [executablePath] + Array(CommandLine.arguments.dropFirst())
        let cStrings = argvStrings.compactMap { strdup($0) }
        defer {
            for ptr in cStrings {
                free(ptr)
            }
        }

        var argv: [UnsafeMutablePointer<CChar>?] = cStrings.map { $0 }
        argv.append(nil)
        execv(executablePath, &argv)
        throw NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))]
        )
        #else
        throw NSError(
            domain: "ProcessLifecycle",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "exec is only supported on Darwin"]
        )
        #endif
    }

    // MARK: - Launchd-Aware Restart

    /// Restart the provider process after a background auto-update.
    ///
    /// If the process is managed by launchd, delegates to
    /// `LaunchAgent.restart()` (`launchctl kickstart -k`), which is a single
    /// atomic launchd operation: it kills this instance and relaunches the
    /// service from the same plist (picking up the freshly-installed binary).
    /// launchd — not this process — performs the kill+relaunch, so it
    /// completes even after we exit. Otherwise, falls back to
    /// `execCurrentProcess()` (execv) which replaces the process image
    /// in-place.
    public static func restartAfterUpdate() throws -> Never {
        if LaunchAgent.isAnySupportedLabelLoaded() {
            // Launchd-managed: kickstart -k kills us and relaunches the
            // service in place. Issue it, then exit so launchd is free to
            // bring the new binary up cleanly (it may already have signalled
            // us; the exit is the belt-and-suspenders path).
            try LaunchAgent.restart()
            Thread.sleep(forTimeInterval: 2.0)
            exit(0)
        } else {
            // Not under launchd: replace process image with execv.
            try execCurrentProcess()
        }
    }

    /// Outcome of a graceful stop attempt via `stopProcessGracefully(pid:timeout:)`.
    public enum GracefulStopOutcome: Sendable, Equatable {
        /// The target PID was not alive when the stop was requested.
        case notRunning
        /// The process exited after receiving SIGTERM (within the drain timeout).
        case stoppedGracefully
        /// The process did not exit within the drain timeout and was force-killed.
        /// The value is the PID that was signalled.
        case forceKilled(Int32)
    }

    /// Ask a running daemon process to shut down gracefully and wait for it to exit.
    ///
    /// Sends `SIGTERM`, then polls until the process exits or `timeout` elapses.
    /// If the process is still alive after the timeout it is sent `SIGKILL` and
    /// polled again briefly. This mirrors the provider's own shutdown drain:
    /// `ProviderLoop.run()` cancels in-flight work and waits for active inference
    /// to finish when its task is cancelled.
    ///
    /// - Parameters:
    ///   - pid: Target process identifier.
    ///   - timeout: Seconds to wait after sending SIGTERM before escalating to SIGKILL.
    /// - Returns: The outcome of the stop attempt.
    public static func stopProcessGracefully(
        pid: Int32,
        timeout: TimeInterval = 600.0
    ) async -> GracefulStopOutcome {
        guard pid > 0, processIsAlive(pid) else { return .notRunning }

        sendSignal(SIGTERM, to: pid)

        // Fast path: process exited synchronously (nothing to drain).
        if !processIsAlive(pid) { return .stoppedGracefully }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, processIsAlive(pid) {
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
        }

        if !processIsAlive(pid) {
            return .stoppedGracefully
        }

        // Drain timeout expired: escalate to SIGKILL. Report this as a force
        // kill even if SIGKILL eventually succeeds, because the graceful drain
        // window was exceeded.
        sendSignal(SIGKILL, to: pid)

        let killDeadline = Date().addingTimeInterval(2.0)
        while Date() < killDeadline, processIsAlive(pid) {
            try? await Task.sleep(nanoseconds: 50_000_000) // 0.05s
        }

        return .forceKilled(pid)
    }

    // MARK: - Internals

    /// Read a PID from a file, returning `nil` if the file is missing or not a valid PID.
    private static func readPID(at url: URL) -> Int32? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int32(trimmed), value > 0 else { return nil }
        return value
    }

    /// Reports whether a process with the given PID is currently alive.
    /// `kill(pid, 0)` returns 0 if we have permission to signal the process,
    /// even though signal 0 is a no-op. `ESRCH` means the process is gone.
    ///
    /// Rejects nonpositive PIDs up front: `kill(0, …)` targets the caller's whole
    /// process group and `kill(-1, …)` targets every process the user may signal.
    /// This helper is fed by on-disk PID / daemon-state files, so a corrupt `0` or
    /// `-1` must never be treated as "a live process" (and must never reach a real
    /// `kill` via callers that gate on this result).
    public static func processIsAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        let rc = kill(pid, 0)
        if rc == 0 { return true }
        return errno != ESRCH
    }

    private static func sendSignal(_ signo: Int32, to pid: Int32) {
        _ = kill(pid, signo)
    }
}
