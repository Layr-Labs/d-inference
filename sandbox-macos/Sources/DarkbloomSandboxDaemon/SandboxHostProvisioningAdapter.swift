import Foundation
import SandboxCore
import SandboxHostControl
import SandboxRuntime

extension SandboxHostProductionAdapter {
    func admitPrepare(
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

    func renew(
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
}
