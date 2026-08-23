import Darwin
import Foundation
import SandboxCore
import SandboxRuntime

enum LumeVirtualMachineOwnership {
    static let fileName = ".darkbloom-ownership.json"
    private static let schemaVersion: UInt16 = 2
    private static let maximumBytes = 16 * 1_024

    enum Owner: Equatable, Sendable {
        case baseTemplate
        case sandbox(id: SandboxID, generation: SandboxGeneration)

        init(operationScope: SandboxOperationScope?) {
            guard let operationScope else {
                self = .baseTemplate
                return
            }
            self = .sandbox(
                id: operationScope.sandboxID,
                generation: operationScope.generation
            )
        }
    }

    struct Identity: Equatable, Sendable {
        let installationID: UUID
    }

    static func write(
        specification: SandboxVirtualMachineSpecification,
        owner: Owner,
        sourceInstallationID: UUID? = nil,
        to virtualMachineDirectory: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do {
            let record = Record(
                specification: specification,
                owner: owner,
                sourceInstallationID: sourceInstallationID,
                installationID: UUID()
            )
            guard record.isValid else {
                throw SandboxRuntimeError.unsupported(
                    "Darkbloom VM ownership commitment is invalid"
                )
            }
            data = try encoder.encode(record)
        } catch {
            if let runtimeError = error as? SandboxRuntimeError {
                throw runtimeError
            }
            throw SandboxRuntimeError.unsupported(
                "failed to encode Darkbloom VM ownership marker"
            )
        }

        let directoryDescriptor = try openOwnedDirectory(
            at: virtualMachineDirectory,
            requirePrivate: false
        )
        defer { close(directoryDescriptor) }
        do {
            guard fchmod(directoryDescriptor, 0o700) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            try SandboxAuthorityFileSystem.requirePrivateDirectory(
                directoryDescriptor
            )
            let descriptor =
                try SandboxAuthorityFileSystem.createUnlinkedPrivateFile(
                    parentDescriptor: directoryDescriptor,
                    prefix: "darkbloom-ownership"
                )
            defer { close(descriptor) }
            try SandboxAuthorityFileSystem.writeAll(data, to: descriptor)
            guard fsync(descriptor) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            _ = try SandboxAuthorityFileSystem.requirePrivateRegularFile(
                descriptor,
                maximumBytes: maximumBytes,
                allowEmpty: false,
                expectedLinkCount: 0
            )
            if unlinkat(directoryDescriptor, fileName, 0) != 0,
               errno != ENOENT
            {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let cloneStatus = fileName.withCString {
                fclonefileat(
                    descriptor,
                    directoryDescriptor,
                    $0,
                    UInt32(CLONE_NOFOLLOW | CLONE_NOOWNERCOPY)
                )
            }
            guard cloneStatus == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let committedDescriptor = openat(
                directoryDescriptor,
                fileName,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW
            )
            guard committedDescriptor >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            defer { close(committedDescriptor) }
            let committed =
                try SandboxAuthorityFileSystem.readStablePrivateFile(
                    committedDescriptor,
                    maximumBytes: maximumBytes
                )
            guard committed == data else {
                throw POSIXError(.EIO)
            }
            guard fsync(committedDescriptor) == 0,
                  fsync(directoryDescriptor) == 0
            else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            throw SandboxRuntimeError.unsupported(
                "failed to persist Darkbloom VM ownership marker"
            )
        }
    }

    static func requireOwned(
        name: String,
        owner: Owner,
        in storageDirectory: URL
    ) throws -> Identity {
        let record = try load(name: name, from: storageDirectory)
        guard record.name == name,
              record.matches(owner: owner)
        else {
            throw SandboxRuntimeError.unsupported(
                "VM \(name) belongs to a different Darkbloom sandbox scope"
            )
        }
        return Identity(installationID: record.installationID)
    }

    static func matches(
        specification: SandboxVirtualMachineSpecification,
        owner: Owner,
        in storageDirectory: URL
    ) -> Bool {
        guard let record = try? load(
            name: specification.name,
            from: storageDirectory
        ) else {
            return false
        }
        return record.matches(specification, owner: owner)
    }

    private static func load(
        name: String,
        from storageDirectory: URL
    ) throws -> Record {
        guard SandboxVirtualMachineNamePolicy.isValid(name) else {
            throw SandboxRuntimeError.invalidName
        }
        let storageDescriptor = try openOwnedDirectory(at: storageDirectory)
        defer { close(storageDescriptor) }
        let virtualMachineDescriptor = openat(
            storageDescriptor,
            name,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard virtualMachineDescriptor >= 0 else {
            throw SandboxRuntimeError.unsupported(
                "VM \(name) is not owned by Darkbloom"
            )
        }
        defer { close(virtualMachineDescriptor) }
        try validateOwnedDirectory(virtualMachineDescriptor)

        let descriptor = openat(
            virtualMachineDescriptor,
            fileName,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw SandboxRuntimeError.unsupported(
                "VM \(name) is not owned by Darkbloom"
            )
        }
        defer { close(descriptor) }

        let data: Data
        do {
            data = try SandboxAuthorityFileSystem.readStablePrivateFile(
                descriptor,
                maximumBytes: maximumBytes
            )
        } catch {
            throw SandboxRuntimeError.unsupported(
                "VM \(name) has an unsafe ownership marker"
            )
        }
        let decoder = JSONDecoder()
        let version: VersionRecord
        do {
            version = try decoder.decode(VersionRecord.self, from: data)
        } catch {
            throw SandboxRuntimeError.unsupported(
                "VM \(name) ownership marker is malformed"
            )
        }
        guard version.schemaVersion == schemaVersion else {
            throw SandboxRuntimeError.unsupported(
                "VM \(name) ownership marker has an unsupported version"
            )
        }
        let record: Record
        do {
            record = try decoder.decode(Record.self, from: data)
        } catch {
            throw SandboxRuntimeError.unsupported(
                "VM \(name) ownership marker is malformed"
            )
        }
        guard record.isValid else {
            throw SandboxRuntimeError.unsupported(
                "VM \(name) ownership marker is malformed"
            )
        }
        return record
    }

    private static func openOwnedDirectory(
        at url: URL,
        requirePrivate: Bool = true
    ) throws -> Int32 {
        let descriptor: Int32
        do {
            descriptor =
                try SandboxAuthorityFileSystem.openExistingDirectory(at: url)
        } catch {
            throw SandboxRuntimeError.unsupported(
                "Darkbloom VM directory is unavailable"
            )
        }
        do {
            if requirePrivate {
                try validateOwnedDirectory(descriptor)
            } else {
                try SandboxAuthorityFileSystem
                    .requireOwnedDirectoryWithoutWriteSharing(descriptor)
            }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private static func validateOwnedDirectory(_ descriptor: Int32) throws {
        do {
            try SandboxAuthorityFileSystem.requirePrivateDirectory(descriptor)
        } catch {
            throw SandboxRuntimeError.unsupported(
                "Darkbloom VM directory failed ownership or mode checks"
            )
        }
    }

    private struct VersionRecord: Decodable {
        let schemaVersion: UInt16
    }

    private struct Record: Codable {
        let schemaVersion: UInt16
        let installationID: UUID
        let name: String
        let cpuCount: UInt16
        let memoryBytes: UInt64
        let diskBytes: UInt64
        let sourceKind: String
        let sourceReference: String
        let sourceInstallationID: UUID?
        let unattendedPreset: String?
        let ownerKind: String
        let sandboxID: SandboxID?
        let sandboxGeneration: SandboxGeneration?

        init(
            specification: SandboxVirtualMachineSpecification,
            owner: Owner,
            sourceInstallationID: UUID?,
            installationID: UUID
        ) {
            schemaVersion = LumeVirtualMachineOwnership.schemaVersion
            self.installationID = installationID
            name = specification.name
            cpuCount = specification.resources.cpuCount
            memoryBytes = specification.resources.memoryBytes
            diskBytes = specification.diskBytes
            switch specification.imageSource {
            case .restoreImage(let url, let preset):
                sourceKind = "restore_image"
                sourceReference = url.standardizedFileURL.path
                self.sourceInstallationID = nil
                unattendedPreset = preset
            case .localTemplate(let template):
                sourceKind = "local_template"
                sourceReference = template
                self.sourceInstallationID = sourceInstallationID
                unattendedPreset = nil
            }
            switch owner {
            case .baseTemplate:
                ownerKind = "base_template"
                sandboxID = nil
                sandboxGeneration = nil
            case .sandbox(let id, let generation):
                ownerKind = "sandbox"
                sandboxID = id
                sandboxGeneration = generation
            }
        }

        func matches(
            _ specification: SandboxVirtualMachineSpecification,
            owner: Owner
        ) -> Bool {
            let expected = Record(
                specification: specification,
                owner: owner,
                sourceInstallationID: sourceInstallationID,
                installationID: installationID
            )
            return schemaVersion == expected.schemaVersion
                && name == expected.name
                && cpuCount == expected.cpuCount
                && memoryBytes == expected.memoryBytes
                && diskBytes == expected.diskBytes
                && sourceKind == expected.sourceKind
                && sourceReference == expected.sourceReference
                && sourceInstallationID == expected.sourceInstallationID
                && unattendedPreset == expected.unattendedPreset
                && ownerKind == expected.ownerKind
                && sandboxID == expected.sandboxID
                && sandboxGeneration == expected.sandboxGeneration
        }

        func matches(owner: Owner) -> Bool {
            switch owner {
            case .baseTemplate:
                ownerKind == "base_template"
                    && sandboxID == nil
                    && sandboxGeneration == nil
            case .sandbox(let id, let generation):
                ownerKind == "sandbox"
                    && sandboxID == id
                    && sandboxGeneration == generation
            }
        }

        var isValid: Bool {
            guard schemaVersion == LumeVirtualMachineOwnership.schemaVersion,
                  SandboxVirtualMachineNamePolicy.isValid(name),
                  cpuCount > 0,
                  memoryBytes > 0,
                  diskBytes > 0,
                  !sourceReference.isEmpty,
                  matchesStoredOwner
            else {
                return false
            }
            switch sourceKind {
            case "restore_image":
                return sourceInstallationID == nil
                    && unattendedPreset == "tahoe"
            case "local_template":
                return SandboxVirtualMachineNamePolicy.isValid(sourceReference)
                    && sourceInstallationID != nil
                    && unattendedPreset == nil
            default:
                return false
            }
        }

        private var matchesStoredOwner: Bool {
            switch ownerKind {
            case "base_template":
                return sandboxID == nil && sandboxGeneration == nil
            case "sandbox":
                return sandboxID != nil && sandboxGeneration != nil
            default:
                return false
            }
        }
    }
}
