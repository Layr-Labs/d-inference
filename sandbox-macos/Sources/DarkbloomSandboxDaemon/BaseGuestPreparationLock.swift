import Darwin
import Foundation
import SandboxRuntime

/// Prevent two preparation commands from racing their root installer against
/// the same base. The persistent lock inode is never replaced or removed.
final class BaseGuestPreparationLock: @unchecked Sendable {
    private let descriptor: Int32

    init(directory: URL) throws {
        let folder = try SandboxAuthorityFileSystem.openPrivateDirectory(at: directory, createIfMissing: false)
        defer { close(folder) }
        let descriptor = openat(folder, ".darkbloom-template.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw BaseGuestPreparationError.unsafeTemplate }
        var valid = false
        defer { if !valid { close(descriptor) } }
        _ = try SandboxAuthorityFileSystem.requirePrivateRegularFile(descriptor)
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw SandboxRuntimeError.operationInProgress(name: directory.lastPathComponent, operation: "prepare-base")
        }
        self.descriptor = descriptor
        valid = true
    }

    deinit { close(descriptor) }
}
