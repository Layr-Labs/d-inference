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
        try workspace.prepare()
        let lockURL = workspace.locksDirectory.appendingPathComponent(
            "\(name).lock",
            isDirectory: false
        )
        let descriptor = open(
            lockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
        guard descriptor >= 0 else {
            throw SandboxRuntimeError.unsupported(
                "failed to open VM operation lock for \(name)"
            )
        }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_mode & 0o077 == 0
        else {
            close(descriptor)
            throw SandboxRuntimeError.unsupported(
                "VM operation lock failed ownership or mode checks"
            )
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            if errno == EWOULDBLOCK {
                throw SandboxRuntimeError.operationInProgress(
                    name: name,
                    operation: operation
                )
            }
            throw SandboxRuntimeError.unsupported(
                "failed to acquire VM operation lock for \(name)"
            )
        }
        self.descriptor = descriptor
    }

    deinit {
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
