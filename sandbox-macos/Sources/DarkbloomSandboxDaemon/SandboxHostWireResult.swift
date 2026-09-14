import Foundation
import SandboxCore
import SandboxHostControl
import SandboxRuntime

extension SandboxHostProductionAdapter {
    static func virtualMachineName(
        for scope: SandboxWireScope
    ) -> String {
        let sandbox = scope.sandboxID.description.replacingOccurrences(
            of: "-",
            with: ""
        )
        return "sbx-\(sandbox)-g\(scope.generation.rawValue)"
    }

    static func parseTimestamp(_ value: String) throws -> Date {
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

    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        return formatter.string(from: date)
    }

    static func operationStatus(
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

    static func failedCommand(
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

    static func failedCancellation(
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

    static func errorCode(_ error: Error) -> String {
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
            case .commandLimitReached:
                return "command_limit_reached"
            case .cleanupFailed:
                return "runtime_cleanup_failed"
            default:
                return "runtime_operation_failed"
            }
        }
        return "host_operation_failed"
    }
}

enum AdapterError: Error {
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
