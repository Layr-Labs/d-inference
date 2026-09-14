import Darwin
import Foundation
import HostRuntimeCoordination
import SandboxRuntime
import SandboxRuntimeLume

enum AccountlessCollectCommand {
    static func run(_ options: AccountlessBaseOptions, aborting: Bool) async throws -> AccountlessBasePhaseReport {
        let input = try AccountlessBaseRootInput(options)
        _ = try AccountlessSystemCommandExecutable.current()
        let permit = try AccountlessBootPermitFile.read(options.path("--permit-file"))
        guard permit.hostID == options.hostID, permit.hostUser == input.owner,
              permit.hostIdentityFile == options.hostIdentityFile.path, permit.storage == options.storage.path,
              permit.reservationData == input.reservation else { throw AccountlessInstallationError.invalidBinding }
        let bootJournal = try AccountlessBootJournal(directory: options.path("--boot-journal-dir"))
        let boot = try bootJournal.read()
        guard boot.permit == permit else { throw AccountlessInstallationError.invalidBinding }
        let publication = try aborting ? nil : AccountlessRootRecordFile(path: options.path("--collection-file"))
        let directory = try options.path("--collection-dir")
        guard directory != (try options.path("--boot-journal-dir")) else { throw AccountlessInstallationError.invalidBinding }
        let descriptor = try SandboxAuthorityFileSystem.openPrivateDirectory(at: directory, createIfMissing: true)
        defer { close(descriptor) }
        let journal = try AccountlessCollectionJournal(directory: directory, boot: boot)
        let inspector = try LumeRootNativeInspector(configuration: .init(executable: URL(fileURLWithPath: permit.runtime),
            storageDirectory: options.storage), ownerUID: input.owner.uid, ownerGID: input.owner.primaryGID)
        try await SandboxStorageEncryption.requireEncryptedAPFS(at: options.storage)
        let replayed = try journal.completion() != nil
        if let completed = try journal.completion() {
            do { try await AccountlessCollectionMaintenance.verifyCompleted(journal: journal, inspector: inspector) }
            catch HostRuntimeOwnershipError.maintenancePending {
                try await finish(journal, inspector: inspector, aborted: completed.aborted)
            }
        } else {
            try await collect(journal, inspector: inspector, aborting: aborting)
        }
        try await AccountlessCollectionMaintenance.verifyCompleted(journal: journal, inspector: inspector)
        guard let completed = try journal.completion() else { throw AccountlessInstallationError.invalidBinding }
        if completed.aborted {
            return .init(phase: .collectionAborted, candidate: input.candidate, journalPath: directory.path,
                replayed: replayed, permitPath: try options.path("--permit-file").path, sourceStopped: true)
        }
        let record = try AccountlessCollectionRecord.make(journal: journal)
        if let publication { try publication.publish(record.encoded()) }
        return .init(phase: .installationCollected, candidate: input.candidate, journalPath: directory.path,
            replayed: replayed, sourceStopped: true, collectionPath: aborting ? nil : try options.path("--collection-file").path)
    }

    private static func collect(_ journal: AccountlessCollectionJournal, inspector: LumeRootNativeInspector, aborting: Bool) async throws {
        let maintenance = try await AccountlessCollectionMaintenance.open(journal: journal, inspector: inspector)
        try await maintenance.collect(aborting: aborting)
    }
    private static func finish(_ journal: AccountlessCollectionJournal, inspector: LumeRootNativeInspector, aborted: Bool) async throws {
        let maintenance = try await AccountlessCollectionMaintenance.open(journal: journal, inspector: inspector)
        try maintenance.finish(aborted: aborted)
    }
}
