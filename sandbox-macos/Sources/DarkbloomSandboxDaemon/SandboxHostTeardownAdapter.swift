import Foundation
import SandboxCore
import SandboxHostControl
import SandboxRuntime

extension SandboxHostProductionAdapter {
    func admitStop(
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

    func admitDelete(
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
            let inspected: SandboxVirtualMachineRecord?
            do {
                inspected = try await runtime.inspect(scope: scope, name: name)
            } catch SandboxCapacityError.leaseNotFound {
                // A replay can observe the lease released by its first delete.
                // deleteAndRelease still proves both lease and VM are absent.
                inspected = nil
            }
            if inspected?.state == .running {
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

    func drain(
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
}
