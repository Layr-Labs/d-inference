import Foundation
import Darwin

public enum ClusterConfigurationError: Error, Equatable, CustomStringConvertible {
    case invalid(String)
    case busy
    case commitUncertain(String)

    public var description: String {
        switch self {
        case .invalid(let message): return message
        case .busy: return "Configuration or native device lease is currently held"
        case .commitUncertain(let path): return "Configuration publication requires inspection: \(path)"
        }
    }
}

/// Bounded configuration files only. This does not read model weights or private keys.
/// Locks coordinate the provider's existing stable `<name>.lock` convention.
enum ClusterConfigurationFiles {
    struct Directory {
        let descriptor: Int32
        let path: String
        let identity: stat

        func check() throws {
            var current = stat(), named = stat()
            guard fstat(descriptor, &current) == 0, lstat(path, &named) == 0,
                  current.st_dev == identity.st_dev, current.st_ino == identity.st_ino,
                  named.st_dev == identity.st_dev, named.st_ino == identity.st_ino,
                  current.st_uid == geteuid(), current.st_mode & 0o022 == 0,
                  current.st_mode & S_IFMT == S_IFDIR, current.st_nlink > 0 else {
                throw ClusterConfigurationError.invalid("Configuration directory changed")
            }
        }
    }

    static func requireAbsolute(_ path: String) throws {
        guard path.hasPrefix("/"), path != "/", path.utf8.count <= 4096,
              !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              !path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().contains(where: {
                  $0.isEmpty || $0 == "." || $0 == ".."
              }) else { throw ClusterConfigurationError.invalid("Expected a canonical absolute file path") }
    }

    static func directory(_ url: URL, create: Bool = false, privateMode: Bool = false) throws -> Directory {
        guard url.isFileURL else { throw ClusterConfigurationError.invalid("Expected a local directory") }
        try requireAbsolute(url.path)
        var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw ClusterConfigurationError.invalid("Cannot open configuration root") }
        do {
            for component in url.path.split(separator: "/") {
                let name = String(component)
                var next = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0 && errno == ENOENT && create {
                    guard mkdirat(fd, name, 0o700) == 0 || errno == EEXIST else {
                        throw ClusterConfigurationError.invalid("Cannot create configuration directory")
                    }
                    next = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else { throw ClusterConfigurationError.invalid("Configuration directory is missing or follows a link at component \(name) (errno \(errno))") }
                Darwin.close(fd); fd = next
            }
            var value = stat()
            guard fstat(fd, &value) == 0, value.st_uid == geteuid(), value.st_mode & 0o022 == 0,
                  !privateMode || value.st_mode & 0o077 == 0 else {
                throw ClusterConfigurationError.invalid("Configuration directory permissions differ")
            }
            let result = Directory(descriptor: fd, path: url.path, identity: value)
            try result.check(); return result
        } catch { Darwin.close(fd); throw error }
    }

    static func read(_ url: URL, maximum: Int, privateMode: Bool = false) throws -> Data {
        try requireAbsolute(url.path)
        let parent = try directory(url.deletingLastPathComponent())
        defer { Darwin.close(parent.descriptor) }
        guard let data = try readAt(parent, name: url.lastPathComponent, maximum: maximum, privateMode: privateMode) else {
            throw ClusterConfigurationError.invalid("Configuration input does not exist")
        }
        return data
    }

    static func readAt(_ parent: Directory, name: String, maximum: Int,
                       privateMode: Bool = false) throws -> Data? {
        try parent.check()
        try requireName(name)
        guard (1...1_048_576).contains(maximum) else { throw ClusterConfigurationError.invalid("Invalid configuration byte bound") }
        let fd = openat(parent.descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 && errno == ENOENT { return nil }
        guard fd >= 0 else { throw ClusterConfigurationError.invalid("Cannot open configuration input") }
        defer { Darwin.close(fd) }
        var before = stat(), after = stat(), named = stat()
        guard fstat(fd, &before) == 0, regular(before), before.st_size > 0,
              before.st_size <= maximum, !privateMode || before.st_mode & 0o077 == 0 else {
            throw ClusterConfigurationError.invalid("Configuration input is unsafe, empty or oversized")
        }
        var result = Data(), buffer = [UInt8](repeating: 0, count: min(maximum + 1, 4096))
        while true {
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n < 0 && errno == EINTR { continue }
            guard n >= 0, n <= maximum - result.count else { throw ClusterConfigurationError.invalid("Configuration input exceeded its byte bound") }
            if n == 0 { break }
            result.append(contentsOf: buffer.prefix(n))
        }
        guard fstat(fd, &after) == 0,
              fstatat(parent.descriptor, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              unchanged(before, after), unchanged(after, named), result.count == before.st_size else {
            throw ClusterConfigurationError.invalid("Configuration input changed while reading")
        }
        try parent.check(); return result
    }

    /// Check ownership/mode/type without reading a credential's contents.
    static func credentialMetadata(_ url: URL, privateMode: Bool) throws {
        try requireAbsolute(url.path)
        let parent = try directory(url.deletingLastPathComponent())
        defer { Darwin.close(parent.descriptor) }
        let fd = openat(parent.descriptor, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw ClusterConfigurationError.invalid("Cannot open configured credential") }
        defer { Darwin.close(fd) }
        var value = stat(), named = stat()
        guard fstat(fd, &value) == 0, regular(value), value.st_size > 0,
              !privateMode || value.st_mode & 0o077 == 0,
              fstatat(parent.descriptor, url.lastPathComponent, &named, AT_SYMLINK_NOFOLLOW) == 0,
              unchanged(value, named) else { throw ClusterConfigurationError.invalid("Configured credential is unsafe") }
        try parent.check()
    }

    static func withLock<T>(_ parent: Directory, name: String, requireEmpty: Bool = false,
                            privateMode: Bool = false, _ body: () throws -> T) throws -> T {
        try parent.check()
        try requireName(name)
        let fd = openat(parent.descriptor, name, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ClusterConfigurationError.invalid("Cannot open configuration lock") }
        defer { Darwin.close(fd) }
        var value = stat(), named = stat()
        guard fstat(fd, &value) == 0, regular(value), !privateMode || value.st_mode & 0o077 == 0,
              fstatat(parent.descriptor, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              value.st_dev == named.st_dev, value.st_ino == named.st_ino else {
            throw ClusterConfigurationError.invalid("Configuration lock is unsafe")
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw ClusterConfigurationError.busy }
        defer { _ = flock(fd, LOCK_UN) }
        guard fstat(fd, &value) == 0, !requireEmpty || value.st_size == 0 else {
            throw ClusterConfigurationError.invalid("Unresolved native ownership journal; explicit recovery required")
        }
        try parent.check()
        let result = try body()
        guard fstat(fd, &value) == 0, regular(value), !privateMode || value.st_mode & 0o077 == 0,
              !requireEmpty || value.st_size == 0,
              fstatat(parent.descriptor, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              value.st_dev == named.st_dev, value.st_ino == named.st_ino else {
            throw ClusterConfigurationError.invalid("Configuration lock changed")
        }
        try parent.check()
        return result
    }

    /// Immutable, content-addressed publication. linkat never replaces an existing
    /// destination; readers can see only a complete fsynced file. The temporary
    /// link is removed before returning, so the admitted file has one link.
    static func publish(_ data: Data, parent: Directory, name: String, maximum: Int) throws {
        try requireName(name)
        guard !data.isEmpty, data.count <= maximum else { throw ClusterConfigurationError.invalid("Configuration publication exceeded its bound") }
        if let existing = try readAt(parent, name: name, maximum: maximum, privateMode: true) {
            guard existing == data else { throw ClusterConfigurationError.invalid("Existing configuration content differs") }
            return
        }
        let temporary = ".cluster-" + UUID().uuidString.lowercased() + ".tmp"
        let fd = openat(parent.descriptor, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ClusterConfigurationError.invalid("Cannot stage configuration file") }
        defer { Darwin.close(fd); _ = unlinkat(parent.descriptor, temporary, 0) }
        try write(data, descriptor: fd)
        try parent.check()
        guard linkat(parent.descriptor, temporary, parent.descriptor, name, 0) == 0 else {
            throw ClusterConfigurationError.invalid("Configuration publication destination appeared")
        }
        guard unlinkat(parent.descriptor, temporary, 0) == 0, fsync(parent.descriptor) == 0 else {
            throw ClusterConfigurationError.commitUncertain(parent.path + "/" + name)
        }
        try parent.check()
        guard try readAt(parent, name: name, maximum: maximum, privateMode: true) == data else {
            throw ClusterConfigurationError.commitUncertain(parent.path + "/" + name)
        }
    }

    /// Reload, transform, and atomically replace one provider TOML under the same
    /// stable sidecar lock used by existing CLI writers. A transform failure leaves
    /// the old bytes intact. Published cluster records may remain unreferenced if
    /// this later pointer update fails; they are never treated as enabled setup.
    static func update(_ url: URL, maximum: Int, transform: (Data?) throws -> Data) throws {
        try requireAbsolute(url.path)
        let parent = try directory(url.deletingLastPathComponent(), create: true)
        defer { Darwin.close(parent.descriptor) }
        try withLock(parent, name: url.lastPathComponent + ".lock") {
            let original = try readAt(parent, name: url.lastPathComponent, maximum: maximum)
            let next = try transform(original)
            guard !next.isEmpty, next.count <= maximum else { throw ClusterConfigurationError.invalid("Provider configuration serialization failed or exceeded its bound") }
            if original == next { return }
            if original == nil {
                try publish(next, parent: parent, name: url.lastPathComponent, maximum: maximum)
                return
            }
            let temporary = ".cluster-provider-" + UUID().uuidString.lowercased() + ".tmp"
            let fd = openat(parent.descriptor, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw ClusterConfigurationError.invalid("Cannot stage provider configuration") }
            defer { Darwin.close(fd); _ = unlinkat(parent.descriptor, temporary, 0) }
            try write(next, descriptor: fd)
            guard try readAt(parent, name: url.lastPathComponent, maximum: maximum) == original else {
                throw ClusterConfigurationError.invalid("Provider configuration changed outside its lock")
            }
            try parent.check()
            guard renameat(parent.descriptor, temporary, parent.descriptor, url.lastPathComponent) == 0 else {
                throw ClusterConfigurationError.invalid("Cannot publish provider configuration")
            }
            do {
                guard fsync(parent.descriptor) == 0 else { throw ClusterConfigurationError.commitUncertain(url.path) }
                try parent.check()
                guard try readAt(parent, name: url.lastPathComponent, maximum: maximum, privateMode: true) == next else {
                    throw ClusterConfigurationError.commitUncertain(url.path)
                }
            } catch { throw ClusterConfigurationError.commitUncertain(url.path) }
        }
    }

    private static func write(_ data: Data, descriptor: Int32) throws {
        var offset = 0
        while offset < data.count {
            let n = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress!.advanced(by: offset), data.count - offset) }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw ClusterConfigurationError.invalid("Configuration write failed") }
            offset += n
        }
        guard fsync(descriptor) == 0 else { throw ClusterConfigurationError.invalid("Configuration file sync failed") }
    }

    private static func regular(_ value: stat) -> Bool {
        value.st_mode & S_IFMT == S_IFREG && value.st_uid == geteuid() && value.st_nlink == 1 && value.st_mode & 0o022 == 0
    }

    private static func requireName(_ name: String) throws {
        guard !name.isEmpty, name.utf8.count <= 255, name != ".", name != "..", !name.contains("/"),
              !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw ClusterConfigurationError.invalid("Invalid configuration file name")
        }
    }

    private static func unchanged(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode && a.st_uid == b.st_uid && a.st_nlink == b.st_nlink &&
        a.st_size == b.st_size && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
        a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
}
