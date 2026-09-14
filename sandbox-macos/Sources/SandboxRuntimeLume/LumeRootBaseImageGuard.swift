import Darwin
import Foundation
import HostRuntimeCoordination
import SandboxRuntime

/// Root-only scope for the base operator. Machine ownership and source/native
/// locks remain held through offline IO and verified detach. The image fd also
/// remains open; a no-openers check must exclude only this exact owned fd.
/// Stopped-state, attachment inventory and Data-volume selection are separate
/// mandatory checks performed by the enclosing mount operation.
package final class LumeRootBaseImageGuard {
    private let machine: HostRuntimeLease
    private let source: LumeBaseImageSourceLocks
    package var imageURL: URL { source.imageURL }
    package var retainedImageDescriptor: Int32 { source.retainedImageDescriptor }

    package init(storage: URL, name: String, ownerUID: uid_t, ownerGID: gid_t,
                 reservationData: Data, expectedDisk: LumeCandidateDiskIdentity) throws {
        guard getuid() == 0, geteuid() == 0, getegid() == 0 else {
            throw SandboxRuntimeError.unsupported("offline base operations require the root operator")
        }
        let machine = try HostRuntimeAuthority.system.acquireSandbox()
        try machine.validateExclusive()
        source = try LumeBaseImageSourceLocks(storage: storage, name: name, ownerUID: ownerUID,
            ownerGID: ownerGID, reservationData: reservationData, expectedDisk: expectedDisk)
        self.machine = machine
        try validateUnchanged()
    }

    deinit { withExtendedLifetime(machine) { source.closeForScopeEnd() } }

    package func validateUnchanged() throws {
        try machine.validateExclusive()
        try source.validateUnchanged()
    }

    package func currentDiskIdentityAfterOwnedIO() throws -> LumeCandidateDiskIdentity {
        try machine.validateExclusive()
        return try source.currentDiskIdentityAfterOwnedIO()
    }
}
