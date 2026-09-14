import Foundation
import HostRuntimeCoordination
import SandboxCore
import SandboxRuntimeLume

/// Immutable inputs for the next phase. Decoding is not stopped/detached proof;
/// root revalidates the source under fresh EX before publishing a boot permit.
struct AccountlessStagingSnapshot: Codable, Equatable, Sendable {
    let candidate: AccountlessBaseCandidateRecord
    let plan: AccountlessInstallationPayloadPlan
    let maintenance: HostRuntimeMaintenanceIntent
    let cleanup: LumeImageMaintenanceCleanup

    func validate() throws {
        try plan.validate(candidate: candidate)
        let intent = Intent(schemaVersion: 1, candidate: candidate, plan: plan)
        guard candidate.isValid, maintenance.schemaVersion == 1,
              maintenance.operationID == candidate.bootstrapAttemptID,
              maintenance.journalSHA256 == BaseGuestRelease.digest(try AccountlessJournalJSON.encode(intent)),
              cleanup.schemaVersion == 1, BaseGuestRelease.isDigest(cleanup.imageFenceSHA256),
              cleanup.disk.device == candidate.disk.device, cleanup.disk.inode == candidate.disk.inode,
              cleanup.disk.size == candidate.disk.size, cleanup.disk.inode > 0, cleanup.disk.size > 0,
              (0..<1_000_000_000).contains(cleanup.disk.modifiedNanoseconds),
              (0..<1_000_000_000).contains(cleanup.disk.changedNanoseconds) else {
            throw AccountlessInstallationError.invalidBinding
        }
    }

    struct Intent: Codable { let schemaVersion: Int; let candidate: AccountlessBaseCandidateRecord; let plan: AccountlessInstallationPayloadPlan }
    struct Staged: Codable { let schemaVersion: Int; let intentSHA256: String }
}

enum AccountlessJournalJSON {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        guard data.count <= AccountlessPrivateJournal.maximumBytes else { throw AccountlessInstallationError.invalidBinding }
        try SandboxJSONIntegrity.requireNoDuplicateKeys(data)
        return try JSONDecoder().decode(type, from: data)
    }
}
