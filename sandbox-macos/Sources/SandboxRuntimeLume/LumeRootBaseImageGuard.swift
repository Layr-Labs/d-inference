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

    /// A distinct post-boot scope accepts only the exact consumed installer
    /// claim and captures the stopped image under the retained native locks.
    package static func claimedInstaller(storage: URL, ownerUID: uid_t, ownerGID: gid_t,
                                          request: LumeInstallerBootRequest) throws -> LumeRootBaseImageGuard {
        try requireRoot()
        let candidate = try request.validate()
        let machine = try HostRuntimeAuthority.system.acquireSandbox()
        return try .init(machine: machine, storage: storage, name: candidate.source.name, ownerUID: ownerUID,
            ownerGID: ownerGID, reservationData: request.reservationData, expectedDisk: request.stagedDisk,
            snapshotPolicy: .captureClaimedInstaller, bootClaim: request)
    }

    package func capturedDisk() throws -> LumeCandidateDiskIdentity {
        try validateUnchanged()
        return source.initialDisk
    }

    /// Read-only discovery for the operator. The returned bytes are not image
    /// authority; begin/recovery compare them again under all source locks.
    package static func readReservation(storage: URL, name: String, ownerUID: uid_t, ownerGID: gid_t) throws -> Data {
        try requireRoot()
        guard SandboxVirtualMachineNamePolicy.isValid(name) else { throw SandboxRuntimeError.invalidName }
        let root = try LumePrivilegedSourceDirectory(path: storage, ownerUID: ownerUID, ownerGID: ownerGID)
        let directory = try root.child(name)
        let bytes = try directory.readRecord(LumeInstalledCandidateCheckpoint.reservationFileName)
        try directory.validate(); try root.validate()
        return bytes
    }

    /// A crash after both fence removals must not restart staging. Hold a fresh
    /// ordinary EX lease and source locks while checking the protected completed
    /// snapshot and observing image absence/openers. No maintenance is published.
    package static func verifyCompletedMaintenance(storage: URL, name: String, ownerUID: uid_t, ownerGID: gid_t,
            reservationData: Data, expectedDisk: LumeCandidateDiskIdentity, intent: HostRuntimeMaintenanceIntent,
            encodedCandidate: Data, cleanup: LumeImageMaintenanceCleanup, bootClaim: LumeInstallerBootRequest? = nil,
            observe: (URL, Int32) async throws -> Void) async throws {
        try requireRoot()
        let machine = try HostRuntimeAuthority.system.acquireSandbox()
        let scope = try LumeRootBaseImageGuard(machine: machine, storage: storage, name: name,
            ownerUID: ownerUID, ownerGID: ownerGID, reservationData: reservationData, expectedDisk: expectedDisk, bootClaim: bootClaim)
        defer { withExtendedLifetime(scope) {} }
        try scope.source.requireReservation(encodedCandidate)
        let proof = try LumeCompletedImageMaintenance(source: scope.source, intent: intent, cleanup: cleanup)
        try proof.validate()
        try await observe(scope.source.imageURL, scope.source.retainedImageDescriptor)
        try machine.validateSystemExclusive()
        try proof.validate()
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
            encodedCandidate: Data, cleanup: LumeImageMaintenanceCleanup?, bootClaim: LumeInstallerBootRequest? = nil) throws -> LumeRootImageMaintenance {
        try requireRoot()
        let maintenance = try HostRuntimeAuthority.system.recoverRootMaintenance(intent)
        // Reuse the recovered EX lease. Acquiring an ordinary lease here would
        // reject the maintenance marker or contend with our own kernel lock.
        let source = try LumeRootBaseImageGuard(machine: maintenance.runtimeLease, storage: storage,
            name: name, ownerUID: ownerUID, ownerGID: ownerGID, reservationData: reservationData, expectedDisk: expectedDisk, bootClaim: bootClaim)
        try source.source.requireReservation(encodedCandidate)
        let image = try LumeImageMaintenanceState(source: source.source, intent: intent, recovering: true, cleanup: cleanup)
        return try LumeRootImageMaintenance(guard: source, maintenance: maintenance, image: image)
    }

    private init(machine: HostRuntimeLease, storage: URL, name: String, ownerUID: uid_t, ownerGID: gid_t,
                 reservationData: Data, expectedDisk: LumeCandidateDiskIdentity,
                 snapshotPolicy: LumeBaseImageSourceLocks.SnapshotPolicy = .rootMaintenanceRecovery,
                 bootClaim: LumeInstallerBootRequest? = nil) throws {
        try Self.requireRoot(); try machine.validateSystemExclusive()
        self.machine = machine
        source = try LumeBaseImageSourceLocks(storage: storage, name: name, ownerUID: ownerUID,
            ownerGID: ownerGID, reservationData: reservationData, expectedDisk: expectedDisk,
            snapshotPolicy: snapshotPolicy, bootClaim: bootClaim)
    }

    func withImage<T>(_ body: (URL, Int32) throws -> T) throws -> T {
        try Self.requireRoot(); try machine.validateSystemExclusive(); try source.validateIdentity()
        return try body(source.imageURL, source.retainedImageDescriptor)
    }

    private static func requireRoot() throws {
        guard getuid() == 0, geteuid() == 0, getegid() == 0 else {
            throw SandboxRuntimeError.unsupported("offline base operations require the root operator")
        }
    }
}
