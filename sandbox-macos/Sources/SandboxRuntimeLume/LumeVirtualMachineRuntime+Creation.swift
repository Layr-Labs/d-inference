import Foundation
import SandboxCore
import SandboxRuntime

extension LumeVirtualMachineRuntime {
    public func create(
        _ specification: SandboxVirtualMachineSpecification
    ) async throws {
        try await create(specification, scope: nil)
    }

    func create(
        _ specification: SandboxVirtualMachineSpecification,
        scope: SandboxOperationScope?
    ) async throws {
        guard SandboxVirtualMachineNamePolicy.isValid(specification.name) else {
            throw SandboxRuntimeError.invalidName
        }
        try preauthorize(
            scope: scope,
            operation: .create,
            virtualMachineName: specification.name,
            resources: specification.resources,
            bootDiskBytes: specification.diskBytes
        )
        let operationLock = try beginOperation(
            "create",
            name: specification.name
        )
        defer {
            endOperation(name: specification.name)
            withExtendedLifetime(operationLock) {}
        }

        let leaseAuthorization = try authorize(
            scope: scope,
            operation: .create,
            virtualMachineName: specification.name,
            resources: specification.resources,
            bootDiskBytes: specification.diskBytes
        )
        defer { withExtendedLifetime(leaseAuthorization) {} }
        let owner = LumeVirtualMachineOwnership.Owner(
            operationScope: scope
        )
        _ = try await validateRuntime()
        try ensureStorageDirectory()
        if let existing = try await inspect(name: specification.name) {
            guard Self.matches(existing, specification: specification),
                  LumeVirtualMachineOwnership.matches(
                      specification: specification,
                      owner: owner,
                      in: configuration.storageDirectory
                  )
            else {
                throw SandboxRuntimeError.unsupported(
                    "VM \(specification.name) already exists without matching Darkbloom ownership"
                )
            }
            let identity = try LumeVirtualMachineOwnership.requireOwned(
                name: specification.name,
                owner: owner,
                in: configuration.storageDirectory
            )
            try LumeVirtualMachineStartIntent.requireAbsent(
                name: specification.name,
                ownership: identity,
                owner: owner,
                in: configuration.storageDirectory
            )
            return
        }
        try requireUnlistedVirtualMachineIsUnowned(
            name: specification.name,
            owner: owner
        )

        var sourceOperationName: String?
        var sourceOperationLock: LumeVirtualMachineOperationLock?
        if case .localTemplate(let template) = specification.imageSource {
            guard template != specification.name else {
                throw SandboxRuntimeError.invalidImageReference
            }
            guard try await inspect(name: template) != nil else {
                throw SandboxRuntimeError.invalidImageReference
            }
            let sourceIdentity = try LumeVirtualMachineOwnership.requireOwned(
                name: template,
                owner: .baseTemplate,
                in: configuration.storageDirectory
            )
            try LumeVirtualMachineStartIntent.requireAbsent(
                name: template,
                ownership: sourceIdentity,
                owner: .baseTemplate,
                in: configuration.storageDirectory
            )
            sourceOperationLock = try beginOperation(
                "clone-source",
                name: template
            )
            sourceOperationName = template
        }
        defer {
            if let sourceOperationName {
                endOperation(name: sourceOperationName)
            }
            withExtendedLifetime(sourceOperationLock) {}
        }

        let arguments: [String]
        var sourceInstallationID: UUID?
        switch specification.imageSource {
        case .restoreImage(let url, let unattendedPreset):
            guard FileManager.default.isReadableFile(atPath: url.path) else {
                throw SandboxRuntimeError.invalidImageReference
            }
            sourceInstallationID = nil
            arguments = storageArguments([
                "create",
                specification.name,
                "--os", "macOS",
                "--cpu", String(specification.resources.cpuCount),
                "--memory", "\(specification.resources.memoryBytes)B",
                "--disk-size", "\(specification.diskBytes)B",
                "--ipsw", url.path,
                "--unattended", unattendedPreset,
                "--no-display",
                "--vnc-port", "0",
                "--network", "nat",
            ])
        case .localTemplate(let template):
            try LumeVirtualMachineDeletionIntent.requireAbsent(workspace: workspace, name: template)
            guard let templateRecord = try await inspect(name: template) else {
                throw SandboxRuntimeError.invalidImageReference
            }
            guard templateRecord.state == .stopped else {
                throw SandboxRuntimeError.unsupported("base template must be stopped before cloning")
            }
            guard templateRecord.diskBytes == specification.diskBytes else {
                throw SandboxRuntimeError.templateBootDiskMismatch(
                    template: template,
                    requested: specification.diskBytes,
                    actual: templateRecord.diskBytes
                )
            }
            let sourceIdentity = try LumeVirtualMachineOwnership.requireOwned(
                name: template,
                owner: .baseTemplate,
                in: configuration.storageDirectory
            )
            try LumeVirtualMachineStartIntent.requireAbsent(
                name: template,
                ownership: sourceIdentity,
                owner: .baseTemplate,
                in: configuration.storageDirectory
            )
            if let release = configuration.isolatedGuest {
                try LumeGuestTemplate.requireReady(name: template, installationID: sourceIdentity.installationID,
                    storage: configuration.storageDirectory, release: release)
            }
            sourceInstallationID = sourceIdentity.installationID
            arguments = [
                "clone",
                template,
                specification.name,
                "--source-storage", configuration.storageDirectory.path,
                "--dest-storage", configuration.storageDirectory.path,
            ]
        }
        let creationWorkspace = try workspace.makeCreationWorkspace(
            name: specification.name
        )

        do {
            if let capacityArbiter {
                _ = try capacityArbiter.validateStorageHeadroom()
            }
            _ = try await run(
                arguments: arguments,
                timeoutSeconds: configuration.createTimeoutSeconds,
                operation: "create",
                environment: creationWorkspace.environment
            )
            guard let created = try await inspect(name: specification.name),
                  created.state == .stopped,
                  Self.matches(created, specification: specification)
            else {
                throw SandboxRuntimeError.malformedOutput(
                    "Lume create completed without the requested stopped VM"
                )
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

    private static func matches(
        _ record: SandboxVirtualMachineRecord,
        specification: SandboxVirtualMachineSpecification
    ) -> Bool {
        record.cpuCount == specification.resources.cpuCount
            && record.memoryBytes == specification.resources.memoryBytes
            && record.diskBytes == specification.diskBytes
    }
}
