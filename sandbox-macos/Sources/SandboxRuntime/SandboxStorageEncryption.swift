import CoreFoundation
import Darwin
import Foundation

/// The initial persistent VM product requires an encrypted APFS backing volume.
/// This is host-volume at-rest protection, not per-VM cryptographic erasure or
/// confidentiality from the running host administrator.
public enum SandboxStorageEncryption {
    public static func requireEncryptedAPFS(at directory: URL,
                                            runner: SandboxProcessRunner = SandboxProcessRunner()) async throws {
        let descriptor = try SandboxAuthorityFileSystem.openPrivateDirectory(
            at: directory, createIfMissing: false)
        defer { close(descriptor) }
        let before = try SandboxAuthorityFileSystem.fileMetadata(descriptor)
        var filesystem = statfs()
        guard fstatfs(descriptor, &filesystem) == 0 else { throw SandboxRuntimeError.unsupported("storage filesystem is unavailable") }
        let type = withUnsafeBytes(of: filesystem.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let mount = withUnsafeBytes(of: filesystem.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        guard type == "apfs", mount.hasPrefix("/") else {
            throw SandboxRuntimeError.unsupported("persistent sandboxes require encrypted APFS storage")
        }
        let result = try await runner.run(executable: URL(fileURLWithPath: "/usr/sbin/diskutil"),
            arguments: ["info", "-plist", mount], timeoutSeconds: 15, maximumOutputBytes: 512 * 1024)
        guard result.exitCode == 0, !result.standardOutputTruncated,
              try isEncryptedAPFS(result.standardOutput, expectedMount: mount) else {
            throw SandboxRuntimeError.unsupported("storage encryption could not be verified")
        }
        let current = try SandboxAuthorityFileSystem.openPrivateDirectory(at: directory, createIfMissing: false)
        defer { close(current) }
        guard SandboxAuthorityFileSystem.sameIdentity(before, try SandboxAuthorityFileSystem.fileMetadata(current)) else {
            throw SandboxRuntimeError.unsupported("storage changed during encryption verification")
        }
    }

    package static func isEncryptedAPFS(_ data: Data, expectedMount: String) throws -> Bool {
        guard let value = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              value["FilesystemType"] as? String == "apfs",
              value["MountPoint"] as? String == expectedMount,
              let encrypted = value["FileVault"] as? NSNumber,
              CFGetTypeID(encrypted) == CFBooleanGetTypeID() else { return false }
        return encrypted.boolValue
    }
}
