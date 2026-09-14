import Darwin
import Foundation
import SandboxRuntime

/// Bounded copying and private output publication, separate from payload policy.
final class AccountlessInstallationPayloadFiles {
    private let root: URL
    private let descriptor: Int32
    private var written: [String: String] = [:]
    private var directories = Set<String>()

    init(destination: URL) throws {
        guard destination.isFileURL, destination.baseURL == nil,
              destination.standardizedFileURL.resolvingSymlinksInPath().path == destination.path else {
            throw AccountlessInstallationError.unsafeDestination
        }
        let parent = try SandboxAuthorityFileSystem.openPrivateDirectory(
            at: destination.deletingLastPathComponent(), createIfMissing: false)
        defer { close(parent) }
        guard mkdirat(parent, destination.lastPathComponent, 0o700) == 0 else {
            throw AccountlessInstallationError.unsafeDestination
        }
        descriptor = try SandboxAuthorityFileSystem.openPrivateChildDirectory(
            parentDescriptor: parent, name: destination.lastPathComponent, createIfMissing: false)
        root = destination
    }
    deinit { close(descriptor) }

    func createDirectory(_ relative: String) throws -> URL {
        var parent = dup(descriptor)
        guard parent >= 0 else { throw AccountlessInstallationError.unsafeDestination }
        defer { close(parent) }
        var path = ""
        for component in relative.split(separator: "/") {
            guard component != ".", component != ".." else { throw AccountlessInstallationError.unsafeDestination }
            let next = try SandboxAuthorityFileSystem.openPrivateChildDirectory(parentDescriptor: parent,
                name: String(component), createIfMissing: true)
            close(parent); parent = next
            path = path.isEmpty ? String(component) : path + "/" + String(component)
            directories.insert(path)
        }
        return root.appendingPathComponent(relative)
    }

    func copyRelease(_ release: BaseGuestRelease, to target: URL) async throws {
        // Every source was validated before output creation. ditto preserves the
        // manifest's signing xattrs; byte-stream copies alone do not do that.
        for relative in BaseGuestRelease.files.map({ "guest/" + $0 }) + ["release-manifest.json"] {
            try Task.checkCancellation()
            let source = release.directory.appendingPathComponent(relative), destination = target.appendingPathComponent(relative)
            guard !FileManager.default.fileExists(atPath: destination.path) else { throw AccountlessInstallationError.unsafeDestination }
            let result = try await SandboxProcessRunner().run(executable: URL(fileURLWithPath: "/usr/bin/ditto"),
                arguments: ["--rsrc", "--extattr", source.path, destination.path], timeoutSeconds: 30, maximumOutputBytes: 16 * 1024)
            guard result.exitCode == 0, !result.standardOutputTruncated, !result.standardErrorTruncated else {
                throw AccountlessInstallationError.copyFailed
            }
            let fd = open(destination.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw AccountlessInstallationError.copyFailed }
            defer { close(fd) }
            let mode: mode_t = relative == "guest/darkbloom-sandbox-guest" ? 0o500 : 0o400
            guard fchmod(fd, mode) == 0 else { throw AccountlessInstallationError.copyFailed }
            _ = try SandboxAuthorityFileSystem.requirePrivateRegularFile(fd, allowEmpty: false)
            let actual = try BaseGuestRelease.copyAndHash(fd, to: nil)
            let expected = relative == "release-manifest.json" ? release.manifestSHA256 : release.hashes[destination.lastPathComponent]
            guard actual == expected else { throw AccountlessInstallationError.releaseChanged }
            try SandboxAuthorityFileSystem.synchronize(fd)
            written[try relativePath(destination)] = actual
            try requireBoundRoot()
        }
    }

    func write(_ data: Data, to path: URL, mode: mode_t) throws {
        _ = try relativePath(path); try requireBoundRoot()
        let parent = try SandboxAuthorityFileSystem.openPrivateDirectory(at: path.deletingLastPathComponent(), createIfMissing: false)
        defer { close(parent) }
        let file = openat(parent, path.lastPathComponent, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw AccountlessInstallationError.unsafeDestination }
        defer { close(file) }
        try SandboxAuthorityFileSystem.writeAll(data, to: file)
        guard fchmod(file, mode) == 0 else { throw AccountlessInstallationError.unsafeDestination }
        try SandboxAuthorityFileSystem.synchronize(file)
        try SandboxAuthorityFileSystem.synchronize(parent)
        written[try relativePath(path)] = BaseGuestRelease.digest(data)
    }

    func inventory() throws -> [String: String] {
        try requireBoundRoot()
        try verifyInventory(directory: descriptor, prefix: "")
        var result: [String: String] = [:]
        for (relative, digest) in written {
            guard relative.hasPrefix("data-overlay/") else { throw AccountlessInstallationError.unsafeDestination }
            result[String(relative.dropFirst("data-overlay/".count))] = digest
        }
        return result
    }
    func synchronize() throws { try requireBoundRoot(); try SandboxAuthorityFileSystem.synchronize(descriptor) }

    private func verifyInventory(directory: Int32, prefix: String) throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(prefix).path)
        guard names.count <= 32 else { throw AccountlessInstallationError.unsafeDestination }
        for name in names {
            let relative = prefix.isEmpty ? name : prefix + "/" + name
            if directories.contains(relative) {
                let child = try SandboxAuthorityFileSystem.openPrivateChildDirectory(parentDescriptor: directory,
                    name: name, createIfMissing: false)
                defer { close(child) }
                try verifyInventory(directory: child, prefix: relative)
            } else {
                guard let expected = written[relative] else { throw AccountlessInstallationError.unsafeDestination }
                let file = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                guard file >= 0 else { throw AccountlessInstallationError.unsafeDestination }
                defer { close(file) }
                _ = try SandboxAuthorityFileSystem.requirePrivateRegularFile(file, allowEmpty: false)
                guard try BaseGuestRelease.copyAndHash(file, to: nil) == expected else { throw AccountlessInstallationError.releaseChanged }
            }
        }
        let expected = Set(directories.union(written.keys).filter {
            let parent = ($0 as NSString).deletingLastPathComponent
            return parent == prefix
        }.map { ($0 as NSString).lastPathComponent })
        guard Set(names) == expected else { throw AccountlessInstallationError.unsafeDestination }
    }

    private func relativePath(_ path: URL) throws -> String {
        guard path.isFileURL, path.baseURL == nil, !path.path.contains("\0"),
              path.path.hasPrefix(root.path + "/") else {
            throw AccountlessInstallationError.unsafeDestination
        }
        let relative = String(path.path.dropFirst(root.path.count + 1))
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        // Foundation shortens /private/tmp in standardizedFileURL. Validate
        // relative components against the already-bound root instead of
        // rejecting that legitimate system alias during publication.
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw AccountlessInstallationError.unsafeDestination
        }
        return relative
    }
    private func requireBoundRoot() throws {
        let current = try SandboxAuthorityFileSystem.openPrivateDirectory(at: root, createIfMissing: false)
        defer { close(current) }
        guard try SandboxAuthorityFileSystem.sameIdentity(SandboxAuthorityFileSystem.fileMetadata(descriptor),
            SandboxAuthorityFileSystem.fileMetadata(current)) else { throw AccountlessInstallationError.unsafeDestination }
    }
}
