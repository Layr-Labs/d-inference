// Copyright © 2026 Eigen Labs.

import Darwin
import Foundation

/// File grammar and leases shared by a rank and the provider that maintains idle plans.
public enum ClusterPrefixRecordDirectory {
    public static let ttlFile = "expiry-ttl"

    private static func lowerHex(_ value: Substring, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    public static func isPlan(_ name: String) -> Bool { name.hasPrefix("v1-") && lowerHex(name.dropFirst(3), count: 24) }
    public static func isRecord(_ name: String) -> Bool { name.hasSuffix(".dbpx") && lowerHex(name.dropLast(5), count: 32) }
    public static func rank(_ name: String) -> Int? {
        guard name.hasPrefix("rank"), name.utf8.count <= 6, let n = Int(name.dropFirst(4)),
              (0...63).contains(n), name == "rank\(n)" else { return nil }
        return n
    }

    public static func openChild(_ parent: Int32, _ name: String, device: dev_t) -> Int32? {
        guard name != ".", name != "..", !name.isEmpty, !name.contains("/") else { return nil }
        let fd = openat(parent, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY)
        guard fd >= 0 else { return nil }
        var s = stat()
        guard fstat(fd, &s) == 0, s.st_uid == getuid(), s.st_dev == device else { close(fd); return nil }
        return fd
    }

    /// A failed open (including a missing `in-use`) or flock never grants permission to clean.
    enum Lease { case acquired(Int32), held, unknown }

    static func lease(_ plan: Int32) -> Lease {
        let fd = openat(plan, "in-use", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return .unknown }
        var s = stat(), entry = stat()
        guard fstat(fd, &s) == 0, s.st_mode & S_IFMT == S_IFREG, s.st_uid == getuid() else { close(fd); return .unknown }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let held = errno == EWOULDBLOCK; close(fd); return held ? .held : .unknown
        }
        guard fstatat(plan, "in-use", &entry, AT_SYMLINK_NOFOLLOW) == 0,
              entry.st_ino == s.st_ino, entry.st_dev == s.st_dev else { close(fd); return .unknown }
        return .acquired(fd)
    }

    public static func withIdlePlan<T>(root: Int32, name: String, device: dev_t, _ visit: (Int32) -> T) -> T? {
        withLeasedPlan(root: root, name: name, device: device) { fd, _ in visit(fd) }
    }

    public static func withLeasedPlan<T>(root: Int32, name: String, device: dev_t, _ visit: (Int32, Int32) -> T) -> T? {
        guard isPlan(name), let plan = openChild(root, name, device: device) else { return nil }
        defer { close(plan) }
        guard case .acquired(let lease) = lease(plan) else { return nil }
        defer { close(lease) }
        return visit(plan, lease)
    }

    @discardableResult
    public static func forEachName(in fd: Int32, _ body: (String) -> Void) -> Bool {
        let copy = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard copy >= 0 else { return false }
        guard let stream = fdopendir(copy) else { close(copy); return false }
        defer { closedir(stream) }
        while true {
            errno = 0
            guard let entry = readdir(stream) else { return errno == 0 }
            guard let name = withUnsafeBytes(of: entry.pointee.d_name, {
                String(validatingCString: $0.baseAddress!.assumingMemoryBound(to: CChar.self))
            }) else { return false }
            if name != ".", name != ".." { body(name) }
        }
    }

    /// A rank publishes only its resolved duration. No pairing identity is needed by maintenance.
    /// Older records have no stamp. An unreadable or malformed stamp skips the rank.
    public static func cleanupTTL(rankFD: Int32, local: Int) -> Int? {
        let fd = openat(rankFD, ttlFile, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return errno == ENOENT ? local : nil }
        defer { close(fd) }
        var s = stat()
        guard fstat(fd, &s) == 0, s.st_mode & S_IFMT == S_IFREG, s.st_uid == getuid(),
              (1...5).contains(s.st_size) else { return nil }
        var bytes = [UInt8](repeating: 0, count: Int(s.st_size))
        guard read(fd, &bytes, bytes.count) == bytes.count, bytes.last == 10,
              let n = Int(String(decoding: bytes.dropLast(), as: UTF8.self)), (1...1_800).contains(n),
              bytes == Array("\(n)\n".utf8) else { return nil }
        return min(local, n)
    }
}
