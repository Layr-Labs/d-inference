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

    /// Bound on the wait for a live predecessor to exit: the daemon drains
    /// in-flight work on SIGTERM for up to `ProviderLoop.gracefulDrainTimeout`
    /// and launchd SIGKILLs it at `ExitTimeOut`; this is that budget plus a
    /// margin, so a takeover never cuts a drain that is inside its own bound.
    public static let defaultPredecessorExitBound: TimeInterval =
        LaunchAgent.previousInstanceExitBound.timeInterval

    /// Acquire the single-instance lock. If an older provider is already
    /// running: a predecessor that is already draining (its daemon-state
    /// record says so — launchd's `bootout`/`kickstart -k` or an operator
    /// already sent it SIGTERM) is left alone, since a SECOND SIGTERM is the
    /// trap's forced-exit path (exit 130, no goingAway frame, in-flight
    /// requests flushed as 502 on the coordinator); otherwise it gets one
    /// SIGTERM to start its drain. Either way this waits up to
    /// `predecessorExitBound` for it to exit and SIGKILLs only past that.
    /// Always writes our own PID to the file at the end.
    ///
    /// Returns the path of the PID file on success, throws on inability to
    /// write.
    @discardableResult
    public static func acquireSingleInstanceLock(
        at pidFile: URL = ProcessLifecycle.defaultPIDFile(),
        predecessorExitBound: TimeInterval = ProcessLifecycle.defaultPredecessorExitBound,
        daemonStateFile: URL = DaemonStateFile.path()
    ) throws -> URL {
        let myPID = ProcessInfo.processInfo.processIdentifier
        let fm = FileManager.default

        if let existing = readPID(at: pidFile),
           existing != myPID,
           processIsAlive(existing)
        {
            if !predecessorIsDraining(pid: existing, stateFile: daemonStateFile) {
                sendSignal(SIGTERM, to: existing)
            }
            let exited = ProcessExitWait.wait(
                bound: .seconds(predecessorExitBound),
                onWaiting: { bound in
                    FileHandle.standardError.write(Data(
                        ("Waiting for the previous provider (pid \(existing)) to finish "
                            + "in-flight work (up to \(bound.components.seconds) s)...\n").utf8))
                },
                gone: { !processIsAlive(existing) })
            if !exited {
                sendSignal(SIGKILL, to: existing)
                // Let the kill land before the PID file changes hands.
                ProcessExitWait.wait(bound: .seconds(1)) { !processIsAlive(existing) }
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

    /// Acquire the production media-serving lock, then perform the one launch
    /// housekeeping pass shared by standalone and coordinator-connected modes.
    /// Keeping the operations in one seam makes their ordering non-optional:
    /// cleanup never races an older provider instance that still owns a legacy
    /// artifact, and connected startup cannot repeat telemetry cleanup during
    /// later client configuration.
    @discardableResult
    public static func acquireMediaServingLock(
        at pidFile: URL = ProcessLifecycle.defaultPIDFile(),
        predecessorExitBound: TimeInterval = ProcessLifecycle.defaultPredecessorExitBound
    ) throws -> URL {
        try acquireMediaServingLock(
            acquireLock: {
                try acquireSingleInstanceLock(
                    at: pidFile,
                    predecessorExitBound: predecessorExitBound)
            },
            purgeLegacyTelemetryQueue: {
                TelemetryOverflowQueue.shared.purge()
            },
            purgeLegacyVideoFiles: {
                MediaIngest.purgeLegacyVideoTempFiles()
            })
    }

    /// Dependency seam for the ordering and exactly-once contract above.
    @discardableResult
    static func acquireMediaServingLock(
        acquireLock: () throws -> URL,
        purgeLegacyTelemetryQueue: () -> Void,
        purgeLegacyVideoFiles: () -> Void
    ) rethrows -> URL {
        let pidFile = try acquireLock()
        purgeLegacyTelemetryQueue()
        purgeLegacyVideoFiles()
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

    /// Terminate only the exact kernel process identity supplied by the caller.
    /// PID reuse can never redirect the signal to an unrelated process.
    public static func terminate(
        _ identity: ProcessIdentity,
        gracePeriod: TimeInterval = 2
    ) -> Bool {
        guard identity.isCurrent() else { return false }
        _ = kill(identity.pid, SIGTERM)
        let deadline = Date().addingTimeInterval(gracePeriod)
        while Date() < deadline, identity.isCurrent() {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if identity.isCurrent() {
            _ = kill(identity.pid, SIGKILL)
        }
        let killDeadline = Date().addingTimeInterval(1)
        while Date() < killDeadline, identity.isCurrent() {
            Thread.sleep(forTimeInterval: 0.02)
        }
        return !identity.isCurrent()
    }

    // MARK: - Internals

    /// Whether the daemon-state record belongs to `pid` and says it is
    /// shutting down (`ProviderLoop.beginShutdownDrain` stamps it before its
    /// first suspension). A record for another pid proves nothing.
    static func predecessorIsDraining(pid: Int32, stateFile: URL) -> Bool {
        guard let state = DaemonStateFile.read(from: stateFile) else { return false }
        return state.pid == pid && state.shuttingDown == true
    }

    private static func readPID(at url: URL) -> Int32? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return Int32(trimmed)
    }

    private static func processIsAlive(_ pid: Int32) -> Bool {
        // kill(pid, 0) returns 0 if we have permission to signal the process,
        // even if signal 0 is a no-op. ESRCH means the process is gone.
        let rc = kill(pid, 0)
        if rc == 0 { return true }
        return errno != ESRCH
    }

    private static func sendSignal(_ signo: Int32, to pid: Int32) {
        _ = kill(pid, signo)
    }
}
