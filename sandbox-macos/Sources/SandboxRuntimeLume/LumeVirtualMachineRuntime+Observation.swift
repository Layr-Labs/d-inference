import Foundation
import SandboxCore
import SandboxRuntime

extension LumeVirtualMachineRuntime {
    func inspect(
        name: String,
        scope: SandboxOperationScope
    ) async throws -> SandboxVirtualMachineRecord? {
        guard SandboxVirtualMachineNamePolicy.isValid(name) else {
            throw SandboxRuntimeError.invalidName
        }
        try preauthorize(
            scope: scope,
            operation: .inspect,
            virtualMachineName: name
        )
        let operationLock = try beginOperation("inspect", name: name)
        defer {
            endOperation(name: name)
            withExtendedLifetime(operationLock) {}
        }
        guard let capacityArbiter else {
            throw SandboxRuntimeError.unsupported(
                "lease-fenced Lume operation requires a capacity arbiter"
            )
        }
        _ = try capacityArbiter.authorize(
            scope: scope,
            virtualMachineName: name,
            operation: .inspect
        )
        let record = try await inspect(name: name)
        let ownership = try LumeVirtualMachineOwnership.presence(
            name: name,
            owner: .init(operationScope: scope),
            in: configuration.storageDirectory
        )
        var resourceCommitment:
            LumeVirtualMachineOwnership.ResourceCommitment?
        switch (record, ownership) {
        case (.some, .owned):
            resourceCommitment =
                try LumeVirtualMachineOwnership.requireResourceCommitment(
                    name: name,
                    owner: .init(operationScope: scope),
                    in: configuration.storageDirectory
                )
        case (.none, .absent):
            break
        case (.some, .absent), (.none, .owned):
            throw SandboxRuntimeError.unsupported(
                "VM \(name) runtime and ownership presence disagree"
            )
        }
        let lease = try capacityArbiter.authorize(
            scope: scope,
            virtualMachineName: name,
            operation: .inspect
        )
        if let record, let resourceCommitment {
            try LumeVirtualMachineResourceCommitment.requireMatch(
                observed: record,
                ownership: resourceCommitment,
                lease: lease
            )
        }
        return record
    }
}
