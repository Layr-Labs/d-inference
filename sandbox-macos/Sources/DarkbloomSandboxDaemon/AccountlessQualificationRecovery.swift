import Darwin
import Foundation
import SandboxRuntime

enum AccountlessQualificationRecovery {
    static func requireSeparateJournal(_ directory: URL, storage: URL, capacity: URL, release: URL? = nil) throws {
        guard let parent = SandboxAuthorityFileSystem.canonicalPath(for: directory.deletingLastPathComponent()),
              !directory.lastPathComponent.isEmpty else { throw AccountlessInstallationError.invalidBinding }
        let resolved = SandboxAuthorityFileSystem.canonicalPath(for: directory)
            ?? URL(fileURLWithPath: parent).appendingPathComponent(directory.lastPathComponent).path
        for protected in [storage, capacity] {
            guard let path = SandboxAuthorityFileSystem.canonicalPath(for: protected),
                  resolved != path, !resolved.hasPrefix(path + "/"), !path.hasPrefix(resolved + "/") else {
                throw AccountlessInstallationError.invalidBinding
            }
        }
        if let release {
            let path = SandboxAuthorityFileSystem.canonicalPath(for: release) ?? release.standardizedFileURL.path
            guard resolved != path, !resolved.hasPrefix(path + "/"), !path.hasPrefix(resolved + "/") else {
                throw AccountlessInstallationError.invalidBinding
            }
        }
    }

    /// Resolve the allocation gap without allocating again or adopting a name.
    /// Expiry fencing may advance the token while preserving the original lease.
    static func activeLease(intent: AccountlessQualificationIntent, saved: SandboxCapacityLease?,
        leases: [SandboxCapacityLease]) throws -> SandboxCapacityLease? {
        if let saved { try intent.validateLease(saved) }
        let matches = leases.filter { $0.scope.sandboxID == intent.sandboxID || $0.virtualMachineName == intent.cloneName }
        guard matches.count <= 1 else { throw AccountlessInstallationError.invalidBinding }
        guard let current = matches.first else { return nil }
        try intent.validateLease(current)
        if let saved {
            guard current.scope.fencingToken >= saved.scope.fencingToken, current.issuedAt == saved.issuedAt else {
                throw AccountlessInstallationError.invalidBinding
            }
        }
        return current
    }

    static func requireAbsent(name: String, storage: URL) throws {
        let directory = try SandboxAuthorityFileSystem.openPrivateDirectory(at: storage, createIfMissing: false)
        defer { close(directory) }
        var info = stat()
        guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else {
            throw AccountlessInstallationError.invalidBinding
        }
    }
}
