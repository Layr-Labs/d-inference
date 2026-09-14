import Darwin
import Foundation
import SandboxRuntime

enum AccountlessMountedDataVolume {
    /// The caller has verified diskutil UUID and ownership policy immediately
    /// before this check. The opened mount is pinned through all payload IO.
    static func withVerifiedDirectory<T>(at mountpoint: URL, binding: AccountlessAPFSVolumeBinding,
                                        writable: Bool, _ body: () throws -> T) throws -> T {
        let descriptor = try SandboxAuthorityFileSystem.openExistingDirectory(at: mountpoint)
        defer { close(descriptor) }
        let before = try SandboxAuthorityFileSystem.fileMetadata(descriptor)
        guard before.st_uid == 0, before.st_mode & S_IFMT == S_IFDIR,
              before.st_mode & 0o022 == 0 else { throw AccountlessDiskError.unsafeMountpoint }
        try SandboxAuthorityFileSystem.requireNoExtendedACL(descriptor)
        try requireFilesystem(descriptor, binding: binding, mountpoint: mountpoint, writable: writable)
        let result = try body()
        let current = try SandboxAuthorityFileSystem.openExistingDirectory(at: mountpoint)
        defer { close(current) }
        guard try SandboxAuthorityFileSystem.sameIdentity(before, SandboxAuthorityFileSystem.fileMetadata(current)) else {
            throw AccountlessDiskError.bindingChanged
        }
        try requireFilesystem(descriptor, binding: binding, mountpoint: mountpoint, writable: writable)
        return result
    }

    private static func requireFilesystem(_ descriptor: Int32, binding: AccountlessAPFSVolumeBinding,
                                          mountpoint: URL, writable: Bool) throws {
        var info = statfs()
        guard fstatfs(descriptor, &info) == 0 else { throw AccountlessDiskError.unsafeMountpoint }
        func string<T>(_ field: T) -> String { withUnsafeBytes(of: field) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) } }
        let required = UInt32(MNT_NOEXEC | MNT_NOSUID | MNT_NODEV | MNT_DONTBROWSE)
        guard string(info.f_fstypename) == "apfs", string(info.f_mntfromname) == binding.dataVolume.nodePath,
              string(info.f_mntonname) == mountpoint.path, info.f_flags & required == required,
              info.f_flags & UInt32(MNT_IGNORE_OWNERSHIP) == 0,
              (info.f_flags & UInt32(MNT_RDONLY) == 0) == writable else { throw AccountlessDiskError.unsafeMountpoint }
    }
}
