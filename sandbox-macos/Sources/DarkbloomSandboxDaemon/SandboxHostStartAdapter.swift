import SandboxCore
import SandboxHostControl
import SandboxRuntime

extension SandboxHostProductionAdapter {
    func admitStart(_ payload: SandboxWireStart) -> SandboxHostControlAdmission {
        do {
            guard isolationReadiness.permitsJobs else {
                throw AdapterError.isolationUnavailable
            }
            // Resume rotates authority without extending the lease or reserving
            // resources again. Queued control messages from before stop remain stale.
            let lease = try capacity.resume(
                scope: payload.scope.operationScope,
                fencingToken: payload.requestedFencingToken,
                expiresAt: Self.parseTimestamp(payload.leaseExpiresAt)
            )
            operationStates[payload.scope.sandboxID] = .booting
            return SandboxHostControlAdmission {
                await self.completeStart(payload, scope: lease.scope)
            }
        } catch {
            // A filesystem durability error can follow publication. Report the
            // observed new fence when present so cleanup never uses stale authority.
            let appliedScope = try? capacity.snapshot().leases.first {
                $0.scope.sandboxID == payload.scope.sandboxID
                    && $0.scope.generation == payload.scope.generation
                    && $0.scope.fencingToken == payload.requestedFencingToken
            }?.scope
            if let appliedScope {
                // The first reply may have been lost after the VM started.
                // A new drain/expiry rejection does not prove that VM stopped.
                return SandboxHostControlAdmission {
                    await self.completeRejectedReplay(payload, scope: appliedScope, primary: error)
                }
            }
            return SandboxHostControlAdmission(response: startFailure(
                payload, scope: payload.scope.operationScope, error: error
            ))
        }
    }

    private func completeRejectedReplay(
        _ payload: SandboxWireStart,
        scope: SandboxOperationScope,
        primary: Error
    ) async -> SandboxHostControlResponse {
        let runtime = runtime
        let name = Self.virtualMachineName(for: payload.scope)
        do {
            try await Task.detached { try await runtime.stop(scope: scope, name: name) }.value
            operationStates[scope.sandboxID] = .stopped
            return startFailure(payload, scope: scope, error: primary)
        } catch {
            operationStates[scope.sandboxID] = .failed
            return .operation(Self.operationStatus(
                payload.operationID, scope: scope, operation: "start", state: .failed,
                errorCode: "runtime_cleanup_failed"
            ))
        }
    }

    private func completeStart(
        _ payload: SandboxWireStart,
        scope: SandboxOperationScope
    ) async -> SandboxHostControlResponse {
        do {
            // The runtime rechecks authority under its operation lock and
            // authenticates readiness even when replay finds a running VM.
            try await runtime.start(scope: scope, name: Self.virtualMachineName(for: payload.scope))
            operationStates[payload.scope.sandboxID] = .ready
            return .operation(Self.operationStatus(
                payload.operationID, scope: scope, operation: "start", state: .ready
            ))
        } catch {
            // Admission and runtime authorization are separate checks. A drain
            // or expiry between them can reject replay before runtime cleanup
            // runs, while the first attempt's VM is still alive.
            return await completeRejectedReplay(payload, scope: scope, primary: error)
        }
    }

    private func startFailure(
        _ payload: SandboxWireStart,
        scope: SandboxOperationScope,
        error: Error
    ) -> SandboxHostControlResponse {
        .operation(Self.operationStatus(
            payload.operationID, scope: scope, operation: "start", state: .failed,
            errorCode: Self.errorCode(error)
        ))
    }
}
