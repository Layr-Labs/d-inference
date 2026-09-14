import Darwin
import Foundation
import SandboxRuntime
import SandboxRuntimeLume

/// Binds the protected staging journal to root's exact reserved source. The
/// caller must still inspect native stopped state and attachment/open-file
/// inventories before any mount and again before completing the operation.
final class AccountlessStagingMaintenance {
    private let journal: AccountlessInstallationStagingJournal
    private let operation: LumeRootImageMaintenance

    private init(journal: AccountlessInstallationStagingJournal, operation: LumeRootImageMaintenance) {
        self.journal = journal; self.operation = operation
    }

    static func begin(journal: AccountlessInstallationStagingJournal, storage: URL,
                      ownerUID: uid_t, ownerGID: gid_t, reservationData: Data) throws -> AccountlessStagingMaintenance {
        try journal.requireStagingAllowed()
        let binding = try binding(journal)
        let source = try LumeRootBaseImageGuard(storage: storage, name: journal.candidate.source.name,
            ownerUID: ownerUID, ownerGID: ownerGID, reservationData: reservationData, expectedDisk: binding.disk)
        let operation = try source.beginMaintenance(intent: journal.maintenanceIntent(), encodedCandidate: binding.candidate)
        return .init(journal: journal, operation: operation)
    }

    static func recover(journal: AccountlessInstallationStagingJournal, storage: URL,
                        ownerUID: uid_t, ownerGID: gid_t, reservationData: Data) throws -> AccountlessStagingMaintenance {
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

    private static func binding(_ journal: AccountlessInstallationStagingJournal) throws
        -> (candidate: Data, disk: LumeCandidateDiskIdentity) {
        // Both schema mirrors intentionally use the same named wire fields.
        // Lume additionally compares the full reservation before granting IO.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try encoder.encode(journal.candidate),
            try JSONDecoder().decode(LumeCandidateDiskIdentity.self, from: encoder.encode(journal.candidate.disk)))
    }
}
