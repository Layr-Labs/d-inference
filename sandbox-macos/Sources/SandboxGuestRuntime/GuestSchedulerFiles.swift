import Darwin
import Foundation
import SandboxGuestProtocol
import SandboxRuntime

enum GuestSchedulerFiles {
    private static let names = ["cron.allow", "at.allow"]
    private static let contents = Data("root\n".utf8)

    static func provision(in directory: URL, ownerUID: uid_t, initialOwnerUID: uid_t) throws {
        let root = try openInitialDirectory(at: directory, ownerUID: ownerUID, initialOwnerUID: initialOwnerUID)
        defer { close(root) }
        let metadata = try SandboxAuthorityFileSystem.fileMetadata(root)
        guard metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == ownerUID || metadata.st_uid == initialOwnerUID,
              metadata.st_mode & 0o022 == 0 else { throw GuestProtocolError.invalidConfiguration }
        try SandboxAuthorityFileSystem.requireNoExtendedACL(root)
        // Fresh macOS owns this directory as daemon. Retire that write authority
        // before placing root policy files; deny arbitrary prior policy instead
        // of overwriting an unknown image's scheduler configuration.
        guard fchown(root, ownerUID, gid_t.max) == 0, fchmod(root, 0o755) == 0 else {
            throw GuestProtocolError.invalidConfiguration
        }
        for name in names {
            if try validateFile(name, parent: root, ownerUID: ownerUID, allowAbsent: true) { continue }
            let fd = openat(root, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw GuestProtocolError.invalidConfiguration }
            defer { close(fd) }
            try SandboxAuthorityFileSystem.writeAll(contents, to: fd)
            guard fchmod(fd, 0o644) == 0 else { throw GuestProtocolError.invalidConfiguration }
            try SandboxAuthorityFileSystem.synchronize(fd)
        }
        try SandboxAuthorityFileSystem.synchronize(root)
        try validate(in: directory, ownerUID: ownerUID)
    }

    /// The generic opener correctly rejects daemon-owned authority. During the
    /// one-time bootstrap handoff only this leaf may still belong to daemon;
    /// its parent and every ancestor retain the ordinary authority policy.
    static func openInitialDirectory(at directory: URL, ownerUID: uid_t, initialOwnerUID: uid_t) throws -> Int32 {
        guard let path = SandboxAuthorityFileSystem.canonicalPath(for: directory) else {
            throw GuestProtocolError.invalidConfiguration
        }
        let canonical = URL(fileURLWithPath: path)
        let parent = try SandboxAuthorityFileSystem.openExistingDirectory(at: canonical.deletingLastPathComponent())
        defer { close(parent) }
        let root = openat(parent, canonical.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw SandboxAuthorityFileSystemError.io(errno) }
        do {
            let metadata = try SandboxAuthorityFileSystem.fileMetadata(root)
            let parentMetadata = try SandboxAuthorityFileSystem.fileMetadata(parent)
            guard metadata.st_mode & S_IFMT == S_IFDIR, metadata.st_dev == parentMetadata.st_dev,
                  metadata.st_uid == ownerUID || metadata.st_uid == initialOwnerUID,
                  metadata.st_mode & 0o022 == 0 else { throw GuestProtocolError.invalidConfiguration }
            try SandboxAuthorityFileSystem.requireNoExtendedACL(root)
            var named = stat()
            guard fstatat(parent, canonical.lastPathComponent, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  SandboxAuthorityFileSystem.sameIdentity(named, metadata) else {
                throw GuestProtocolError.invalidConfiguration
            }
            return root
        } catch {
            close(root)
            throw error
        }
    }

    static func validate(in directory: URL, ownerUID: uid_t) throws {
        let root = try SandboxAuthorityFileSystem.openExistingDirectory(at: directory)
        defer { close(root) }
        let metadata = try SandboxAuthorityFileSystem.fileMetadata(root)
        guard metadata.st_mode & S_IFMT == S_IFDIR, metadata.st_uid == ownerUID,
              metadata.st_mode & 0o022 == 0 else { throw GuestProtocolError.invalidConfiguration }
        try SandboxAuthorityFileSystem.requireNoExtendedACL(root)
        for name in names { _ = try validateFile(name, parent: root, ownerUID: ownerUID, allowAbsent: false) }
    }

    @discardableResult
    private static func validateFile(_ name: String, parent: Int32, ownerUID: uid_t, allowAbsent: Bool) throws -> Bool {
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0, errno == ENOENT, allowAbsent { return false }
        guard fd >= 0 else { throw GuestProtocolError.invalidConfiguration }
        defer { close(fd) }
        let metadata = try SandboxAuthorityFileSystem.fileMetadata(fd)
        guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == ownerUID,
              metadata.st_nlink == 1, metadata.st_mode & 0o7777 == 0o644,
              metadata.st_size == contents.count else { throw GuestProtocolError.invalidConfiguration }
        try SandboxAuthorityFileSystem.requireNoExtendedACL(fd)
        guard try GuestDescriptor.read(fd, count: contents.count) == contents else {
            throw GuestProtocolError.invalidConfiguration
        }
        return true
    }
}
