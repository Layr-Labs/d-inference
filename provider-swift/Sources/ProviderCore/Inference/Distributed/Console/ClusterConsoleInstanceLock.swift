import Foundation
import Darwin

/// One console screen per user. Two screens would each start actions without
/// seeing the other's, so the second one refuses to open. The lock is an empty
/// owner-only file in the user's own temporary directory, held with `flock`
/// for the life of the screen. It records nothing, opening a screen leaves
/// nothing in the home directory, and the kernel releases the lock if the
/// process dies.
public final class ClusterConsoleInstanceLock: @unchecked Sendable {
    public struct Held: Error, CustomStringConvertible {
        public var description: String {
            "Another `darkbloom cluster` screen is open for this user. Close it first, or run `darkbloom cluster console --plain` to print the same state without opening a screen."
        }
    }

    static let fileName = "darkbloom-cluster-console.lock"
    private let descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }

    public static func acquire() throws -> ClusterConsoleInstanceLock {
        // The per-user directory macOS keeps for this user alone; not an environment variable.
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) > 0 else {
            throw ClusterConfigurationError.invalid("Cannot find this user's temporary directory for the console lock")
        }
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return try acquire(directory: URL(fileURLWithPath: path, isDirectory: true))
    }

    static func acquire(directory: URL) throws -> ClusterConsoleInstanceLock {
        let parent = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0 else { throw ClusterConfigurationError.invalid("Cannot open the directory for the console lock") }
        defer { Darwin.close(parent) }
        var information = stat()
        // Only this user may add or replace entries there.
        guard fstat(parent, &information) == 0, information.st_uid == geteuid(), information.st_mode & 0o022 == 0 else {
            throw ClusterConfigurationError.invalid("The directory for the console lock is not this user's own")
        }
        let descriptor = openat(parent, fileName, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw ClusterConfigurationError.invalid("Cannot open the console lock") }
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
