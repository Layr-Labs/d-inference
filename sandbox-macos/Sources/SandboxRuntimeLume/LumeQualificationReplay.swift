import Darwin
import Foundation
import SandboxCore
import SandboxRuntime

extension LumeVirtualMachineRuntime {
    /// Reads only an already-published exact receipt. Recovery cannot publish
    /// readiness from journaled booleans or reconstruct a native-check result.
    package func verifyPublishedQualification(request: LumeInstallerBootRequest,
        expectedDisk: LumeCandidateDiskIdentity, installation: SandboxAccountlessInstallationReceipt,
        receipt: SandboxGuestTemplateReceipt) async throws {
        guard capacityArbiter == nil, let authority = configuration.hostRuntimeLease,
              let release = configuration.isolatedGuest else { throw qualificationReplayFailure() }
        try authority.validateExclusive()
        _ = try await validateRuntime()
        let candidate = try request.validate()
        guard validatedRuntime?.files["lume"]?.sha256 == request.runtimeSHA256,
              expectedDisk.device == candidate.disk.device, expectedDisk.inode == candidate.disk.inode,
              expectedDisk.size == candidate.disk.size, receipt.accountless?.installation == installation,
              installation.source == candidate.source, installation.payload == candidate.payload,
              installation.rootJobID == candidate.bootstrapAttemptID else { throw qualificationReplayFailure() }
        let source = try LumeBaseCandidateOperationGuard(name: candidate.source.name, storage: configuration.storageDirectory)
        defer { withExtendedLifetime(source) {} }
        guard source.source == candidate.source,
              try LumeInstallerBootClaim.existsMatching(request, name: candidate.source.name, storage: configuration.storageDirectory) else {
            throw qualificationReplayFailure()
        }
        let store = try LumeInstalledCandidateStore(name: candidate.source.name, storage: configuration.storageDirectory)
        try LumeGuestTemplate.requireReady(name: candidate.source.name, installationID: candidate.source.installationID,
            storage: configuration.storageDirectory, release: release)
        let directory = try SandboxAuthorityFileSystem.openPrivateDirectory(
            at: configuration.storageDirectory.appendingPathComponent(candidate.source.name), createIfMissing: false)
        defer { close(directory) }
        let file = openat(directory, SandboxGuestTemplateReceipt.fileName, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard file >= 0 else { throw qualificationReplayFailure() }
        defer { close(file) }
        let data = try SandboxAuthorityFileSystem.readStablePrivateFile(file, maximumBytes: 16384)
        try SandboxJSONIntegrity.requireNoDuplicateKeys(data)
        guard try JSONDecoder().decode(SandboxGuestTemplateReceipt.self, from: data) == receipt,
              try store.diskIdentity() == expectedDisk,
              let observed = try await inspect(name: candidate.source.name), observed.state == .stopped,
              observed.cpuCount == candidate.resources.cpuCount, observed.memoryBytes == candidate.resources.memoryBytes,
              observed.diskBytes == candidate.disk.size else { throw qualificationReplayFailure() }
        try LumeVirtualMachineStartIntent.requireAbsent(name: candidate.source.name,
            ownership: .init(installationID: candidate.source.installationID), owner: .baseTemplate, in: configuration.storageDirectory)
        try LumeVirtualMachineDeletionIntent.requireAbsent(workspace: workspace, name: candidate.source.name)
        var named = stat()
        guard fstatat(directory, SandboxGuestTemplateReceipt.fileName, &named, AT_SYMLINK_NOFOLLOW) == 0,
              try SandboxAuthorityFileSystem.stableIdentity(SandboxAuthorityFileSystem.fileMetadata(file), named),
              try store.diskIdentity() == expectedDisk,
              try LumeGuestTemplateSource.load(name: candidate.source.name, installationID: candidate.source.installationID,
                storage: configuration.storageDirectory) == candidate.source,
              try LumeInstallerBootClaim.existsMatching(request, name: candidate.source.name, storage: configuration.storageDirectory) else {
            throw qualificationReplayFailure()
        }
        try authority.validateExclusive()
    }

    private func qualificationReplayFailure() -> SandboxRuntimeError {
        .unsupported("published qualification does not match the root installation, boot claim, runtime or stopped source")
    }
}
