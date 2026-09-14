import Foundation
import SandboxCore
import SandboxRuntimeLume

/// Root's public handoff after verified guest installation, exact temporary
/// cleanup and detach. This authorizes installed-checkpoint validation only.
struct AccountlessCollectionRecord: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let permitSHA256: String
    let collectionIntentSHA256: String
    let guestResultSHA256: String
    let installation: SandboxAccountlessInstallationReceipt
    let cleanup: LumeCandidateInstallationCleanup

    static func make(journal: AccountlessCollectionJournal) throws -> Self {
        guard let completed = try journal.completion(), !completed.aborted, try journal.removed(),
              let data = try journal.resultData() else { throw AccountlessInstallationError.incompleteInstallation }
        let candidate = journal.boot.staging.candidate
        let installation = try AccountlessJournalJSON.decode(AccountlessInstallationResult.self, data).completedInstallation(candidate: candidate)
        let cleanup = LumeCandidateInstallationCleanup(candidateID: candidate.candidateID, bootstrapAttemptID: candidate.bootstrapAttemptID,
            source: candidate.source, installationReceiptSHA256: BaseGuestRelease.digest(try AccountlessJournalJSON.encode(installation)),
            disk: completed.cleanup.disk, temporaryJobRemoved: true, temporaryPayloadRemoved: true, fullyDetached: true, sourceStoppedVerified: true)
        let record = try Self(schemaVersion: 1, permitSHA256: journal.boot.permitSHA256,
            collectionIntentSHA256: journal.maintenanceIntent().journalSHA256, guestResultSHA256: BaseGuestRelease.digest(data),
            installation: installation, cleanup: cleanup)
        try record.validate(permit: journal.boot.permit)
        return record
    }

    func validate(permit: AccountlessBootPermit) throws {
        let candidate = try permit.candidate()
        guard schemaVersion == 1, permitSHA256 == BaseGuestRelease.digest(try permit.encoded()),
              [collectionIntentSHA256, guestResultSHA256].allSatisfy(BaseGuestRelease.isDigest),
              installation.installationComplete, installation.source == candidate.source,
              installation.payload == candidate.payload, installation.rootJobID == candidate.bootstrapAttemptID,
              cleanup.schemaVersion == 1, cleanup.candidateID == candidate.candidateID,
              cleanup.bootstrapAttemptID == candidate.bootstrapAttemptID, cleanup.source == candidate.source,
              cleanup.installationReceiptSHA256 == BaseGuestRelease.digest(try AccountlessJournalJSON.encode(installation)),
              cleanup.disk.device == permit.stagedDisk.device, cleanup.disk.inode == permit.stagedDisk.inode,
              cleanup.disk.size == permit.stagedDisk.size, cleanup.temporaryJobRemoved, cleanup.temporaryPayloadRemoved,
              cleanup.fullyDetached, cleanup.sourceStoppedVerified else { throw AccountlessInstallationError.invalidBinding }
    }

    func encoded() throws -> Data {
        let bytes = try AccountlessJournalJSON.encode(self)
        guard bytes.count <= HostUserIdentityFile.maximumBytes else { throw AccountlessInstallationError.invalidBinding }
        return bytes
    }
    static func read(_ path: URL, permit: AccountlessBootPermit) throws -> Self {
        let bytes = try AccountlessRootRecordFile.read(path)
        let record = try AccountlessJournalJSON.decode(Self.self, bytes)
        try record.validate(permit: permit)
        guard bytes == (try record.encoded()) else { throw AccountlessInstallationError.invalidBinding }
        return record
    }
}
