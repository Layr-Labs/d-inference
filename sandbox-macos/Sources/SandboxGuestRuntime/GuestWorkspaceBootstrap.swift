import Darwin
import Foundation
import SandboxGuestProtocol
import SandboxRuntime

/// The supervisor never repairs a tenant-controlled pathname with a privileged
/// path-based chown/chmod. Namespace changes after open affect only the opened
/// inode, and mount/symlink substitutions fail before mutation.
enum GuestWorkspaceBootstrap {
    static func prepare(
        path: String,
        tenantUID: uid_t,
        tenantGID: gid_t,
        supervisorUID: uid_t = 0,
        requireSeparateVolume: Bool = true,
        quiesce: () async throws -> Void
    ) async throws -> GuestWorkspace {
        try await quiesce()
        try Task.checkCancellation()
        try prepareDirectories(path: path, tenantUID: tenantUID, tenantGID: tenantGID,
                               supervisorUID: supervisorUID, requireSeparateVolume: requireSeparateVolume)
        return try GuestWorkspace(path: path, tenantUID: tenantUID, tenantGID: tenantGID,
                                  requireSeparateVolume: requireSeparateVolume)
    }

    static func prepareDirectories(
        path: String,
        tenantUID: uid_t,
        tenantGID: gid_t,
        supervisorUID: uid_t = 0,
        requireSeparateVolume: Bool = true
    ) throws {
        let root = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard root >= 0 else { throw GuestProtocolError.invalidConfiguration }
        defer { close(root) }
        let rootInfo = try SandboxAuthorityFileSystem.fileMetadata(root)
        var boot = stat()
        guard rootInfo.st_mode & S_IFMT == S_IFDIR, stat("/", &boot) == 0,
              !requireSeparateVolume || rootInfo.st_dev != boot.st_dev
        else { throw GuestProtocolError.invalidConfiguration }
        try SandboxAuthorityFileSystem.requireNoExtendedACL(root)
        guard fchown(root, supervisorUID, tenantGID) == 0, fchmod(root, 0o1770) == 0 else {
            throw GuestProtocolError.invalidConfiguration
        }

        let created = mkdirat(root, ".tmp", 0o700) == 0
        guard created || errno == EEXIST else { throw GuestProtocolError.invalidConfiguration }
        let temporary = openat(root, ".tmp", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard temporary >= 0 else { throw GuestProtocolError.invalidConfiguration }
        defer { close(temporary) }
        let info = try SandboxAuthorityFileSystem.fileMetadata(temporary)
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_dev == rootInfo.st_dev,
              info.st_uid == supervisorUID || info.st_uid == tenantUID
        else { throw GuestProtocolError.invalidConfiguration }
        try SandboxAuthorityFileSystem.requireNoExtendedACL(temporary)
        guard fchown(temporary, tenantUID, tenantGID) == 0,
              fchmod(temporary, 0o700) == 0,
              fsync(temporary) == 0, fsync(root) == 0
        else { throw GuestProtocolError.invalidConfiguration }
        var named = stat()
        guard fstatat(root, ".tmp", &named, AT_SYMLINK_NOFOLLOW) == 0,
              named.st_dev == info.st_dev, named.st_ino == info.st_ino
        else { throw GuestProtocolError.invalidConfiguration }
    }
}
