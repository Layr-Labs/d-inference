import Foundation
import SandboxCore
import SandboxHostControl
import SandboxRuntime

actor SandboxHostProductionAdapter:
    SandboxHostHeartbeatSource,
    SandboxHostControlMessageHandler
{
    struct ActiveCommand {
        let executionID: UUID
        let scope: SandboxWireScope
        let task: Task<SandboxGuestCommandResult, Error>
    }

    let capacity: any SandboxHostCapacityControlling
    let runtime: any SandboxHostVirtualMachineControlling
    let isolationReadiness: SandboxHostIsolationReadiness
    var operationStates: [SandboxID: SandboxWireOperationState] = [:]
    var activeCommands: [UUID: ActiveCommand] = [:]

    init(
        capacity: any SandboxHostCapacityControlling,
        runtime: any SandboxHostVirtualMachineControlling,
        isolationReadiness: SandboxHostIsolationReadiness = .unavailable
    ) {
        self.capacity = capacity
        self.runtime = runtime
        self.isolationReadiness = isolationReadiness
    }

    func heartbeat() async throws -> SandboxWireHostHeartbeat {
        let snapshot = try capacity.snapshot()
        let reservedCPU = snapshot.leases.reduce(UInt32(0)) {
            $0 + UInt32($1.cpuCount)
        }
        let reservedMemory = snapshot.leases.reduce(UInt64(0)) {
            $0 + $1.memoryBytes
        }
        let availableCPU = UInt16(
            max(
                0,
                Int(snapshot.effectivePolicy.maximumReservedCPUCount)
                    - Int(reservedCPU)
            )
        )
        let availableMemory = snapshot.effectivePolicy
            .maximumReservedMemoryBytes
            .subtractingReportingOverflow(reservedMemory)
        var observations: [SandboxWireHostLeaseObservation] = []
        observations.reserveCapacity(snapshot.leases.count)
        for lease in snapshot.leases {
            let state = await observedState(for: lease)
            observations.append(
                SandboxWireHostLeaseObservation(
                    scope: SandboxWireScope(scope: lease.scope),
                    state: state,
                    resources: SandboxWireResources(
                        cpuCount: lease.cpuCount,
                        memoryBytes: lease.memoryBytes,
                        workspaceBytes: lease.workspaceBytes,
                        commandTimeoutSeconds: 900,
                        gpu: false
                    ),
                    leaseExpiresAt: Self.timestamp(lease.expiresAt)
                )
            )
        }
        return SandboxWireHostHeartbeat(
            mode: snapshot.mode == .sandboxDedicated
                && isolationReadiness.permitsJobs
                ? SandboxHostMode.sandboxDedicated.rawValue
                : SandboxHostMode.draining.rawValue,
            availableCPU: availableCPU,
            availableMemoryBytes: availableMemory.overflow
                ? 0
                : availableMemory.partialValue,
            nextFencingToken: snapshot.nextFencingToken,
            leases: observations
        )
    }

    func cancelCommandsForExpiredLeases(_ leases: [SandboxCapacityLease]) async {
        let matching = activeCommands.filter { _, command in
            leases.contains {
                $0.scope.sandboxID == command.scope.sandboxID
                    && $0.scope.generation == command.scope.generation
            }
        }
        // Renewal rotates the fencing token while an existing command keeps
        // its original scope. Expiry applies to the same sandbox generation.
        for (_, command) in matching { command.task.cancel() }
        for (id, command) in matching {
            _ = try? await command.task.value
            if activeCommands[id]?.executionID == command.executionID {
                activeCommands.removeValue(forKey: id)
            }
        }
    }

    func admit(
        _ message: SandboxCoordinatorControlMessage
    ) async throws -> SandboxHostControlAdmission {
        switch message {
        case .prepare(let envelope):
            return admitPrepare(envelope.payload)
        case .leaseRenew(let envelope):
            return SandboxHostControlAdmission(
                response: renew(envelope.payload)
            )
        case .command(let envelope):
            return admitExecute(envelope.payload)
        case .fileOperation(let envelope):
            return admitFile(envelope.payload)
        case .cancelCommand(let envelope):
            return admitCancellation(envelope.payload)
        case .start(let envelope):
            return admitStart(envelope.payload)
        case .stop(let envelope):
            return admitStop(envelope.payload)
        case .delete(let envelope):
            return admitDelete(envelope.payload)
        case .drain(let envelope):
            return SandboxHostControlAdmission(
                response: drain(envelope.payload)
            )
        }
    }

    private func observedState(
        for lease: SandboxCapacityLease
    ) async -> SandboxWireOperationState {
        if let state = operationStates[lease.scope.sandboxID],
           state == .preparing
            || state == .booting
            || state == .stopping
            || state == .deleting
        {
            return state
        }
        do {
            guard let record = try await runtime.inspect(
                scope: lease.scope,
                name: lease.virtualMachineName
            ) else {
                return .failed
            }
            switch record.state {
            case .running:
                return isolationReadiness.permitsJobs ? .ready : .failed
            case .starting, .installing:
                return .booting
            case .stopping:
                return .stopping
            case .stopped:
                return .stopped
            case .paused, .failed, .unknown:
                return .failed
            }
        } catch {
            return .failed
        }
    }
}
