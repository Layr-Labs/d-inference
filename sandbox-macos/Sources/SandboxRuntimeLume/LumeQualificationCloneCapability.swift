import Foundation
import SandboxCore
import SandboxRuntime

/// Single-use permission to clone one installed candidate for qualification.
/// Source evidence and the active lease are checked again before and after the
/// native clone. This cannot be decoded or supplied through public create APIs.
package final class LumeQualificationCloneCapability: @unchecked Sendable {
    package let qualificationID: UUID
    package let specification: SandboxVirtualMachineSpecification
    package let lease: SandboxCapacityLease
    package let checkpoint: LumeInstalledCandidateCheckpoint
    // Retention prevents a later actor from reusing a deallocated actor's address.
    let issuingRuntime: LumeVirtualMachineRuntime
    let sourceGuard: LumeBaseCandidateOperationGuard
    let store: LumeInstalledCandidateStore
    let snapshot: LumeInstalledCandidateStore.Snapshot
    // Accessed only by issuingRuntime. The retained actor identity prevents a
    // different actor from reading or consuming this mutable state.
    var consumed = false
    var createdInstallationID: UUID?

    private init(qualificationID: UUID, specification: SandboxVirtualMachineSpecification,
                 lease: SandboxCapacityLease, issuingRuntime: LumeVirtualMachineRuntime,
                 sourceGuard: LumeBaseCandidateOperationGuard, store: LumeInstalledCandidateStore,
                 snapshot: LumeInstalledCandidateStore.Snapshot) {
        self.qualificationID = qualificationID; self.specification = specification; self.lease = lease
        self.issuingRuntime = issuingRuntime; self.sourceGuard = sourceGuard; self.store = store
        self.snapshot = snapshot; checkpoint = snapshot.checkpoint
    }

    fileprivate static func issue(qualificationID: UUID, specification: SandboxVirtualMachineSpecification,
                                 lease: SandboxCapacityLease, issuingRuntime: LumeVirtualMachineRuntime,
                                 sourceGuard: LumeBaseCandidateOperationGuard, store: LumeInstalledCandidateStore,
                                 snapshot: LumeInstalledCandidateStore.Snapshot) -> LumeQualificationCloneCapability {
        .init(qualificationID: qualificationID, specification: specification, lease: lease,
              issuingRuntime: issuingRuntime, sourceGuard: sourceGuard, store: store, snapshot: snapshot)
    }
}

extension LumeVirtualMachineRuntime {
    package func qualificationCloneCapability(candidateID: UUID, qualificationID: UUID,
        scope: SandboxOperationScope, specification: SandboxVirtualMachineSpecification) async throws -> LumeQualificationCloneCapability {
        guard case .localTemplate(let sourceName) = specification.imageSource,
              sourceName != specification.name, configuration.isolatedGuest != nil,
              capacityArbiter != nil, let authority = configuration.hostRuntimeLease else { throw qualificationFailure() }
        try authority.validateExclusive()
        try preauthorize(scope: scope, operation: .create, virtualMachineName: specification.name,
            resources: specification.resources, bootDiskBytes: specification.diskBytes)
        let destinationLock = try beginOperation("qualification-authority", name: specification.name)
        defer { endOperation(name: specification.name); withExtendedLifetime(destinationLock) {} }
        let authorization = try authorize(scope: scope, operation: .create, virtualMachineName: specification.name,
            resources: specification.resources, bootDiskBytes: specification.diskBytes)
        guard let authorization else { throw qualificationFailure() }
        defer { withExtendedLifetime(authorization) {} }
        let sourceGuard = try LumeBaseCandidateOperationGuard(name: sourceName, storage: configuration.storageDirectory)
        let store = try LumeInstalledCandidateStore(name: sourceName, storage: configuration.storageDirectory)
        try await requireQualificationDestinationAvailable(specification, lease: authorization.lease)
        let snapshot = try await validateQualificationSource(sourceGuard: sourceGuard, store: store,
            candidateID: candidateID, qualificationID: qualificationID, specification: specification,
            lease: authorization.lease)
        return .issue(qualificationID: qualificationID, specification: specification, lease: authorization.lease,
            issuingRuntime: self, sourceGuard: sourceGuard, store: store, snapshot: snapshot)
    }

    package func revalidateQualificationCloneCapability(_ capability: LumeQualificationCloneCapability) async throws {
        guard capability.issuingRuntime === self, !capability.consumed else { throw qualificationFailure() }
        let specification = capability.specification
        let destinationLock = try beginOperation("qualification-authority", name: specification.name)
        defer { endOperation(name: specification.name); withExtendedLifetime(destinationLock) {} }
        let authorization = try authorize(scope: capability.lease.scope, operation: .create,
            virtualMachineName: specification.name, resources: specification.resources,
            bootDiskBytes: specification.diskBytes)
        guard let authorization, authorization.lease == capability.lease else { throw qualificationFailure() }
        defer { withExtendedLifetime(authorization) {} }
        try await requireQualificationDestinationAvailable(specification, lease: authorization.lease)
        let current = try await validateQualificationSource(sourceGuard: capability.sourceGuard,
            store: capability.store, candidateID: capability.checkpoint.candidateID,
            qualificationID: capability.qualificationID, specification: specification, lease: capability.lease)
        guard current == capability.snapshot else { throw qualificationFailure() }
    }

    // The caller already holds the destination operation and lease-mutation
    // locks. Do not acquire either lock again, or the source lock retained by
    // the capability: those locks deliberately are not reentrant.
    func consumeQualificationCloneCapability(_ capability: LumeQualificationCloneCapability,
                                            lease: SandboxCapacityLease) async throws {
        guard capability.issuingRuntime === self, !capability.consumed,
              capability.lease == lease else { throw qualificationFailure() }
        try await requireQualificationDestinationAvailable(capability.specification, lease: lease)
        try await requireQualificationSourceUnchanged(capability)
        capability.consumed = true
    }

    func revalidateConsumedQualificationSource(_ capability: LumeQualificationCloneCapability,
                                              lease: SandboxCapacityLease) async throws {
        guard capability.issuingRuntime === self, capability.consumed,
              capability.lease == lease else { throw qualificationFailure() }
        try await requireQualificationSourceUnchanged(capability)
    }

    private func requireQualificationSourceUnchanged(_ capability: LumeQualificationCloneCapability) async throws {
        let current = try await validateQualificationSource(sourceGuard: capability.sourceGuard,
            store: capability.store, candidateID: capability.checkpoint.candidateID,
            qualificationID: capability.qualificationID, specification: capability.specification, lease: capability.lease)
        guard current == capability.snapshot else { throw qualificationFailure() }
    }

    private func requireQualificationDestinationAvailable(_ specification: SandboxVirtualMachineSpecification,
                                                         lease: SandboxCapacityLease) async throws {
        guard try await inspect(name: specification.name) == nil else { throw qualificationFailure() }
        try requireUnlistedVirtualMachineIsUnowned(name: specification.name, owner: .init(operationScope: lease.scope))
    }

    private func validateQualificationSource(sourceGuard: LumeBaseCandidateOperationGuard,
        store: LumeInstalledCandidateStore, candidateID: UUID, qualificationID: UUID,
        specification: SandboxVirtualMachineSpecification, lease: SandboxCapacityLease) async throws -> LumeInstalledCandidateStore.Snapshot {
        let snapshot = try await qualificationSourceSnapshot(sourceGuard: sourceGuard, store: store,
            candidateID: candidateID, qualificationID: qualificationID, specification: specification)
        guard let capacityArbiter,
              try capacityArbiter.authorize(scope: lease.scope, virtualMachineName: specification.name,
                operation: .create, resources: specification.resources, bootDiskBytes: specification.diskBytes) == lease else {
            throw qualificationFailure()
        }
        return snapshot
    }

    func recordCreatedQualificationClone(_ capability: LumeQualificationCloneCapability) throws {
        guard capability.issuingRuntime === self, capability.consumed, capability.createdInstallationID == nil else {
            throw qualificationFailure()
        }
        let identity = try LumeVirtualMachineOwnership.requireOwned(name: capability.specification.name,
            owner: .init(operationScope: capability.lease.scope), in: configuration.storageDirectory)
        guard identity.installationID != capability.checkpoint.source.installationID,
              LumeVirtualMachineOwnership.matches(specification: capability.specification,
                owner: .init(operationScope: capability.lease.scope), in: configuration.storageDirectory) else {
            throw qualificationFailure()
        }
        capability.createdInstallationID = identity.installationID
    }

    private func qualificationFailure() -> SandboxRuntimeError {
        .unsupported("qualification candidate, destination, runtime or active lease does not match")
    }
}
