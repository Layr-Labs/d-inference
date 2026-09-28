import Foundation
import CryptoKit
import Darwin

/// Streaming verification of installed executables and bounded public metadata.
/// Checkpoint payload verification remains in the native loader. This is a
/// filesystem identity check, not executable-code or library attestation.
enum DistributedInstalledFiles {
    struct Identity: @unchecked Sendable {
        let url: URL
        let information: stat

        func requireUnchanged() throws {
            let parent = try ClusterConfigurationFiles.directory(url.deletingLastPathComponent())
            defer { Darwin.close(parent.descriptor) }
            var current = stat()
            guard fstatat(parent.descriptor, url.lastPathComponent, &current, AT_SYMLINK_NOFOLLOW) == 0,
                  DistributedInstalledFiles.same(information, current) else {
                throw ClusterConfigurationError.invalid("Verified installed input changed")
            }
            try parent.check()
        }
    }

    static func verify(_ url: URL, expectedSHA256: String, maximumBytes: Int,
                       executable: Bool = false, deadline: UInt64) throws -> Identity {
        guard ClusterConfigurationSyntax.hash(expectedSHA256), (1...(256 * 1024 * 1024)).contains(maximumBytes) else {
            throw ClusterConfigurationError.invalid("Invalid installed input bound or pin")
        }
        try check(deadline)
        let parent = try ClusterConfigurationFiles.directory(url.deletingLastPathComponent())
        defer { Darwin.close(parent.descriptor) }
        let descriptor = openat(parent.descriptor, url.lastPathComponent, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw ClusterConfigurationError.invalid("Cannot open installed input") }
        defer { Darwin.close(descriptor) }
        var before = stat(), after = stat(), named = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_uid == geteuid(), before.st_nlink == 1, before.st_mode & 0o022 == 0,
              before.st_size > 0, before.st_size <= maximumBytes,
              !executable || before.st_mode & 0o111 != 0 else {
            throw ClusterConfigurationError.invalid("Installed input is unsafe, empty, oversized or not executable")
        }
        var digest = SHA256(), total = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try check(deadline)
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0, count <= maximumBytes - total else {
                throw ClusterConfigurationError.invalid("Installed input read exceeded its bound")
            }
            if count == 0 { break }
            digest.update(data: Data(buffer.prefix(count))); total += count
        }
        try check(deadline)
        guard fstat(descriptor, &after) == 0,
              fstatat(parent.descriptor, url.lastPathComponent, &named, AT_SYMLINK_NOFOLLOW) == 0,
              same(before, after), same(after, named), total == before.st_size,
              digest.finalize().map({ String(format: "%02x", $0) }).joined() == expectedSHA256 else {
            throw ClusterConfigurationError.invalid("Installed input identity or SHA-256 differs")
        }
        try parent.check()
        return .init(url: url, information: after)
    }

    static func check(_ deadline: UInt64) throws {
        guard DispatchTime.now().uptimeNanoseconds < deadline else {
            throw ClusterConfigurationError.invalid("Installed preflight deadline expired")
        }
    }

    private static func same(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_uid == b.st_uid && a.st_mode == b.st_mode &&
        a.st_nlink == b.st_nlink && a.st_size == b.st_size &&
        a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
        a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
}
