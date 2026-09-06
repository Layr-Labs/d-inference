import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Transaction artifacts are evidence of an interrupted publication, never a
/// source of authentication tokens. Call while holding the credential lock.
enum ProviderCredentialRecoveryArtifacts {
    static func hasTokenBackup(canonicalPath: URL) throws -> Bool {
        try candidates(for: canonicalPath).contains {
            transactionID($0.lastPathComponent, base: canonicalPath.lastPathComponent, suffix: "original") != nil
        }
    }

    /// Capture identity, permissions and timestamps without reading secret file
    /// contents. Include every generation: another interruption during recovery
    /// may leave metadata backups with a different UUID from the token backup.
    static func capture(credentialPaths: [URL]) throws -> [Snapshot] {
        var snapshots: [Snapshot] = []
        for path in Set(credentialPaths) {
            let entries: [URL]
            do {
                entries = try candidates(for: path)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                // Custom metadata paths may have no directory yet. The token
                // directory is inspected separately by the fail-closed guard.
                continue
            }
            for candidate in entries {
                guard ["original", "pending"].contains(where: {
                    transactionID(candidate.lastPathComponent, base: path.lastPathComponent, suffix: $0) != nil
                }) else { continue }
                guard let snapshot = try Snapshot(path: candidate) else {
                    throw ProviderCredentialStoreError.credentialChanged
                }
                snapshots.append(snapshot)
            }
        }
        return snapshots.sorted { $0.path.path < $1.path.path }
    }

    private static func candidates(for path: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: path.deletingLastPathComponent(), includingPropertiesForKeys: nil
        )
    }

    private static func transactionID(_ name: String, base: String, suffix: String) -> UUID? {
        let prefix = base + "."
        let ending = "." + suffix
        guard name.hasPrefix(prefix), name.hasSuffix(ending) else { return nil }
        let id = String(name.dropFirst(prefix.count).dropLast(ending.count))
        guard id.count == 36 else { return nil }
        return UUID(uuidString: id)
    }

    struct Snapshot: Sendable, Equatable {
        let path: URL
        private let device: Int64
        private let inode: UInt64
        private let mode: UInt32
        private let size: Int64
        private let modifiedSeconds: Int
        private let modifiedNanoseconds: Int
        private let changedSeconds: Int
        private let changedNanoseconds: Int

        init?(path: URL) throws {
            var info = stat()
            guard lstat(path.path, &info) == 0 else {
                if errno == ENOENT { return nil }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            // Never follow a symlink or recursively delete a matching directory.
            guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
                throw ProviderCredentialStoreError.credentialRecoveryRequired
            }
            self.path = path
            device = Int64(info.st_dev)
            inode = UInt64(info.st_ino)
            mode = UInt32(info.st_mode)
            size = Int64(info.st_size)
            #if canImport(Darwin)
            modifiedSeconds = info.st_mtimespec.tv_sec
            modifiedNanoseconds = info.st_mtimespec.tv_nsec
            changedSeconds = info.st_ctimespec.tv_sec
            changedNanoseconds = info.st_ctimespec.tv_nsec
            #else
            modifiedSeconds = info.st_mtim.tv_sec
            modifiedNanoseconds = info.st_mtim.tv_nsec
            changedSeconds = info.st_ctim.tv_sec
            changedNanoseconds = info.st_ctim.tv_nsec
            #endif
        }

        /// Best effort only after a fresh credential has committed. A changed
        /// artifact belongs to someone else; leave it rather than deleting it.
        func removeIfUnchanged() {
            guard let current = try? Self(path: path), current == self else { return }
            try? FileManager.default.removeItem(at: path)
        }
    }
}
