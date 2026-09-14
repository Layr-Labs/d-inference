import Darwin
import Foundation
import HostRuntimeCoordination
import SandboxRuntimeLume

/// Shares the staging lock but exposes only completed observations and the
/// irreversible handoff record. It can never reopen staging/image IO.
final class AccountlessStagingTransition {
    private let files: AccountlessPrivateJournal
    init(directory: URL) throws { files = try .init(directory: directory, lockName: "staging.lock") }

    func snapshot() throws -> AccountlessStagingSnapshot {
        try files.requireAbsent(["installation-result.json", "cleanup-intent.json", "cleaned.json"])
        guard let intentData = try files.read("staging-intent.json"),
              let stagedData = try files.read("staged.json"),
              let cleanupData = try files.read("staging-detached.json") else { throw AccountlessInstallationError.invalidBinding }
        let intent = try AccountlessJournalJSON.decode(AccountlessStagingSnapshot.Intent.self, intentData)
        let hash = BaseGuestRelease.digest(intentData)
        guard intent.schemaVersion == 1, intentData == (try AccountlessJournalJSON.encode(intent)),
              stagedData == (try AccountlessJournalJSON.encode(AccountlessStagingSnapshot.Staged(schemaVersion: 1, intentSHA256: hash))) else {
            throw AccountlessInstallationError.invalidBinding
        }
        let value = try AccountlessStagingSnapshot(candidate: intent.candidate, plan: intent.plan,
            maintenance: .init(operationID: intent.candidate.bootstrapAttemptID, journalSHA256: hash),
            cleanup: AccountlessJournalJSON.decode(LumeImageMaintenanceCleanup.self, cleanupData))
        try value.validate()
        var info = stat()
        if fstatat(files.descriptor, "mount-attempts", &info, AT_SYMLINK_NOFOLLOW) == 0 {
            let mounts = try AccountlessMountAttempts(directory: files.directory.appendingPathComponent("mount-attempts"), maintenanceSHA256: hash)
            for attempt in try mounts.existing() {
                guard try attempt.completion() != nil else { throw AccountlessDiskError.cleanupUnproven }
            }
        } else if errno != ENOENT { throw AccountlessInstallationError.unsafeDestination }
        try files.validate()
        return value
    }

    func isClosed(for expected: AccountlessStagingSnapshot, permitSHA256: String) throws -> Bool {
        guard try snapshot() == expected else { throw AccountlessInstallationError.invalidBinding }
        let bytes = try handoffData(expected, permitSHA256: permitSHA256)
        guard let existing = try files.read("boot-intent.json") else { return false }
        guard existing == bytes else { throw AccountlessInstallationError.invalidBinding }
        return true
    }

    func close(for expected: AccountlessStagingSnapshot, permitSHA256: String) throws {
        guard try snapshot() == expected else { throw AccountlessInstallationError.invalidBinding }
        try files.publishMatching(handoffData(expected, permitSHA256: permitSHA256), name: "boot-intent.json")
        guard try isClosed(for: expected, permitSHA256: permitSHA256) else { throw AccountlessInstallationError.invalidBinding }
    }

    private func handoffData(_ snapshot: AccountlessStagingSnapshot, permitSHA256: String) throws -> Data {
        guard BaseGuestRelease.isDigest(permitSHA256) else { throw AccountlessInstallationError.invalidBinding }
        return try AccountlessJournalJSON.encode(Handoff(schemaVersion: 1,
            bootstrapAttemptID: snapshot.candidate.bootstrapAttemptID,
            snapshotSHA256: BaseGuestRelease.digest(AccountlessJournalJSON.encode(snapshot)), permitSHA256: permitSHA256))
    }
    private struct Handoff: Codable {
        let schemaVersion: Int; let bootstrapAttemptID: UUID; let snapshotSHA256: String; let permitSHA256: String
    }
}
