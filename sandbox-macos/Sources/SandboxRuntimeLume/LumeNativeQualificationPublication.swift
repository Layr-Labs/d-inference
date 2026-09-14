import Darwin
import Foundation
import SandboxCore
import SandboxRuntime

extension LumeVirtualMachineRuntime {
    /// Keeps the opaque native result, source lock and machine authority alive
    /// throughout publication and readback. Callers never receive an unguarded
    /// ready receipt to publish later after its source capability was released.
    package func withVerifiedQualificationReceipt(_ result: LumeNativeQualificationResult,
        publish: @Sendable (SandboxGuestTemplateReceipt) async throws -> Void) async throws {
        defer { withExtendedLifetime(result) {} }
        let receipt = try await verifiedQualificationReceipt(result)
        try Task.checkCancellation()
        try await publish(receipt)
        try await verifyQualificationPublication(receipt, capability: result.observation.capability)
    }

    /// Returns complete readiness evidence only after normal teardown has
    /// durably released the clone. The result retains the source lock while the
    /// caller publishes; no journal of booleans can reconstruct this capability.
    private func verifiedQualificationReceipt(_ result: LumeNativeQualificationResult) async throws -> SandboxGuestTemplateReceipt {
        let observation = result.observation, capability = observation.capability
        guard capability.issuingRuntime === self, capability.nativeChecksAttempted,
              result.initialBootID != result.restartedBootID else { throw publicationFailure() }
        let cleanup = try await verifyQualificationCleanup(observation)
        let checks = SandboxGuestNativeChecks(authenticatedGuest: true, tenantIdentity: true, commandExecution: true,
            workspaceRoundTrip: true, protectedPathDenied: true, controlDiskDenied: true, restart: true)
        let qualification = SandboxGuestNativeQualification(qualificationID: capability.qualificationID,
            source: capability.checkpoint.source, payload: capability.checkpoint.payload, cloneName: capability.specification.name,
            cloneInstallationID: observation.cloneInstallationID, checks: checks, cleanup: cleanup)
        let evidence = SandboxAccountlessTemplateEvidence(installation: capability.snapshot.installation, qualification: qualification)
        guard evidence.ready else { throw publicationFailure() }
        return SandboxGuestTemplateReceipt(accountless: evidence)
    }


    func verifyQualificationPublication(_ expected: SandboxGuestTemplateReceipt, capability: LumeQualificationCloneCapability) async throws {
        let source = capability.checkpoint.source
        guard capability.issuingRuntime === self, let release = configuration.isolatedGuest,
              let arbiter = capacityArbiter, let authority = configuration.hostRuntimeLease else { throw publicationFailure() }
        try authority.validateExclusive()
        _ = try await validateRuntime()
        try requireQualificationDeletion(arbiter, capability: capability)
        try requireQualificationDirectoryAbsent(capability.specification.name)
        try LumeGuestTemplate.requireReady(name: source.name, installationID: source.installationID,
            storage: configuration.storageDirectory, release: release)
        let directory = try SandboxAuthorityFileSystem.openPrivateDirectory(
            at: configuration.storageDirectory.appendingPathComponent(source.name), createIfMissing: false)
        defer { close(directory) }
        let file = openat(directory, SandboxGuestTemplateReceipt.fileName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard file >= 0 else { throw publicationFailure() }
        defer { close(file) }
        let data = try SandboxAuthorityFileSystem.readStablePrivateFile(file, maximumBytes: 16384)
        try SandboxJSONIntegrity.requireNoDuplicateKeys(data)
        guard try JSONDecoder().decode(SandboxGuestTemplateReceipt.self, from: data) == expected,
              try capability.store.diskIdentity() == capability.checkpoint.disk,
              try LumeGuestTemplateSource.load(name: source.name, installationID: source.installationID,
                storage: configuration.storageDirectory) == source,
              let observed = try await inspect(name: source.name), observed.state == .stopped,
              observed.cpuCount == capability.specification.resources.cpuCount,
              observed.memoryBytes == capability.specification.resources.memoryBytes,
              observed.diskBytes == capability.specification.diskBytes else { throw publicationFailure() }
        var named = stat()
        guard fstatat(directory, SandboxGuestTemplateReceipt.fileName, &named, AT_SYMLINK_NOFOLLOW) == 0,
              try SandboxAuthorityFileSystem.stableIdentity(SandboxAuthorityFileSystem.fileMetadata(file), named),
              try capability.store.diskIdentity() == capability.checkpoint.disk else { throw publicationFailure() }
        try authority.validateExclusive()
        try requireQualificationDeletion(arbiter, capability: capability)
        try requireQualificationDirectoryAbsent(capability.specification.name)
    }

    private func publicationFailure() -> SandboxRuntimeError {
        .unsupported("qualified source publication does not match retained native and cleanup evidence")
    }
}
