import Darwin
import Foundation
import SandboxRuntime
import SandboxRuntimeLume

/// Binds the protected staging journal to root's exact reserved source. Entry
/// verifies native stopped state; stagePayload owns attachment, mount policy,
/// payload IO and independently verified detach before releasing both fences.
final class AccountlessStagingMaintenance {
    private let journal: AccountlessInstallationStagingJournal
    private let operation: LumeRootImageMaintenance

    private init(journal: AccountlessInstallationStagingJournal, operation: LumeRootImageMaintenance) {
        self.journal = journal; self.operation = operation
    }

    static func begin(journal: AccountlessInstallationStagingJournal, storage: URL,
                      ownerUID: uid_t, ownerGID: gid_t, reservationData: Data,
                      nativeInspector: LumeRootNativeInspector) async throws -> AccountlessStagingMaintenance {
        try journal.requireStagingAllowed()
        try nativeInspector.requireSourceNamespace(storage: storage, ownerUID: ownerUID, ownerGID: ownerGID)
        try await nativeInspector.requireStopped(name: journal.candidate.source.name,
            resources: journal.candidate.resources, diskBytes: journal.candidate.disk.size)
        let binding = try binding(journal)
        let source = try LumeRootBaseImageGuard(storage: storage, name: journal.candidate.source.name,
            ownerUID: ownerUID, ownerGID: ownerGID, reservationData: reservationData, expectedDisk: binding.disk)
        let operation = try source.beginMaintenance(intent: journal.maintenanceIntent(), encodedCandidate: binding.candidate)
        return .init(journal: journal, operation: operation)
    }

    static func recover(journal: AccountlessInstallationStagingJournal, storage: URL,
                        ownerUID: uid_t, ownerGID: gid_t, reservationData: Data,
                        nativeInspector: LumeRootNativeInspector) async throws -> AccountlessStagingMaintenance {
        try nativeInspector.requireSourceNamespace(storage: storage, ownerUID: ownerUID, ownerGID: ownerGID)
        try await nativeInspector.requireStopped(name: journal.candidate.source.name,
            resources: journal.candidate.resources, diskBytes: journal.candidate.disk.size)
        let binding = try binding(journal)
        let operation = try LumeRootBaseImageGuard.recoverMaintenance(storage: storage,
            name: journal.candidate.source.name, ownerUID: ownerUID, ownerGID: ownerGID,
            reservationData: reservationData, expectedDisk: binding.disk, intent: journal.maintenanceIntent(),
            encodedCandidate: binding.candidate, cleanup: journal.detachedCleanup())
        return .init(journal: journal, operation: operation)
    }

    func withOfflineImage<T>(_ body: (URL, Int32) throws -> T) throws -> T {
        try journal.requireStagingAllowed()
        return try operation.withOfflineImage(body)
    }

    func withOfflineImage<T>(_ body: (URL, Int32) async throws -> T) async throws -> T {
        try journal.requireStagingAllowed()
        return try await operation.withOfflineImage(body)
    }

    func finishAfterVerifiedCleanup() throws {
        try operation.finishAfterVerifiedCleanup { try journal.recordDetached($0) }
    }

    func startOwnedProcess(executable: URL, arguments: [String]) throws -> SandboxManagedProcess {
        try journal.requireStagingAllowed()
        return try operation.startOwnedProcess(executable: executable, arguments: arguments)
    }

    func validateActiveImageOwnership() throws {
        try journal.requireStagingAllowed()
        try operation.validateActiveImageOwnership()
    }

    func startOwnedSystemCommand(tool: AccountlessMountSystemTools.Tool, arguments: [String]) throws -> SandboxManagedProcess {
        let executable = try AccountlessSystemCommandExecutable.current()
        return try startOwnedProcess(executable: executable, arguments: AccountlessSystemCommandWorker.arguments(
            intent: journal.maintenanceIntent(), tool: tool, arguments: arguments))
    }

    /// The mountpoint is always created under this protected journal. Callers
    /// supply a verified payload directory, never an arbitrary mounted path.
    func stagePayload(from payloadDirectory: URL) async throws {
        try await withOfflineImage { image, descriptor in
            let stager = AccountlessOfflineStager(journal: journal, tools: .init(operation: self),
                image: image, imageDescriptor: descriptor, validateOwnership: validateActiveImageOwnership)
            try await stager.stage(payloadDirectory: payloadDirectory)
        }
        try finishAfterVerifiedCleanup()
        try Task.checkCancellation()
    }

    static func verifyCompleted(journal: AccountlessInstallationStagingJournal, storage: URL,
                                ownerUID: uid_t, ownerGID: gid_t, reservationData: Data,
                                nativeInspector: LumeRootNativeInspector) async throws {
        guard let cleanup = try journal.detachedCleanup() else { throw AccountlessInstallationError.invalidBinding }
        let snapshot = try AccountlessStagingSnapshot(candidate: journal.candidate, plan: journal.plan,
            maintenance: journal.maintenanceIntent(), cleanup: cleanup)
        try await verifyCompleted(snapshot: snapshot, storage: storage, ownerUID: ownerUID, ownerGID: ownerGID,
            reservationData: reservationData, nativeInspector: nativeInspector)
    }

    static func verifyCompleted(snapshot: AccountlessStagingSnapshot, storage: URL,
                                ownerUID: uid_t, ownerGID: gid_t, reservationData: Data,
                                nativeInspector: LumeRootNativeInspector) async throws {
        try snapshot.validate()
        try nativeInspector.requireSourceNamespace(storage: storage, ownerUID: ownerUID, ownerGID: ownerGID)
        try await nativeInspector.requireStopped(name: snapshot.candidate.source.name,
            resources: snapshot.candidate.resources, diskBytes: snapshot.candidate.disk.size)
        let encodedCandidate = try AccountlessJournalJSON.encode(snapshot.candidate)
        let disk = try AccountlessJournalJSON.decode(LumeCandidateDiskIdentity.self,
            AccountlessJournalJSON.encode(snapshot.candidate.disk))
        try await LumeRootBaseImageGuard.verifyCompletedMaintenance(storage: storage, name: snapshot.candidate.source.name,
            ownerUID: ownerUID, ownerGID: ownerGID, reservationData: reservationData, expectedDisk: disk,
            intent: snapshot.maintenance, encodedCandidate: encodedCandidate, cleanup: snapshot.cleanup) { image, descriptor in
            try await AccountlessDetachedImageObservation.verify(image: image, descriptor: descriptor)
        }
    }

    private static func binding(_ journal: AccountlessInstallationStagingJournal) throws
        -> (candidate: Data, disk: LumeCandidateDiskIdentity) {
        // Both schema mirrors intentionally use the same named wire fields.
        // Lume additionally compares the full reservation before granting IO.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try encoder.encode(journal.candidate),
            try JSONDecoder().decode(LumeCandidateDiskIdentity.self, from: encoder.encode(journal.candidate.disk)))
    }
}
