import Foundation
import SandboxCore
import SandboxRuntime

public actor LumeLeaseFencedVirtualMachineRuntime {
    private let capacityArbiter: SandboxHostCapacityArbiter
    private let runtime: LumeVirtualMachineRuntime
    private let storageDirectory: URL

    public init(
        configuration: LumeRuntimeConfiguration,
        capacityArbiter: SandboxHostCapacityArbiter
    ) throws {
        try capacityArbiter.requireStorageDirectory(
            configuration.storageDirectory
        )
        self.capacityArbiter = capacityArbiter
        self.storageDirectory = configuration.storageDirectory
        self.runtime = LumeVirtualMachineRuntime(
            configuration: configuration,
            capacityArbiter: capacityArbiter
        )
    }

    public func capabilities() async throws -> SandboxRuntimeCapabilities {
        try capacityArbiter.requireStorageDirectory(storageDirectory)
        return try await runtime.capabilities()
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

    package func delete(
        scope: SandboxOperationScope,
        name: String
    ) async throws {
        try await runtime.delete(name: name, scope: scope)
    }

    public func release(
        scope: SandboxOperationScope,
        name: String
    ) async throws {
        try await runtime.stopAndRelease(name: name, scope: scope)
    }

    public func reconcileExpiredLeases() async throws
        -> [LumeExpiredLeaseReconciliationResult]
    {
        try capacityArbiter.requireStorageDirectory(storageDirectory)
        let expired = try capacityArbiter.expiredLeases()
        var results: [LumeExpiredLeaseReconciliationResult] = []
        results.reserveCapacity(expired.count)
        for observed in expired {
            var lease = observed
            do {
                lease = try capacityArbiter.fenceExpiredLease(
                    scope: observed.scope
                )
                try await runtime.stopAndRelease(
                    name: lease.virtualMachineName,
                    scope: lease.scope
                )
                results.append(.init(lease: lease, outcome: .released))
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
