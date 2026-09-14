import Darwin
import Foundation
import HostRuntimeCoordination
import SandboxCore
import SandboxRuntime
import SandboxRuntimeLume

/// The privileged operator owns this directory. Persist intent before touching
/// a guest disk; a boot intent permanently closes the staging recovery path.
/// This journal never grants source/image authority or publishes readiness.
final class AccountlessInstallationStagingJournal {
    private let files: AccountlessPrivateJournal
    private var directory: URL { files.directory }
    private var descriptor: Int32 { files.descriptor }
    private let intent: Data
    let candidate: AccountlessBaseCandidateRecord
    let plan: AccountlessInstallationPayloadPlan

    init(directory: URL, candidate: AccountlessBaseCandidateRecord,
         plan: AccountlessInstallationPayloadPlan) throws {
        try plan.validate(candidate: candidate)
        files = try AccountlessPrivateJournal(directory: directory, lockName: "staging.lock")
        self.candidate = candidate; self.plan = plan
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        intent = try encoder.encode(Intent(schemaVersion: 1, candidate: candidate, plan: plan))
        try validateJournal(allowMissingIntent: true)
        try publishMatching(intent, name: "staging-intent.json")
    }

    func requireStagingAllowed() throws {
        try validateJournal()
        guard try detachedCleanup() == nil else { throw AccountlessInstallationError.stagingClosed }
    }

    func maintenanceIntent() throws -> HostRuntimeMaintenanceIntent {
        try validateJournal()
        return try .init(operationID: candidate.bootstrapAttemptID, journalSHA256: BaseGuestRelease.digest(intent))
    }

    func mountAttempts() throws -> AccountlessMountAttempts {
        try requireStagingAllowed()
        let child = try SandboxAuthorityFileSystem.openPrivateChildDirectory(parentDescriptor: descriptor,
            name: "mount-attempts", createIfMissing: true)
        defer { close(child) }
        try requireBoundDirectory()
        return try .init(directory: directory.appendingPathComponent("mount-attempts"),
            maintenanceSHA256: maintenanceIntent().journalSHA256)
    }

    /// This closes offline writes permanently, including after process restart.
    /// The operator calls it only after observing detach and stopped-state proof.
    func recordDetached(_ cleanup: LumeImageMaintenanceCleanup) throws {
        try validateJournal()
        guard try read("staged.json") != nil else { throw AccountlessInstallationError.invalidBinding }
        if let mounts = try existingMountAttempts() {
            for attempt in try mounts.existing() {
                guard try attempt.completion() != nil else { throw AccountlessDiskError.cleanupUnproven }
            }
        }
        try requireCleanupBinding(cleanup)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try publishMatching(encoder.encode(cleanup), name: "staging-detached.json")
    }

    private func existingMountAttempts() throws -> AccountlessMountAttempts? {
        var info = stat()
        if fstatat(descriptor, "mount-attempts", &info, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw AccountlessInstallationError.unsafeDestination }
            return nil
        }
        return try .init(directory: directory.appendingPathComponent("mount-attempts"),
            maintenanceSHA256: BaseGuestRelease.digest(intent))
    }

    func detachedCleanup() throws -> LumeImageMaintenanceCleanup? {
        guard let data = try read("staging-detached.json") else { return nil }
        try SandboxJSONIntegrity.requireNoDuplicateKeys(data)
        let cleanup = try JSONDecoder().decode(LumeImageMaintenanceCleanup.self, from: data)
        try requireCleanupBinding(cleanup)
        return cleanup
    }

    private func requireCleanupBinding(_ cleanup: LumeImageMaintenanceCleanup) throws {
        guard cleanup.schemaVersion == 1, BaseGuestRelease.isDigest(cleanup.imageFenceSHA256),
              cleanup.disk.device == candidate.disk.device, cleanup.disk.inode == candidate.disk.inode,
              cleanup.disk.size == candidate.disk.size else { throw AccountlessInstallationError.invalidBinding }
    }

    private func validateJournal(allowMissingIntent: Bool = false) throws {
        try requireBoundDirectory()
        try files.requireAbsent(["boot-intent.json", "installation-result.json", "cleanup-intent.json", "cleaned.json"])
        let existingIntent = try read("staging-intent.json")
        guard existingIntent != nil || allowMissingIntent else { throw AccountlessInstallationError.invalidBinding }
        if let existing = existingIntent, existing != intent {
            throw AccountlessInstallationError.invalidBinding
        }
        if let existing = try read("staged.json") {
            guard existingIntent != nil, existing == (try stagedData()) else {
                throw AccountlessInstallationError.invalidBinding
            }
        }
        if try detachedCleanup() != nil {
            guard existingIntent != nil, try read("staged.json") != nil else {
                throw AccountlessInstallationError.invalidBinding
            }
        }
    }

    func recordStaged() throws {
        try requireStagingAllowed()
        // The caller has verified every staged file and the boot job. The
        // receipt records that observation, never inferring a guest boot.
        try publishMatching(stagedData(), name: "staged.json")
    }

    func isStaged() throws -> Bool {
        try requireStagingAllowed()
        return try read("staged.json") != nil
    }

    private func stagedData() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Staged(schemaVersion: 1, intentSHA256: BaseGuestRelease.digest(intent)))
    }

    private func publishMatching(_ data: Data, name: String) throws { try files.publishMatching(data, name: name) }
    private func read(_ name: String) throws -> Data? { try files.read(name) }
    private func requireBoundDirectory() throws { try files.validate() }

    private struct Intent: Codable { let schemaVersion: Int; let candidate: AccountlessBaseCandidateRecord; let plan: AccountlessInstallationPayloadPlan }
    private struct Staged: Codable { let schemaVersion: Int; let intentSHA256: String }
}
