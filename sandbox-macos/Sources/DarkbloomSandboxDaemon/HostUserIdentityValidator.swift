import Darwin
import Foundation

struct HostUserProcessIdentity: Equatable, Sendable {
    let realUID: UInt32
    let effectiveUID: UInt32
    let realGID: UInt32
    let effectiveGID: UInt32

    static func capture() -> Self {
        Self(realUID: getuid(), effectiveUID: geteuid(), realGID: getgid(), effectiveGID: getegid())
    }
}

enum HostUserIdentityValidator {
    @discardableResult
    static func validate(file: URL, hostID: UUID,
                         read: (URL) throws -> Data = HostUserIdentityFile.read,
                         process: () -> HostUserProcessIdentity = HostUserProcessIdentity.capture,
                         lookup: (HostUserIdentity) throws -> HostUserIdentity = HostUserAccountLookup.lookup,
                         home: (HostUserIdentity) throws -> Void = HostUserAccountLookup.requireOwnedHome) throws -> HostUserIdentity {
        let binding = try HostUserIdentityBinding.decode(read(file), hostID: hostID)
        let selected = binding.host_user
        let before = process()
        let required = HostUserProcessIdentity(realUID: selected.uid, effectiveUID: selected.uid,
                                              realGID: selected.primaryGID, effectiveGID: selected.primaryGID)
        guard before == required else { throw HostUserIdentityError.identityMismatch }
        let actual = try lookup(selected)
        try actual.validate()
        guard actual == selected else { throw HostUserIdentityError.identityMismatch }
        try home(selected)
        guard process() == before else { throw HostUserIdentityError.identityMismatch }
        return selected
    }
}
