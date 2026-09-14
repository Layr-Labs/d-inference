import Darwin
import Foundation
import SandboxRuntime

/// Root publishes into an already-protected, traversable directory. The GUI
/// reader uses the same strict root-file contract as its host identity binding.
final class AccountlessBootPermitFile {
    private let path: URL
    private let parent: Int32

    init(path: URL) throws {
        guard getuid() == 0, geteuid() == 0, getegid() == 0 else {
            throw AccountlessInstallationError.unsafeDestination
        }
        let canonical = try Self.creationPath(path)
        self.path = canonical
        parent = try Self.openParent(canonical)
    }
    deinit { close(parent) }

    static func read(_ path: URL) throws -> AccountlessBootPermit {
        try .decode(HostUserIdentityFile.read(path))
    }

    /// The destination must be new or matching, so canonicalize its existing
    /// parent rather than requiring realpath(destination) to succeed first.
    static func creationPath(_ path: URL) throws -> URL {
        guard path.isFileURL, path.baseURL == nil, path.path.hasPrefix("/"), !path.path.contains("\0"),
              path.path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
                .allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              let parent = SandboxAuthorityFileSystem.canonicalPath(for: path.deletingLastPathComponent()) else {
            throw AccountlessInstallationError.unsafeDestination
        }
        return URL(fileURLWithPath: parent, isDirectory: true).appendingPathComponent(path.lastPathComponent)
    }

    func containsMatching(_ bytes: Data) throws -> Bool {
        try validate()
        var info = stat()
        if fstatat(parent, path.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw AccountlessInstallationError.unsafeDestination }
            return false
        }
        guard try HostUserIdentityFile.read(path) == bytes else { throw AccountlessInstallationError.invalidBinding }
        return true
    }

    func publish(_ bytes: Data) throws {
        _ = try AccountlessBootPermit.decode(bytes)
        if try containsMatching(bytes) { return }
        let file = try createUnlinkedFile()
        defer { close(file) }
        try SandboxAuthorityFileSystem.writeAll(bytes, to: file)
        guard fchmod(file, 0o444) == 0 else { throw AccountlessInstallationError.unsafeDestination }
        try SandboxAuthorityFileSystem.synchronize(file); try validate()
        guard fclonefileat(file, parent, path.lastPathComponent, 0) == 0 else { throw AccountlessInstallationError.unsafeDestination }
        try SandboxAuthorityFileSystem.synchronize(parent)
        guard try containsMatching(bytes) else { throw AccountlessInstallationError.invalidBinding }
    }

    private func validate() throws {
        let current = try Self.openParent(path); defer { close(current) }
        guard try SandboxAuthorityFileSystem.sameIdentity(SandboxAuthorityFileSystem.fileMetadata(parent),
            SandboxAuthorityFileSystem.fileMetadata(current)) else { throw AccountlessInstallationError.unsafeDestination }
    }

    /// The parent is root-controlled but GUI-traversable. The temporary inode
    /// is private and empty while named, and unlinked before any bytes are
    /// written. The general private-journal helper keeps its stronger parent rule.
    private func createUnlinkedFile() throws -> Int32 {
        try validate()
        let name = ".boot-permit-" + UUID().uuidString.lowercased() + ".partial"
        let file = openat(parent, name, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard file >= 0 else { throw AccountlessInstallationError.unsafeDestination }
        do {
            _ = try SandboxAuthorityFileSystem.requirePrivateRegularFile(file, maximumBytes: 0, expectedLinkCount: 1)
            guard unlinkat(parent, name, 0) == 0 else { throw AccountlessInstallationError.unsafeDestination }
            _ = try SandboxAuthorityFileSystem.requirePrivateRegularFile(file, maximumBytes: 0, expectedLinkCount: 0)
            return file
        } catch { close(file); throw error }
    }

    private static func openParent(_ path: URL) throws -> Int32 {
        var current = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard current >= 0 else { throw AccountlessInstallationError.unsafeDestination }
        do {
            for part in path.deletingLastPathComponent().path.split(separator: "/") {
                let next = openat(current, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw AccountlessInstallationError.unsafeDestination }
                close(current); current = next
                let info = try SandboxAuthorityFileSystem.fileMetadata(current)
                guard info.st_uid == 0, info.st_mode & 0o022 == 0, info.st_mode & 0o001 != 0 else {
                    throw AccountlessInstallationError.unsafeDestination
                }
                try SandboxAuthorityFileSystem.requireNoExtendedACL(current)
            }
            return current
        } catch { close(current); throw error }
    }
}
