import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

enum AppInstallLockError: Error, LocalizedError {
    case unavailable(path: String, reason: String)
    case timedOut(path: String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let path, let reason):
            "Darkbloom could not acquire the app installation lock at \(path): \(reason)"
        case .timedOut(let path):
            "Another Darkbloom installation is still active at \(path)."
        }
    }

    var recoverySuggestion: String? {
        "Wait for the other Darkbloom installation to finish, then reopen the app."
    }
}

/// Cross-process exclusion shared conceptually with `scripts/install.sh`.
///
/// A directory is the lock primitive because stock macOS has no `flock`
/// executable for the shell installer. Creation and stale-owner renames are
/// atomic on the destination volume.
enum AppInstallLock {
    static let directoryName = ".app-install-lock"

    private static let ownerFileName = "owner"
    private static let ownerInitializationGrace: TimeInterval = 5

    static func withLock<Result>(
        in installRoot: URL,
        timeout: TimeInterval = 30,
        pollInterval: TimeInterval = 0.05,
        fileManager: FileManager = .default,
        _ body: () throws -> Result
    ) throws -> Result {
        let lock = try acquire(
            in: installRoot,
            timeout: timeout,
            pollInterval: pollInterval,
            fileManager: fileManager
        )
        defer { lock.release() }
        return try body()
    }

    private static func acquire(
        in installRoot: URL,
        timeout: TimeInterval,
        pollInterval: TimeInterval,
        fileManager: FileManager
    ) throws -> HeldAppInstallLock {
        let directory = installRoot.appendingPathComponent(directoryName, isDirectory: true)
        let deadline = Date().addingTimeInterval(max(0, timeout))

        while true {
            do {
                try fileManager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
                return try HeldAppInstallLock(
                    directory: directory,
                    ownerFileName: ownerFileName,
                    fileManager: fileManager
                )
            } catch {
                guard itemExists(at: directory, fileManager: fileManager) else {
                    throw AppInstallLockError.unavailable(
                        path: directory.path,
                        reason: error.localizedDescription
                    )
                }
            }

            if reclaimStaleLock(at: directory, fileManager: fileManager) {
                continue
            }
            guard Date() < deadline else {
                throw AppInstallLockError.timedOut(path: directory.path)
            }
            Thread.sleep(forTimeInterval: max(0.001, pollInterval))
        }
    }

    private static func reclaimStaleLock(
        at directory: URL,
        fileManager: FileManager
    ) -> Bool {
        let ownerURL = directory.appendingPathComponent(ownerFileName)
        if let owner = try? String(contentsOf: ownerURL, encoding: .utf8),
           let pidLine = owner.split(separator: "\n").first(where: { $0.hasPrefix("pid=") }),
           let pid = Int32(pidLine.dropFirst(4))
        {
            errno = 0
            if kill(pid, 0) == 0 || errno == EPERM {
                return false
            }
            guard errno == ESRCH else { return false }
            return quarantineAndRemove(directory, fileManager: fileManager)
        }

        guard let attributes = try? fileManager.attributesOfItem(atPath: directory.path),
              let modifiedAt = attributes[.modificationDate] as? Date,
              Date().timeIntervalSince(modifiedAt) >= ownerInitializationGrace
        else {
            return false
        }
        return quarantineAndRemove(directory, fileManager: fileManager)
    }

    private static func quarantineAndRemove(
        _ directory: URL,
        fileManager: FileManager
    ) -> Bool {
        let quarantined = directory.deletingLastPathComponent()
            .appendingPathComponent(
                "\(directory.lastPathComponent).stale-\(UUID().uuidString.lowercased())",
                isDirectory: true
            )
        do {
            try fileManager.moveItem(at: directory, to: quarantined)
            try? fileManager.removeItem(at: quarantined)
            return true
        } catch {
            return false
        }
    }

    private static func itemExists(at url: URL, fileManager: FileManager) -> Bool {
        fileManager.fileExists(atPath: url.path)
            || (try? fileManager.attributesOfItem(atPath: url.path)) != nil
    }
}

private final class HeldAppInstallLock {
    private let directory: URL
    private let ownerURL: URL
    private let token = UUID().uuidString.lowercased()
    private let fileManager: FileManager

    init(
        directory: URL,
        ownerFileName: String,
        fileManager: FileManager
    ) throws {
        self.directory = directory
        ownerURL = directory.appendingPathComponent(ownerFileName)
        self.fileManager = fileManager
        let owner = "pid=\(getpid())\ntoken=\(token)\n"
        do {
            try Data(owner.utf8).write(to: ownerURL, options: .withoutOverwriting)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: ownerURL.path
            )
        } catch {
            try? fileManager.removeItem(at: directory)
            throw AppInstallLockError.unavailable(
                path: directory.path,
                reason: error.localizedDescription
            )
        }
    }

    func release() {
        guard let owner = try? String(contentsOf: ownerURL, encoding: .utf8),
              owner.contains("token=\(token)\n")
        else {
            return
        }
        try? fileManager.removeItem(at: directory)
    }
}
