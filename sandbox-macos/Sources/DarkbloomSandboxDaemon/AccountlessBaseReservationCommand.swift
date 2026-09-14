import Foundation
import HostRuntimeCoordination
import SandboxRuntime
import SandboxRuntimeLume
import SandboxRuntimeVZ

enum AccountlessBaseReservationCommand {
    static func run(_ options: AccountlessBaseOptions) async throws -> AccountlessBasePhaseReport {
        try HostUserIdentityValidator.validate(file: options.hostIdentityFile, hostID: options.hostID)
        let monitor = try SandboxGUISessionMonitor()
        let lease = try HostRuntimeAuthority.system.acquireSandbox()
        defer { withExtendedLifetime(lease) {} }
        let specification = try options.specification()
        let report = SandboxHostInspector().inspect(storageDirectory: options.storage)
        try ServeCommand.requireEligibleHost(report, maximumCPUCount: specification.resources.cpuCount,
            maximumMemoryBytes: specification.resources.memoryBytes)
        try await SandboxStorageEncryption.requireEncryptedAPFS(at: options.storage)
        let release = try BaseGuestRelease(directory: options.path("--guest-release"))
        let runtime = LumeVirtualMachineRuntime(configuration: try .init(executable: options.path("--lume"),
            storageDirectory: options.storage, commandTimeoutSeconds: 120, createTimeoutSeconds: 7_200,
            trustPolicy: .production, hostRuntimeLease: lease))
        return try await AccountlessGUISession.run(operation: {
            let created = try await AccountlessBaseCandidatePreparer(runtime: runtime).prepare(
                specification: specification, storage: options.storage, release: release)
            return .init(phase: .awaitingRootInstallation, candidate: created.candidate, replayed: created.replayed)
        }, monitor: { try await monitor.run() })
    }
}
