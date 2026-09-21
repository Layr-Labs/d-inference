/// ProcessLifecycle -- single-instance enforcement and OS-level helpers
/// that every long-running provider process needs (PID file, caffeinate
/// sleep prevention).
///
/// CLI lifecycle commands drain and stop the old owner before these helpers
/// acquire a kernel-owned instance lock, publish the new PID, and spawn `caffeinate -s -i -w <pid>` so the
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

    private static let instanceLocks = InstanceLocks()

    private final class InstanceLocks: @unchecked Sendable {
        let mutex = NSLock()
        var held: [URL: UpdateProcessLock] = [:]
    }

    public enum InstanceError: Error, CustomStringConvertible {
        case alreadyRunning(Int32)
        public var description: String {
            switch self {
            case .alreadyRunning(let pid): return "Provider process \(pid) is still running. Drain it with darkbloom stop/restart before replacing it."
            }
        }
    }

    /// The kernel lock is held for the process lifetime. This low-level handoff
    /// never signals an existing owner: CLI lifecycle commands own draining.
    @discardableResult
    public static func acquireSingleInstanceLock(
        at pidFile: URL = ProcessLifecycle.defaultPIDFile(),
        terminationGracePeriod: TimeInterval = 2.0
    ) throws -> URL {
        _ = terminationGracePeriod // retained for source compatibility, never a kill deadline
        return try instanceLocks.mutex.withLock {
            if instanceLocks.held[pidFile] != nil { return pidFile }
            let lock = try UpdateProcessLock.acquire(at: pidFile.appendingPathExtension("lock"), operation: "provider-instance")
            if let existing = readPID(at: pidFile), existing != getpid(), processIsAlive(existing) {
                lock.release()
                throw InstanceError.alreadyRunning(existing)
            }
            try "\(getpid())\n".write(to: pidFile, atomically: true, encoding: .utf8)
            instanceLocks.held[pidFile] = lock
            return pidFile
        }
    }

    public static func existingPID(at pidFile: URL = ProcessLifecycle.defaultPIDFile()) -> Int32? {
        readPID(at: pidFile)
    }

    public static func requestTermination(_ identity: ProcessIdentity) throws {
        guard identity.isCurrent() else { return }
        guard kill(identity.pid, SIGTERM) == 0 || errno == ESRCH else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
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
        terminationGracePeriod: TimeInterval = 2.0
    ) throws -> URL {
        try acquireMediaServingLock(
            acquireLock: {
                try acquireSingleInstanceLock(
                    at: pidFile,
                    terminationGracePeriod: terminationGracePeriod)
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
        instanceLocks.mutex.withLock {
            if readPID(at: pidFile) == getpid() { try? FileManager.default.removeItem(at: pidFile) }
            instanceLocks.held.removeValue(forKey: pidFile)?.release()
        }
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
