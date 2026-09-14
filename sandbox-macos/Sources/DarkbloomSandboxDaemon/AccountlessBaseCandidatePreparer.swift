import Foundation
import SandboxCore
import SandboxRuntime
import SandboxRuntimeLume

protocol AccountlessBaseCandidateRuntime: Sendable {
    func requireBaseCandidateStorage(_ storage: URL) async throws
    func create(_ specification: SandboxVirtualMachineSpecification) async throws
    func inspect(name: String) async throws -> SandboxVirtualMachineRecord?
}

extension LumeVirtualMachineRuntime: AccountlessBaseCandidateRuntime {}

struct AccountlessBaseCandidatePreparer: Sendable {
    let runtime: any AccountlessBaseCandidateRuntime

    func prepare(specification: SandboxVirtualMachineSpecification, storage: URL,
                 release: BaseGuestRelease) async throws -> AccountlessBaseCandidateReport {
        guard case .appleRestore(let image) = specification.imageSource else { throw AccountlessBaseCandidateError.unsupportedSource }
        let payload = SandboxGuestPayloadIdentity(releaseManifestSHA256: release.manifestSHA256,
            guestSHA256: release.hashes["darkbloom-sandbox-guest"] ?? "",
            bootstrapSHA256: release.hashes["darkbloom-sandbox-bootstrap.sh"] ?? "",
            launchdSHA256: release.hashes["io.darkbloom.sandbox.guest.plist"] ?? "",
            installerSHA256: release.hashes["install-sandbox-guest.sh"] ?? "")
        guard payload.isValid else { throw AccountlessBaseCandidateError.invalidRecord }
        try Task.checkCancellation()
        try await runtime.requireBaseCandidateStorage(storage)
        let directory = storage.appendingPathComponent(specification.name, isDirectory: true)
        if try await runtime.inspect(name: specification.name) != nil {
            // Missing/partial first-attempt state is quarantined. An owned VM
            // might already have booted; absence of a ready receipt proves less.
            let existing = try AccountlessBaseCandidateStore(directory: directory)
            guard try existing.read() != nil else { throw AccountlessBaseCandidateError.existingBaseWithoutCandidate }
        }
        try await runtime.create(specification)
        try Task.checkCancellation()
        let preparation = try BaseGuestPreparationLock(directory: directory)
        defer { withExtendedLifetime(preparation) {} }
        let operation = try LumeBaseCandidateOperationGuard(name: specification.name, storage: storage)
        defer { withExtendedLifetime(operation) {} }
        let template = BaseGuestTemplateStore(directory: directory)
        let store = try AccountlessBaseCandidateStore(directory: directory)
        try await requireStopped(specification)
        try store.requireNoPreparedArtifacts()
        let source = try template.source(name: specification.name)
        guard source == operation.source, source.reference == image.standardizedFileURL.path else {
            throw AccountlessBaseCandidateError.candidateChanged
        }
        let disk = try store.diskIdentity(expectedBytes: specification.diskBytes)
        let existing = try store.read()
        let record: AccountlessBaseCandidateRecord
        if let existing {
            guard existing.source == source, existing.payload == payload,
                  existing.resources == specification.resources, existing.disk == disk else {
                throw AccountlessBaseCandidateError.candidateChanged
            }
            record = existing
        } else {
            record = AccountlessBaseCandidateRecord(schemaVersion: 1, phase: .awaitingRootInstallation,
                candidateID: UUID(), bootstrapAttemptID: UUID(), source: source, payload: payload,
                resources: specification.resources, disk: disk, installed: false, qualified: false)
            try Task.checkCancellation()
            try store.publish(record)
        }
        try Task.checkCancellation()
        try await requireStopped(specification)
        try store.requireNoPreparedArtifacts()
        guard try template.source(name: specification.name) == source,
              try store.diskIdentity(expectedBytes: specification.diskBytes) == disk,
              try store.read() == record else { throw AccountlessBaseCandidateError.candidateChanged }
        return .init(candidate: record, recordPath: store.recordPath, replayed: existing != nil)
    }

    private func requireStopped(_ specification: SandboxVirtualMachineSpecification) async throws {
        guard let record = try await runtime.inspect(name: specification.name), record.state == .stopped,
              record.cpuCount == specification.resources.cpuCount, record.memoryBytes == specification.resources.memoryBytes,
              record.diskBytes == specification.diskBytes else { throw AccountlessBaseCandidateError.notStopped }
    }
}
