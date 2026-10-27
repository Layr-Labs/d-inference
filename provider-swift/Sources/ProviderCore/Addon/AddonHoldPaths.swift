import Darwin
import Foundation

/// Files the provider shares with local add-ons, all in the install
/// directory's owner-only `runtime` directory (`~/.darkbloom/runtime` for
/// production builds; dev and staging installs use their own directory).
public struct AddonHoldPaths: Sendable, Equatable {
    /// Test-only override of the socket path.
    public static let socketOverrideVariable = "DARKBLOOM_ADDON_SOCKET"

    /// Newline-delimited JSON control socket (`addon.sock`).
    public var socket: URL
    /// Persisted active holds (`addon-hold.json`).
    public var holdState: URL
    /// The machine lock an add-on holds exclusively while any lease or VM
    /// exists (`ownership.lock`). The provider only observes it.
    public var machineLock: URL

    public init(runtimeDirectory: URL, socket: URL? = nil) {
        self.socket = socket ?? runtimeDirectory.appendingPathComponent("addon.sock")
        holdState = runtimeDirectory.appendingPathComponent("addon-hold.json")
        machineLock = runtimeDirectory.appendingPathComponent("ownership.lock")
    }

    /// The override moves the whole runtime directory to the socket's
    /// directory: add-ons keep `ownership.lock` beside the socket, so a test
    /// setup never observes the real machine lock or hold record.
    public static func production(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> AddonHoldPaths {
        if let override = environment[socketOverrideVariable], !override.isEmpty {
            let socket = URL(fileURLWithPath: override)
            return AddonHoldPaths(runtimeDirectory: socket.deletingLastPathComponent(), socket: socket)
        }
        return AddonHoldPaths(runtimeDirectory: BuildEnvironment.current.installDirectory(home: home)
            .appendingPathComponent("runtime", isDirectory: true))
    }
}

/// The owner-only directory holding the socket and the hold record.
enum AddonRuntimeDirectory {
    enum Failure: Error, CustomStringConvertible {
        case notOwnerOnlyDirectory(String)
        var description: String {
            switch self {
            case .notOwnerOnlyDirectory(let path): return "\(path) is not a directory owned by this user"
            }
        }
    }

    /// Creates the directory `0700`, or tightens an existing one this user
    /// owns. A symlink, a file or another user's directory is refused.
    static func prepare(_ directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == geteuid() else {
            throw Failure.notOwnerOnlyDirectory(directory.path)
        }
        if info.st_mode & 0o077 != 0, chmod(directory.path, 0o700) != 0 {
            throw Failure.notOwnerOnlyDirectory(directory.path)
        }
    }
}

/// The add-on holds `ownership.lock` exclusively while any lease or VM exists
/// and the kernel drops it when the add-on exits. The provider never holds it:
/// a non-blocking shared probe only observes whether an exclusive owner exists.
enum AddonMachineLock {
    enum Observation: Sendable, Equatable { case held, free }

    /// A missing file is free. Any other failure to observe the lock counts as
    /// held, so an expired lease never loads models beside running VMs.
    static func observe(_ url: URL) -> Observation {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return errno == ENOENT ? .free : .held }
        defer { close(fd) }
        guard flock(fd, LOCK_SH | LOCK_NB) == 0 else { return .held }
        flock(fd, LOCK_UN)
        return .free
    }
}
