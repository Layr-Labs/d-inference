import Darwin
import Foundation
import SandboxRuntime

enum LumeVirtualMachineStartIntentAuthority {
    enum PublicationConflict: Error, Sendable {
        case alreadyExists
    }

    static func readIfPresent(
        name: String,
        fileName: String,
        maximumBytes: Int,
        in storageDirectory: URL
    ) throws -> Data? {
        let directoryDescriptor = try openVirtualMachineDirectory(
            name: name,
            in: storageDirectory
        )
        defer { close(directoryDescriptor) }
        let descriptor = openat(
            directoryDescriptor,
            fileName,
            O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            if errno == ENOENT {
                return nil
            }
            throw failure(name, "start intent path is unsafe")
        }
        defer { close(descriptor) }
        return try readStableData(
            descriptor,
            name: name,
            maximumBytes: maximumBytes
        )
    }

    static func publish(
        _ data: Data,
        name: String,
        fileName: String,
        maximumBytes: Int,
        in storageDirectory: URL
    ) throws {
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw failure(name, "start intent exceeds its size bound")
        }
        let directoryDescriptor = try openVirtualMachineDirectory(
            name: name,
            in: storageDirectory
        )
        defer { close(directoryDescriptor) }
        let stagingDescriptor: Int32
        do {
            stagingDescriptor =
                try SandboxAuthorityFileSystem.createUnlinkedPrivateFile(
                    parentDescriptor: directoryDescriptor,
                    prefix: "darkbloom-start-intent"
                )
        } catch {
            throw failure(name, "could not stage start intent")
        }
        defer { close(stagingDescriptor) }

        do {
            try SandboxAuthorityFileSystem.writeAll(
                data,
                to: stagingDescriptor
            )
            try SandboxAuthorityFileSystem.synchronize(stagingDescriptor)
            try requireExactPrivateFile(
                stagingDescriptor,
                maximumBytes: maximumBytes,
                expectedLinkCount: 0
            )
        } catch {
            throw failure(name, "could not durably stage start intent")
        }

        let cloneStatus = fileName.withCString {
            fclonefileat(
                stagingDescriptor,
                directoryDescriptor,
                $0,
                UInt32(CLONE_NOFOLLOW | CLONE_NOOWNERCOPY)
            )
        }
        guard cloneStatus == 0 else {
            if errno == EEXIST {
                throw PublicationConflict.alreadyExists
            }
            throw failure(name, "could not publish start intent")
        }

        let committedDescriptor = try openRequired(
            name: name,
            fileName: fileName,
            directoryDescriptor: directoryDescriptor
        )
        defer { close(committedDescriptor) }
        do {
            let committed = try readStableData(
                committedDescriptor,
                name: name,
                maximumBytes: maximumBytes
            )
            guard committed == data else {
                throw SandboxAuthorityFileSystemError.unsafePath
            }
            try SandboxAuthorityFileSystem.synchronize(committedDescriptor)
            try SandboxAuthorityFileSystem.synchronize(directoryDescriptor)
        } catch {
            throw failure(name, "start intent publication is uncertain")
        }
    }

    static func remove(
        expectedData: Data,
        name: String,
        fileName: String,
        maximumBytes: Int,
        in storageDirectory: URL
    ) throws {
        let directoryDescriptor = try openVirtualMachineDirectory(
            name: name,
            in: storageDirectory
        )
        defer { close(directoryDescriptor) }
        let descriptor = try openRequired(
            name: name,
            fileName: fileName,
            directoryDescriptor: directoryDescriptor
        )
        defer { close(descriptor) }

        do {
            let actualData = try readStableData(
                descriptor,
                name: name,
                maximumBytes: maximumBytes
            )
            guard actualData == expectedData else {
                throw SandboxAuthorityFileSystemError.unsafePath
            }
            let openedMetadata =
                try SandboxAuthorityFileSystem.fileMetadata(descriptor)
            var pathMetadata = stat()
            guard fstatat(
                directoryDescriptor,
                fileName,
                &pathMetadata,
                AT_SYMLINK_NOFOLLOW
            ) == 0,
                SandboxAuthorityFileSystem.sameIdentity(
                    openedMetadata,
                    pathMetadata
                )
            else {
                throw SandboxAuthorityFileSystemError.unsafePath
            }
            guard unlinkat(directoryDescriptor, fileName, 0) == 0 else {
                throw SandboxAuthorityFileSystemError.io(errno)
            }
            try requireExactPrivateFile(
                descriptor,
                maximumBytes: maximumBytes,
                expectedLinkCount: 0
            )
            try SandboxAuthorityFileSystem.synchronize(directoryDescriptor)
        } catch {
            throw failure(name, "could not durably clear start intent")
        }
    }

    private static func readStableData(
        _ descriptor: Int32,
        name: String,
        maximumBytes: Int
    ) throws -> Data {
        do {
            try requireExactPrivateFile(
                descriptor,
                maximumBytes: maximumBytes
            )
            let data = try SandboxAuthorityFileSystem.readStablePrivateFile(
                descriptor,
                maximumBytes: maximumBytes
            )
            try requireExactPrivateFile(
                descriptor,
                maximumBytes: maximumBytes
            )
            return data
        } catch {
            throw failure(
                name,
                "start intent failed ownership, mode, ACL, link, size, or stability checks"
            )
        }
    }

    private static func requireExactPrivateFile(
        _ descriptor: Int32,
        maximumBytes: Int,
        expectedLinkCount: nlink_t = 1
    ) throws {
        let metadata =
            try SandboxAuthorityFileSystem.requirePrivateRegularFile(
                descriptor,
                maximumBytes: maximumBytes,
                allowEmpty: false,
                expectedLinkCount: expectedLinkCount
            )
        guard metadata.st_mode & 0o777 == mode_t(0o600) else {
            throw SandboxAuthorityFileSystemError.unsafePath
        }
    }

    private static func openRequired(
        name: String,
        fileName: String,
        directoryDescriptor: Int32
    ) throws -> Int32 {
        let descriptor = openat(
            directoryDescriptor,
            fileName,
            O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw failure(name, "start intent is unavailable")
        }
        return descriptor
    }

    private static func openVirtualMachineDirectory(
        name: String,
        in storageDirectory: URL
    ) throws -> Int32 {
        guard SandboxVirtualMachineNamePolicy.isValid(name) else {
            throw SandboxRuntimeError.invalidName
        }
        let storageDescriptor: Int32
        do {
            storageDescriptor =
                try SandboxAuthorityFileSystem.openExistingDirectory(
                    at: storageDirectory
                )
            try SandboxAuthorityFileSystem.requirePrivateDirectory(
                storageDescriptor
            )
        } catch {
            throw failure(name, "VM storage directory is unsafe")
        }
        defer { close(storageDescriptor) }

        let descriptor = openat(
            storageDescriptor,
            name,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw failure(name, "VM directory is unavailable")
        }
        do {
            try SandboxAuthorityFileSystem.requirePrivateDirectory(descriptor)
            return descriptor
        } catch {
            close(descriptor)
            throw failure(name, "VM directory is unsafe")
        }
    }

    private static func failure(
        _ name: String,
        _ detail: String
    ) -> SandboxRuntimeError {
        .unsupported("VM \(name) \(detail)")
    }
}
