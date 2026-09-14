import Darwin
import Foundation

/// A root-private immutable fence beside the permanent authority inode. Normal
/// admission needs only an absence check; only the root operator reads content.
final class HostRuntimeMaintenanceStore {
    private let authority: HostRuntimeAuthority
    private let parent: Int32
    private var pinnedRecord: Int32 = -1

    init(authority: HostRuntimeAuthority) throws {
        self.authority = authority
        parent = try authority.openDirectory()
    }
    deinit { if pinnedRecord >= 0 { close(pinnedRecord) }; close(parent) }

    func pinMatchingRecord(_ expected: Data) throws -> stat {
        guard pinnedRecord < 0 else { throw HostRuntimeOwnershipError.maintenanceChanged }
        try validateParent()
        let file = try Self.openRecord(parent: parent)
        do {
            let info = try Self.readMatching(file, parent: parent, ownerUID: authority.ownerUID,
                ownerGID: authority.maintenanceOwnerGID, expected: expected)
            try validateParent()
            pinnedRecord = file
            return info
        } catch { close(file); throw error }
    }

    static func requireAbsent(parent: Int32) throws {
        var info = stat()
        if fstatat(parent, HostRuntimeAuthority.maintenanceFileName, &info, AT_SYMLINK_NOFOLLOW) == 0 {
            throw HostRuntimeOwnershipError.maintenancePending
        }
        guard errno == ENOENT else { throw HostRuntimeOwnershipError.systemError(errno) }
    }

    func publish(_ data: Data) throws {
        try validateParent()
        try Self.requireAbsent(parent: parent)
        guard !data.isEmpty, data.count <= 4096 else { throw HostRuntimeOwnershipError.invalidMaintenanceIntent }
        let temporaryName = ".maintenance-" + UUID().uuidString.lowercased() + ".partial"
        let file = openat(parent, temporaryName, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard file >= 0 else { throw HostRuntimeOwnershipError.systemError(errno) }
        defer { close(file) }
        // Unlink before writing so an interrupted partial file never becomes a
        // maintenance record. fclonefileat publishes completed bytes exclusively.
        guard unlinkat(parent, temporaryName, 0) == 0 else { throw HostRuntimeOwnershipError.systemError(errno) }
        guard fchown(file, authority.ownerUID, authority.maintenanceOwnerGID) == 0,
              fchmod(file, 0o600) == 0 else { throw HostRuntimeOwnershipError.systemError(errno) }
        try Self.writeAll(data, to: file)
        try Self.synchronize(file)
        try validateParent()
        guard fclonefileat(file, parent, HostRuntimeAuthority.maintenanceFileName, 0) == 0 else {
            if errno == EEXIST { throw HostRuntimeOwnershipError.maintenancePending }
            throw HostRuntimeOwnershipError.systemError(errno)
        }
        try Self.synchronize(parent)
        try requireMatching(data)
    }

    @discardableResult
    func requireMatching(_ expected: Data, identity: stat? = nil) throws -> stat {
        try validateParent()
        let current = try pinnedRecord >= 0
            ? Self.readMatching(pinnedRecord, parent: parent, ownerUID: authority.ownerUID,
                ownerGID: authority.maintenanceOwnerGID, expected: expected)
            : Self.requireMatching(parent: parent, ownerUID: authority.ownerUID,
                ownerGID: authority.maintenanceOwnerGID, expected: expected)
        guard identity.map({ Self.stable($0, current) }) ?? true else { throw HostRuntimeOwnershipError.maintenanceChanged }
        try validateParent()
        return current
    }

    @discardableResult
    static func requireMatching(parent: Int32, ownerUID: uid_t, ownerGID: gid_t, expected: Data) throws -> stat {
        let file = try openRecord(parent: parent)
        defer { close(file) }
        return try readMatching(file, parent: parent, ownerUID: ownerUID, ownerGID: ownerGID, expected: expected)
    }

    func removeMatching(_ expected: Data, identity: stat) throws {
        try validateParent()
        let file = try Self.openRecord(parent: parent)
        defer { close(file) }
        let original = try Self.readMatching(file, parent: parent, ownerUID: authority.ownerUID,
            ownerGID: authority.maintenanceOwnerGID, expected: expected)
        guard Self.stable(original, identity) else { throw HostRuntimeOwnershipError.maintenanceChanged }
        try validateParent()
        try Self.requireNamed(original, parent: parent)
        guard unlinkat(parent, HostRuntimeAuthority.maintenanceFileName, 0) == 0 else {
            throw HostRuntimeOwnershipError.systemError(errno)
        }
        try Self.synchronize(parent)
        try Self.requireAbsent(parent: parent)
        try validateParent()
    }

    private func validateParent() throws {
        let current = try authority.openDirectory()
        defer { close(current) }
        let before = try Self.metadata(parent), named = try Self.metadata(current)
        guard before.st_dev == named.st_dev, before.st_ino == named.st_ino else {
            throw HostRuntimeOwnershipError.maintenanceChanged
        }
    }

    private static func openRecord(parent: Int32) throws -> Int32 {
        let file = openat(parent, HostRuntimeAuthority.maintenanceFileName, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard file >= 0 else { throw HostRuntimeOwnershipError.maintenanceChanged }
        return file
    }

    private static func readMatching(_ file: Int32, parent: Int32, ownerUID: uid_t,
                                     ownerGID: gid_t, expected: Data) throws -> stat {
        let before = try requirePrivateRecord(file, ownerUID: ownerUID, ownerGID: ownerGID)
        guard before.st_size == expected.count else { throw HostRuntimeOwnershipError.maintenanceChanged }
        var data = Data(count: Int(before.st_size)), offset = 0
        try data.withUnsafeMutableBytes { bytes in
            while offset < bytes.count {
                let count = pread(file, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, off_t(offset))
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw HostRuntimeOwnershipError.maintenanceChanged }
                offset += count
            }
        }
        let after = try requirePrivateRecord(file, ownerUID: ownerUID, ownerGID: ownerGID)
        guard data == expected, stable(before, after) else { throw HostRuntimeOwnershipError.maintenanceChanged }
        try requireNamed(after, parent: parent)
        return after
    }

    private static func requirePrivateRecord(_ file: Int32, ownerUID: uid_t, ownerGID: gid_t) throws -> stat {
        let info = try metadata(file)
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == ownerUID, info.st_gid == ownerGID,
              info.st_mode & 0o7777 == 0o600, info.st_nlink == 1, info.st_size > 0, info.st_size <= 4096 else {
            throw HostRuntimeOwnershipError.maintenanceChanged
        }
        errno = 0
        if let acl = acl_get_fd_np(file, ACL_TYPE_EXTENDED) {
            acl_free(UnsafeMutableRawPointer(acl))
            throw HostRuntimeOwnershipError.maintenanceChanged
        }
        guard errno == ENOENT else { throw HostRuntimeOwnershipError.systemError(errno) }
        return info
    }

    private static func requireNamed(_ original: stat, parent: Int32) throws {
        var named = stat()
        guard fstatat(parent, HostRuntimeAuthority.maintenanceFileName, &named, AT_SYMLINK_NOFOLLOW) == 0,
              stable(original, named) else { throw HostRuntimeOwnershipError.maintenanceChanged }
    }

    private static func stable(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode
            && a.st_uid == b.st_uid && a.st_gid == b.st_gid && a.st_nlink == b.st_nlink
            && a.st_size == b.st_size && a.st_flags == b.st_flags && a.st_gen == b.st_gen
            && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
            && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }

    private static func metadata(_ file: Int32) throws -> stat {
        var info = stat()
        guard fstat(file, &info) == 0 else { throw HostRuntimeOwnershipError.systemError(errno) }
        return info
    }

    private static func writeAll(_ data: Data, to file: Int32) throws {
        var offset = 0
        try data.withUnsafeBytes { bytes in
            while offset < bytes.count {
                let count = write(file, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw HostRuntimeOwnershipError.systemError(count == 0 ? EIO : errno) }
                offset += count
            }
        }
    }

    private static func synchronize(_ file: Int32) throws {
        while fsync(file) != 0 {
            guard errno == EINTR else { throw HostRuntimeOwnershipError.systemError(errno) }
        }
    }
}
