import Foundation
import SandboxCore
import SandboxRuntime

/// Validated source/allocation binding only. There is no clone consumer yet.
/// Future consumption must still enforce platform, encryption and native-start
/// requirements. This cannot be decoded or supplied through public create APIs.
package final class LumeQualificationCloneCapability: @unchecked Sendable {
    package let qualificationID: UUID
    package let specification: SandboxVirtualMachineSpecification
    package let lease: SandboxCapacityLease
    package let checkpoint: LumeInstalledCandidateCheckpoint
    // Retention prevents a later actor from reusing a deallocated actor's address.
    fileprivate let issuingRuntime: LumeVirtualMachineRuntime
    fileprivate let sourceGuard: LumeBaseCandidateOperationGuard
    fileprivate let store: LumeInstalledCandidateStore
    fileprivate let snapshot: LumeInstalledCandidateStore.Snapshot

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
        let snapshot = try await validateQualificationSource(sourceGuard: sourceGuard, store: store,
            candidateID: candidateID, qualificationID: qualificationID, specification: specification,
            lease: authorization.lease)
        return .issue(qualificationID: qualificationID, specification: specification, lease: authorization.lease,
            issuingRuntime: self, sourceGuard: sourceGuard, store: store, snapshot: snapshot)
    }

    package func revalidateQualificationCloneCapability(_ capability: LumeQualificationCloneCapability) async throws {
        guard capability.issuingRuntime === self else { throw qualificationFailure() }
        let specification = capability.specification
        let destinationLock = try beginOperation("qualification-authority", name: specification.name)
        defer { endOperation(name: specification.name); withExtendedLifetime(destinationLock) {} }
        let authorization = try authorize(scope: capability.lease.scope, operation: .create,
            virtualMachineName: specification.name, resources: specification.resources,
            bootDiskBytes: specification.diskBytes)
        guard let authorization, authorization.lease == capability.lease else { throw qualificationFailure() }
        defer { withExtendedLifetime(authorization) {} }
        let current = try await validateQualificationSource(sourceGuard: capability.sourceGuard,
            store: capability.store, candidateID: capability.checkpoint.candidateID,
            qualificationID: capability.qualificationID, specification: specification, lease: capability.lease)
        guard current == capability.snapshot else { throw qualificationFailure() }
    }

    private func validateQualificationSource(sourceGuard: LumeBaseCandidateOperationGuard,
        store: LumeInstalledCandidateStore, candidateID: UUID, qualificationID: UUID,
        specification: SandboxVirtualMachineSpecification, lease: SandboxCapacityLease) async throws -> LumeInstalledCandidateStore.Snapshot {
        guard let authority = configuration.hostRuntimeLease, let release = configuration.isolatedGuest,
              let capacityArbiter, case .localTemplate(let sourceName) = specification.imageSource,
              sourceGuard.source.name == sourceName else { throw qualificationFailure() }
        try authority.validateExclusive()
        _ = try await validateRuntime()
        try Task.checkCancellation()
        let files = try release.validatedReleaseFiles()
        let source = try LumeGuestTemplateSource.load(name: sourceName,
            installationID: sourceGuard.source.installationID, storage: configuration.storageDirectory)
        guard source == sourceGuard.source else { throw qualificationFailure() }
        try LumeVirtualMachineStartIntent.requireAbsent(name: sourceName,
            ownership: .init(installationID: source.installationID), owner: .baseTemplate,
            in: configuration.storageDirectory)
        try LumeVirtualMachineDeletionIntent.requireAbsent(workspace: workspace, name: sourceName)
        let snapshot = try store.read(source: source, guestFiles: files)
        let checkpoint = snapshot.checkpoint
        guard checkpoint.candidateID == candidateID,
              ![candidateID, checkpoint.bootstrapAttemptID, source.installationID].contains(qualificationID),
              checkpoint.resources == specification.resources, checkpoint.disk.size == specification.diskBytes,
              let observed = try await inspect(name: sourceName), observed.state == .stopped,
              observed.cpuCount == checkpoint.resources.cpuCount,
              observed.memoryBytes == checkpoint.resources.memoryBytes, observed.diskBytes == checkpoint.disk.size
        else { throw qualificationFailure() }
        let sourceCommitment = try LumeVirtualMachineOwnership.requireResourceCommitment(
            name: sourceName, owner: .baseTemplate, in: configuration.storageDirectory)
        try LumeVirtualMachineResourceCommitment.requireMatch(observed: observed,
            ownership: sourceCommitment, lease: nil)
        guard try await inspect(name: specification.name) == nil else { throw qualificationFailure() }
        try requireUnlistedVirtualMachineIsUnowned(name: specification.name, owner: .init(operationScope: lease.scope))
        try Task.checkCancellation()
        try authority.validateExclusive()
        guard try capacityArbiter.authorize(scope: lease.scope, virtualMachineName: specification.name,
                operation: .create, resources: specification.resources, bootDiskBytes: specification.diskBytes) == lease,
              try release.validatedReleaseFiles() == files,
              try LumeGuestTemplateSource.load(name: sourceName, installationID: source.installationID,
                storage: configuration.storageDirectory) == source,
              try store.read(source: source, guestFiles: files) == snapshot else { throw qualificationFailure() }
        return snapshot
    }

    private func qualificationFailure() -> SandboxRuntimeError {
        .unsupported("qualification candidate, destination, runtime or active lease does not match")
    }
}
