import Darwin
import Foundation
import SandboxRuntime

enum AccountlessSystemCommandExecutable {
    /// Relaunch only the current immutable root-owned executable. argv[0] is not
    /// an executable identity and a mutable user checkout is not a worker install.
    static func current() throws -> URL {
        guard let executable = Bundle.main.executableURL else { throw AccountlessDiskError.bindingChanged }
        let parent = try SandboxAuthorityFileSystem.openExistingDirectory(at: executable.deletingLastPathComponent())
        defer { close(parent) }
        let file = openat(parent, executable.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard file >= 0 else { throw AccountlessDiskError.bindingChanged }
        defer { close(file) }
        let info = try SandboxAuthorityFileSystem.fileMetadata(file)
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == 0, info.st_gid == 0, info.st_nlink == 1,
              info.st_size > 0, info.st_mode & 0o7222 == 0, info.st_mode & 0o111 != 0 else {
            throw AccountlessDiskError.bindingChanged
        }
        try SandboxAuthorityFileSystem.requireNoExtendedACL(file)
        var named = stat()
        guard fstatat(parent, executable.lastPathComponent, &named, AT_SYMLINK_NOFOLLOW) == 0,
              SandboxAuthorityFileSystem.stableIdentity(info, named) else { throw AccountlessDiskError.bindingChanged }
        return executable
    }
}
