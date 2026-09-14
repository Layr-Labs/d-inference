import Foundation
import SandboxCore
import SandboxRuntime

extension LumeVirtualMachineRuntime {
    public func delete(name: String) async throws {
        try await delete(name: name, scope: nil)
    }

    func delete(
        name: String,
        scope: SandboxOperationScope?
    ) async throws {
        try await performDelete(
            name: name,
            scope: scope,
            releaseCapacity: false
        )
    }

    func deleteAndRelease(
        name: String,
        scope: SandboxOperationScope
    ) async throws {
        try await performDelete(
            name: name,
            scope: scope,
            releaseCapacity: true
        )
    }

    private func performDelete(
        name: String,
        scope: SandboxOperationScope?,
        releaseCapacity: Bool
    ) async throws {
        guard SandboxVirtualMachineNamePolicy.isValid(name) else { throw SandboxRuntimeError.invalidName }
        var reservationAbsent = false
        do { try preauthorize(scope: scope, operation: .delete, virtualMachineName: name) }
        catch SandboxCapacityError.leaseNotFound where releaseCapacity && scope != nil { reservationAbsent = true }
        let operationLock = try beginOperation(releaseCapacity ? "delete-and-release" : "delete", name: name)
        defer { endOperation(name: name); withExtendedLifetime(operationLock) {} }
        try LumeOfflineOperationFence.requireAbsent(storage: configuration.storageDirectory, name: name)
        let pending = try LumeVirtualMachineDeletionIntent.load(workspace: workspace, name: name)
        try pending?.requireMatching(name: name, scope: scope)
        if releaseCapacity, let capacityArbiter, let scope,
           try capacityArbiter.deletionConfirmed(scope: scope, virtualMachineName: name) {
            guard try await inspect(name: name) == nil else {
                throw SandboxRuntimeError.malformedOutput("deleted VM reappeared after fenced capacity release")
            }
            if let pending {
                try pending.removeOwnedTree(workspace: workspace)
                try pending.clear(workspace: workspace)
            } else {
                try requireUnlistedVirtualMachineIsUnowned(name: name, owner: .init(operationScope: scope))
            }
            return
        }
        if reservationAbsent {
            guard pending == nil, try await inspect(name: name) == nil else {
                throw SandboxCapacityError.leaseNotFound
            }
            try requireUnlistedVirtualMachineIsUnowned(name: name, owner: .init(operationScope: scope))
            return
        }
        let authorization = try authorize(scope: scope, operation: .delete, virtualMachineName: name)
        defer { withExtendedLifetime(authorization) {} }
        if let pending {
            // The stopped proof lives outside the directory. A previous Lume
            // delete may already have removed config/ownership/journal files.
            try pending.removeOwnedTree(workspace: workspace)
            try releaseCapacityIfRequested(releaseCapacity, scope: scope, authorization: authorization)
            if releaseCapacity || scope == nil { try pending.clear(workspace: workspace) }
            return
        }
        let owner = LumeVirtualMachineOwnership.Owner(operationScope: scope)
        guard let existing = try await inspect(name: name) else {
            try requireUnlistedVirtualMachineIsUnowned(name: name, owner: owner)
            try releaseCapacityIfRequested(releaseCapacity, scope: scope, authorization: authorization)
            return
        }
        let commitment = try LumeVirtualMachineOwnership.requireResourceCommitment(
            name: name, owner: owner, in: configuration.storageDirectory)
        try LumeVirtualMachineResourceCommitment.requireMatch(observed: existing, ownership: commitment,
            lease: authorization?.lease)
        if releaseCapacity {
            try await stopWithoutOperationFence(name: name, owner: owner, expectedLease: authorization?.lease)
        } else {
            try LumeVirtualMachineStartIntent.requireAbsent(name: name, ownership: commitment.identity,
                owner: owner, in: configuration.storageDirectory)
            guard existing.state == .stopped else {
                throw SandboxRuntimeError.unsupported("refusing to delete VM \(name) while state is \(existing.state.rawValue)")
            }
        }
        guard let stopped = try await inspect(name: name), stopped.state == .stopped else {
            throw SandboxRuntimeError.unsupported("VM deletion requires stopped proof")
        }
        try LumeVirtualMachineResourceCommitment.requireMatch(observed: stopped, ownership: commitment,
            lease: authorization?.lease)
        let intent = try LumeVirtualMachineDeletionIntent.persist(workspace: workspace, name: name,
            scope: scope, installationID: commitment.identity.installationID)
        _ = try await run(arguments: storageArguments(["delete", name, "--force"]),
            timeoutSeconds: configuration.commandTimeoutSeconds, operation: "delete")
        try intent.removeOwnedTree(workspace: workspace)
        try releaseCapacityIfRequested(releaseCapacity, scope: scope, authorization: authorization)
        if releaseCapacity || scope == nil { try intent.clear(workspace: workspace) }
    }

    private func releaseCapacityIfRequested(
        _ releaseCapacity: Bool,
        scope: SandboxOperationScope?,
        authorization: SandboxLeaseMutationAuthorization?
    ) throws {
        guard releaseCapacity else {
            return
        }
        guard let capacityArbiter,
              let scope,
              let authorization
        else {
            throw SandboxRuntimeError.unsupported(
                "capacity release requires a fenced lease authorization"
            )
        }
        try capacityArbiter.releaseDeleted(
            scope: scope,
            holding: authorization
        )
    }

}
