import Foundation
import SandboxCore
import SandboxGuestProtocol
import SandboxRuntime

extension LumeVirtualMachineRuntime {
    func file(scope: SandboxOperationScope, name: String,
              request: GuestRequest) async throws -> GuestResponse {
        let operation: SandboxLeaseOperation
        switch request.operation {
        case .download, .uploadStatus, .uploadAbort: operation = .inspect
        case .uploadBegin, .uploadChunk, .uploadCommit, .mkdir: operation = .execute
        default: throw GuestProtocolError.invalidMessage
        }
        guard configuration.isolatedGuest != nil,
              SandboxVirtualMachineNamePolicy.isValid(name) else { throw GuestProtocolError.unavailable }
        try preauthorize(scope: scope, operation: operation, virtualMachineName: name)
        let operationLock = try beginOperation("file", name: name)
        defer { endOperation(name: name); withExtendedLifetime(operationLock) {} }
        let authorization = try authorize(scope: scope, operation: operation, virtualMachineName: name)
        defer { withExtendedLifetime(authorization) {} }
        guard let observed = try await inspect(name: name), observed.state == .running else {
            throw GuestProtocolError.unavailable
        }
        let commitment = try LumeVirtualMachineOwnership.requireResourceCommitment(
            name: name, owner: .init(operationScope: scope), in: configuration.storageDirectory)
        try LumeVirtualMachineResourceCommitment.requireMatch(
            observed: observed, ownership: commitment, lease: authorization?.lease)
        if let requested = request.size, request.operation == .uploadBegin,
           let lease = authorization?.lease, requested > lease.workspaceBytes {
            throw GuestProtocolError.invalidMessage
        }
        let result: GuestResponse
        do {
            result = try await isolatedGuestClient(name: name).request(request)
        } catch {
            // A lost or cancelled reply may have contained mandatory cleanup
            // evidence. Do not assume that the guest is still safe for work.
            try await stopAfterInterruptedFile(name: name, scope: scope, lease: authorization?.lease)
            throw error
        }
        if result.requiresVMStop == true {
            try await stopAfterInterruptedFile(name: name, scope: scope, lease: authorization?.lease)
            throw GuestProtocolError.cleanupUncertain
        }
        try Task.checkCancellation()
        // Authority may rotate while the guest performs I/O. Discard a stale
        // result; transfer status provides recovery after an uncertain commit.
        try preauthorize(scope: scope, operation: operation, virtualMachineName: name)
        return result
    }

    private func stopAfterInterruptedFile(name: String, scope: SandboxOperationScope,
                                          lease: SandboxCapacityLease?) async throws {
        let cleanup = Task.detached {
            try await self.stopWithoutOperationFence(name: name,
                owner: .init(operationScope: scope), expectedLease: lease)
        }
        do { try await cleanup.value }
        catch {
            throw SandboxRuntimeError.cleanupFailed(operation: "file operation \(name)",
                primary: "guest response or cleanup was unproven", cleanup: String(describing: error))
        }
    }
}
