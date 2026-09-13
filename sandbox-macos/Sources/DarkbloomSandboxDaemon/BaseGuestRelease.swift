import CryptoKit
import Darwin
import Foundation
import SandboxRuntime
import Security

enum BaseGuestPreparationError: Error {
    case invalidRelease, invalidReceipt, unsafeTemplate, staleTemplate
}

/// Only the four manifest-covered guest payloads enter the temporary read-only
/// share. Host applications, credentials, and release tooling stay outside it.
struct BaseGuestRelease: Sendable {
    static let files = ["darkbloom-sandbox-guest", "darkbloom-sandbox-bootstrap.sh",
                        "io.darkbloom.sandbox.guest.plist", "install-sandbox-guest.sh"]
    let directory: URL
    let manifestSHA256: String
    let hashes: [String: String]

    init(directory: URL,
         verifySignature: (URL, String) throws -> Void = Self.verifySignature) throws {
        let directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        let root = try SandboxAuthorityFileSystem.openExistingDirectory(at: directory)
        defer { close(root) }
        try Self.requireSafeReleaseEntry(root, directory: true)
        let manifest = directory.appendingPathComponent("release-manifest.json")
        let manifestFD = openat(root, manifest.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard manifestFD >= 0 else { throw BaseGuestPreparationError.invalidRelease }
        defer { close(manifestFD) }
        try Self.requireSafeReleaseEntry(manifestFD, directory: false)
        let data = try Self.readBounded(manifestFD, maximumBytes: 1_048_576)
        try verifySignature(manifest, "io.darkbloom.sandbox.release-manifest")
        let value = try JSONDecoder().decode(Manifest.self, from: data)
        guard value.schemaVersion == 1, value.signingMode == "developer_id" else {
            throw BaseGuestPreparationError.invalidRelease
        }
        let guest = directory.appendingPathComponent("guest", isDirectory: true)
        let guestFD = openat(root, "guest", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard guestFD >= 0 else { throw BaseGuestPreparationError.invalidRelease }
        defer { close(guestFD) }
        try Self.requireSafeReleaseEntry(guestFD, directory: true)
        guard Set(try FileManager.default.contentsOfDirectory(atPath: guest.path)) == Set(Self.files) else {
            throw BaseGuestPreparationError.invalidRelease
        }
        var hashes: [String: String] = [:]
        for name in Self.files {
            guard let expected = value.files["guest/" + name], Self.isDigest(expected) else {
                throw BaseGuestPreparationError.invalidRelease
            }
            let fd = openat(guestFD, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw BaseGuestPreparationError.invalidRelease }
            defer { close(fd) }
            try Self.requireSafeReleaseEntry(fd, directory: false)
            guard try Self.copyAndHash(fd, to: nil) == expected else { throw BaseGuestPreparationError.invalidRelease }
            hashes[name] = expected
        }
        try verifySignature(guest.appendingPathComponent("darkbloom-sandbox-guest"), "io.darkbloom.sandbox.guest")
        guard try Self.readBounded(manifestFD, maximumBytes: 1_048_576) == data else {
            throw BaseGuestPreparationError.invalidRelease
        }
        self.directory = directory; self.hashes = hashes
        self.manifestSHA256 = Self.digest(data)
    }

    func stage(in storage: URL) throws -> BaseGuestStaging {
        let root = try SandboxAuthorityFileSystem.openPrivateDirectory(at: storage, createIfMissing: true)
        defer { close(root) }
        let support = try SandboxAuthorityFileSystem.openPrivateChildDirectory(parentDescriptor: root,
            name: ".darkbloom-runtime", createIfMissing: true)
        defer { close(support) }
        let name = "bootstrap-" + UUID().uuidString.lowercased()
        let folder = try SandboxAuthorityFileSystem.openPrivateChildDirectory(parentDescriptor: support,
            name: name, createIfMissing: true)
        defer { close(folder) }
        let destination = storage.standardizedFileURL.resolvingSymlinksInPath()
            .appendingPathComponent(".darkbloom-runtime", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        for filename in Self.files {
            let source = open(directory.appendingPathComponent("guest/" + filename).path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard source >= 0 else { throw BaseGuestPreparationError.invalidRelease }
            defer { close(source) }
            try Self.requireSafeReleaseEntry(source, directory: false)
            let target = openat(folder, filename, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard target >= 0 else { throw BaseGuestPreparationError.invalidRelease }
            defer { close(target) }
            guard try Self.copyAndHash(source, to: target) == hashes[filename],
                  fchmod(target, filename.hasSuffix(".plist") ? 0o400 : 0o500) == 0,
                  fsync(target) == 0 else { throw BaseGuestPreparationError.invalidRelease }
        }
        guard fsync(folder) == 0, fsync(support) == 0 else { throw BaseGuestPreparationError.invalidRelease }
        return BaseGuestStaging(directory: destination, hashes: hashes)
    }

    static func copyAndHash(_ source: Int32, to target: Int32?) throws -> String {
        var before = stat(), after = stat()
        guard fstat(source, &before) == 0, before.st_size >= 0, before.st_size <= 128 * 1_048_576 else {
            throw BaseGuestPreparationError.invalidRelease
        }
        var digest = SHA256(), offset: off_t = 0
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while offset < before.st_size {
            let count = pread(source, &buffer, min(buffer.count, Int(before.st_size - offset)), offset)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw BaseGuestPreparationError.invalidRelease }
            let data = Data(buffer.prefix(count))
            digest.update(data: data)
            if let target { try SandboxAuthorityFileSystem.writeAll(data, to: target) }
            offset += off_t(count)
        }
        guard fstat(source, &after) == 0, after.st_size == before.st_size,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
              after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec,
              after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec else {
            throw BaseGuestPreparationError.invalidRelease
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func requireSafeReleaseEntry(_ descriptor: Int32, directory: Bool) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG),
              info.st_uid == 0 || info.st_uid == geteuid(),
              info.st_mode & 0o022 == 0, directory || info.st_nlink == 1 else {
            throw BaseGuestPreparationError.invalidRelease
        }
        try SandboxAuthorityFileSystem.requireNoExtendedACL(descriptor)
    }
    private static func readBounded(_ descriptor: Int32, maximumBytes: Int) throws -> Data {
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_size > 0, info.st_size <= maximumBytes else {
            throw BaseGuestPreparationError.invalidRelease
        }
        var data = Data(count: Int(info.st_size))
        let count = data.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, $0.count, 0) }
        guard count == data.count else { throw BaseGuestPreparationError.invalidRelease }
        return data
    }
    private static func verifySignature(_ url: URL, identifier: String) throws {
        var code: SecStaticCode?, requirement: SecRequirement?
        let rule = "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"SLDQ2GJ6TL\""
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else {
            throw BaseGuestPreparationError.invalidRelease
        }
    }
    private struct Manifest: Decodable {
        let schemaVersion: Int
        let signingMode: String
        let files: [String: String]
        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version", signingMode = "signing_mode", files
        }
    }
}

struct BaseGuestStaging: Sendable {
    let directory: URL
    let hashes: [String: String]

    /// Called only after stopped-state proof; an unexpected staged entry leaves
    /// the folder intact for inspection instead of recursively deleting it.
    func removeAfterStopped() throws {
        let folder = try SandboxAuthorityFileSystem.openPrivateDirectory(at: directory, createIfMissing: false)
        defer { close(folder) }
        guard Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)) == Set(hashes.keys) else {
            throw BaseGuestPreparationError.invalidRelease
        }
        for (name, hash) in hashes {
            let source = openat(folder, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard source >= 0 else { throw BaseGuestPreparationError.invalidRelease }
            defer { close(source) }
            guard try BaseGuestRelease.copyAndHash(source, to: nil) == hash else { throw BaseGuestPreparationError.invalidRelease }
        }
        for name in hashes.keys {
            guard unlinkat(folder, name, 0) == 0 else { throw BaseGuestPreparationError.invalidRelease }
        }
        let parent = try SandboxAuthorityFileSystem.openPrivateDirectory(at: directory.deletingLastPathComponent(), createIfMissing: false)
        defer { close(parent) }
        guard unlinkat(parent, directory.lastPathComponent, AT_REMOVEDIR) == 0, fsync(parent) == 0 else {
            throw BaseGuestPreparationError.invalidRelease
        }
    }
}
