import Darwin
import Foundation
import SandboxRuntime

/// Private, descriptor-bound journal IO. Callers define phase semantics; this
/// owner supplies one stable lock and immutable, matching record publication.
final class AccountlessPrivateJournal {
    let directory: URL
    let descriptor: Int32
    private let lock: Int32
    private let lockName: String
    static let maximumBytes = 32 * 1024

    init(directory: URL, lockName: String) throws {
        try Self.requireName(lockName)
        let descriptor = try SandboxAuthorityFileSystem.openPrivateDirectory(at: directory, createIfMissing: false)
        let created = openat(descriptor, lockName, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard created >= 0 || errno == EEXIST else { close(descriptor); throw AccountlessInstallationError.unsafeDestination }
        let lock = created >= 0 ? created : openat(descriptor, lockName, O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        var adopted = false
        defer { if !adopted { if lock >= 0 { close(lock) }; close(descriptor) } }
        guard lock >= 0 else { throw AccountlessInstallationError.unsafeDestination }
        _ = try SandboxAuthorityFileSystem.requirePrivateRegularFile(lock, maximumBytes: 0)
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw AccountlessInstallationError.stagingInProgress }
        try Self.requireNamed(lock, parent: descriptor, name: lockName)
        try SandboxAuthorityFileSystem.synchronize(descriptor)
        self.directory = directory; self.descriptor = descriptor; self.lock = lock; self.lockName = lockName
        adopted = true
    }

    deinit { close(lock); close(descriptor) }

    func validate() throws {
        let current = try SandboxAuthorityFileSystem.openPrivateDirectory(at: directory, createIfMissing: false)
        defer { close(current) }
        guard try SandboxAuthorityFileSystem.sameIdentity(SandboxAuthorityFileSystem.fileMetadata(descriptor),
            SandboxAuthorityFileSystem.fileMetadata(current)) else { throw AccountlessInstallationError.unsafeDestination }
        try Self.requireNamed(lock, parent: descriptor, name: lockName)
    }

    func requireAbsent(_ names: [String]) throws {
        try validate()
        for name in names {
            try Self.requireName(name)
            var metadata = stat()
            if fstatat(descriptor, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 { throw AccountlessInstallationError.stagingClosed }
            guard errno == ENOENT else { throw AccountlessInstallationError.unsafeDestination }
        }
    }

    func read(_ name: String) throws -> Data? {
        try Self.requireName(name); try validate()
        let file = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if file < 0, errno == ENOENT { return nil }
        guard file >= 0 else { throw AccountlessInstallationError.unsafeDestination }
        defer { close(file) }
        let data = try SandboxAuthorityFileSystem.readStablePrivateFile(file, maximumBytes: Self.maximumBytes)
        try Self.requireNamed(file, parent: descriptor, name: name)
        try validate()
        return data
    }

    func publishMatching(_ data: Data, name: String) throws {
        guard data.count <= Self.maximumBytes else { throw AccountlessInstallationError.invalidBinding }
        if let existing = try read(name) {
            guard existing == data else { throw AccountlessInstallationError.invalidBinding }
            return
        }
        let temporary = try SandboxAuthorityFileSystem.createUnlinkedPrivateFile(parentDescriptor: descriptor, prefix: "staging")
        defer { close(temporary) }
        try SandboxAuthorityFileSystem.writeAll(data, to: temporary)
        try SandboxAuthorityFileSystem.synchronize(temporary)
        try validate()
        guard fclonefileat(temporary, descriptor, name, 0) == 0 else { throw AccountlessInstallationError.unsafeDestination }
        try SandboxAuthorityFileSystem.synchronize(descriptor)
        guard try read(name) == data else { throw AccountlessInstallationError.invalidBinding }
    }

    private static func requireName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw AccountlessInstallationError.unsafeDestination
        }
    }

    private static func requireNamed(_ file: Int32, parent: Int32, name: String) throws {
        var named = stat()
        guard fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              try SandboxAuthorityFileSystem.stableIdentity(SandboxAuthorityFileSystem.fileMetadata(file), named)
        else { throw AccountlessInstallationError.unsafeDestination }
    }
}
