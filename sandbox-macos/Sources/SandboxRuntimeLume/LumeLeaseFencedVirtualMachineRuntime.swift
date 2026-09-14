import Foundation
import SandboxCore
import SandboxRuntime
import SandboxGuestProtocol

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

    package func qualificationCloneCapability(candidateID: UUID, qualificationID: UUID,
        scope: SandboxOperationScope, specification: SandboxVirtualMachineSpecification) async throws -> LumeQualificationCloneCapability {
        try await runtime.qualificationCloneCapability(candidateID: candidateID, qualificationID: qualificationID,
            scope: scope, specification: specification)
    }

    package func createQualificationClone(_ capability: LumeQualificationCloneCapability) async throws {
        try await runtime.createQualificationClone(capability)
    }

    package func revalidateQualificationCloneCapability(_ capability: LumeQualificationCloneCapability) async throws {
        try await runtime.revalidateQualificationCloneCapability(capability)
    }

    package func execute(
        scope: SandboxOperationScope,
        name: String,
        request: SandboxGuestCommandRequest
    ) async throws -> SandboxGuestCommandResult {
        try await runtime.execute(
            name: name,
            scope: scope,
            request: request
        )
    }

    public func stop(
        scope: SandboxOperationScope,
        name: String
    ) async throws {
        try await runtime.stop(name: name, scope: scope)
    }

    package func file(scope: SandboxOperationScope, name: String,
                      request: GuestRequest) async throws -> GuestResponse {
        try await runtime.file(scope: scope, name: name, request: request)
    }

    package func delete(
        scope: SandboxOperationScope,
        name: String
    ) async throws {
        try await runtime.delete(name: name, scope: scope)
    }

    package func deleteAndRelease(
        scope: SandboxOperationScope,
        name: String
    ) async throws {
        try await runtime.deleteAndRelease(name: name, scope: scope)
    }

    public func release(
        scope: SandboxOperationScope,
        name: String
    ) async throws {
        try await teardown(name: name, scope: scope)
    }

    private func teardown(name: String, scope: SandboxOperationScope) async throws {
        if try LumeVirtualMachineDeletionIntent.load(
            workspace: LumeRuntimeWorkspace(storageDirectory: storageDirectory), name: name) == nil,
           try !capacityArbiter.deletionConfirmed(scope: scope, virtualMachineName: name) {
            // Without a durable stopped deletion intent, missing/unknown VM
            // state must retain capacity rather than being treated as cleanup.
            try await runtime.stop(name: name, scope: scope)
        }
        try await runtime.deleteAndRelease(name: name, scope: scope)
    }

    public func reconcileExpiredLeases() async throws
        -> [LumeExpiredLeaseReconciliationResult]
    {
        try capacityArbiter.requireStorageDirectory(storageDirectory)
        try await reconcileReleasedDeletionIntents()
        let expired = try capacityArbiter.expiredLeases()
        let pending = try capacityArbiter.snapshot().leases.filter { lease in
            try LumeVirtualMachineDeletionIntent.load(
                workspace: LumeRuntimeWorkspace(storageDirectory: storageDirectory),
                name: lease.virtualMachineName) != nil
        }
        let candidates = pending + expired.filter { expired in !pending.contains { $0.scope.sandboxID == expired.scope.sandboxID } }
        var results: [LumeExpiredLeaseReconciliationResult] = []
        results.reserveCapacity(candidates.count)
        for observed in candidates {
            var lease = observed
            do {
                if expired.contains(where: { $0.scope == observed.scope }) {
                    lease = try capacityArbiter.fenceExpiredLease(scope: observed.scope)
                }
                try await teardown(name: lease.virtualMachineName, scope: lease.scope)
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

    private func reconcileReleasedDeletionIntents() async throws {
        let workspace = LumeRuntimeWorkspace(storageDirectory: storageDirectory)
        for intent in try LumeVirtualMachineDeletionIntent.pending(workspace: workspace) {
            guard let original = intent.scope,
                  let released = try capacityArbiter.releasedDeletionScope(
                    matching: original, virtualMachineName: intent.name) else { continue }
            // deleteAndRelease rechecks the exact release receipt durably under
            // the VM operation lock before clearing the original intent.
            try await runtime.deleteAndRelease(name: intent.name, scope: released)
        }
    }

    public func stopAllForShutdown() async throws {
        var failures: [String] = []
        for lease in try capacityArbiter.snapshot().leases {
            do {
                try await runtime.stop(name: lease.virtualMachineName, scope: lease.scope)
            } catch {
                failures.append("\(lease.virtualMachineName): \(error)")
            }
        }
        guard failures.isEmpty else {
            throw SandboxRuntimeError.unsupported("VM shutdown remains unproven: " + failures.joined(separator: "; "))
        }
    }
}
