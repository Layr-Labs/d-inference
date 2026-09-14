import Darwin
import Foundation
import HostRuntimeCoordination
import SandboxCore
import SandboxRuntime
import SandboxRuntimeLume

/// A separate post-boot transaction. The initial disk is captured beneath root's
/// native locks; successful removal and verified detach are different records.
final class AccountlessCollectionJournal {
    struct Intent: Codable, Equatable {
        let schemaVersion: Int
        let purpose: String
        let operationID: UUID
        let bootRecordSHA256: String
        let permitSHA256: String
        let initialDisk: LumeCandidateDiskIdentity
    }
    struct Completion: Codable, Equatable {
        let schemaVersion: Int
        let intentSHA256: String
        let aborted: Bool
        let cleanup: LumeImageMaintenanceCleanup
    }
    private let files: AccountlessPrivateJournal
    let boot: AccountlessBootJournal.Record

    init(directory: URL, boot: AccountlessBootJournal.Record) throws {
        try boot.validate(); self.boot = boot
        files = try .init(directory: directory, lockName: "collection.lock")
    }

    func intent() throws -> Intent? {
        guard let data = try files.read("collection-intent.json") else { return nil }
        let value = try AccountlessJournalJSON.decode(Intent.self, data)
        guard value.schemaVersion == 1, value.purpose == "accountlessReceiptCollection",
              value.operationID != boot.staging.candidate.bootstrapAttemptID,
              value.bootRecordSHA256 == BaseGuestRelease.digest(try AccountlessJournalJSON.encode(boot)),
              value.permitSHA256 == boot.permitSHA256, value.initialDisk.device == boot.permit.stagedDisk.device,
              value.initialDisk.inode == boot.permit.stagedDisk.inode, value.initialDisk.size == boot.permit.stagedDisk.size,
              data == (try AccountlessJournalJSON.encode(value)) else { throw AccountlessInstallationError.invalidBinding }
        _ = try HostRuntimeMaintenanceIntent(operationID: value.operationID, journalSHA256: BaseGuestRelease.digest(data))
        return value
    }

    func begin(initialDisk: LumeCandidateDiskIdentity) throws {
        guard try intent() == nil else { throw AccountlessInstallationError.invalidBinding }
        let value = Intent(schemaVersion: 1, purpose: "accountlessReceiptCollection", operationID: UUID(),
            bootRecordSHA256: BaseGuestRelease.digest(try AccountlessJournalJSON.encode(boot)),
            permitSHA256: boot.permitSHA256, initialDisk: initialDisk)
        try files.publishMatching(AccountlessJournalJSON.encode(value), name: "collection-intent.json")
        guard try intent() == value else { throw AccountlessInstallationError.invalidBinding }
    }

    func maintenanceIntent() throws -> HostRuntimeMaintenanceIntent {
        guard let value = try intent(), let bytes = try files.read("collection-intent.json") else {
            throw AccountlessInstallationError.invalidBinding
        }
        return try .init(operationID: value.operationID, journalSHA256: BaseGuestRelease.digest(bytes))
    }

    func requireActive() throws {
        _ = try maintenanceIntent()
        guard try completion() == nil else { throw AccountlessInstallationError.stagingClosed }
    }

    func mountAttempts() throws -> AccountlessMountAttempts {
        try requireActive()
        let directory = try SandboxAuthorityFileSystem.openPrivateChildDirectory(parentDescriptor: files.descriptor,
            name: "mount-attempts", createIfMissing: true)
        close(directory); try files.validate()
        return try .init(directory: files.directory.appendingPathComponent("mount-attempts"),
            maintenanceSHA256: maintenanceIntent().journalSHA256)
    }

    func resultData() throws -> Data? { try files.read("guest-result.json") }
    func recordResult(_ bytes: Data, logs: [String: Data]) throws {
        try requireActive()
        let result = try AccountlessJournalJSON.decode(AccountlessInstallationResult.self, bytes)
        _ = try result.completedInstallation(candidate: boot.staging.candidate)
        guard Set(logs.keys) == ["installer.log", "helper.log"] else { throw AccountlessInstallationError.invalidBinding }
        for name in logs.keys.sorted() { try files.publishMatching(logs[name]!, name: name, maximumBytes: 65536, allowEmpty: true) }
        try files.publishMatching(bytes, name: "guest-result.json")
    }

    func removalPlan() throws -> AccountlessCollectionRemovalPlan? {
        try files.read("removal-plan.json").map { try AccountlessJournalJSON.decode(AccountlessCollectionRemovalPlan.self, $0) }
    }
    func recordRemovalPlan(_ plan: AccountlessCollectionRemovalPlan) throws {
        try requireActive()
        guard try resultData() != nil else { throw AccountlessInstallationError.invalidBinding }
        try plan.validate(boot: boot)
        let prefix = boot.staging.plan.stageRelativePath + "/result/"
        guard let result = try resultData(), plan.files[prefix + "receipt.json"]?.sha256 == BaseGuestRelease.digest(result) else {
            throw AccountlessInstallationError.invalidBinding
        }
        for name in ["installer.log", "helper.log"] {
            guard let log = try files.read(name, maximumBytes: 65536, allowEmpty: true),
                  plan.files[prefix + name]?.sha256 == BaseGuestRelease.digest(log) else { throw AccountlessInstallationError.invalidBinding }
        }
        try files.publishMatching(AccountlessJournalJSON.encode(plan), name: "removal-plan.json")
    }
    func removed() throws -> Bool {
        guard let bytes = try files.read("removed.json") else { return false }
        guard bytes == (try removedRecord()) else { throw AccountlessInstallationError.invalidBinding }
        return true
    }
    func recordRemoved() throws {
        try requireActive()
        try files.publishMatching(removedRecord(), name: "removed.json")
    }

    func completion() throws -> Completion? {
        guard let data = try files.read("collection-detached.json") else { return nil }
        let value = try AccountlessJournalJSON.decode(Completion.self, data)
        guard value.schemaVersion == 1, value.intentSHA256 == (try maintenanceIntent().journalSHA256),
              value.cleanup.schemaVersion == 1, BaseGuestRelease.isDigest(value.cleanup.imageFenceSHA256),
              value.cleanup.disk.device == boot.permit.stagedDisk.device,
              value.cleanup.disk.inode == boot.permit.stagedDisk.inode, value.cleanup.disk.size == boot.permit.stagedDisk.size,
              try value.aborted || removed() else { throw AccountlessInstallationError.invalidBinding }
        return value
    }
    func recordDetached(_ cleanup: LumeImageMaintenanceCleanup, aborted: Bool) throws {
        guard try aborted || removed() else { throw AccountlessInstallationError.invalidBinding }
        for attempt in try mountAttemptsForCompletion().existing() {
            guard try attempt.completion() != nil else { throw AccountlessDiskError.cleanupUnproven }
        }
        let record = Completion(schemaVersion: 1, intentSHA256: try maintenanceIntent().journalSHA256, aborted: aborted, cleanup: cleanup)
        try files.publishMatching(AccountlessJournalJSON.encode(record), name: "collection-detached.json")
        guard try completion() == record else { throw AccountlessInstallationError.invalidBinding }
    }

    private func mountAttemptsForCompletion() throws -> AccountlessMountAttempts {
        let descriptor = try SandboxAuthorityFileSystem.openPrivateChildDirectory(parentDescriptor: files.descriptor,
            name: "mount-attempts", createIfMissing: false)
        close(descriptor)
        return try .init(directory: files.directory.appendingPathComponent("mount-attempts"),
            maintenanceSHA256: maintenanceIntent().journalSHA256)
    }
    private func removedRecord() throws -> Data {
        guard let result = try resultData(), let plan = try files.read("removal-plan.json") else {
            throw AccountlessInstallationError.invalidBinding
        }
        return try AccountlessJournalJSON.encode(Removed(schemaVersion: 1, intentSHA256: maintenanceIntent().journalSHA256,
            resultSHA256: BaseGuestRelease.digest(result), planSHA256: BaseGuestRelease.digest(plan)))
    }
    private struct Removed: Codable { let schemaVersion: Int; let intentSHA256: String; let resultSHA256: String; let planSHA256: String }
}
