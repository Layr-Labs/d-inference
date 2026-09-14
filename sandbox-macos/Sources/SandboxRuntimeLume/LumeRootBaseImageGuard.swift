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

    package init(storage: URL, name: String, ownerUID: uid_t, ownerGID: gid_t,
                 reservationData: Data, expectedDisk: LumeCandidateDiskIdentity) throws {
        try Self.requireRoot()
        let machine = try HostRuntimeAuthority.system.acquireSandbox()
        try machine.validateSystemExclusive()
        source = try LumeBaseImageSourceLocks(storage: storage, name: name, ownerUID: ownerUID,
            ownerGID: ownerGID, reservationData: reservationData, expectedDisk: expectedDisk)
        self.machine = machine
        try validateUnchanged()
    }

    deinit { withExtendedLifetime(machine) { source.closeForScopeEnd() } }

    package func validateUnchanged() throws {
        try machine.validateSystemExclusive()
        try source.validateUnchanged()
    }

    package func beginMaintenance(intent: HostRuntimeMaintenanceIntent,
                                  encodedCandidate: Data) throws -> LumeRootImageMaintenance {
        try Self.requireRoot()
        try validateUnchanged()
        try source.requireReservation(encodedCandidate)
        // Do not create a new global intent over an unrelated image fence.
        try LumeOfflineOperationFence.requireAbsent(directory: source.directoryDescriptor, name: source.baseSource.name)
        let maintenance = try machine.beginRootMaintenance(intent)
        let image = try LumeImageMaintenanceState(source: source, intent: intent, recovering: false)
        return try LumeRootImageMaintenance(guard: self, maintenance: maintenance, image: image)
    }

    package static func recoverMaintenance(storage: URL, name: String, ownerUID: uid_t, ownerGID: gid_t,
            reservationData: Data, expectedDisk: LumeCandidateDiskIdentity, intent: HostRuntimeMaintenanceIntent,
            encodedCandidate: Data, cleanup: LumeImageMaintenanceCleanup?) throws -> LumeRootImageMaintenance {
        try requireRoot()
        let maintenance = try HostRuntimeAuthority.system.recoverRootMaintenance(intent)
        // Reuse the recovered EX lease. Acquiring an ordinary lease here would
        // reject the maintenance marker or contend with our own kernel lock.
        let source = try LumeRootBaseImageGuard(machine: maintenance.runtimeLease, storage: storage,
            name: name, ownerUID: ownerUID, ownerGID: ownerGID, reservationData: reservationData, expectedDisk: expectedDisk)
        try source.source.requireReservation(encodedCandidate)
        let image = try LumeImageMaintenanceState(source: source.source, intent: intent, recovering: true, cleanup: cleanup)
        return try LumeRootImageMaintenance(guard: source, maintenance: maintenance, image: image)
    }

    private init(machine: HostRuntimeLease, storage: URL, name: String, ownerUID: uid_t, ownerGID: gid_t,
                 reservationData: Data, expectedDisk: LumeCandidateDiskIdentity) throws {
        try Self.requireRoot(); try machine.validateSystemExclusive()
        self.machine = machine
        source = try LumeBaseImageSourceLocks(storage: storage, name: name, ownerUID: ownerUID,
            ownerGID: ownerGID, reservationData: reservationData, expectedDisk: expectedDisk,
            snapshotPolicy: .rootMaintenanceRecovery)
    }

    fileprivate func withImage<T>(_ body: (URL, Int32) throws -> T) throws -> T {
        try Self.requireRoot(); try machine.validateSystemExclusive(); try source.validateIdentity()
        return try body(source.imageURL, source.retainedImageDescriptor)
    }

    private static func requireRoot() throws {
        guard getuid() == 0, geteuid() == 0, getegid() == 0 else {
            throw SandboxRuntimeError.unsupported("offline base operations require the root operator")
        }
    }
}

/// Serial root operation: both durable fences are installed before image IO is
/// exposed. Finish requires independently observed detach/stopped-state cleanup
/// and a synchronously persisted journal checkpoint. No deinit clears fences.
package final class LumeRootImageMaintenance {
    private let source: LumeRootBaseImageGuard
    private let maintenance: HostRuntimeMaintenanceScope
    private let image: LumeImageMaintenanceState

    fileprivate init(guard source: LumeRootBaseImageGuard, maintenance: HostRuntimeMaintenanceScope,
                     image: LumeImageMaintenanceState) throws {
        self.source = source; self.maintenance = maintenance; self.image = image
        try maintenance.runtimeLease.validateSystemExclusive(); try maintenance.validate()
    }

    package func withOfflineImage<T>(_ body: (URL, Int32) throws -> T) throws -> T {
        try maintenance.validate(); try image.validateForOfflineIO()
        let result = try source.withImage(body)
        try image.validateForOfflineIO(); try maintenance.validate()
        return result
    }

    package func finishAfterVerifiedCleanup(persist: (LumeImageMaintenanceCleanup) throws -> Void) throws {
        try maintenance.validate()
        try image.removeFenceAfterVerifiedCleanup(persist: persist)
        // Image fence first, global fence last. Both EX and the retained image
        // descriptor remain owned until this scope and its guard are released.
        try maintenance.finishAfterVerifiedCleanup()
    }
}
