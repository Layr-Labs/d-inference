import Darwin
import Foundation
import SandboxRuntime
import SandboxRuntimeLume

enum AccountlessAuthorizeBootCommand {
    static func run(_ options: AccountlessBaseOptions) async throws -> AccountlessBasePhaseReport {
        let input = try AccountlessBaseRootInput(options)
        let stagingDirectory = try options.path("--journal-dir"), bootDirectory = try options.path("--boot-journal-dir")
        guard SandboxAuthorityFileSystem.canonicalPath(for: stagingDirectory) != SandboxAuthorityFileSystem.canonicalPath(for: bootDirectory) else {
            throw AccountlessInstallationError.invalidBinding
        }
        let publication = try AccountlessBootPermitFile(path: options.path("--permit-file"))
        let transition = try AccountlessStagingTransition(directory: stagingDirectory)
        let snapshot = try transition.snapshot()
        guard snapshot.candidate == input.candidate,
              snapshot.plan == (try AccountlessBaseRootInput.plan(at: options.path("--payload"), candidate: input.candidate)) else {
            throw AccountlessInstallationError.invalidBinding
        }
        let runtime = try options.path("--lume")
        let inspector = try LumeRootNativeInspector(configuration: .init(executable: runtime, storageDirectory: options.storage),
            ownerUID: input.owner.uid, ownerGID: input.owner.primaryGID)
        let permit = AccountlessBootPermit(schemaVersion: 1, hostID: options.hostID, hostUser: input.owner,
            hostIdentityFile: options.hostIdentityFile.path, storage: options.storage.path, runtime: runtime.path,
            runtimeSHA256: inspector.executableSHA256, reservationData: input.reservation,
            stagedDisk: snapshot.cleanup.disk, stagingSnapshotSHA256: BaseGuestRelease.digest(try AccountlessJournalJSON.encode(snapshot)),
            maximumBootSeconds: snapshot.plan.maximumBootSeconds)
        let bytes = try permit.encoded(), hash = BaseGuestRelease.digest(bytes)
        let closed = try transition.isClosed(for: snapshot, permitSHA256: hash)
        let published = try publication.containsMatching(bytes)
        guard !published || closed else { throw AccountlessInstallationError.invalidBinding }
        let directory = try SandboxAuthorityFileSystem.openPrivateDirectory(at: bootDirectory, createIfMissing: true)
        defer { close(directory) }
        let journal = try AccountlessBootJournal(directory: bootDirectory)
        try journal.record(permit, staging: snapshot)
        if !published {
            try await SandboxStorageEncryption.requireEncryptedAPFS(at: options.storage)
            try await AccountlessStagingMaintenance.verifyCompleted(snapshot: snapshot, storage: options.storage,
                ownerUID: input.owner.uid, ownerGID: input.owner.primaryGID, reservationData: input.reservation,
                nativeInspector: inspector)
            // The private intent precedes the irreversible staging closure;
            // the GUI-readable permission is always the final publication.
            try transition.close(for: snapshot, permitSHA256: hash)
            try publication.publish(bytes)
        }
        return .init(phase: .installerBootAuthorized, candidate: input.candidate,
            journalPath: bootDirectory.path, replayed: published, permitPath: try options.path("--permit-file").path)
    }
}
