import Darwin
import Foundation
import SandboxRuntime

/// No overwrite: exact existing bytes are a replay; any other entry conflicts.
/// The caller owns and holds the directory descriptor for the entire operation.
enum LumeCandidateEvidencePublication {
    static func requireMatchingOrAbsent(_ data: Data, name: String, directory: Int32) throws {
        try requireInput(data, name: name)
        let file = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if file < 0, errno == ENOENT { return }
        guard file >= 0 else { throw LumeInstalledCandidateStore.failure() }
        defer { close(file) }
        let existing = try SandboxAuthorityFileSystem.readStablePrivateFile(file, maximumBytes: 16 * 1024)
        var named = stat()
        guard existing == data, fstatat(directory, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              try SandboxAuthorityFileSystem.sameIdentity(SandboxAuthorityFileSystem.fileMetadata(file), named) else {
            throw LumeInstalledCandidateStore.failure()
        }
    }

    static func publish(_ data: Data, name: String, directory: Int32) throws {
        try requireInput(data, name: name)
        let file = try SandboxAuthorityFileSystem.createUnlinkedPrivateFile(parentDescriptor: directory, prefix: "installed-candidate")
        defer { close(file) }
        try SandboxAuthorityFileSystem.writeAll(data, to: file)
        try SandboxAuthorityFileSystem.synchronize(file)
        if fclonefileat(file, directory, name, 0) != 0, errno != EEXIST { throw LumeInstalledCandidateStore.failure() }
        try requireMatchingOrAbsent(data, name: name, directory: directory)
        let committed = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard committed >= 0 else { throw LumeInstalledCandidateStore.failure() }
        defer { close(committed) }
        try SandboxAuthorityFileSystem.synchronize(committed)
        try SandboxAuthorityFileSystem.synchronize(directory)
    }

    private static func requireInput(_ data: Data, name: String) throws {
        guard !data.isEmpty, data.count <= 16 * 1024,
              [LumeInstalledCandidateCheckpoint.installationFileName, LumeInstalledCandidateCheckpoint.cleanupFileName,
               LumeInstalledCandidateCheckpoint.fileName].contains(name) else { throw LumeInstalledCandidateStore.failure() }
    }
}
