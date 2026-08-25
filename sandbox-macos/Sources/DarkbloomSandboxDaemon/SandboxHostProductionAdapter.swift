import Foundation
import SandboxCore
import SandboxHostControl
import SandboxRuntime
import SandboxRuntimeLume

protocol SandboxHostCapacityControlling: Sendable {
    func snapshot() throws -> SandboxCapacitySnapshot
    func reserve(
        authoritativeScope: SandboxOperationScope,
        virtualMachineName: String,
        resources: SandboxResourceSpecification,
        bootDiskBytes: UInt64,
        expiresAt: Date
    ) throws -> SandboxCapacityLease
    func renew(
        scope: SandboxOperationScope,
        fencingToken: SandboxFencingToken,
        expiresAt: Date
    ) throws -> SandboxCapacityLease
    func setMode(_ mode: SandboxHostMode) throws -> SandboxCapacitySnapshot
}

extension SandboxHostCapacityArbiter: SandboxHostCapacityControlling {}

protocol SandboxHostVirtualMachineControlling: Sendable {
    func inspect(
        scope: SandboxOperationScope,
        name: String
    ) async throws -> SandboxVirtualMachineRecord?
    func create(
        scope: SandboxOperationScope,
        specification: SandboxVirtualMachineSpecification
    ) async throws
    func start(
        scope: SandboxOperationScope,
        name: String
    ) async throws
    func execute(
        scope: SandboxOperationScope,
        name: String,
        request: SandboxGuestCommandRequest
    ) async throws -> SandboxGuestCommandResult
    func stop(
        scope: SandboxOperationScope,
        name: String
    ) async throws
    func deleteAndRelease(
        scope: SandboxOperationScope,
        name: String
    ) async throws
}

extension LumeLeaseFencedVirtualMachineRuntime:
    SandboxHostVirtualMachineControlling
{}

struct SandboxHostIsolationReadiness: Equatable, Sendable {
    let signedGuestControl: Bool
    let networkPolicy: Bool
    let workspaceQuota: Bool

    var permitsJobs: Bool {
        signedGuestControl && networkPolicy && workspaceQuota
    }

    static let unavailable = SandboxHostIsolationReadiness(
        signedGuestControl: false,
        networkPolicy: false,
        workspaceQuota: false
    )
}

actor SandboxHostProductionAdapter:
    SandboxHostHeartbeatSource,
    SandboxHostControlMessageHandler
{
    private struct ActiveCommand {
        let executionID: UUID
        let scope: SandboxWireScope
        let task: Task<SandboxGuestCommandResult, Error>
    }

    private let capacity: any SandboxHostCapacityControlling
    private let runtime: any SandboxHostVirtualMachineControlling
    private let isolationReadiness: SandboxHostIsolationReadiness
    private var operationStates: [SandboxID: SandboxWireOperationState] = [:]
    private var activeCommands: [UUID: ActiveCommand] = [:]

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
        case .cancelCommand(let envelope):
            return admitCancellation(envelope.payload)
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

    private func admitPrepare(
        _ payload: SandboxWirePrepare
    ) -> SandboxHostControlAdmission {
        let scope = payload.scope
        do {
            guard isolationReadiness.permitsJobs else {
                throw AdapterError.isolationUnavailable
            }
            guard !payload.resources.gpu else {
                throw AdapterError.gpuIsolationUnavailable
            }
            guard payload.resources.commandTimeoutSeconds == 900,
                  let resources = payload.resources.resourceSpecification,
                  SandboxVirtualMachineNamePolicy.isValid(payload.baseImageID)
            else {
                throw AdapterError.invalidRequest
            }
            let expiresAt = try Self.parseTimestamp(payload.leaseExpiresAt)
            let name = Self.virtualMachineName(for: scope)
            let lease = try capacity.reserve(
                authoritativeScope: scope.operationScope,
                virtualMachineName: name,
                resources: resources,
                bootDiskBytes: SandboxDiskPolicy.alpha.bootDiskBytes.lowerBound,
                expiresAt: expiresAt
            )
            operationStates[scope.sandboxID] = .preparing
            let specification = try SandboxVirtualMachineSpecification(
                name: name,
                resources: resources,
                imageSource: .localTemplate(name: payload.baseImageID),
                diskBytes: lease.bootDiskBytes
            )
            return SandboxHostControlAdmission {
                await self.completePrepare(
                    payload,
                    lease: lease,
                    specification: specification
                )
            }
        } catch {
            operationStates[scope.sandboxID] = .failed
            return SandboxHostControlAdmission(
                response: .operation(
                    Self.operationStatus(
                        payload.operationID,
                        scope: scope.operationScope,
                        operation: "prepare",
                        state: .failed,
                        errorCode: Self.errorCode(error)
                    )
                )
            )
        }
    }

    private func completePrepare(
        _ payload: SandboxWirePrepare,
        lease: SandboxCapacityLease,
        specification: SandboxVirtualMachineSpecification
    ) async -> SandboxHostControlResponse {
        do {
            try await runtime.create(
                scope: lease.scope,
                specification: specification
            )
            operationStates[payload.scope.sandboxID] = .booting
            try await runtime.start(
                scope: lease.scope,
                name: specification.name
            )
            operationStates[payload.scope.sandboxID] = .ready
            return .operation(
                Self.operationStatus(
                    payload.operationID,
                    scope: lease.scope,
                    operation: "prepare",
                    state: .ready
                )
            )
        } catch {
            operationStates[payload.scope.sandboxID] = .failed
            return .operation(
                Self.operationStatus(
                    payload.operationID,
                    scope: payload.scope.operationScope,
                    operation: "prepare",
                    state: .failed,
                    errorCode: Self.errorCode(error)
                )
            )
        }
    }

    private func renew(
        _ payload: SandboxWireLeaseRenew
    ) -> SandboxHostControlResponse {
        do {
            let renewed = try capacity.renew(
                scope: payload.scope.operationScope,
                fencingToken: payload.requestedFencingToken,
                expiresAt: Self.parseTimestamp(payload.leaseExpiresAt)
            )
            return .operation(
                Self.operationStatus(
                    payload.operationID,
                    scope: renewed.scope,
                    operation: "renew",
                    state: operationStates[renewed.scope.sandboxID] ?? .ready
                )
            )
        } catch {
            return .operation(
                Self.operationStatus(
                    payload.operationID,
                    scope: payload.scope.operationScope,
                    operation: "renew",
                    state: .failed,
                    errorCode: Self.errorCode(error)
                )
            )
        }
    }

    private func admitExecute(
        _ payload: SandboxWireCommand
    ) -> SandboxHostControlAdmission {
        guard isolationReadiness.permitsJobs else {
            return SandboxHostControlAdmission(
                response: .command(
                    Self.failedCommand(
                        payload,
                        errorCode: AdapterError.isolationUnavailable.code
                    )
                )
            )
        }
        guard let idempotencyKey = UUID(uuidString: payload.idempotencyKey),
              let executable = payload.arguments.first
        else {
            return SandboxHostControlAdmission(
                response: .command(
                    Self.failedCommand(
                        payload,
                        errorCode: AdapterError.invalidRequest.code
                    )
                )
            )
        }
        if let active = activeCommands[payload.commandID] {
            guard active.scope == payload.scope else {
                return SandboxHostControlAdmission(
                    response: .command(
                        Self.failedCommand(
                            payload,
                            errorCode: AdapterError.staleAuthority.code
                        )
                    )
                )
            }
            return SandboxHostControlAdmission {
                await self.commandResponse(
                    payload,
                    executionID: active.executionID,
                    task: active.task
                )
            }
        }

        let request: SandboxGuestCommandRequest
        do {
            request = try SandboxGuestCommandRequest(
                idempotencyKey: idempotencyKey,
                executable: executable,
                arguments: Array(payload.arguments.dropFirst()),
                environment: payload.environment ?? [:],
                workingDirectory: payload.workingDirectory ?? "/Users/lume",
                timeoutSeconds: payload.timeoutSeconds
            )
        } catch {
            return SandboxHostControlAdmission(
                response: .command(
                    Self.failedCommand(
                        payload,
                        errorCode: Self.errorCode(error)
                    )
                )
            )
        }

        let runtime = runtime
        let scope = payload.scope.operationScope
        let name = Self.virtualMachineName(for: payload.scope)
        let task = Task {
            try await runtime.execute(
                scope: scope,
                name: name,
                request: request
            )
        }
        let executionID = UUID()
        activeCommands[payload.commandID] = ActiveCommand(
            executionID: executionID,
            scope: payload.scope,
            task: task
        )
        return SandboxHostControlAdmission {
            await self.commandResponse(
                payload,
                executionID: executionID,
                task: task
            )
        }
    }

    private func commandResponse(
        _ payload: SandboxWireCommand,
        executionID: UUID,
        task: Task<SandboxGuestCommandResult, Error>
    ) async -> SandboxHostControlResponse {
        defer {
            if activeCommands[payload.commandID]?.executionID == executionID {
                activeCommands.removeValue(forKey: payload.commandID)
            }
        }
        do {
            let result = try await task.value
            let state: SandboxWireCommandState
            if result.timedOut {
                state = .timedOut
            } else if result.exitCode == 0 {
                state = .succeeded
            } else {
                state = .failed
            }
            return .command(
                SandboxWireCommandStatus(
                    commandID: payload.commandID,
                    scope: payload.scope,
                    state: state,
                    exitCode: result.exitCode,
                    standardOutput: String(
                        decoding: result.standardOutput,
                        as: UTF8.self
                    ),
                    standardError: String(
                        decoding: result.standardError,
                        as: UTF8.self
                    ),
                    outputTruncated: result.standardOutputTruncated
                        || result.standardErrorTruncated,
                    errorCode: result.timedOut ? "command_timeout" : nil
                )
            )
        } catch is CancellationError {
            return .command(
                SandboxWireCommandStatus(
                    commandID: payload.commandID,
                    scope: payload.scope,
                    state: .cancelled
                )
            )
        } catch {
            let code = Self.errorCode(error)
            let state: SandboxWireCommandState =
                code == "operation_timeout" ? .timedOut : .failed
            return .command(
                SandboxWireCommandStatus(
                    commandID: payload.commandID,
                    scope: payload.scope,
                    state: state,
                    exitCode: state == .failed ? -1 : nil,
                    errorCode: code
                )
            )
        }
    }

    private func admitCancellation(
        _ payload: SandboxWireCommandControl
    ) -> SandboxHostControlAdmission {
        guard let active = activeCommands[payload.commandID] else {
            let runtime = runtime
            let scope = payload.scope.operationScope
            let name = Self.virtualMachineName(for: payload.scope)
            let stopProof: Task<Void, Error> = Task {
                try await runtime.stop(scope: scope, name: name)
            }
            return SandboxHostControlAdmission {
                await self.cancellationResponse(
                    payload,
                    active: nil,
                    stopProof: stopProof
                )
            }
        }
        guard active.scope == payload.scope else {
            return SandboxHostControlAdmission(
                response: .command(
                    SandboxWireCommandStatus(
                        commandID: payload.commandID,
                        scope: payload.scope,
                        state: .failed,
                        exitCode: -1,
                        errorCode: AdapterError.staleAuthority.code
                    )
                )
            )
        }
        active.task.cancel()
        return SandboxHostControlAdmission {
            await self.cancellationResponse(
                payload,
                active: active,
                stopProof: nil
            )
        }
    }

    private func cancellationResponse(
        _ payload: SandboxWireCommandControl,
        active: ActiveCommand?,
        stopProof: Task<Void, Error>?
    ) async -> SandboxHostControlResponse {
        if let active {
            defer {
                if activeCommands[payload.commandID]?.executionID
                    == active.executionID
                {
                    activeCommands.removeValue(forKey: payload.commandID)
                }
            }
            do {
                _ = try await active.task.value
            } catch is CancellationError {
                // Lume returns cancellation only after guest cleanup and its
                // fenced VM stop have completed.
            } catch {
                return Self.failedCancellation(payload, error: error)
            }
        } else {
            do {
                guard let stopProof else {
                    return Self.failedCancellation(
                        payload,
                        error: AdapterError.cancellationProofUnavailable
                    )
                }
                try await stopProof.value
            } catch {
                return Self.failedCancellation(payload, error: error)
            }
        }
        return .command(
            SandboxWireCommandStatus(
                commandID: payload.commandID,
                scope: payload.scope,
                state: .cancelled
            )
        )
    }

    private func admitStop(
        _ payload: SandboxWireOperation
    ) -> SandboxHostControlAdmission {
        let scope = payload.scope.operationScope
        operationStates[scope.sandboxID] = .stopping
        return SandboxHostControlAdmission {
            await self.completeStop(payload)
        }
    }

    private func completeStop(
        _ payload: SandboxWireOperation
    ) async -> SandboxHostControlResponse {
        let scope = payload.scope.operationScope
        do {
            try await runtime.stop(
                scope: scope,
                name: Self.virtualMachineName(for: payload.scope)
            )
            operationStates[scope.sandboxID] = .stopped
            return .operation(
                Self.operationStatus(
                    payload.operationID,
                    scope: scope,
                    operation: "stop",
                    state: .stopped
                )
            )
        } catch {
            operationStates[scope.sandboxID] = .failed
            return .operation(
                Self.operationStatus(
                    payload.operationID,
                    scope: scope,
                    operation: "stop",
                    state: .failed,
                    errorCode: Self.errorCode(error)
                )
            )
        }
    }

    private func admitDelete(
        _ payload: SandboxWireOperation
    ) -> SandboxHostControlAdmission {
        let scope = payload.scope.operationScope
        operationStates[scope.sandboxID] = .deleting
        return SandboxHostControlAdmission {
            await self.completeDelete(payload)
        }
    }

    private func completeDelete(
        _ payload: SandboxWireOperation
    ) async -> SandboxHostControlResponse {
        let scope = payload.scope.operationScope
        let name = Self.virtualMachineName(for: payload.scope)
        do {
            if try await runtime.inspect(scope: scope, name: name)?.state == .running {
                try await runtime.stop(scope: scope, name: name)
            }
            try await runtime.deleteAndRelease(
                scope: scope,
                name: name
            )
            operationStates.removeValue(forKey: scope.sandboxID)
            return .operation(
                Self.operationStatus(
                    payload.operationID,
                    scope: scope,
                    operation: "delete",
                    state: .deleted
                )
            )
        } catch {
            operationStates[scope.sandboxID] = .failed
            return .operation(
                Self.operationStatus(
                    payload.operationID,
                    scope: scope,
                    operation: "delete",
                    state: .failed,
                    errorCode: Self.errorCode(error)
                )
            )
        }
    }

    private func drain(
        _ payload: SandboxWireDrain
    ) -> SandboxHostControlResponse {
        do {
            _ = try capacity.setMode(.draining)
            return .none
        } catch {
            return .failure(
                SandboxWireHostFailure(
                    operationID: payload.operationID,
                    errorCode: Self.errorCode(error)
                )
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

    private static func virtualMachineName(
        for scope: SandboxWireScope
    ) -> String {
        let sandbox = scope.sandboxID.description.replacingOccurrences(
            of: "-",
            with: ""
        )
        return "sbx-\(sandbox)-g\(scope.generation.rawValue)"
    }

    private static func parseTimestamp(_ value: String) throws -> Date {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        if let parsed = fractional.date(from: value) {
            return parsed
        }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        guard let parsed = standard.date(from: value) else {
            throw AdapterError.invalidRequest
        }
        return parsed
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        return formatter.string(from: date)
    }

    private static func operationStatus(
        _ operationID: UUID,
        scope: SandboxOperationScope,
        operation: String,
        state: SandboxWireOperationState,
        errorCode: String? = nil
    ) -> SandboxWireOperationStatus {
        SandboxWireOperationStatus(
            operationID: operationID,
            scope: SandboxWireScope(scope: scope),
            operation: operation,
            state: state,
            errorCode: errorCode
        )
    }

    private static func failedCommand(
        _ payload: SandboxWireCommand,
        errorCode: String
    ) -> SandboxWireCommandStatus {
        SandboxWireCommandStatus(
            commandID: payload.commandID,
            scope: payload.scope,
            state: .failed,
            exitCode: -1,
            errorCode: errorCode
        )
    }

    private static func failedCancellation(
        _ payload: SandboxWireCommandControl,
        error: Error
    ) -> SandboxHostControlResponse {
        .command(
            SandboxWireCommandStatus(
                commandID: payload.commandID,
                scope: payload.scope,
                state: .failed,
                exitCode: -1,
                errorCode: errorCode(error)
            )
        )
    }

    private static func errorCode(_ error: Error) -> String {
        if let error = error as? AdapterError {
            return error.code
        }
        if let error = error as? SandboxCapacityError {
            switch error {
            case .staleFencingToken,
                 .staleSandboxGeneration,
                 .activeSandboxGeneration:
                return "stale_authority"
            case .capacityExhausted,
                 .insufficientHostStorage:
                return "capacity_exhausted"
            case .leaseExpired:
                return "lease_expired"
            case .leaseNotFound:
                return "lease_not_found"
            case .hostNotAcceptingSandboxes:
                return "host_draining"
            default:
                return "capacity_state_error"
            }
        }
        if let error = error as? SandboxRuntimeError {
            switch error {
            case .operationTimedOut:
                return "operation_timeout"
            case .operationInProgress:
                return "operation_in_progress"
            case .cleanupFailed:
                return "runtime_cleanup_failed"
            default:
                return "runtime_operation_failed"
            }
        }
        return "host_operation_failed"
    }
}

private enum AdapterError: Error {
    case invalidRequest
    case staleAuthority
    case isolationUnavailable
    case gpuIsolationUnavailable
    case cancellationProofUnavailable

    var code: String {
        switch self {
        case .invalidRequest:
            "invalid_request"
        case .staleAuthority:
            "stale_authority"
        case .isolationUnavailable:
            "isolation_unavailable"
        case .gpuIsolationUnavailable:
            "gpu_isolation_unavailable"
        case .cancellationProofUnavailable:
            "cancellation_proof_unavailable"
        }
    }
}
