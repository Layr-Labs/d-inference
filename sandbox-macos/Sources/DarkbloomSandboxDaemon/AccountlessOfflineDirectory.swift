import Darwin
import Foundation
import SandboxRuntime

/// Descriptor-relative IO for the privileged operator's payload and mounted
/// Data volume. The enclosing operator must first prove image/mount authority.
/// Tests use owned temporary directories; this type never mounts a filesystem.
final class AccountlessOfflineDirectory {
    let descriptor: Int32
    let device: dev_t

    init(path: URL) throws {
        let file = try SandboxAuthorityFileSystem.openExistingDirectory(at: path)
        do {
            let info = try Self.requireDirectory(file)
            descriptor = file; device = info.st_dev
        } catch { close(file); throw error }
    }

    private init(descriptor: Int32, device: dev_t) { self.descriptor = descriptor; self.device = device }
    deinit { close(descriptor) }

    func requireBound(to path: URL) throws {
        let current = try AccountlessOfflineDirectory(path: path)
        guard try SandboxAuthorityFileSystem.sameIdentity(SandboxAuthorityFileSystem.fileMetadata(descriptor),
            SandboxAuthorityFileSystem.fileMetadata(current.descriptor)) else {
            throw AccountlessInstallationError.unsafeDestination
        }
    }

    func child(_ name: String, create: Bool = false) throws -> AccountlessOfflineDirectory {
        try Self.requireComponent(name)
        if create {
            if mkdirat(descriptor, name, 0o700) == 0 {
                try SandboxAuthorityFileSystem.synchronize(descriptor)
            } else if errno != EEXIST { throw AccountlessInstallationError.unsafeDestination }
        }
        let file = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard file >= 0 else { throw AccountlessInstallationError.unsafeDestination }
        do {
            guard try Self.requireDirectory(file).st_dev == device else { throw AccountlessInstallationError.unsafeDestination }
            try requireNamed(file, name: name)
            return .init(descriptor: file, device: device)
        } catch { close(file); throw error }
    }

    func descend(_ relative: String) throws -> AccountlessOfflineDirectory {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty else { throw AccountlessInstallationError.unsafeDestination }
        var directory = self
        for part in parts { directory = try directory.child(part) }
        return directory
    }

    func names() throws -> Set<String> {
        let copied = dup(descriptor)
        guard copied >= 0 else { throw AccountlessInstallationError.unsafeDestination }
        guard let stream = fdopendir(copied) else { close(copied); throw AccountlessInstallationError.unsafeDestination }
        defer { closedir(stream) }
        rewinddir(stream)
        var names = Set<String>()
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw AccountlessInstallationError.unsafeDestination }
                return names
            }
            var raw = entry.pointee.d_name
            let name = withUnsafePointer(to: &raw) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            try Self.requireComponent(name)
            guard names.insert(name).inserted, names.count <= 32 else { throw AccountlessInstallationError.unsafeDestination }
        }
    }

    func openFile(_ name: String, mode: UInt16, maximumBytes: Int = 128 * 1_048_576,
                  allowEmpty: Bool = false, allowPublic: Bool = false) throws -> Int32 {
        try Self.requireComponent(name)
        let file = openat(descriptor, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard file >= 0 else { throw AccountlessInstallationError.unsafeDestination }
        do {
            let info: stat
            if allowPublic {
                info = try SandboxAuthorityFileSystem.fileMetadata(file)
                guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_gid == getegid(),
                      info.st_nlink == 1, info.st_size >= 0, info.st_size <= maximumBytes,
                      allowEmpty || info.st_size > 0, info.st_mode & 0o022 == 0 else { throw AccountlessInstallationError.unsafeDestination }
                try SandboxAuthorityFileSystem.requireNoExtendedACL(file)
            } else {
                info = try SandboxAuthorityFileSystem.requirePrivateRegularFile(file, maximumBytes: maximumBytes, allowEmpty: allowEmpty)
            }
            guard info.st_dev == device, info.st_mode & 0o7777 == mode else { throw AccountlessInstallationError.unsafeDestination }
            try requireNamed(file, name: name)
            return file
        } catch { close(file); throw error }
    }

    func contains(_ name: String) throws -> Bool {
        try Self.requireComponent(name)
        var info = stat()
        if fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { return true }
        guard errno == ENOENT else { throw AccountlessInstallationError.unsafeDestination }
        return false
    }

    func requireNamed(_ file: Int32, name: String) throws {
        var named = stat()
        guard fstatat(descriptor, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              try SandboxAuthorityFileSystem.stableIdentity(SandboxAuthorityFileSystem.fileMetadata(file), named)
        else { throw AccountlessInstallationError.unsafeDestination }
    }

    private static func requireDirectory(_ file: Int32) throws -> stat {
        let info = try SandboxAuthorityFileSystem.fileMetadata(file)
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(),
              info.st_mode & 0o700 == 0o700, info.st_mode & 0o7022 == 0 else {
            throw AccountlessInstallationError.unsafeDestination
        }
        try SandboxAuthorityFileSystem.requireNoExtendedACL(file)
        return info
    }

    private static func requireComponent(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw AccountlessInstallationError.unsafeDestination
        }
    }
}
