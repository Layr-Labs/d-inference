import Darwin
import Foundation
import SandboxRuntime

/// Ordinary broker operations never interpret or remove this root-owned fence.
/// Any entry blocks use, including malformed files and dangling links. Recovery
/// belongs to the separately authorized root maintenance workflow.
package enum LumeOfflineOperationFence {
    package static let fileName = ".darkbloom-offline.json"

    static func requireAbsent(storage: URL, name: String) throws {
        guard SandboxVirtualMachineNamePolicy.isValid(name) else { throw SandboxRuntimeError.invalidName }
        let parent = try SandboxAuthorityFileSystem.openPrivateDirectory(at: storage, createIfMissing: false)
        defer { close(parent) }
        let directory = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if directory < 0, errno == ENOENT { return }
        guard directory >= 0 else { throw unavailable(name) }
        defer { close(directory) }
        try SandboxAuthorityFileSystem.requirePrivateDirectory(directory)
        try requireAbsent(directory: directory, name: name)
    }

    static func requireAbsent(directory: Int32, name: String) throws {
        var info = stat()
        if fstatat(directory, fileName, &info, AT_SYMLINK_NOFOLLOW) == 0 { throw unavailable(name) }
        guard errno == ENOENT else { throw unavailable(name) }
    }

    private static func unavailable(_ name: String) -> SandboxRuntimeError {
        .unsupported("VM \(name) is fenced for pending offline maintenance")
    }
}
