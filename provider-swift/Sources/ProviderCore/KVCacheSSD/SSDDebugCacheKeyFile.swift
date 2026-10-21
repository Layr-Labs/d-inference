// Copyright © 2026 Eigen Labs.

#if DEBUG
import CryptoKit
import Darwin
import Foundation

/// DEBUG builds only: an ad hoc signed qualification binary has no keychain
/// access group, so it cannot persist the Secure-Enclave-wrapped SSD cache KEK.
/// The operator instead creates a private 32-byte key file
/// (`DARKBLOOM_DEBUG_CACHE_KEY_FILE`), so encrypted checkpoints survive a
/// restart. This code never creates, repairs or rewrites that file. A release
/// build uses the keychain-backed KEK and has no such path.
enum SSDDebugCacheKeyFile {
    static let environmentKey = "DARKBLOOM_DEBUG_CACHE_KEY_FILE"
    static let keyByteCount = 32
    static let requiredMode: mode_t = 0o600

    enum Failure: Error, Equatable, CustomStringConvertible {
        case relativePath
        case missing
        case symbolicLink
        case notRegularFile
        case notOwnedByCurrentUser
        case wrongMode(mode_t)
        case multipleLinks
        case wrongSize(Int64)
        case unreadable(errno: Int32)
        case changedWhileReading

        var description: String {
            let reason = switch self {
            case .relativePath: "path is not absolute"
            case .missing: "file does not exist"
            case .symbolicLink: "path is a symbolic link"
            case .notRegularFile: "not a regular file"
            case .notOwnedByCurrentUser: "not owned by the current user"
            case .wrongMode(let mode): "mode is \(String(mode, radix: 8)), not 600"
            case .multipleLinks: "file has more than one hard link"
            case .wrongSize(let size): "size is \(size) bytes, not \(SSDDebugCacheKeyFile.keyByteCount)"
            case .unreadable(let code): "unreadable (errno \(code))"
            case .changedWhileReading: "file changed while reading"
            }
            return "\(SSDDebugCacheKeyFile.environmentKey): \(reason)"
        }
    }

    /// A non-empty value selects the file; an empty value is unset.
    static func selectedPath(environment: [String: String]) -> String? {
        guard let path = environment[environmentKey], !path.isEmpty else { return nil }
        return path
    }

    /// Reads the operator's key without following a final symlink and
    /// derives a domain-separated KEK, so the same file cannot be reused as
    /// key material for another purpose by accident.
    static func load(path: String) throws -> SymmetricKey {
        guard path.hasPrefix("/") else { throw Failure.relativePath }
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            let code = errno
            switch code {
            case ENOENT: throw Failure.missing
            case ELOOP: throw Failure.symbolicLink
            default: throw Failure.unreadable(errno: code)
            }
        }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0 else { throw Failure.unreadable(errno: errno) }
        guard before.st_mode & S_IFMT == S_IFREG else { throw Failure.notRegularFile }
        guard before.st_uid == geteuid() else { throw Failure.notOwnedByCurrentUser }
        guard before.st_mode & 0o7777 == requiredMode else { throw Failure.wrongMode(before.st_mode & 0o7777) }
        guard before.st_nlink == 1 else { throw Failure.multipleLinks }
        guard before.st_size == keyByteCount else { throw Failure.wrongSize(Int64(before.st_size)) }

        // One spare byte detects growth after the size check.
        var bytes = [UInt8](repeating: 0, count: keyByteCount + 1)
        defer { bytes.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) } }
        var count = 0
        while count < bytes.count {
            let n = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress! + count, $0.count - count) }
            if n < 0 && errno == EINTR { continue }
            guard n >= 0 else { throw Failure.unreadable(errno: errno) }
            if n == 0 { break }
            count += n
        }
        var after = stat()
        guard count == keyByteCount, fstat(fd, &after) == 0,
            after.st_ino == before.st_ino, after.st_dev == before.st_dev,
            after.st_size == before.st_size,
            after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
            after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec
        else { throw Failure.changedWhileReading }
        let material = SymmetricKey(data: bytes.prefix(keyByteCount))
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: material, info: Data("darkbloom-debug-ssd-cache-kek-v1".utf8),
            outputByteCount: keyByteCount)
    }
}
#endif
