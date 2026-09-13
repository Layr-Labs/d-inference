import CryptoKit
import Darwin
import Foundation
import SandboxRuntime
import Security

/// Host-only secret material. Never include this value in logs or wire descriptions.
public struct LumeGuestMaterials: Sendable {
    public let instanceID: UUID
    public let controlDisk: URL
    public let workspaceDisk: URL
    public let workspaceBytes: UInt64
    public let credential: Data
}

/// Invokes only the scripts covered by a verified sandbox release manifest.
public struct LumeGuestMaterialConfiguration: Sendable {
    public let releaseDirectory: URL
    public let developmentAdHoc: Bool
    private static let directoryName = ".darkbloom-guest"
    private static let controlBytes: UInt64 = 128 * 1_024 * 1_024
    private static let tools = [
        "prepare-sandbox-instance.py", "materialize-sandbox-instance.py",
        "sandbox_release_support.py",
    ]

    public init(releaseDirectory: URL, developmentAdHoc: Bool = false) throws {
        guard releaseDirectory.isFileURL, releaseDirectory.baseURL == nil,
              releaseDirectory.path.hasPrefix("/"),
              releaseDirectory.standardizedFileURL.path == releaseDirectory.path
        else { throw Self.failure("release path must be absolute and normalized") }
        self.releaseDirectory = releaseDirectory
        self.developmentAdHoc = developmentAdHoc
    }

    public func validate() throws {
        try validateRelease()
    }

    public func prepare(
        in ownedVMDirectory: URL,
        instanceID: UUID,
        workspaceBytes: UInt64,
        runner: SandboxProcessRunner
    ) async throws -> LumeGuestMaterials {
        try Self.validateWorkspaceBytes(workspaceBytes)
        let owner = try SandboxAuthorityFileSystem.openPrivateDirectory(
            at: ownedVMDirectory, createIfMissing: false
        )
        defer { close(owner) }
        let before = try SandboxAuthorityFileSystem.fileMetadata(owner)
        var metadata = stat()
        if fstatat(owner, Self.directoryName, &metadata, AT_SYMLINK_NOFOLLOW) == 0 {
            return try load(in: ownedVMDirectory, instanceID: instanceID, workspaceBytes: workspaceBytes)
        }
        guard errno == ENOENT else { throw Self.failure("cannot inspect existing materials") }
        try validateRelease()
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: [
                "-E", "-s", "-B",
                releaseDirectory.appendingPathComponent("tools/prepare-sandbox-instance.py").path,
                "--output", ownedVMDirectory.appendingPathComponent(Self.directoryName).path,
                "--instance-id", instanceID.uuidString.lowercased(),
                "--workspace-gib", String(workspaceBytes / (1_024 * 1_024 * 1_024)),
            ],
            environment: ["PYTHONDONTWRITEBYTECODE": "1"],
            currentDirectory: releaseDirectory,
            timeoutSeconds: 900,
            maximumOutputBytes: 16 * 1_024
        )
        guard result.exitCode == 0 else {
            throw Self.failure("material preparation failed; incomplete materials remain reserved")
        }
        try validateRelease()
        let current = try SandboxAuthorityFileSystem.openPrivateDirectory(
            at: ownedVMDirectory, createIfMissing: false
        )
        defer { close(current) }
        guard SandboxAuthorityFileSystem.sameIdentity(
            before, try SandboxAuthorityFileSystem.fileMetadata(current)
        ) else { throw Self.failure("owned VM directory changed during preparation") }
        return try load(in: ownedVMDirectory, instanceID: instanceID, workspaceBytes: workspaceBytes)
    }

    public func load(
        in ownedVMDirectory: URL,
        instanceID: UUID,
        workspaceBytes: UInt64
    ) throws -> LumeGuestMaterials {
        try Self.validateWorkspaceBytes(workspaceBytes)
        let owner = try SandboxAuthorityFileSystem.openPrivateDirectory(
            at: ownedVMDirectory, createIfMissing: false
        )
        defer { close(owner) }
        let directory = try SandboxAuthorityFileSystem.openPrivateChildDirectory(
            parentDescriptor: owner, name: Self.directoryName, createIfMissing: false
        )
        defer { close(directory) }
        let root = ownedVMDirectory.appendingPathComponent(Self.directoryName)
        let manifest: MaterialManifest = try Self.decodePrivate(
            "material-manifest.json", in: directory
        )
        let broker: Broker = try Self.decodePrivate("broker.json", in: directory)
        let control = root.appendingPathComponent("control.cdr")
        let workspace = root.appendingPathComponent("workspace.cdr")
        guard manifest.schemaVersion == 1, manifest.instanceID == instanceID,
              manifest.controlPath == control.path, manifest.controlBytes == Self.controlBytes,
              manifest.workspacePath == workspace.path, manifest.workspaceDiskBytes == workspaceBytes,
              manifest.images.count == 2,
              let controlImage = manifest.images.first(where: { $0.role == "control" }),
              let workspaceImage = manifest.images.first(where: { $0.role == "workspace" }),
              controlImage.path == control.path, controlImage.bytes == Self.controlBytes,
              controlImage.readOnly, Self.isDigest(controlImage.sha256),
              workspaceImage.path == workspace.path, workspaceImage.bytes == workspaceBytes,
              !workspaceImage.readOnly, Self.isDigest(workspaceImage.sha256),
              broker.version == 1, broker.instanceID == instanceID,
              let credential = Data(base64Encoded: broker.credential), credential.count == 32
        else { throw Self.failure("material identity, paths or resource commitment do not match") }
        let controlFD = try Self.openPrivate("control.cdr", in: directory)
        defer { close(controlFD) }
        let controlStat = try SandboxAuthorityFileSystem.requirePrivateRegularFile(controlFD)
        guard controlStat.st_mode & 0o777 == 0o400,
              controlStat.st_size == off_t(Self.controlBytes),
              try Self.digest(controlFD) == controlImage.sha256
        else { throw Self.failure("control image changed or is not read-only") }
        let workspaceFD = try Self.openPrivate("workspace.cdr", in: directory)
        defer { close(workspaceFD) }
        let workspaceStat = try SandboxAuthorityFileSystem.requirePrivateRegularFile(workspaceFD)
        guard workspaceStat.st_mode & 0o777 == 0o600,
              workspaceStat.st_size == off_t(workspaceBytes)
        else { throw Self.failure("workspace image capacity or permissions changed") }
        // Workspaces are mutable by design. Their original hash cannot validate restart state.
        try Self.requireNamedIdentity(controlFD, name: "control.cdr", parent: directory)
        try Self.requireNamedIdentity(workspaceFD, name: "workspace.cdr", parent: directory)
        try Self.requireNamedIdentity(directory, name: Self.directoryName, parent: owner)
        return LumeGuestMaterials(instanceID: instanceID, controlDisk: control,
                                  workspaceDisk: workspace, workspaceBytes: workspaceBytes,
                                  credential: credential)
    }

    package func validateRelease() throws {
        _ = try validatedReleaseFiles()
    }

    /// Read the signed manifest through the same descriptor whose ownership,
    /// stable contents and named identity are validated for runtime tooling.
    package func validatedReleaseFiles() throws -> [String: String] {
        let root = try SandboxAuthorityFileSystem.openExistingDirectory(at: releaseDirectory)
        defer { close(root) }
        try requireReleaseMetadata(root, directory: true)
        if !developmentAdHoc {
            var ancestor = releaseDirectory.deletingLastPathComponent()
            while true {
                let descriptor = try SandboxAuthorityFileSystem.openExistingDirectory(at: ancestor)
                defer { close(descriptor) }
                try requireReleaseMetadata(descriptor, directory: true)
                if ancestor.path == "/" { break }
                ancestor.deleteLastPathComponent()
            }
        }
        let manifestFD = try Self.openFile("release-manifest.json", in: root)
        defer { close(manifestFD) }
        try requireReleaseMetadata(manifestFD, directory: false)
        let signedIdentity = try SandboxAuthorityFileSystem.fileMetadata(manifestFD)
        try Self.requireNamedIdentity(manifestFD, name: "release-manifest.json", parent: root)
        try validateManifestSignature()
        let data = try readReleaseFile(manifestFD)
        let manifest = try JSONDecoder().decode(ReleaseManifest.self, from: data)
        guard manifest.schemaVersion == 1 else { throw Self.failure("unsupported release manifest") }
        let toolsFD = openat(root, "tools", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard toolsFD >= 0 else { throw Self.failure("release tools directory missing") }
        defer { close(toolsFD) }
        try requireReleaseMetadata(toolsFD, directory: true)
        let names = try FileManager.default.contentsOfDirectory(
            atPath: releaseDirectory.appendingPathComponent("tools").path
        )
        guard Set(names) == Set(Self.tools) else {
            throw Self.failure("release tools contain unexpected importable entries")
        }
        for name in Self.tools {
            let descriptor = try Self.openFile(name, in: toolsFD)
            defer { close(descriptor) }
            try requireReleaseMetadata(descriptor, directory: false)
            guard let expected = manifest.files["tools/" + name], Self.isDigest(expected),
                  try Self.digest(descriptor) == expected
            else { throw Self.failure("release tool differs from signed manifest") }
            try Self.requireNamedIdentity(descriptor, name: name, parent: toolsFD)
        }
        try Self.requireNamedIdentity(manifestFD, name: "release-manifest.json", parent: root)
        try Self.requireNamedIdentity(toolsFD, name: "tools", parent: root)
        guard SandboxAuthorityFileSystem.stableIdentity(signedIdentity,
                try SandboxAuthorityFileSystem.fileMetadata(manifestFD)),
              try readReleaseFile(manifestFD) == data else {
            throw Self.failure("release manifest changed during signature validation")
        }
        return manifest.files
    }

    private func validateManifestSignature() throws {
        let identifier = "io.darkbloom.sandbox.release-manifest"
        let requirementText = developmentAdHoc ? "identifier \"\(identifier)\""
            : "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"SLDQ2GJ6TL\""
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(
            releaseDirectory.appendingPathComponent("release-manifest.json") as CFURL,
            SecCSFlags(), &code
        ) == errSecSuccess, let code,
              SecRequirementCreateWithString(requirementText as CFString, SecCSFlags(), &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess
        else { throw Self.failure("sandbox release manifest signature is invalid") }
    }

    private func requireReleaseMetadata(_ descriptor: Int32, directory: Bool) throws {
        let metadata = try SandboxAuthorityFileSystem.fileMetadata(descriptor)
        guard metadata.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG),
              metadata.st_uid == 0 || (developmentAdHoc && metadata.st_uid == geteuid()),
              metadata.st_mode & 0o022 == 0,
              directory || metadata.st_nlink == 1
        else { throw Self.failure("release files must be protected from broker or shared writes") }
        try SandboxAuthorityFileSystem.requireNoExtendedACL(descriptor)
    }

    private func readReleaseFile(_ descriptor: Int32) throws -> Data {
        let before = try SandboxAuthorityFileSystem.fileMetadata(descriptor)
        guard before.st_size > 0, before.st_size <= 1_048_576 else {
            throw Self.failure("release manifest is oversized")
        }
        var bytes = Data(count: Int(before.st_size))
        let count = bytes.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, $0.count, 0) }
        guard count == bytes.count,
              SandboxAuthorityFileSystem.stableIdentity(before, try SandboxAuthorityFileSystem.fileMetadata(descriptor))
        else { throw Self.failure("release manifest changed while reading") }
        return bytes
    }

    private static func decodePrivate<T: Decodable>(_ name: String, in directory: Int32) throws -> T {
        let descriptor = try openPrivate(name, in: directory)
        defer { close(descriptor) }
        let data = try SandboxAuthorityFileSystem.readStablePrivateFile(descriptor, maximumBytes: 16 * 1_024)
        try requireNamedIdentity(descriptor, name: name, parent: directory)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func openFile(_ name: String, in directory: Int32) throws -> Int32 {
        let descriptor = openat(directory, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw failure("required material file is unavailable") }
        return descriptor
    }

    private static func openPrivate(_ name: String, in directory: Int32) throws -> Int32 {
        let descriptor = try openFile(name, in: directory)
        do {
            _ = try SandboxAuthorityFileSystem.requirePrivateRegularFile(descriptor)
            return descriptor
        } catch { close(descriptor); throw error }
    }

    private static func requireNamedIdentity(_ descriptor: Int32, name: String, parent: Int32) throws {
        var named = stat()
        guard fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              SandboxAuthorityFileSystem.sameIdentity(named, try SandboxAuthorityFileSystem.fileMetadata(descriptor))
        else { throw failure("material authority changed while reading") }
    }

    private static func digest(_ descriptor: Int32) throws -> String {
        let before = try SandboxAuthorityFileSystem.fileMetadata(descriptor)
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        var offset: off_t = 0
        while offset < before.st_size {
            let count = pread(descriptor, &buffer, min(buffer.count, Int(before.st_size - offset)), offset)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw failure("failed to read complete material") }
            hasher.update(data: buffer.prefix(count))
            offset += off_t(count)
        }
        guard SandboxAuthorityFileSystem.stableIdentity(before, try SandboxAuthorityFileSystem.fileMetadata(descriptor)) else {
            throw failure("material changed while hashing")
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func validateWorkspaceBytes(_ bytes: UInt64) throws {
        guard [UInt64(25), 50].map({ $0 * 1_024 * 1_024 * 1_024 }).contains(bytes) else {
            throw failure("unsupported workspace disk capacity")
        }
    }

    private static func failure(_ text: String) -> SandboxRuntimeError { .unsupported(text) }
}

private struct ReleaseManifest: Decodable {
    let schemaVersion: UInt16
    let files: [String: String]
    enum CodingKeys: String, CodingKey { case schemaVersion = "schema_version", files }
}

private struct Broker: Decodable {
    let version: UInt16
    let instanceID: UUID
    let credential: String
}

private struct MaterialManifest: Decodable {
    let schemaVersion: UInt16
    let instanceID: UUID
    let controlPath: String
    let controlBytes: UInt64
    let workspacePath: String
    let workspaceDiskBytes: UInt64
    let images: [Image]
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", instanceID, controlPath, controlBytes
        case workspacePath, workspaceDiskBytes, images
    }
    struct Image: Decodable {
        let role: String
        let path: String
        let bytes: UInt64
        let sha256: String
        let readOnly: Bool
        enum CodingKeys: String, CodingKey { case role, path, bytes, sha256, readOnly = "read_only" }
    }
}
