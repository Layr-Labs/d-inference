import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Kernel-owned exclusion for every process that can replace the installed app.
///
/// The primary lock coordinates current app, CLI, updater, and shell-installer
/// code. The legacy updater lock is acquired second by one-shot installers so
/// they also serialize with provider versions released before the primary lock
/// existed. Lock files are deliberately persistent: unlinking a file while it
/// is locked can create two independently locked inodes at the same path.
public final class InstallMutationLock: @unchecked Sendable {
    public static let fileName = ".app-install.lock"
    public static let legacyUpdateLockRelativePath = "recovery/update.lock"
    public static let selfUpdateTransactionRelativePath =
        "recovery/transaction.json"

    public enum LockError: Error, LocalizedError, Sendable {
        case unavailable(path: String, reason: String)
        case timedOut(path: String)

        public var errorDescription: String? {
            switch self {
            case .unavailable(let path, let reason):
                return "Darkbloom could not open the installation lock at \(path): \(reason)"
            case .timedOut(let path):
                return "Another Darkbloom installation is still active at \(path)."
            }
        }

        public var recoverySuggestion: String? {
            "Wait for the other Darkbloom installation to finish, then retry."
        }
    }

    private struct HeldDescriptor {
        let descriptor: Int32
        let path: URL
    }

    private let releaseMutex = NSLock()
    private var heldDescriptors: [HeldDescriptor]
    private var released = false

    private init(heldDescriptors: [HeldDescriptor]) {
        self.heldDescriptors = heldDescriptors
    }

    deinit {
        release()
    }

    /// Acquire only the new primary lock. `SelfUpdater` then acquires its
    /// existing owner-recording lock second, preserving one global lock order.
    public static func acquirePrimary(
        in installRoot: URL,
        timeout: TimeInterval = 30,
        pollInterval: TimeInterval = 0.05,
        fileManager: FileManager = .default
    ) throws -> InstallMutationLock {
        try acquire(
            paths: [primaryLockURL(in: installRoot)],
            timeout: timeout,
            pollInterval: pollInterval,
            fileManager: fileManager
        )
    }

    /// Acquire both the primary lock and the legacy updater lock, in that
    /// order. App relocation and shell installation use this during rollout
    /// so an older provider's updater cannot mutate the same destination.
    public static func acquireForOneShotInstall(
        in installRoot: URL,
        timeout: TimeInterval = 30,
        pollInterval: TimeInterval = 0.05,
        fileManager: FileManager = .default
    ) throws -> InstallMutationLock {
        let lock = try acquire(
            paths: [
                primaryLockURL(in: installRoot),
                legacyUpdateLockURL(in: installRoot),
            ],
            timeout: timeout,
            pollInterval: pollInterval,
            fileManager: fileManager
        )
        do {
            try lock.clearLegacyOwnerRecord()
            return lock
        } catch {
            lock.release()
            throw error
        }
    }

    public static func withOneShotInstallLock<Result>(
        in installRoot: URL,
        timeout: TimeInterval = 30,
        pollInterval: TimeInterval = 0.05,
        fileManager: FileManager = .default,
        _ body: () throws -> Result
    ) throws -> Result {
        let lock = try acquireForOneShotInstall(
            in: installRoot,
            timeout: timeout,
            pollInterval: pollInterval,
            fileManager: fileManager
        )
        defer { lock.release() }
        return try body()
    }

    public static func primaryLockURL(in installRoot: URL) -> URL {
        installRoot.appendingPathComponent(fileName)
    }

    public static func legacyUpdateLockURL(in installRoot: URL) -> URL {
        installRoot.appendingPathComponent(legacyUpdateLockRelativePath)
    }

    public static func selfUpdateTransactionURL(in installRoot: URL) -> URL {
        installRoot.appendingPathComponent(selfUpdateTransactionRelativePath)
    }

    public static func pendingOneShotTransaction(
        in installRoot: URL,
        fileManager: FileManager = .default
    ) throws -> URL? {
        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: installRoot,
                includingPropertiesForKeys: nil
            )
        } catch {
            throw LockError.unavailable(
                path: installRoot.path,
                reason: "could not inspect installer recovery state: "
                    + error.localizedDescription
            )
        }
        let sortedEntries = entries.sorted {
            $0.lastPathComponent < $1.lastPathComponent
        }
        let pending = sortedEntries.first { entry in
            entry.lastPathComponent.hasPrefix(".install-backup-")
                || entry.lastPathComponent.hasPrefix(".install-staging-")
        }
        // #region agent log
        AgentDebugLog.write(
            hypothesisId: "A",
            location: "InstallMutationLock.swift:pendingOneShotTransaction",
            message: "Scanned install root for pending one-shot transaction",
            data: [
                "pid": ProcessInfo.processInfo.processIdentifier,
                "installRoot": installRoot.path,
                "entries": sortedEntries.map(\.lastPathComponent),
                "recognized": sortedEntries.filter {
                    $0.lastPathComponent.hasPrefix(".install-backup-")
                        || $0.lastPathComponent.hasPrefix(".install-staging-")
                }.map(\.lastPathComponent),
                "selected": pending?.lastPathComponent ?? "<none>",
            ]
        )
        // #endregion
        return pending
    }

    public func release() {
        releaseMutex.lock()
        defer { releaseMutex.unlock() }
        guard !released else { return }
        released = true

        for held in heldDescriptors.reversed() {
            _ = flock(held.descriptor, LOCK_UN)
            _ = close(held.descriptor)
        }
        // #region agent log
        AgentDebugLog.write(
            hypothesisId: "D",
            location: "InstallMutationLock.swift:release",
            message: "Released primary installation lock descriptors",
            data: [
                "pid": ProcessInfo.processInfo.processIdentifier,
                "paths": heldDescriptors.map { $0.path.path },
                "descriptorCount": heldDescriptors.count,
            ]
        )
        // #endregion
        heldDescriptors.removeAll()
    }

    private func clearLegacyOwnerRecord() throws {
        guard let legacy = heldDescriptors.last else { return }
        guard ftruncate(legacy.descriptor, 0) == 0,
              lseek(legacy.descriptor, 0, SEEK_SET) >= 0
        else {
            throw LockError.unavailable(
                path: legacy.path.path,
                reason: Self.posixMessage()
            )
        }
    }

    private static func acquire(
        paths: [URL],
        timeout: TimeInterval,
        pollInterval: TimeInterval,
        fileManager: FileManager
    ) throws -> InstallMutationLock {
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        var held: [HeldDescriptor] = []
        do {
            for path in paths {
                let descriptor = try openAndLock(
                    path,
                    deadline: deadline,
                    canWait: timeout > 0,
                    pollInterval: pollInterval,
                    fileManager: fileManager
                )
                held.append(HeldDescriptor(descriptor: descriptor, path: path))
            }
            return InstallMutationLock(heldDescriptors: held)
        } catch {
            for item in held.reversed() {
                _ = flock(item.descriptor, LOCK_UN)
                _ = close(item.descriptor)
            }
            throw error
        }
    }

    private static func openAndLock(
        _ path: URL,
        deadline: TimeInterval,
        canWait: Bool,
        pollInterval: TimeInterval,
        fileManager: FileManager
    ) throws -> Int32 {
        do {
            try fileManager.createDirectory(
                at: path.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw LockError.unavailable(
                path: path.path,
                reason: error.localizedDescription
            )
        }

        let descriptor = open(
            path.path,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw LockError.unavailable(path: path.path, reason: posixMessage())
        }

        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            let reason = posixMessage()
            _ = close(descriptor)
            throw LockError.unavailable(path: path.path, reason: reason)
        }
        guard status.st_mode & S_IFMT == S_IFREG else {
            _ = close(descriptor)
            throw LockError.unavailable(
                path: path.path,
                reason: "lock path is not a regular file"
            )
        }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            let reason = posixMessage()
            _ = close(descriptor)
            throw LockError.unavailable(path: path.path, reason: reason)
        }

        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            if code == EINTR {
                continue
            }
            if code == EWOULDBLOCK || code == EAGAIN {
                guard canWait,
                      ProcessInfo.processInfo.systemUptime < deadline
                else {
                    _ = close(descriptor)
                    throw LockError.timedOut(path: path.path)
                }
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                Thread.sleep(
                    forTimeInterval: min(
                        max(0.001, pollInterval),
                        max(0.001, remaining)
                    )
                )
                continue
            }
            let reason = String(cString: strerror(code))
            _ = close(descriptor)
            throw LockError.unavailable(path: path.path, reason: reason)
        }
        return descriptor
    }

    private static func posixMessage() -> String {
        String(cString: strerror(errno))
    }
}
