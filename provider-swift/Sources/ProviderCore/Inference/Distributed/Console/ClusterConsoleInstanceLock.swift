import Foundation
import Darwin

/// One console screen per user. Two screens would each start actions without
/// seeing the other's, so the second one refuses to open. The lock is an empty
/// owner-only file held with `flock` for the life of the screen; it records
/// nothing and is released by the kernel if the process dies.
public final class ClusterConsoleInstanceLock: @unchecked Sendable {
    public struct Held: Error, CustomStringConvertible {
        public var description: String {
            "Another `darkbloom cluster` screen is open for this user. Close it first, or run `darkbloom cluster console --plain` to print the same state without opening a screen."
        }
    }

    static let fileName = "console.lock"
    private let descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }

    public static func acquire() throws -> ClusterConsoleInstanceLock { try acquire(paths: ClusterUserPaths()) }

    static func acquire(paths: ClusterUserPaths) throws -> ClusterConsoleInstanceLock {
        let directory = try ClusterConfigurationFiles.directory(paths.deviceDirectory, create: true, privateMode: true)
        defer { Darwin.close(directory.descriptor) }
        let descriptor = openat(directory.descriptor, fileName, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw ClusterConfigurationError.invalid("Cannot open the console lock") }
        var information = stat()
        guard fstat(descriptor, &information) == 0, information.st_mode & S_IFMT == S_IFREG,
              information.st_uid == geteuid(), information.st_mode & 0o077 == 0, information.st_nlink == 1 else {
            Darwin.close(descriptor)
            throw ClusterConfigurationError.invalid("The console lock is not an owner-only regular file")
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            throw Held()
        }
        return ClusterConsoleInstanceLock(descriptor: descriptor)
    }

    deinit {
        _ = flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }
}
