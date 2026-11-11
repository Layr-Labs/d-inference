import Foundation
import Darwin

/// One console screen per user and install. Two screens would each start
/// actions without seeing the other's, so the second one refuses to open. The
/// lock is an empty owner-only file in the user's own temporary directory,
/// named after the install's command (`darkbloom-cluster-console.lock`, DevNet's
/// `darkbloom-dev-…`, whose screens act on its own pair), held with `flock`
/// for the life of the screen. It records nothing, opening a screen leaves
/// nothing in the home directory, and the kernel releases the lock if the
/// process dies.
public final class ClusterConsoleInstanceLock: @unchecked Sendable {
    public struct Held: Error, CustomStringConvertible {
        public var description: String {
            let cli = BuildEnvironment.current.cliName
            return "Another `\(cli) cluster` screen is open for this user. Close it first, or run `\(cli) cluster console --plain` to print the same state without opening a screen."
        }
    }

    static let fileName = lockFileName("console")

    /// This install's lock for `use` (`console`, `exchange`, `control`): production's `darkbloom-cluster-<use>.lock`.
    static func lockFileName(_ use: String, environment: BuildEnvironment = .current) -> String {
        "\(environment.cliName)-cluster-\(use).lock"
    }
    private let descriptor: Int32
    private let state = NSLock()
    private var released = false

    private init(descriptor: Int32) { self.descriptor = descriptor }

    /// Lets go of the lock before this object ends (a screen whose run is over and that only waits for its last key);
    /// idempotent.
    public func release() {
        state.withLock {
            guard !released else { return }
            released = true
            _ = flock(descriptor, LOCK_UN)
            Darwin.close(descriptor)
        }
    }

    public static func acquire() throws -> ClusterConsoleInstanceLock {
        try acquire(directory: userTemporaryDirectory())
    }

    /// The directory macOS keeps for this user alone, by its real path. It is
    /// not taken from an environment variable.
    static func userTemporaryDirectory() throws -> URL {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) > 0 else {
            throw ClusterConfigurationError.invalid("Cannot find this user's temporary directory")
        }
        // The real path: the cluster file policy refuses a link in any component.
        guard let resolved = realpath(buffer, nil) else {
            throw ClusterConfigurationError.invalid("Cannot resolve this user's temporary directory")
        }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    static func acquire(directory: URL) throws -> ClusterConsoleInstanceLock {
        try acquire(directory: directory, fileName: fileName, waitSeconds: 0)
    }

    /// The same owner-only lock under another name; `waitSeconds` above 0 waits that long for a holder to let go.
    static func acquire(directory: URL, fileName: String, waitSeconds: Double) throws -> ClusterConsoleInstanceLock {
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
        let deadline = Date(timeIntervalSinceNow: waitSeconds)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR, Date() < deadline else {
                Darwin.close(descriptor)
                throw Held()
            }
            usleep(50_000)
        }
        return ClusterConsoleInstanceLock(descriptor: descriptor)
    }

    deinit { release() }
}
