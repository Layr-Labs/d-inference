import Foundation
import SandboxCore
import SandboxRuntime

extension LumeVirtualMachineRuntime {
    /// Advances an existing raw reservation only after the caller has collected
    /// complete installation and root cleanup records. This never starts a VM.
    package func publishInstalledCandidate(name: String, candidateID: UUID,
        installationData: Data, cleanupData: Data, expectedRuntimeSHA256: String? = nil,
        expectedBootRequest: LumeInstallerBootRequest? = nil) async throws -> LumeInstalledCandidateCheckpoint {
        guard capacityArbiter == nil, let authority = configuration.hostRuntimeLease,
              let release = configuration.isolatedGuest else {
            throw SandboxRuntimeError.unsupported("installed candidate publication requires the exclusive base runtime")
        }
        try authority.validateExclusive()
        _ = try await validateRuntime()
        if let expectedRuntimeSHA256, validatedRuntime?.files["lume"]?.sha256 != expectedRuntimeSHA256 {
            throw SandboxRuntimeError.unsupported("installed publication runtime differs from the root permit")
        }
        let sourceGuard = try LumeBaseCandidateOperationGuard(name: name, storage: configuration.storageDirectory)
        defer { withExtendedLifetime(sourceGuard) {} }
        let source = sourceGuard.source
        if let expectedBootRequest {
            let claimed = try expectedBootRequest.validate()
            guard claimed.source == source, claimed.candidateID == candidateID,
                  try LumeInstallerBootClaim.existsMatching(expectedBootRequest, name: name, storage: configuration.storageDirectory) else {
                throw SandboxRuntimeError.unsupported("installed publication requires its exact consumed boot claim")
            }
        }
        let files = try release.validatedReleaseFiles()
        let observed = try await requireInstalledCandidateStopped(source: source)
        try Task.checkCancellation()
        let store = try LumeInstalledCandidateStore(name: name, storage: configuration.storageDirectory)
        let result = try store.publish(source: source, candidateID: candidateID, guestFiles: files,
            observed: observed, installationData: installationData, cleanupData: cleanupData)
        let after = try await requireInstalledCandidateStopped(source: source)
        guard after.cpuCount == result.checkpoint.resources.cpuCount,
              after.memoryBytes == result.checkpoint.resources.memoryBytes,
              after.diskBytes == result.checkpoint.disk.size else { throw LumeInstalledCandidateStore.failure() }
        try authority.validateExclusive()
        guard try release.validatedReleaseFiles() == files,
              try store.read(source: source, guestFiles: files) == result else {
            throw LumeInstalledCandidateStore.failure()
        }
        if let expectedBootRequest {
            guard try LumeInstallerBootClaim.existsMatching(expectedBootRequest, name: name, storage: configuration.storageDirectory) else {
                throw SandboxRuntimeError.unsupported("installed publication boot claim changed")
            }
        }
        return result.checkpoint
    }

    private func requireInstalledCandidateStopped(source: SandboxGuestBaseSource) async throws -> SandboxVirtualMachineRecord {
        let current = try LumeGuestTemplateSource.load(name: source.name,
            installationID: source.installationID, storage: configuration.storageDirectory)
        guard current == source, let observed = try await inspect(name: source.name), observed.state == .stopped else {
            throw LumeInstalledCandidateStore.failure()
        }
        let commitment = try LumeVirtualMachineOwnership.requireResourceCommitment(name: source.name,
            owner: .baseTemplate, in: configuration.storageDirectory)
        try LumeVirtualMachineResourceCommitment.requireMatch(observed: observed, ownership: commitment, lease: nil)
        try LumeVirtualMachineStartIntent.requireAbsent(name: source.name,
            ownership: .init(installationID: source.installationID), owner: .baseTemplate, in: configuration.storageDirectory)
        try LumeVirtualMachineDeletionIntent.requireAbsent(workspace: workspace, name: source.name)
        return observed
    }
}
