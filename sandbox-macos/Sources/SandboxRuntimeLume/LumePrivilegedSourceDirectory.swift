import Darwin
import Foundation
import SandboxRuntime

/// An explicit owner's existing private source namespace. Unlike ordinary VM
/// IO this reader can be used by root, but never creates or adopts directories.
final class LumePrivilegedSourceDirectory {
    let descriptor: Int32
    let ownerUID: uid_t
    let ownerGID: gid_t
    let path: URL

    init(path: URL, ownerUID: uid_t, ownerGID: gid_t) throws {
        guard ownerUID > 0, ownerUID != .max, ownerGID > 0, ownerGID != .max,
              geteuid() == 0 || geteuid() == ownerUID,
              let canonical = SandboxAuthorityFileSystem.canonicalPath(for: path) else { throw failure() }
        var current = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard current >= 0 else { throw failure() }
        do {
            try Self.requireAncestor(current, ownerUID: ownerUID)
            for part in canonical.split(separator: "/") {
                let next = openat(current, String(part), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                guard next >= 0 else { throw failure() }
                do { try Self.requireAncestor(next, ownerUID: ownerUID) }
                catch { close(next); throw error }
                close(current); current = next
            }
            try Self.requirePrivateDirectory(current, ownerUID: ownerUID, ownerGID: ownerGID)
        } catch { close(current); throw error }
        descriptor = current; self.ownerUID = ownerUID; self.ownerGID = ownerGID
        self.path = URL(fileURLWithPath: canonical, isDirectory: true)
    }

    deinit { close(descriptor) }

    func child(_ name: String) throws -> LumePrivilegedSourceDirectory {
        try Self.requireComponent(name)
        let child = try LumePrivilegedSourceDirectory(path: path.appendingPathComponent(name), ownerUID: ownerUID, ownerGID: ownerGID)
        var named = stat()
        guard fstatat(descriptor, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              try SandboxAuthorityFileSystem.sameIdentity(named, SandboxAuthorityFileSystem.fileMetadata(child.descriptor)) else { throw failure() }
        return child
    }

    func validate() throws {
        let current = try Self(path: path, ownerUID: ownerUID, ownerGID: ownerGID)
        guard try SandboxAuthorityFileSystem.sameIdentity(SandboxAuthorityFileSystem.fileMetadata(descriptor),
            SandboxAuthorityFileSystem.fileMetadata(current.descriptor)) else { throw failure() }
    }

    func requireAbsent(_ name: String) throws {
        try Self.requireComponent(name)
        var info = stat()
        if fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { throw failure() }
        guard errno == ENOENT else { throw failure() }
    }

    func openFile(_ name: String, writable: Bool = false, privateMode: Bool = true,
                  maximumBytes: Int64? = nil, allowEmpty: Bool = true) throws -> Int32 {
        try Self.requireComponent(name)
        let file = openat(descriptor, name, (writable ? O_RDWR : O_RDONLY) | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard file >= 0 else { throw failure() }
        do {
            let info = try metadata(file, name: name, privateMode: privateMode, maximumBytes: maximumBytes, allowEmpty: allowEmpty)
            guard !writable || info.st_mode & 0o600 == 0o600 else { throw failure() }
            return file
        } catch { close(file); throw error }
    }

    func openPersistentLock(_ name: String, privateMode: Bool, createIfMissing: Bool) throws -> Int32 {
        try Self.requireComponent(name)
        if createIfMissing {
            let created = openat(descriptor, name, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
            if created >= 0 {
                do {
                    guard fchown(created, ownerUID, ownerGID) == 0, fchmod(created, 0o600) == 0 else { throw failure() }
                    _ = try metadata(created, name: name, privateMode: true, maximumBytes: 0)
                    try SandboxAuthorityFileSystem.synchronize(created)
                    try SandboxAuthorityFileSystem.synchronize(descriptor)
                    return created
                } catch { close(created); throw error }
            }
            guard errno == EEXIST else { throw failure() }
        }
        return try openFile(name, writable: true, privateMode: privateMode, maximumBytes: 64 * 1024)
    }

    func metadata(_ file: Int32, name: String, privateMode: Bool = true,
                  maximumBytes: Int64? = nil, allowEmpty: Bool = true) throws -> stat {
        let info = try SandboxAuthorityFileSystem.fileMetadata(file)
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == ownerUID, info.st_gid == ownerGID,
              info.st_nlink == 1, info.st_mode & 0o7111 == 0, info.st_mode & 0o022 == 0,
              !privateMode || info.st_mode & 0o077 == 0, info.st_size >= 0,
              allowEmpty || info.st_size > 0, maximumBytes.map({ info.st_size <= $0 }) ?? true else { throw failure() }
        try SandboxAuthorityFileSystem.requireNoExtendedACL(file)
        var named = stat()
        guard fstatat(descriptor, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              SandboxAuthorityFileSystem.stableIdentity(info, named) else { throw failure() }
        return info
    }

    func readRecord(_ name: String) throws -> Data {
        let file = try openFile(name, maximumBytes: 16 * 1024, allowEmpty: false)
        defer { close(file) }
        let before = try metadata(file, name: name, maximumBytes: 16 * 1024, allowEmpty: false)
        var data = Data(count: Int(before.st_size)), offset = 0
        try data.withUnsafeMutableBytes { bytes in
            while offset < bytes.count {
                let count = pread(file, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, off_t(offset))
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw failure() }
                offset += count
            }
        }
        guard try SandboxAuthorityFileSystem.stableIdentity(before,
            metadata(file, name: name, maximumBytes: 16 * 1024, allowEmpty: false)) else { throw failure() }
        return data
    }

    private static func requirePrivateDirectory(_ file: Int32, ownerUID: uid_t, ownerGID: gid_t) throws {
        let info = try SandboxAuthorityFileSystem.fileMetadata(file)
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == ownerUID, info.st_gid == ownerGID,
              info.st_mode & 0o7777 == 0o700 else { throw failure() }
        try SandboxAuthorityFileSystem.requireNoExtendedACL(file)
    }

    private static func requireAncestor(_ file: Int32, ownerUID: uid_t) throws {
        let info = try SandboxAuthorityFileSystem.fileMetadata(file)
        let protectedTemporary = info.st_uid == 0 && info.st_mode & mode_t(S_ISTXT) != 0
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == 0 || info.st_uid == ownerUID,
              info.st_mode & 0o022 == 0 || protectedTemporary else { throw failure() }
        try SandboxAuthorityFileSystem.requireNoExtendedACL(file)
    }

    private static func requireComponent(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else { throw failure() }
    }
}

private func failure() -> SandboxRuntimeError { .unsupported("privileged base source namespace is unsafe or changed") }
