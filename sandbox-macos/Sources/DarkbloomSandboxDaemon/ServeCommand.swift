import Darwin
import Foundation
import HostRuntimeCoordination
import SandboxCore
import SandboxHostControl
import SandboxRuntime
import SandboxRuntimeLume
import SandboxRuntimeVZ

enum ServeCommand {
    static func run(_ arguments: [String]) async throws {
        let options = try Options(arguments)
        try HostUserIdentityValidator.validate(file: options.hostIdentityFile, hostID: options.hostID)
        let hostRuntimeLease = try HostRuntimeAuthority.system.acquireSandbox()
        defer { withExtendedLifetime(hostRuntimeLease) {} }
        let report = SandboxHostInspector().inspect(
            policy: hostInspectionPolicy(developmentAdHocLume: options.developmentAdHocLume),
            storageDirectory: options.storageDirectory
        )
        try requireEligibleHost(report, maximumCPUCount: options.maximumCPUCount,
                                maximumMemoryBytes: options.maximumMemoryBytes)

        let policy = try SandboxCapacityPolicy(
            maximumReservedCPUCount: options.maximumCPUCount,
            maximumReservedMemoryBytes: options.maximumMemoryBytes,
            maximumReservedGrowthBytes: options.maximumGrowthBytes,
            storageHeadroomBytes: options.storageHeadroomBytes,
            maximumLeaseDurationSeconds:
                SandboxCapacityPolicy.maximumSupportedLeaseDurationSeconds
        )
        let capacity = try SandboxHostCapacityArbiter(
            stateDirectory: options.capacityDirectory,
            storageDirectory: options.storageDirectory,
            policy: policy
        )
        _ = try capacity.initialize()
        let guestMaterials = try options.guestRelease.map {
            try LumeGuestMaterialConfiguration(releaseDirectory: $0,
                developmentAdHoc: options.developmentAdHocLume)
        }
        if let guestMaterials {
            try guestMaterials.validate()
            try await SandboxStorageEncryption.requireEncryptedAPFS(at: options.storageDirectory)
        }
        let runtime = try LumeLeaseFencedVirtualMachineRuntime(
            configuration: try LumeRuntimeConfiguration(
                executable: options.lumeExecutable,
                storageDirectory: options.storageDirectory,
                commandTimeoutSeconds: 120,
                createTimeoutSeconds: 7_200,
                trustPolicy: options.developmentAdHocLume
                    ? .developmentAdHoc
                    : .production,
                isolatedGuest: guestMaterials,
                hostRuntimeLease: hostRuntimeLease
            ),
            capacityArbiter: capacity
        )
        let reconciliation = try await runtime.reconcileExpiredLeases()
        guard reconciliation.allSatisfy({
            if case .retained = $0.outcome {
                return false
            }
            return true
        }) else {
            throw DaemonCLIError.reconciliationIncomplete
        }
        // Starting the service never grants workload ownership or clears an
        // operator drain. Activation is a separate, explicit host operation.

        let adapter = SandboxHostProductionAdapter(
            capacity: capacity,
            runtime: runtime,
            isolationReadiness: guestMaterials == nil ? .unavailable : .init(
                signedGuestControl: true, networkPolicy: true, workspaceQuota: true)
        )
        let capabilities = SandboxWireHostCapabilities(
            daemonVersion: "0.1.0",
            operatingSystem: "macos",
            architecture: report.architecture,
            machineModel: Self.sysctlString("hw.model") ?? "unknown-mac",
            chipName: Self.sysctlString("machdep.cpu.brand_string")
                ?? "unknown-apple-silicon",
            cpuCount: UInt16(report.cpuCount),
            memoryBytes: report.memoryBytes,
            maximumSandboxes: UInt16(
                SandboxCapacityPolicy.supportedRunningSandboxes
            ),
            workspaceSizesBytes: [
                25 * SandboxResourcePolicy.gibibyte,
                50 * SandboxResourcePolicy.gibibyte,
            ],
            baseImageIDs: options.baseImageIDs,
            supportsGPU: false,
            supportsFiles: guestMaterials != nil,
            supportsStart: guestMaterials != nil
        )
        let client = SandboxHostControlClient(
            configuration: try SandboxHostControlConfiguration(
                coordinatorURL: options.coordinatorURL,
                hostID: options.hostID,
                token: try SandboxHostTokenFile.read(options.tokenFile),
                capabilities: capabilities,
                allowInsecureLoopback: options.allowInsecureLoopback
            ),
            heartbeatSource: adapter,
            messageHandler: adapter
        )
        let maintenance = SandboxHostLeaseMaintenance(
            snapshot: { try capacity.snapshot().leases },
            cancelCommands: { await adapter.cancelCommandsForExpiredLeases($0) },
            reconcile: { try await runtime.reconcileExpiredLeases() })
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await client.run() }
                group.addTask { try await maintenance.run() }
                defer { group.cancelAll() }
                _ = try await group.next()
            }
        } catch {
            // Cancellation must not interrupt the final stop proof. Each VM
            // also holds an inherited EX descriptor through a broker crash.
            let cleanup = Task.detached { try await runtime.stopAllForShutdown() }
            do { try await cleanup.value }
            catch { throw SandboxRuntimeError.cleanupFailed(operation: "sandbox service shutdown",
                primary: "control connection ended", cleanup: String(describing: error)) }
            throw error
        }
        try await runtime.stopAllForShutdown()
    }

    static func hostInspectionPolicy(developmentAdHocLume: Bool) -> SandboxHostInspectionPolicy {
        // The doctor's provisioning floor must not stop recovery after VMs
        // consume their reserved storage. The arbiter checks actual configured
        // volume headroom at admission and drains low-storage hosts on reopen.
        SandboxHostInspectionPolicy(requireVirtualizationEntitlement: !developmentAdHocLume,
                                    requireAvailableDiskCapacity: false)
    }

    static func requireEligibleHost(_ report: SandboxHostReport, maximumCPUCount: UInt16,
                                    maximumMemoryBytes: UInt64) throws {
        guard report.isEligible, report.cpuCount >= Int(maximumCPUCount),
              report.memoryBytes >= maximumMemoryBytes else { throw DaemonCLIError.hostIneligible }
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else {
            return nil
        }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else {
            return nil
        }
        return String(cString: bytes)
    }

}
