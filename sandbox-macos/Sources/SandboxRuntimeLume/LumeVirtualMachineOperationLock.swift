import Darwin
import Foundation
import SandboxRuntime

final class LumeVirtualMachineOperationLock: @unchecked Sendable {
    private let descriptor: Int32

    init(
        workspace: LumeRuntimeWorkspace,
        name: String,
        operation: String
    ) throws {
        guard SandboxVirtualMachineNamePolicy.isValid(name) else {
            throw SandboxRuntimeError.invalidName
        }
        try workspace.prepare()
        let directoryDescriptor: Int32
        do {
            directoryDescriptor =
                try SandboxAuthorityFileSystem.openPrivateDirectory(
                    at: workspace.locksDirectory,
                    createIfMissing: false,
                    requirePrivateParent: true
                )
        } catch {
            throw Self.failure("VM operation lock directory is unsafe")
        }
        defer { close(directoryDescriptor) }
        let lockName = "\(name).lock"
        var created = false
        var descriptor = openat(
            directoryDescriptor,
            lockName,
            O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
        if descriptor >= 0 {
            created = true
        } else if errno == EEXIST {
            descriptor = openat(
                directoryDescriptor,
                lockName,
                O_RDWR | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard descriptor >= 0 else {
            throw SandboxRuntimeError.unsupported(
                "failed to open VM operation lock for \(name)"
            )
        }
        do {
            _ = try SandboxAuthorityFileSystem.requirePrivateRegularFile(
                descriptor
            )
        } catch {
            close(descriptor)
            throw SandboxRuntimeError.unsupported(
                "VM operation lock failed ownership or mode checks"
            )
        }
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            if errno == EINTR {
                continue
            }
            let code = errno
            close(descriptor)
            if code == EWOULDBLOCK || code == EAGAIN {
                throw SandboxRuntimeError.operationInProgress(
                    name: name,
                    operation: operation
                )
            }
            throw SandboxRuntimeError.unsupported(
                "failed to acquire VM operation lock for \(name)"
            )
        }
        do {
            if created {
                try SandboxAuthorityFileSystem.synchronize(descriptor)
                try SandboxAuthorityFileSystem.synchronize(
                    directoryDescriptor
                )
            }
            let locked = try SandboxAuthorityFileSystem.fileMetadata(descriptor)
            let rebound = openat(
                directoryDescriptor,
                lockName,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW
            )
            guard rebound >= 0 else {
                throw Self.failure("VM operation lock path disappeared")
            }
            defer { close(rebound) }
            _ = try SandboxAuthorityFileSystem.requirePrivateRegularFile(
                rebound
            )
            let reboundMetadata =
                try SandboxAuthorityFileSystem.fileMetadata(rebound)
            guard SandboxAuthorityFileSystem.sameIdentity(
                locked,
                reboundMetadata
            ) else {
                throw Self.failure("VM operation lock path was replaced")
            }
        } catch {
            _ = flock(descriptor, LOCK_UN)
            close(descriptor)
            throw Self.failure("VM operation lock binding is unsafe")
        }
        self.descriptor = descriptor
    }

    deinit {
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    private static func failure(_ detail: String) -> SandboxRuntimeError {
        .unsupported(detail)
    }
}
