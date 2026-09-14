import Foundation
import SandboxCore
import SandboxRuntime

extension LumeVirtualMachineRuntime {
    // Source integrity is independent of whether the disposable clone lease is
    // active or durably released. Callers must separately prove the needed state.
    func qualificationSourceSnapshot(sourceGuard: LumeBaseCandidateOperationGuard,
        store: LumeInstalledCandidateStore, candidateID: UUID, qualificationID: UUID,
        specification: SandboxVirtualMachineSpecification) async throws -> LumeInstalledCandidateStore.Snapshot {
        guard let authority = configuration.hostRuntimeLease, let release = configuration.isolatedGuest,
              capacityArbiter != nil, case .localTemplate(let sourceName) = specification.imageSource,
              sourceGuard.source.name == sourceName else { throw SandboxRuntimeError.unsupported("qualification source changed") }
        try authority.validateExclusive()
        _ = try await validateRuntime()
        try Task.checkCancellation()
        let files = try release.validatedReleaseFiles()
        let source = try LumeGuestTemplateSource.load(name: sourceName,
            installationID: sourceGuard.source.installationID, storage: configuration.storageDirectory)
        guard source == sourceGuard.source else { throw SandboxRuntimeError.unsupported("qualification source changed") }
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
        else { throw SandboxRuntimeError.unsupported("qualification source changed") }
        let sourceCommitment = try LumeVirtualMachineOwnership.requireResourceCommitment(
            name: sourceName, owner: .baseTemplate, in: configuration.storageDirectory)
        try LumeVirtualMachineResourceCommitment.requireMatch(observed: observed,
            ownership: sourceCommitment, lease: nil)
        try Task.checkCancellation()
        try authority.validateExclusive()
        guard try release.validatedReleaseFiles() == files,
              try LumeGuestTemplateSource.load(name: sourceName, installationID: source.installationID,
                storage: configuration.storageDirectory) == source,
              try store.read(source: source, guestFiles: files) == snapshot else { throw SandboxRuntimeError.unsupported("qualification source changed") }
        return snapshot
    }

}
