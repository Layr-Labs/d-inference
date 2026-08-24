import Foundation
import SandboxCore
import SandboxRuntime

public actor LumeLeaseFencedVirtualMachineRuntime {
    private let capacityArbiter: SandboxHostCapacityArbiter
    private let runtime: LumeVirtualMachineRuntime

    public init(
        configuration: LumeRuntimeConfiguration,
        capacityArbiter: SandboxHostCapacityArbiter
    ) throws {
        try capacityArbiter.requireStorageDirectory(
            configuration.storageDirectory
        )
        self.capacityArbiter = capacityArbiter
        self.runtime = LumeVirtualMachineRuntime(
            configuration: configuration,
            capacityArbiter: capacityArbiter
        )
    }

    public func capabilities() async throws -> SandboxRuntimeCapabilities {
        try await runtime.capabilities()
    }

    public func inspect(
        scope: SandboxOperationScope,
        name: String
    ) async throws -> SandboxVirtualMachineRecord? {
        try await runtime.inspect(name: name, scope: scope)
    }

    public func create(
        scope: SandboxOperationScope,
        specification: SandboxVirtualMachineSpecification
    ) async throws {
        try await runtime.create(
            specification,
            scope: scope
        )
    }

    public func start(
        scope: SandboxOperationScope,
        name: String
    ) async throws {
        try await runtime.start(name: name, scope: scope)
    }

    public func stop(
        scope: SandboxOperationScope,
        name: String
    ) async throws {
        try await runtime.stop(name: name, scope: scope)
    }

    public func delete(
        scope: SandboxOperationScope,
        name: String
    ) async throws {
        try await runtime.delete(name: name, scope: scope)
    }

    public func release(
        scope: SandboxOperationScope,
        name: String
    ) async throws {
        try await runtime.stop(name: name, scope: scope)
        try capacityArbiter.release(scope: scope)
    }

    public func reconcileExpiredLeases() async throws
        -> [LumeExpiredLeaseReconciliationResult]
    {
        let expired = try capacityArbiter.expiredLeases()
        var results: [LumeExpiredLeaseReconciliationResult] = []
        results.reserveCapacity(expired.count)
        for observed in expired {
            var lease = observed
            do {
                lease = try capacityArbiter.fenceExpiredLease(
                    scope: observed.scope
                )
                try await runtime.stop(
                    name: lease.virtualMachineName,
                    scope: lease.scope
                )
                do {
                    try capacityArbiter.release(scope: lease.scope)
                    results.append(.init(lease: lease, outcome: .released))
                } catch SandboxCapacityError.leaseNotFound {
                    results.append(
                        .init(lease: lease, outcome: .alreadyReleased)
                    )
                }
            } catch SandboxCapacityError.leaseNotFound {
                results.append(
                    .init(lease: lease, outcome: .alreadyReleased)
                )
            } catch {
                results.append(
                    .init(
                        lease: lease,
                        outcome: .retained(String(describing: error))
                    )
                )
            }
        }
        return results
    }
}
