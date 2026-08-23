import Darwin
import Foundation
import SandboxRuntime

enum LumeVirtualMachineOwnership {
    static let fileName = ".darkbloom-ownership.json"
    private static let schemaVersion: UInt16 = 1
    private static let maximumBytes = 16 * 1_024

    static func write(
        specification: SandboxVirtualMachineSpecification,
        to virtualMachineDirectory: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do {
            data = try encoder.encode(Record(
                specification: specification,
                installationID: UUID()
            ))
        } catch {
            throw SandboxRuntimeError.unsupported(
                "failed to encode Darkbloom VM ownership marker"
            )
        }

        let directoryDescriptor = try openOwnedDirectory(
            at: virtualMachineDirectory
        )
        defer { close(directoryDescriptor) }
        let temporaryName = ".darkbloom-ownership.\(UUID().uuidString).partial"
        let descriptor = openat(
            directoryDescriptor,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
        guard descriptor >= 0 else {
            throw SandboxRuntimeError.unsupported(
                "failed to create Darkbloom VM ownership marker"
            )
        }
        var descriptorIsOpen = true
        var shouldRemoveTemporary = true
        defer {
            if descriptorIsOpen {
                close(descriptor)
            }
            if shouldRemoveTemporary {
                unlinkat(directoryDescriptor, temporaryName, 0)
            }
        }

        do {
            try data.withUnsafeBytes { bytes in
                var written = 0
                while written < bytes.count {
                    let count = Darwin.write(
                        descriptor,
                        bytes.baseAddress?.advanced(by: written),
                        bytes.count - written
                    )
                    guard count > 0 else {
                        throw POSIXError(
                            POSIXErrorCode(rawValue: errno) ?? .EIO
                        )
                    }
                    written += count
                }
            }
            guard fsync(descriptor) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let closeStatus = close(descriptor)
            descriptorIsOpen = false
            guard closeStatus == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard renameat(
                directoryDescriptor,
                temporaryName,
                directoryDescriptor,
                fileName
            ) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            shouldRemoveTemporary = false
            guard fsync(directoryDescriptor) == 0 else {
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
        in storageDirectory: URL
    ) throws {
        let record = try load(name: name, from: storageDirectory)
        guard record.name == name else {
            throw SandboxRuntimeError.unsupported(
                "VM ownership marker does not match \(name)"
            )
        }
    }

    static func matches(
        specification: SandboxVirtualMachineSpecification,
        in storageDirectory: URL
    ) -> Bool {
        guard let record = try? load(
            name: specification.name,
            from: storageDirectory
        ) else {
            return false
        }
        return record.matches(specification)
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

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_mode & 0o077 == 0,
              metadata.st_size > 0,
              metadata.st_size <= maximumBytes
        else {
            throw SandboxRuntimeError.unsupported(
                "VM \(name) has an unsafe ownership marker"
            )
        }

        let handle = FileHandle(
            fileDescriptor: descriptor,
            closeOnDealloc: false
        )
        let data: Data
        do {
            data = try handle.readToEnd() ?? Data()
        } catch {
            throw SandboxRuntimeError.unsupported(
                "VM \(name) ownership marker is unreadable"
            )
        }
        let record: Record
        do {
            record = try JSONDecoder().decode(Record.self, from: data)
        } catch {
            throw SandboxRuntimeError.unsupported(
                "VM \(name) ownership marker is malformed"
            )
        }
        guard record.schemaVersion == schemaVersion else {
            throw SandboxRuntimeError.unsupported(
                "VM \(name) ownership marker has an unsupported version"
            )
        }
        return record
    }

    private static func openOwnedDirectory(at url: URL) throws -> Int32 {
        let descriptor = open(
            url.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw SandboxRuntimeError.unsupported(
                "Darkbloom VM directory is unavailable"
            )
        }
        do {
            try validateOwnedDirectory(descriptor)
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private static func validateOwnedDirectory(_ descriptor: Int32) throws {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == geteuid(),
              metadata.st_mode & 0o022 == 0
        else {
            throw SandboxRuntimeError.unsupported(
                "Darkbloom VM directory failed ownership or mode checks"
            )
        }
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
        let unattendedPreset: String?

        init(
            specification: SandboxVirtualMachineSpecification,
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
                unattendedPreset = preset
            case .localTemplate(let template):
                sourceKind = "local_template"
                sourceReference = template
                unattendedPreset = nil
            }
        }

        func matches(
            _ specification: SandboxVirtualMachineSpecification
        ) -> Bool {
            let expected = Record(
                specification: specification,
                installationID: installationID
            )
            return schemaVersion == expected.schemaVersion
                && name == expected.name
                && cpuCount == expected.cpuCount
                && memoryBytes == expected.memoryBytes
                && diskBytes == expected.diskBytes
                && sourceKind == expected.sourceKind
                && sourceReference == expected.sourceReference
                && unattendedPreset == expected.unattendedPreset
        }
    }
}
