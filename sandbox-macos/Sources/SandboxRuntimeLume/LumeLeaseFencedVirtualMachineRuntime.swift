import Foundation
import SandboxCore
import SandboxRuntime

public actor LumeLeaseFencedVirtualMachineRuntime {
    private let capacityArbiter: SandboxHostCapacityArbiter
    private let runtime: LumeVirtualMachineRuntime

    public init(
        configuration: LumeRuntimeConfiguration,
        capacityArbiter: SandboxHostCapacityArbiter
    ) {
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
        name: String,
        now: Date = Date()
    ) async throws -> SandboxVirtualMachineRecord? {
        _ = try capacityArbiter.authorize(
            scope: scope,
            virtualMachineName: name,
            operation: .inspect,
            now: now
        )
        return try await runtime.inspect(name: name)
    }

    public func create(
        scope: SandboxOperationScope,
        specification: SandboxVirtualMachineSpecification,
        now: Date = Date()
    ) async throws {
        try await runtime.create(
            specification,
            scope: scope,
            now: now
        )
    }

    public func start(
        scope: SandboxOperationScope,
        name: String,
        now: Date = Date()
    ) async throws {
        try await runtime.start(name: name, scope: scope, now: now)
    }

    public func execute(
        scope: SandboxOperationScope,
        name: String,
        request: SandboxGuestCommandRequest,
        now: Date = Date()
    ) async throws -> SandboxGuestCommandResult {
        try await runtime.execute(
            name: name,
            scope: scope,
            request: request,
            now: now
        )
    }

    public func stop(
        scope: SandboxOperationScope,
        name: String,
        now: Date = Date()
    ) async throws {
        try await runtime.stop(name: name, scope: scope, now: now)
    }

    public func delete(
        scope: SandboxOperationScope,
        name: String,
        now: Date = Date()
    ) async throws {
        try await runtime.delete(name: name, scope: scope, now: now)
    }
}
