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
    struct SingleInstanceOwner: Codable, Equatable {
        let schema: Int
        let processIdentity: ProcessIdentity

        init(processIdentity: ProcessIdentity) {
            schema = 1
            self.processIdentity = processIdentity
        }
    }

    /// Default PID file location: `~/.darkbloom/provider.pid`.
    /// Override with `DARKBLOOM_PID_FILE` env var (useful for multi-instance testing).
    public static func defaultPIDFile() -> URL {
        if let override = ProcessInfo.processInfo.environment["DARKBLOOM_PID_FILE"] {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".darkbloom/provider.pid")
    }

    /// Acquire the single-instance lock. If the file names an older provider
    /// whose exact kernel identity is still live, terminate that identity
    /// before replacing the record. Legacy PID-only and stale/reused-PID files
    /// are overwritten without signaling anything.
    ///
    /// Returns the path of the PID file on success, throws on inability to
    /// write.
    @discardableResult
    public static func acquireSingleInstanceLock(
        at pidFile: URL = ProcessLifecycle.defaultPIDFile(),
        terminationGracePeriod: TimeInterval = 2.0
    ) throws -> URL {
        guard let currentIdentity = ProcessIdentity.current() else {
            throw ProcessLifecycleError.currentProcessIdentityUnavailable
        }
        return try acquireSingleInstanceLock(
            at: pidFile,
            terminationGracePeriod: terminationGracePeriod,
            currentIdentity: currentIdentity,
            readIdentity: ProcessIdentity.read(pid:),
            terminate: { terminate($0, gracePeriod: $1) }
        )
    }

    @discardableResult
    static func acquireSingleInstanceLock(
        at pidFile: URL,
        terminationGracePeriod: TimeInterval,
        currentIdentity: ProcessIdentity,
        readIdentity: (Int32) -> ProcessIdentity?,
        terminate: (ProcessIdentity, TimeInterval) -> Bool
    ) throws -> URL {
        let fm = FileManager.default

        let parent = pidFile.deletingLastPathComponent()
        try fm.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )

        if let existing = readOwner(at: pidFile)?.processIdentity,
           existing != currentIdentity,
           readIdentity(existing.pid) == existing,
           !terminate(existing, terminationGracePeriod)
        {
            throw ProcessLifecycleError.existingProviderDidNotExit(existing.pid)
        }

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        var data = try encoder.encode(SingleInstanceOwner(processIdentity: currentIdentity))
        data.append(0x0A)
        try data.write(to: pidFile, options: .atomic)
        do {
            try fm.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: pidFile.path
            )
        } catch {
            try? fm.removeItem(at: pidFile)
            throw error
        }
        return pidFile
    }

    private static func readOwner(at url: URL) -> SingleInstanceOwner? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let owner = try? decoder.decode(SingleInstanceOwner.self, from: data),
              owner.schema == 1
        else {
            return nil
        }
        return owner
    }

    static func releaseSingleInstanceLock(
        at pidFile: URL,
        currentIdentity: ProcessIdentity?
    ) {
        guard let currentIdentity,
              readOwner(at: pidFile)?.processIdentity == currentIdentity
        else {
            return
        }
        try? FileManager.default.removeItem(at: pidFile)
    }

    /// Remove the lock record only when this exact process still owns it.
    /// A stale process can therefore never delete a successor's record.
    public static func releaseSingleInstanceLock(
        at pidFile: URL = ProcessLifecycle.defaultPIDFile()
    ) {
        releaseSingleInstanceLock(
            at: pidFile,
            currentIdentity: ProcessIdentity.current()
        )
    }

    /// Decode the exact process identity currently recorded as the lock owner.
    /// Legacy PID-only files deliberately return nil because they cannot safely
    /// authorize a signal.
    public static func singleInstanceOwner(
        at pidFile: URL = ProcessLifecycle.defaultPIDFile()
    ) -> ProcessIdentity? {
        readOwner(at: pidFile)?.processIdentity
    }

    /// Terminate a currently recorded provider only when its kernel identity
    /// still matches. Missing, legacy, stale, and PID-reused records are no-ops.
    @discardableResult
    public static func terminateRecordedInstance(
        at pidFile: URL = ProcessLifecycle.defaultPIDFile(),
        gracePeriod: TimeInterval = 2
    ) -> Bool {
        guard let identity = singleInstanceOwner(at: pidFile),
              identity.isCurrent()
        else {
            return true
        }
        return terminate(identity, gracePeriod: gracePeriod)
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

}

public enum ProcessLifecycleError: LocalizedError, Sendable, Equatable {
    case currentProcessIdentityUnavailable
    case existingProviderDidNotExit(Int32)

    public var errorDescription: String? {
        switch self {
        case .currentProcessIdentityUnavailable:
            return "could not read this process's kernel identity"
        case .existingProviderDidNotExit(let pid):
            return "existing provider process \(pid) did not exit"
        }
    }
}
