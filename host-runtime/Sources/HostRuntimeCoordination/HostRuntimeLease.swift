import Darwin
import Foundation

/// Retain through engine/VM cleanup. Closing its descriptor releases the kernel lock.
public final class HostRuntimeLease: @unchecked Sendable {
    private let descriptor: Int32
    let authority: HostRuntimeAuthority
    private let directoryIdentity: stat
    private let lockIdentity: stat
    private let groupID: gid_t
    private let exclusive: Bool

    init(descriptor: Int32, authority: HostRuntimeAuthority,
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

    /// Require machine-exclusive ownership before beginning VM installation.
    public func validateExclusive() throws {
        guard exclusive else { throw HostRuntimeOwnershipError.insecureAuthority }
        try validate()
    }

    /// Privileged base operations must use the permanent system authority,
    /// never an alternate or test authority supplied by a caller.
    public func validateSystemExclusive() throws {
        guard !authority.testing,
              authority.directory.standardizedFileURL == HostRuntimeAuthority.system.directory.standardizedFileURL else {
            throw HostRuntimeOwnershipError.insecureAuthority
        }
        try validateExclusive()
    }

    /// The descriptor is valid only inside `spawn`. Add a child-only dup2 spawn
    /// action; never clear CLOEXEC in the parent. The duplicate shares this
    /// lease's open file description, so closing the parent does not release
    /// exclusive ownership while the actual VM process still holds its copy.
    public func withInheritedDescriptor<T>(_ spawn: (Int32) throws -> T) throws -> T {
        try validateExclusive()
        let duplicate = fcntl(descriptor, F_DUPFD_CLOEXEC, 64)
        guard duplicate >= 0 else { throw HostRuntimeOwnershipError.systemError(errno) }
        defer { close(duplicate) }
        return try spawn(duplicate)
    }
}
