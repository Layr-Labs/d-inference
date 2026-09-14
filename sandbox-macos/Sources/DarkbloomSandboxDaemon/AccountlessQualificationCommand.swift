import Foundation
import HostRuntimeCoordination
import SandboxRuntime
import SandboxRuntimeLume
import SandboxRuntimeVZ

enum AccountlessQualificationCommand {
    static func run(_ options: AccountlessBaseOptions) async throws -> AccountlessBasePhaseReport {
        let permit = try AccountlessBootPermitFile.read(options.path("--permit-file")), candidate = try permit.candidate()
        guard permit.hostID == options.hostID, permit.hostIdentityFile == options.hostIdentityFile.path,
              permit.storage == options.storage.path, candidate.source.name == options.name,
              try HostUserIdentityValidator.validate(file: options.hostIdentityFile, hostID: options.hostID) == permit.hostUser else {
            throw AccountlessInstallationError.invalidBinding
        }
        let collection = try AccountlessCollectionRecord.read(options.path("--collection-file"), permit: permit)
        let monitor = try SandboxGUISessionMonitor()
        let authority = try HostRuntimeAuthority.system.acquireSandbox()
        defer { withExtendedLifetime(authority) {} }
        try await SandboxStorageEncryption.requireEncryptedAPFS(at: options.storage)
        let capacity = try options.path("--capacity-dir"), release = try options.path("--guest-release")
        let arbiter = try SandboxHostCapacityArbiter.openExisting(stateDirectory: capacity, storageDirectory: options.storage)
        let settings = try LumeGuestMaterialConfiguration(releaseDirectory: release)
        let configuration = try LumeRuntimeConfiguration(executable: URL(fileURLWithPath: permit.runtime), storageDirectory: options.storage,
            commandTimeoutSeconds: 120, createTimeoutSeconds: 600, trustPolicy: .production, isolatedGuest: settings, hostRuntimeLease: authority)
        let owner = try AccountlessQualificationOwner(directory: options.path("--qualification-dir"), permit: permit, collection: collection,
            capacityDirectory: capacity, guestReleaseDirectory: release, configuration: configuration, arbiter: arbiter)
        return try await AccountlessGUISession.run(operation: { try await owner.run() }, monitor: { try await monitor.run() })
    }
}
