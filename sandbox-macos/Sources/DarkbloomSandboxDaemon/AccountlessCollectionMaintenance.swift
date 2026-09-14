import Foundation
import HostRuntimeCoordination
import SandboxRuntime
import SandboxRuntimeLume

final class AccountlessCollectionMaintenance {
    private let journal: AccountlessCollectionJournal
    private let operation: LumeRootImageMaintenance

    private init(journal: AccountlessCollectionJournal, operation: LumeRootImageMaintenance) {
        self.journal = journal; self.operation = operation
    }

    static func open(journal: AccountlessCollectionJournal, inspector: LumeRootNativeInspector) async throws -> Self {
        let permit = journal.boot.permit, request = try permit.request()
        let storage = URL(fileURLWithPath: permit.storage), candidate = try permit.candidate()
        try inspector.requireSourceNamespace(storage: storage, ownerUID: permit.hostUser.uid, ownerGID: permit.hostUser.primaryGID)
        guard inspector.executableSHA256 == permit.runtimeSHA256 else { throw AccountlessInstallationError.invalidBinding }
        try await inspector.requireStopped(name: candidate.source.name, resources: candidate.resources, diskBytes: candidate.disk.size)
        if try journal.completion() == nil {
            do {
                let source = try LumeRootBaseImageGuard.claimedInstaller(storage: storage, ownerUID: permit.hostUser.uid,
                    ownerGID: permit.hostUser.primaryGID, request: request)
                let disk = try source.capturedDisk()
                if let initial = try journal.intent() {
                    guard initial.initialDisk == disk else { throw AccountlessInstallationError.invalidBinding }
                } else { try journal.begin(initialDisk: disk) }
                let operation = try source.beginMaintenance(intent: journal.maintenanceIntent(), encodedCandidate: request.reservationData)
                return Self(journal: journal, operation: operation)
            } catch HostRuntimeOwnershipError.maintenancePending {
                // Exact recovery below; an unrelated global intent cannot match.
            }
        }
        guard let initial = try journal.intent() else { throw AccountlessInstallationError.invalidBinding }
        let operation = try LumeRootBaseImageGuard.recoverMaintenance(storage: storage, name: candidate.source.name,
            ownerUID: permit.hostUser.uid, ownerGID: permit.hostUser.primaryGID, reservationData: request.reservationData,
            expectedDisk: initial.initialDisk, intent: journal.maintenanceIntent(), encodedCandidate: request.reservationData,
            cleanup: journal.completion()?.cleanup, bootClaim: request)
        return Self(journal: journal, operation: operation)
    }

    func collect(aborting: Bool) async throws {
        try journal.requireActive()
        try await operation.withOfflineImage { image, descriptor in
            let tools = AccountlessMountSystemTools { tool, arguments, seconds in
                let child = try self.operation.startOwnedProcess(executable: AccountlessSystemCommandExecutable.current(),
                    arguments: AccountlessSystemCommandWorker.arguments(intent: self.journal.maintenanceIntent(), tool: tool, arguments: arguments))
                return try await AccountlessSystemCommandWait.naturalExit(of: child, seconds: seconds)
            }
            let transaction = try AccountlessOfflineImageTransaction(attempts: self.journal.mountAttempts(),
                maintenanceSHA256: self.journal.maintenanceIntent().journalSHA256, tools: tools,
                image: image, imageDescriptor: descriptor, validateOwnership: self.operation.validateActiveImageOwnership)
            if try aborting || self.journal.removed() {
                try await transaction.recoverAttachments()
            } else {
                try await transaction.perform { data, binding in
                    try AccountlessOfflineCollector(journal: self.journal).collect(dataDirectory: data, volumeUUID: binding.volumeUUID)
                }
            }
        }
        try finish(aborted: aborting)
        try Task.checkCancellation()
    }

    func finish(aborted: Bool) throws {
        try operation.finishAfterVerifiedCleanup { try journal.recordDetached($0, aborted: aborted) }
    }

    static func verifyCompleted(journal: AccountlessCollectionJournal, inspector: LumeRootNativeInspector) async throws {
        guard let initial = try journal.intent(), let completed = try journal.completion() else {
            throw AccountlessInstallationError.invalidBinding
        }
        let permit = journal.boot.permit, candidate = try permit.candidate(), request = try permit.request()
        let storage = URL(fileURLWithPath: permit.storage)
        try inspector.requireSourceNamespace(storage: storage, ownerUID: permit.hostUser.uid, ownerGID: permit.hostUser.primaryGID)
        guard inspector.executableSHA256 == permit.runtimeSHA256 else { throw AccountlessInstallationError.invalidBinding }
        try await inspector.requireStopped(name: candidate.source.name, resources: candidate.resources, diskBytes: candidate.disk.size)
        try await LumeRootBaseImageGuard.verifyCompletedMaintenance(storage: storage, name: candidate.source.name,
            ownerUID: permit.hostUser.uid, ownerGID: permit.hostUser.primaryGID, reservationData: request.reservationData,
            expectedDisk: initial.initialDisk, intent: journal.maintenanceIntent(), encodedCandidate: request.reservationData,
            cleanup: completed.cleanup, bootClaim: request) { image, descriptor in
                try await AccountlessDetachedImageObservation.verify(image: image, descriptor: descriptor)
            }
    }
}
