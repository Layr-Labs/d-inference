import Foundation

/// Separate from staging so a boot handoff never needs to reopen a closed
/// staging owner. Later receipt collection can recover the exact original inputs.
final class AccountlessBootJournal {
    private let files: AccountlessPrivateJournal
    init(directory: URL) throws { files = try .init(directory: directory, lockName: "boot.lock") }

    func read() throws -> Record {
        guard let data = try files.read("boot-intent.json") else { throw AccountlessInstallationError.invalidBinding }
        let record = try AccountlessJournalJSON.decode(Record.self, data)
        try record.validate()
        guard data == (try AccountlessJournalJSON.encode(record)) else { throw AccountlessInstallationError.invalidBinding }
        return record
    }

    func record(_ permit: AccountlessBootPermit, staging: AccountlessStagingSnapshot) throws {
        try staging.validate()
        guard try permit.candidate() == staging.candidate, permit.stagedDisk == staging.cleanup.disk,
              permit.stagingSnapshotSHA256 == BaseGuestRelease.digest(try AccountlessJournalJSON.encode(staging)) else {
            throw AccountlessInstallationError.invalidBinding
        }
        let bytes = try permit.encoded()
        let record = Record(schemaVersion: 1, permit: permit, permitSHA256: BaseGuestRelease.digest(bytes), staging: staging)
        try files.publishMatching(AccountlessJournalJSON.encode(record), name: "boot-intent.json")
    }

    struct Record: Codable, Equatable, Sendable {
        let schemaVersion: Int; let permit: AccountlessBootPermit; let permitSHA256: String; let staging: AccountlessStagingSnapshot

        func validate() throws {
            try staging.validate()
            guard schemaVersion == 1, permitSHA256 == BaseGuestRelease.digest(try permit.encoded()),
                  try permit.candidate() == staging.candidate, permit.stagedDisk == staging.cleanup.disk,
                  permit.stagingSnapshotSHA256 == BaseGuestRelease.digest(try AccountlessJournalJSON.encode(staging)) else {
                throw AccountlessInstallationError.invalidBinding
            }
        }
    }
}
