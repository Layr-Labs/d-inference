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
    ) {
        self.capacityArbiter = capacityArbiter
        self.storageDirectory = configuration.storageDirectory
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
        _ = try capacityArbiter.authorize(
            scope: scope,
            virtualMachineName: name,
            operation: .inspect
        )
        let record = try await runtime.inspect(name: name)
        if record != nil {
            _ = try LumeVirtualMachineOwnership.requireOwned(
                name: name,
                owner: .init(operationScope: scope),
                in: storageDirectory
            )
        }
        return record
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

    public func execute(
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

    public func delete(
        scope: SandboxOperationScope,
        name: String
    ) async throws {
        try await runtime.delete(name: name, scope: scope)
    }
}
