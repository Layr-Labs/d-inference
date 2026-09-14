import Foundation
import SandboxCore
import SandboxRuntime

extension LumeVirtualMachineRuntime {
    /// Shared native creation, publication and cleanup for ordinary VMs and
    /// qualification clones. The caller retains both lease and operation locks.
    func executeCreation(specification: SandboxVirtualMachineSpecification,
                         owner: LumeVirtualMachineOwnership.Owner,
                         sourceInstallationID: UUID?, arguments: [String],
                         qualification: LumeQualificationCloneCapability?,
                         lease: SandboxCapacityLease?) async throws {
        let creationWorkspace = try workspace.makeCreationWorkspace(
            name: specification.name
        )

        do {
            if let capacityArbiter {
                _ = try capacityArbiter.validateStorageHeadroom()
            }
            if case .appleRestore = specification.imageSource {
                let result = try await runManagedAppleRestore(arguments: arguments, environment: creationWorkspace.environment)
                try validateCommandResult(result, operation: "create")
            } else {
                _ = try await run(arguments: arguments, timeoutSeconds: configuration.createTimeoutSeconds,
                                  operation: "create", environment: creationWorkspace.environment)
            }
            guard let created = try await inspect(name: specification.name),
                  created.state == .stopped,
                  Self.matchesCreation(created, specification: specification)
            else {
                throw SandboxRuntimeError.malformedOutput(
                    "Lume create completed without the requested stopped VM"
                )
            }
            if let qualification {
                guard let lease else { throw SandboxRuntimeError.invalidImageReference }
                try await revalidateConsumedQualificationSource(qualification, lease: lease)
            }
            try LumeVirtualMachineOwnership.write(
                specification: specification,
                owner: owner,
                sourceInstallationID: sourceInstallationID,
                to: creationWorkspace.destination
            )
        } catch {
            do {
                try await cleanupFailedCreationIgnoringCancellation(
                    workspace: creationWorkspace
                )
            } catch let cleanupError {
                throw SandboxRuntimeError.cleanupFailed(
                    operation: "create \(specification.name)",
                    primary: String(describing: error),
                    cleanup: String(describing: cleanupError)
                )
            }
            throw error
        }
        do {
            try await cleanupCreationScratchIgnoringCancellation(
                workspace: creationWorkspace
            )
        } catch {
            throw SandboxRuntimeError.cleanupFailed(
                operation: "finish create \(specification.name)",
                primary: "virtual machine creation completed",
                cleanup: String(describing: error)
            )
        }
    }

    private func cleanupFailedCreationIgnoringCancellation(
        workspace: LumeCreationWorkspace
    ) async throws {
        let cleanup = Task.detached {
            try await workspace.removeAllArtifacts()
        }
        try await cleanup.value
    }

    private func cleanupCreationScratchIgnoringCancellation(
        workspace: LumeCreationWorkspace
    ) async throws {
        let cleanup = Task.detached {
            try await workspace.removeScratch()
        }
        try await cleanup.value
    }

}
