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
        try await create(specification, scope: scope, qualification: nil)
    }

    package func createQualificationClone(_ capability: LumeQualificationCloneCapability) async throws {
        try await create(capability.specification, scope: capability.lease.scope, qualification: capability)
    }

    private func create(_ specification: SandboxVirtualMachineSpecification, scope: SandboxOperationScope?,
                        qualification: LumeQualificationCloneCapability?) async throws {
        guard SandboxVirtualMachineNamePolicy.isValid(specification.name) else {
            throw SandboxRuntimeError.invalidName
        }
        if case .appleRestore = specification.imageSource {
            guard scope == nil else {
                throw SandboxRuntimeError.unsupported("raw Apple restore is restricted to base preparation")
            }
            guard let lease = configuration.hostRuntimeLease else {
                throw SandboxRuntimeError.unsupported("raw Apple restore requires exclusive host ownership")
            }
            try lease.validateExclusive()
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
        try LumeOfflineOperationFence.requireAbsent(storage: configuration.storageDirectory, name: specification.name)

        let leaseAuthorization = try authorize(
            scope: scope,
            operation: .create,
            virtualMachineName: specification.name,
            resources: specification.resources,
            bootDiskBytes: specification.diskBytes
        )
        defer { withExtendedLifetime(leaseAuthorization) {} }
        if let qualification {
            guard let leaseAuthorization else { throw SandboxRuntimeError.invalidImageReference }
            try await consumeQualificationCloneCapability(qualification, lease: leaseAuthorization.lease)
        }
        let owner = LumeVirtualMachineOwnership.Owner(
            operationScope: scope
        )
        _ = try await validateRuntime()
        try ensureStorageDirectory()
        if let existing = try await inspect(name: specification.name) {
            guard qualification == nil, Self.matchesCreation(existing, specification: specification),
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
            if qualification == nil {
                sourceOperationLock = try beginOperation("clone-source", name: template)
                sourceOperationName = template
            }
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
        case .appleRestore(let url):
            sourceInstallationID = nil
            arguments = try restoreArguments(specification, url: url, unattendedPreset: nil)
        case .restoreImage(let url, let unattendedPreset):
            sourceInstallationID = nil
            arguments = try restoreArguments(specification, url: url, unattendedPreset: unattendedPreset)
        case .localTemplate(let template):
            try LumeOfflineOperationFence.requireAbsent(storage: configuration.storageDirectory, name: template)
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
            if let release = configuration.isolatedGuest, qualification == nil {
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
        try await executeCreation(specification: specification, owner: owner,
            sourceInstallationID: sourceInstallationID, arguments: arguments,
            qualification: qualification, lease: leaseAuthorization?.lease)
    }

    private func restoreArguments(_ specification: SandboxVirtualMachineSpecification,
                                  url: URL, unattendedPreset: String?) throws -> [String] {
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw SandboxRuntimeError.invalidImageReference
        }
        var arguments = [
            "create", specification.name, "--os", "macOS",
            "--cpu", String(specification.resources.cpuCount),
            "--memory", "\(specification.resources.memoryBytes)B",
            "--disk-size", "\(specification.diskBytes)B", "--ipsw", url.path,
        ]
        if let unattendedPreset {
            arguments += ["--unattended", unattendedPreset, "--no-display",
                          "--vnc-port", "0", "--network", "nat"]
        }
        return storageArguments(arguments)
    }

    static func matchesCreation(
        _ record: SandboxVirtualMachineRecord,
        specification: SandboxVirtualMachineSpecification
    ) -> Bool {
        record.cpuCount == specification.resources.cpuCount
            && record.memoryBytes == specification.resources.memoryBytes
            && record.diskBytes == specification.diskBytes
    }
}
