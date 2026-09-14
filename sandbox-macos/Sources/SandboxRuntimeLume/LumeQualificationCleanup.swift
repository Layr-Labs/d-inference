import Darwin
import Foundation
import SandboxCore
import SandboxRuntime

/// Identity observed while the disposable clone and its private materials exist.
/// It carries no secret, cannot be decoded or constructed by a caller, and does
/// not claim that guest qualification checks passed.
package final class LumeQualificationCloneObservation: Sendable {
    package let cloneInstallationID: UUID
    package let materialsInstanceID: UUID
    fileprivate let capability: LumeQualificationCloneCapability

    fileprivate init(capability: LumeQualificationCloneCapability, cloneInstallationID: UUID, materialsInstanceID: UUID) {
        self.capability = capability; self.cloneInstallationID = cloneInstallationID
        self.materialsInstanceID = materialsInstanceID
    }
}

extension LumeVirtualMachineRuntime {
    package func observeQualificationClone(_ capability: LumeQualificationCloneCapability) async throws -> LumeQualificationCloneObservation {
        guard capability.issuingRuntime === self, capability.consumed,
              let createdID = capability.createdInstallationID, let capacityArbiter,
              let release = configuration.isolatedGuest else { throw qualificationCleanupFailure() }
        let name = capability.specification.name, lease = capability.lease
        let operation = try beginOperation("qualification-clone-observation", name: name)
        defer { endOperation(name: name); withExtendedLifetime(operation) {} }
        let authorization = try authorize(scope: lease.scope, operation: .execute, virtualMachineName: name,
            resources: capability.specification.resources, bootDiskBytes: capability.specification.diskBytes)
        guard authorization?.lease == lease else { throw qualificationCleanupFailure() }
        defer { withExtendedLifetime(authorization) {} }
        try await requireQualificationSourceSnapshot(capability)
        let ownership = try LumeVirtualMachineOwnership.requireResourceCommitment(name: name,
            owner: .init(operationScope: lease.scope), in: configuration.storageDirectory)
        guard ownership.identity.installationID == createdID,
              let observed = try await inspect(name: name), observed.state == .running else { throw qualificationCleanupFailure() }
        try LumeVirtualMachineResourceCommitment.requireMatch(observed: observed, ownership: ownership, lease: lease)
        let material = try release.load(in: configuration.storageDirectory.appendingPathComponent(name),
            instanceID: createdID, workspaceBytes: lease.workspaceBytes)
        try await requireQualificationSourceSnapshot(capability)
        guard try capacityArbiter.authorize(scope: lease.scope, virtualMachineName: name, operation: .execute,
                resources: capability.specification.resources, bootDiskBytes: capability.specification.diskBytes) == lease,
              try LumeVirtualMachineOwnership.requireOwned(name: name, owner: .init(operationScope: lease.scope),
                in: configuration.storageDirectory).installationID == createdID else { throw qualificationCleanupFailure() }
        return .init(capability: capability, cloneInstallationID: createdID, materialsInstanceID: material.instanceID)
    }

    /// No capacity mutation and no readiness publication. A missing VM or an
    /// expired/removed lease alone is insufficient: the durable deletion receipt
    /// must bind this exact generation, name and an equal-or-newer fencing token.
    package func verifyQualificationCleanup(_ observation: LumeQualificationCloneObservation) async throws -> SandboxGuestQualificationCleanup {
        let capability = observation.capability
        guard capability.issuingRuntime === self, capability.consumed,
              capability.createdInstallationID == observation.cloneInstallationID,
              observation.cloneInstallationID == observation.materialsInstanceID,
              let capacityArbiter else { throw qualificationCleanupFailure() }
        let name = capability.specification.name
        let operation = try beginOperation("qualification-cleanup-verification", name: name)
        defer { endOperation(name: name); withExtendedLifetime(operation) {} }
        try requireQualificationDeletion(capacityArbiter, capability: capability)
        try await requireQualificationSourceSnapshot(capability)
        guard try await inspect(name: name) == nil else { throw qualificationCleanupFailure() }
        try requireQualificationDirectoryAbsent(name)
        try LumeVirtualMachineDeletionIntent.requireAbsent(workspace: workspace, name: name)
        try await requireQualificationSourceSnapshot(capability)
        try requireQualificationDeletion(capacityArbiter, capability: capability)
        try requireQualificationDirectoryAbsent(name)
        return .init(cloneInstallationID: observation.cloneInstallationID, materialsInstanceID: observation.materialsInstanceID,
            cloneRemoved: true, materialsRemoved: true, capacityReleased: true,
            sourceStoppedReverified: true, sourceUnchangedReverified: true)
    }

    private func requireQualificationSourceSnapshot(_ capability: LumeQualificationCloneCapability) async throws {
        guard try await qualificationSourceSnapshot(sourceGuard: capability.sourceGuard, store: capability.store,
            candidateID: capability.checkpoint.candidateID, qualificationID: capability.qualificationID,
            specification: capability.specification) == capability.snapshot else { throw qualificationCleanupFailure() }
    }

    private func requireQualificationDeletion(_ arbiter: SandboxHostCapacityArbiter, capability: LumeQualificationCloneCapability) throws {
        guard let released = try arbiter.releasedDeletionScope(matching: capability.lease.scope,
                virtualMachineName: capability.specification.name),
              try arbiter.deletionConfirmed(scope: released, virtualMachineName: capability.specification.name) else {
            throw qualificationCleanupFailure()
        }
    }

    private func requireQualificationDirectoryAbsent(_ name: String) throws {
        let directory = try SandboxAuthorityFileSystem.openPrivateDirectory(at: configuration.storageDirectory, createIfMissing: false)
        defer { close(directory) }
        var info = stat()
        guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else { throw qualificationCleanupFailure() }
    }

    private func qualificationCleanupFailure() -> SandboxRuntimeError {
        .unsupported("qualification clone identity, materials, source or durable deletion evidence does not match")
    }
}
