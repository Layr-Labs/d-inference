import Darwin
import Foundation
import SandboxRuntime

/// Descriptor-relative publication into the selected GUI user's VM directory.
/// Production callers are root; owned test fixtures exercise the same IO rules.
/// The immutable record remains pinned so identical replacement bytes do not
/// authorize a live operation. Dropping the store never removes the fence.
final class LumeImageMaintenanceStore {
    private let source: LumeBaseImageSourceLocks
    private let expected: Data
    private let ownerUID = geteuid()
    private let ownerGID = getegid()
    private var pinned: Int32 = -1
    private var identity: stat?
    private var parent: Int32 { source.directoryDescriptor }

    init(source: LumeBaseImageSourceLocks, expected: Data) throws {
        guard !expected.isEmpty, expected.count <= 16 * 1024 else { throw failure() }
        self.source = source; self.expected = expected
        try source.validateIdentity()
    }

    deinit { if pinned >= 0 { close(pinned) } }

    func exists() throws -> Bool {
        try source.validateIdentity()
        var info = stat()
        if fstatat(parent, LumeOfflineOperationFence.fileName, &info, AT_SYMLINK_NOFOLLOW) == 0 { return true }
        guard errno == ENOENT else { throw failure() }
        return false
    }

    func requireAbsent() throws {
        guard try !exists() else { throw failure() }
    }

    func publish() throws {
        guard pinned < 0 else { throw failure() }
        try requireAbsent()
        let name = ".offline-" + UUID().uuidString.lowercased() + ".partial"
        let file = openat(parent, name, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard file >= 0 else { throw failure() }
        defer { close(file) }
        // Never publish partially written intent, even after an abrupt exit.
        guard unlinkat(parent, name, 0) == 0, fchown(file, ownerUID, ownerGID) == 0,
              fchmod(file, 0o600) == 0 else { throw failure() }
        try SandboxAuthorityFileSystem.writeAll(expected, to: file)
        try SandboxAuthorityFileSystem.synchronize(file)
        try source.validateIdentity()
        guard fclonefileat(file, parent, LumeOfflineOperationFence.fileName, 0) == 0 else { throw failure() }
        try SandboxAuthorityFileSystem.synchronize(parent)
        try pinMatching()
    }

    func pinMatching() throws {
        guard pinned < 0 else { throw failure() }
        try source.validateIdentity()
        let file = openat(parent, LumeOfflineOperationFence.fileName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard file >= 0 else { throw failure() }
        do {
            let info = try readMatching(file)
            try source.validateIdentity()
            identity = info; pinned = file
        } catch { close(file); throw error }
    }

    func validate() throws {
        guard pinned >= 0, let identity else { throw failure() }
        try source.validateIdentity()
        guard try SandboxAuthorityFileSystem.stableIdentity(identity, readMatching(pinned)) else { throw failure() }
        try source.validateIdentity()
    }

    /// Only the completion path may accept absence. Its protected journal must
    /// already contain the completion snapshot before calling this method.
    func removeAfterRecordedCleanup() throws {
        if try !exists() { return }
        try validate()
        guard unlinkat(parent, LumeOfflineOperationFence.fileName, 0) == 0 else { throw failure() }
        try SandboxAuthorityFileSystem.synchronize(parent)
        try requireAbsent()
    }

    private func readMatching(_ file: Int32) throws -> stat {
        let before = try metadata(file)
        let bytes = try SandboxAuthorityFileSystem.readStablePrivateFile(file, maximumBytes: 16 * 1024)
        let after = try metadata(file)
        guard bytes == expected, SandboxAuthorityFileSystem.stableIdentity(before, after) else { throw failure() }
        var named = stat()
        guard fstatat(parent, LumeOfflineOperationFence.fileName, &named, AT_SYMLINK_NOFOLLOW) == 0,
              SandboxAuthorityFileSystem.stableIdentity(after, named) else { throw failure() }
        return after
    }

    private func metadata(_ file: Int32) throws -> stat {
        let info = try SandboxAuthorityFileSystem.requirePrivateRegularFile(file,
            maximumBytes: 16 * 1024, allowEmpty: false)
        guard info.st_uid == ownerUID, info.st_gid == ownerGID, info.st_mode & 0o7777 == 0o600 else { throw failure() }
        return info
    }
}

private func failure() -> SandboxRuntimeError { .unsupported("offline image maintenance fence is unsafe or changed") }
