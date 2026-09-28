import Foundation
import Darwin

/// Owner-only atomic mailbox, bound to a kernel process identity. A stale
/// command cannot target a new process that reused the old PID. The CLI holds
/// the existing cross-process update lease while issuing a command.
public struct LifecycleMailbox: Sendable {
    public let directory: URL
    public let identity: ProcessIdentity

    public init(identity: ProcessIdentity, directory: URL = DaemonStateFile.path().deletingLastPathComponent().appendingPathComponent("lifecycle")) {
        self.identity = identity; self.directory = directory
    }

    private func path(_ suffix: String) -> URL {
        directory.appendingPathComponent("\(identity.pid)-\(identity.startTimeMicros).\(suffix).json")
    }

    public func writeRequest(_ request: ProviderDrainRequest) throws { try write(request, suffix: "request") }
    public func writeStatus(_ status: ProviderDrainStatus) throws { try write(status, suffix: "status") }
    public func readRequest() -> ProviderDrainRequest? { read(ProviderDrainRequest.self, suffix: "request") }
    public func readStatus() -> ProviderDrainStatus? { read(ProviderDrainStatus.self, suffix: "status") }

    public func writeSwitchRequest(_ request: ProviderModelSwitchRequest) throws { try write(request, suffix: "switch-request") }
    public func writeSwitchStatus(_ status: ProviderModelSwitchStatus) throws { try write(status, suffix: "switch-status") }
    public func readSwitchStatus() -> ProviderModelSwitchStatus? { read(ProviderModelSwitchStatus.self, suffix: "switch-status") }

    /// Rename is the acceptance boundary. Each loop/monitor can consume a
    /// publication once, and cleanup can never unlink a newer publication.
    public func claimSwitchRequest() -> ProviderModelSwitchRequest? {
        claimSwitchRequest(afterClaim: {})
    }

    internal func claimSwitchRequest(afterClaim: () -> Void) -> ProviderModelSwitchRequest? {
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o077 == 0 else { return nil }
        let claimed = path("switch-claim-\(UUID().uuidString)")
        guard rename(path("switch-request").path, claimed.path) == 0 else { return nil }
        defer { try? FileManager.default.removeItem(at: claimed) }
        afterClaim()
        return read(ProviderModelSwitchRequest.self, at: claimed)
    }

    private func write<T: Encodable>(_ value: T, suffix: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o077 == 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let temporary = directory.appendingPathComponent(UUID().uuidString)
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close(); try? FileManager.default.removeItem(at: temporary) }
        try file.write(contentsOf: JSONEncoder().encode(value))
        guard rename(temporary.path, path(suffix).path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    private func read<T: Decodable>(_ type: T.Type, suffix: String) -> T? {
        read(type, at: path(suffix))
    }

    private func read<T: Decodable>(_ type: T.Type, at path: URL) -> T? {
        let fd = open(path.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o077 == 0, info.st_size <= 8192,
              let data = try? file.read(upToCount: 8193) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
