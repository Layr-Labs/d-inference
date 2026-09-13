import Darwin
import Foundation

public enum HostRuntimeOwnershipError: Error, Equatable, CustomStringConvertible {
    case authorityMissing
    case insecureAuthority
    case occupied
    case authorityChanged
    case systemError(Int32)

    public var description: String {
        switch self {
        case .authorityMissing: "machine runtime ownership has not been provisioned"
        case .insecureAuthority: "machine runtime ownership has unsafe permissions or identity"
        case .occupied: "another runtime owns this machine"
        case .authorityChanged: "machine runtime ownership authority was replaced"
        case .systemError(let code): "machine runtime ownership failed with errno \(code)"
        }
    }
}

/// A root-provisioned inode is the single authority shared by both runtimes.
/// This type never creates, repairs, truncates, or replaces system authority.
public struct HostRuntimeAuthority: Sendable {
    public static let system = HostRuntimeAuthority(directory: URL(
        fileURLWithPath: "/Library/Application Support/Darkbloom/runtime", isDirectory: true
    ))
    public static let groupName = "darkbloom_runtime"
    public static let lockName = "ownership.lock"
    public let directory: URL
    private let ownerUID: uid_t
    private let testGroupID: gid_t?
    private let testing: Bool

    public init(directory: URL) {
        self.directory = directory
        ownerUID = 0
        testGroupID = nil
        testing = false
    }

    package init(testDirectory: URL, ownerUID: uid_t, groupID: gid_t) {
        directory = testDirectory
        self.ownerUID = ownerUID
        testGroupID = groupID
        testing = true
    }

    /// Backward compatibility applies only before the authority directory exists.
    public func acquireInferenceIfInstalled() throws -> HostRuntimeLease? {
        try acquire(exclusive: false, allowMissing: true)
    }

    public func acquireSandbox() throws -> HostRuntimeLease {
        guard let lease = try acquire(exclusive: true, allowMissing: false) else {
            throw HostRuntimeOwnershipError.authorityMissing
        }
        return lease
    }

    private func acquire(exclusive: Bool, allowMissing: Bool) throws -> HostRuntimeLease? {
        let parent: Int32
        do { parent = try openDirectory() }
        catch HostRuntimeOwnershipError.authorityMissing where allowMissing { return nil }
        defer { close(parent) }
        let groupID: gid_t
        if let testGroupID { groupID = testGroupID }
        else {
            guard let group = getgrnam(Self.groupName) else {
                throw HostRuntimeOwnershipError.insecureAuthority
            }
            groupID = group.pointee.gr_gid
            guard groupID != 0 else { throw HostRuntimeOwnershipError.insecureAuthority }
        }
        let descriptor = openat(parent, Self.lockName, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ENOENT { throw HostRuntimeOwnershipError.authorityMissing }
            throw Self.pathError()
        }
        do {
            let metadata = try inspectLock(descriptor, groupID: groupID)
            let mode = (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB
            while flock(descriptor, mode) != 0 {
                if errno == EINTR { continue }
                if errno == EWOULDBLOCK { throw HostRuntimeOwnershipError.occupied }
                throw HostRuntimeOwnershipError.systemError(errno)
            }
            let directoryIdentity = try Self.metadata(parent)
            try validate(descriptor, directoryIdentity: directoryIdentity,
                         lockIdentity: metadata, groupID: groupID)
            return HostRuntimeLease(descriptor: descriptor, authority: self,
                                    directoryIdentity: directoryIdentity,
                                    lockIdentity: metadata, groupID: groupID,
                                    exclusive: exclusive)
        } catch {
            // Before ownership transfers into a lease, this scope owns the fd.
            close(descriptor)
            throw error
        }
    }

    fileprivate func validate(_ descriptor: Int32, directoryIdentity: stat,
                              lockIdentity: stat, groupID: gid_t) throws {
        let current: Int32
        do { current = try openDirectory() }
        catch { throw HostRuntimeOwnershipError.authorityChanged }
        defer { close(current) }
        var named = stat()
        let held = try inspectLock(descriptor, groupID: groupID)
        guard Self.sameIdentity(try Self.metadata(current), directoryIdentity),
              Self.sameIdentity(held, lockIdentity),
              fstatat(current, Self.lockName, &named, AT_SYMLINK_NOFOLLOW) == 0,
              Self.sameIdentity(named, held)
        else { throw HostRuntimeOwnershipError.authorityChanged }
    }

    private func openDirectory() throws -> Int32 {
        let original = directory.path
        let normalized = directory.standardizedFileURL.path
        let systemAlias = ["/var", "/tmp"].contains {
            normalized == $0 || normalized.hasPrefix($0 + "/")
        }
        guard directory.isFileURL, directory.baseURL == nil,
              original.hasPrefix("/"), !original.contains("\0"),
              normalized == original || (systemAlias && original == "/private" + normalized)
        else { throw HostRuntimeOwnershipError.insecureAuthority }
        // Foundation commonly emits /var and /tmp aliases. Expand these two
        // fixed system aliases; every subsequent component still uses O_NOFOLLOW.
        let path = systemAlias ? "/private" + normalized : original
        let components = path.split(separator: "/").map(String.init)
        guard !components.isEmpty, !components.contains("."), !components.contains("..") else {
            throw HostRuntimeOwnershipError.insecureAuthority
        }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw Self.pathError() }
        do {
            try inspectDirectory(descriptor, authority: false)
            for (index, component) in components.enumerated() {
                let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                guard next >= 0 else {
                    if errno == ENOENT { throw HostRuntimeOwnershipError.authorityMissing }
                    throw Self.pathError()
                }
                do { try inspectDirectory(next, authority: index == components.count - 1) }
                catch { close(next); throw error }
                close(descriptor)
                descriptor = next
            }
            return descriptor
        } catch { close(descriptor); throw error }
    }

    private func inspectDirectory(_ descriptor: Int32, authority: Bool) throws {
        let metadata = try Self.metadata(descriptor)
        let trustedOwner = metadata.st_uid == 0 || (testing && metadata.st_uid == ownerUID)
        let testTemporaryAncestor = testing && !authority && metadata.st_uid == 0
            && metadata.st_mode & mode_t(S_ISTXT) != 0
        guard metadata.st_mode & S_IFMT == S_IFDIR, trustedOwner,
              metadata.st_mode & 0o022 == 0 || testTemporaryAncestor,
              !authority || metadata.st_uid == ownerUID
        else { throw HostRuntimeOwnershipError.insecureAuthority }
        try Self.requireNoACL(descriptor)
    }

    private func inspectLock(_ descriptor: Int32, groupID: gid_t) throws -> stat {
        let metadata = try Self.metadata(descriptor)
        guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == ownerUID,
              metadata.st_gid == groupID, metadata.st_mode & 0o777 == 0o660,
              metadata.st_nlink == 1, metadata.st_size == 0
        else { throw HostRuntimeOwnershipError.insecureAuthority }
        try Self.requireNoACL(descriptor)
        return metadata
    }

    private static func requireNoACL(_ descriptor: Int32) throws {
        errno = 0
        if let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) {
            acl_free(UnsafeMutableRawPointer(acl))
            throw HostRuntimeOwnershipError.insecureAuthority
        }
        guard errno == ENOENT else { throw HostRuntimeOwnershipError.systemError(errno) }
    }

    private static func metadata(_ descriptor: Int32) throws -> stat {
        var value = stat()
        guard fstat(descriptor, &value) == 0 else { throw HostRuntimeOwnershipError.systemError(errno) }
        return value
    }

    private static func sameIdentity(_ first: stat, _ second: stat) -> Bool {
        first.st_dev == second.st_dev && first.st_ino == second.st_ino
    }

    private static func pathError() -> HostRuntimeOwnershipError {
        [ELOOP, ENOTDIR].contains(errno) ? .insecureAuthority : .systemError(errno)
    }
}

/// Retain through engine/VM cleanup. Closing its descriptor releases the kernel lock.
public final class HostRuntimeLease: @unchecked Sendable {
    private let descriptor: Int32
    private let authority: HostRuntimeAuthority
    private let directoryIdentity: stat
    private let lockIdentity: stat
    private let groupID: gid_t
    private let exclusive: Bool

    fileprivate init(descriptor: Int32, authority: HostRuntimeAuthority,
                     directoryIdentity: stat, lockIdentity: stat, groupID: gid_t,
                     exclusive: Bool) {
        self.descriptor = descriptor
        self.authority = authority
        self.directoryIdentity = directoryIdentity
        self.lockIdentity = lockIdentity
        self.groupID = groupID
        self.exclusive = exclusive
    }

    deinit { close(descriptor) }

    public func validate() throws {
        try authority.validate(descriptor, directoryIdentity: directoryIdentity,
                               lockIdentity: lockIdentity, groupID: groupID)
    }

    /// The descriptor is valid only inside `spawn`. Add a child-only dup2 spawn
    /// action; never clear CLOEXEC in the parent. The duplicate shares this
    /// lease's open file description, so closing the parent does not release
    /// exclusive ownership while the actual VM process still holds its copy.
    public func withInheritedDescriptor<T>(_ spawn: (Int32) throws -> T) throws -> T {
        guard exclusive else { throw HostRuntimeOwnershipError.insecureAuthority }
        try validate()
        let duplicate = fcntl(descriptor, F_DUPFD_CLOEXEC, 64)
        guard duplicate >= 0 else { throw HostRuntimeOwnershipError.systemError(errno) }
        defer { close(duplicate) }
        return try spawn(duplicate)
    }
}
