import Foundation
import HostRuntimeCoordination
import SandboxRuntime
import SandboxRuntimeLume
import SandboxRuntimeVZ

enum AccountlessBootCommand {
    static func run(_ options: AccountlessBaseOptions) async throws -> AccountlessBasePhaseReport {
        let permitPath = try options.path("--permit-file")
        let permit = try AccountlessBootPermitFile.read(permitPath), candidate = try permit.candidate()
        guard permit.hostID == options.hostID, permit.hostIdentityFile == options.hostIdentityFile.path,
              permit.storage == options.storage.path, candidate.source.name == options.name else {
            throw AccountlessInstallationError.invalidBinding
        }
        let user = try HostUserIdentityValidator.validate(file: options.hostIdentityFile, hostID: options.hostID)
        guard user == permit.hostUser else { throw HostUserIdentityError.identityMismatch }
        let monitor = try SandboxGUISessionMonitor()
        let lease = try HostRuntimeAuthority.system.acquireSandbox()
        defer { withExtendedLifetime(lease) {} }
        let host = SandboxHostInspector().inspect(policy: .init(requireAvailableDiskCapacity: false), storageDirectory: options.storage)
        try ServeCommand.requireEligibleHost(host, maximumCPUCount: candidate.resources.cpuCount,
            maximumMemoryBytes: candidate.resources.memoryBytes)
        try await SandboxStorageEncryption.requireEncryptedAPFS(at: options.storage)
        guard try AccountlessBootPermitFile.read(permitPath) == permit else { throw AccountlessInstallationError.invalidBinding }
        let runtime = LumeVirtualMachineRuntime(configuration: try .init(executable: URL(fileURLWithPath: permit.runtime),
            storageDirectory: options.storage, commandTimeoutSeconds: 30, trustPolicy: .production, hostRuntimeLease: lease))
        let request = try permit.request()
        let outcome = try await AccountlessGUISession.run(operation: { try await runtime.runInstaller(request) },
            monitor: { try await monitor.run() })
        return .init(phase: outcome.replayed ? .installerAttemptRecovered : .installerBootStopped,
            candidate: candidate, replayed: outcome.replayed, permitPath: permitPath.path,
            nativeExitCode: outcome.nativeExitCode, observedRunning: outcome.observedRunning, sourceStopped: outcome.sourceStopped)
    }
}
