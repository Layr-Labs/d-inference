import Foundation
import HostRuntimeCoordination
import SandboxRuntime
import SandboxRuntimeLume
import SandboxRuntimeVZ

enum AccountlessPublishInstalledCommand {
    static func run(_ options: AccountlessBaseOptions) async throws -> AccountlessBasePhaseReport {
        let permit = try AccountlessBootPermitFile.read(options.path("--permit-file")), candidate = try permit.candidate()
        guard permit.hostID == options.hostID, permit.hostIdentityFile == options.hostIdentityFile.path,
              permit.storage == options.storage.path, candidate.source.name == options.name,
              try HostUserIdentityValidator.validate(file: options.hostIdentityFile, hostID: options.hostID) == permit.hostUser else {
            throw AccountlessInstallationError.invalidBinding
        }
        let record = try AccountlessCollectionRecord.read(options.path("--collection-file"), permit: permit)
        let monitor = try SandboxGUISessionMonitor()
        let lease = try HostRuntimeAuthority.system.acquireSandbox()
        defer { withExtendedLifetime(lease) {} }
        try await SandboxStorageEncryption.requireEncryptedAPFS(at: options.storage)
        let release = try LumeGuestMaterialConfiguration(releaseDirectory: options.path("--guest-release"))
        let runtime = LumeVirtualMachineRuntime(configuration: try .init(executable: URL(fileURLWithPath: permit.runtime),
            storageDirectory: options.storage, commandTimeoutSeconds: 30, trustPolicy: .production,
            isolatedGuest: release, hostRuntimeLease: lease))
        let installation = try AccountlessJournalJSON.encode(record.installation), cleanup = try AccountlessJournalJSON.encode(record.cleanup)
        let request = try permit.request()
        _ = try await AccountlessGUISession.run(operation: {
            try await runtime.publishInstalledCandidate(name: candidate.source.name, candidateID: candidate.candidateID,
                installationData: installation, cleanupData: cleanup, expectedRuntimeSHA256: permit.runtimeSHA256,
                expectedBootRequest: request)
        }, monitor: { try await monitor.run() })
        return .init(phase: .installedAwaitingQualification, candidate: candidate,
            sourceStopped: true, collectionPath: try options.path("--collection-file").path, installed: true)
    }
}
