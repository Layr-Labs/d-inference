import CryptoKit
import Darwin
import Foundation

enum WorkerCapabilityError: Error { case invalid(String) }

/// Bounded regular-file snapshots. The descriptor and its pathname must retain
/// the same identity/size/timestamps through the read. No checkpoint is opened.
enum WorkerCapabilityInput {
    static func check(_ deadline: UInt64) throws {
        guard DispatchTime.now().uptimeNanoseconds < deadline else {
            throw WorkerCapabilityError.invalid("Metadata deadline expired")
        }
    }

    static func read(_ path: String, maximumBytes: Int, deadline: UInt64) throws -> Data {
        var result = Data()
        try chunks(path, maximumBytes: maximumBytes, deadline: deadline) { result.append($0) }
        return result
    }

    static func hash(_ path: String, maximumBytes: Int, deadline: UInt64) throws -> String {
        var digest = SHA256()
        try chunks(path, maximumBytes: maximumBytes, deadline: deadline) { digest.update(data: $0) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func chunks(_ path: String, maximumBytes: Int, deadline: UInt64,
                               consume: (Data) throws -> Void) throws {
        try check(deadline)
        guard path.hasPrefix("/"), !path.utf8.contains(0), path.utf8.count <= 4096,
              maximumBytes > 0 else { throw WorkerCapabilityError.invalid("Invalid metadata input path/bound") }
        let fd = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw WorkerCapabilityError.invalid("Cannot open metadata input") }
        defer { Darwin.close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG,
              before.st_size > 0, before.st_size <= maximumBytes else {
            throw WorkerCapabilityError.invalid("Metadata input is not a bounded nonempty regular file")
        }
        var remaining = Int(before.st_size)
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while remaining > 0 {
            try check(deadline)
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, min(remaining, $0.count)) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw WorkerCapabilityError.invalid("Metadata input ended or failed during snapshot") }
            try consume(Data(buffer.prefix(count))); remaining -= count
        }
        var trailing: UInt8 = 0
        var count: Int
        repeat { try check(deadline); count = Darwin.read(fd, &trailing, 1) } while count < 0 && errno == EINTR
        var after = stat(), pathAfter = stat()
        guard count == 0, fstat(fd, &after) == 0, lstat(path, &pathAfter) == 0,
              same(before, after), same(before, pathAfter) else {
            throw WorkerCapabilityError.invalid("Metadata input changed during snapshot")
        }
        try check(deadline)
    }

    private static func same(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode && a.st_size == b.st_size
            && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
            && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
}
