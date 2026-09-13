import Darwin
import Foundation
import SandboxGuestProtocol
import SandboxRuntime

public enum GuestBootstrapInstallation {
    public static func disablePersistentSchedulers() async throws {
        try await GuestSchedulerPolicy.provision()
    }

    /// macOS synthesizes this empty root mountpoint at the next boot. No
    /// writable-root assumption or privileged mount is needed during install.
    public static func provisionWorkspaceMountpoint() throws {
        try GuestConfiguration.requireVirtualizedRoot()
        _ = try GuestConfiguration.signedExecutable()
        try GuestSyntheticMountpoint.provision(in: URL(fileURLWithPath: "/private/etc"), ownerUID: 0)
    }
}

enum GuestSyntheticMountpoint {
    private static let name = "io.darkbloom.sandbox"

    static func provision(in configurationDirectory: URL, ownerUID: uid_t) throws {
        let root = try SandboxAuthorityFileSystem.openExistingDirectory(at: configurationDirectory)
        defer { close(root) }
        try requireDirectory(root, ownerUID: ownerUID)
        var manifests: [String: Data] = [:]
        if let main = try readManifest("synthetic.conf", parent: root, ownerUID: ownerUID) {
            manifests["synthetic.conf"] = main
        }
        var directory = openat(root, "synthetic.d", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if directory < 0 {
            guard errno == ENOENT, mkdirat(root, "synthetic.d", 0o755) == 0 else {
                throw GuestProtocolError.invalidConfiguration
            }
            directory = openat(root, "synthetic.d", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard directory >= 0 else { throw GuestProtocolError.invalidConfiguration }
        defer { close(directory) }
        try requireDirectory(directory, ownerUID: ownerUID)
        let entries = try FileManager.default.contentsOfDirectory(
            atPath: configurationDirectory.appendingPathComponent("synthetic.d").path)
        guard entries.count <= 64 else { throw GuestProtocolError.invalidConfiguration }
        for entry in entries {
            guard !entry.contains("/"), !entry.contains("\0"),
                  let data = try readManifest(entry, parent: directory, ownerUID: ownerUID)
            else { throw GuestProtocolError.invalidConfiguration }
            manifests["synthetic.d/" + entry] = data
        }
        guard try requiresWorkspaceEntry(manifests) else { return }
        guard !entries.contains(name) else { throw GuestProtocolError.invalidConfiguration }
        let temporaryName = ".darkbloom-synthetic-\(UUID().uuidString)"
        let temporary = openat(directory, temporaryName, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard temporary >= 0 else { throw GuestProtocolError.invalidConfiguration }
        defer { close(temporary) }
        var published = false
        defer {
            if !published { _ = unlinkat(directory, temporaryName, 0) }
        }
        try SandboxAuthorityFileSystem.writeAll(Data("workspace\n".utf8), to: temporary)
        guard fchmod(temporary, 0o644) == 0 else { throw GuestProtocolError.invalidConfiguration }
        try SandboxAuthorityFileSystem.synchronize(temporary)
        guard renameatx_np(directory, temporaryName, directory, name, UInt32(RENAME_EXCL)) == 0 else {
            throw GuestProtocolError.invalidConfiguration
        }
        published = true
        try SandboxAuthorityFileSystem.synchronize(directory)
        try SandboxAuthorityFileSystem.synchronize(root)
    }

    static func requiresWorkspaceEntry(_ manifests: [String: Data]) throws -> Bool {
        var count = 0
        for data in manifests.values {
            guard let text = String(data: data, encoding: .utf8) else { throw GuestProtocolError.invalidConfiguration }
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                guard !line.hasPrefix("#") else { continue }
                let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
                if columns.first == "workspace" {
                    guard columns.count == 1, line == "workspace" else { throw GuestProtocolError.invalidConfiguration }
                    count += 1
                }
            }
        }
        guard count <= 1 else { throw GuestProtocolError.invalidConfiguration }
        return count == 0
    }

    private static func readManifest(_ name: String, parent: Int32, ownerUID: uid_t) throws -> Data? {
        let descriptor = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if descriptor < 0, errno == ENOENT { return nil }
        guard descriptor >= 0 else { throw GuestProtocolError.invalidConfiguration }
        defer { close(descriptor) }
        let before = try SandboxAuthorityFileSystem.fileMetadata(descriptor)
        guard before.st_mode & S_IFMT == S_IFREG, before.st_uid == ownerUID,
              before.st_mode & 0o022 == 0, before.st_nlink == 1,
              before.st_size >= 0, before.st_size <= 65536 else { throw GuestProtocolError.invalidConfiguration }
        try SandboxAuthorityFileSystem.requireNoExtendedACL(descriptor)
        let data = try GuestDescriptor.read(descriptor, count: Int(before.st_size))
        guard SandboxAuthorityFileSystem.stableIdentity(before, try SandboxAuthorityFileSystem.fileMetadata(descriptor)) else {
            throw GuestProtocolError.invalidConfiguration
        }
        return data
    }

    private static func requireDirectory(_ descriptor: Int32, ownerUID: uid_t) throws {
        let metadata = try SandboxAuthorityFileSystem.fileMetadata(descriptor)
        guard metadata.st_mode & S_IFMT == S_IFDIR, metadata.st_uid == ownerUID,
              metadata.st_mode & 0o022 == 0 else { throw GuestProtocolError.invalidConfiguration }
        try SandboxAuthorityFileSystem.requireNoExtendedACL(descriptor)
    }
}
