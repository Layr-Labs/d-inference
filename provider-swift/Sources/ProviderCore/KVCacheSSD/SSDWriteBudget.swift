import CryptoKit
import Darwin
import Foundation

/// Root-wide endurance reservations, independent of scheduling/priority tokens.
/// The caller creates the dedicated root and handles the cap == 0 opt-out.
/// A reservation is durable before admission and is never refunded on write failure.
final class SSDWriteBudget: Sendable {
    static let defaultFileName = ".write-budget"
    /// Speculative first-sight bytes, a sub-allowance that still also counts
    /// in the default ledger (`SSDWriteRateLimiter.consumeSpeculative`).
    static let speculativeFileName = ".write-budget-speculative"
    private static let bucketCount = 25
    private static let recordBytes = (2 + bucketCount) * 8 + 32
    private let root: URL
    private let rootDevice: dev_t
    private let rootInode: ino_t
    private let ledgerDevice: dev_t
    private let ledgerInode: ino_t
    private let fileName: String

    private enum Failure: Error {
        case unsafePath, unavailable, corrupt
    }

    init(root: URL, fileName: String = SSDWriteBudget.defaultFileName) throws {
        self.root = root
        self.fileName = fileName
        let directory = try Self.openRoot(root)
        defer { close(directory) }
        var rootInfo = stat()
        guard fstat(directory, &rootInfo) == 0 else { throw Failure.unavailable }
        rootDevice = rootInfo.st_dev
        rootInode = rootInfo.st_ino
        var fd = openat(
            directory, fileName,
            O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | O_EXLOCK,
            S_IRUSR | S_IWUSR)
        let created = fd >= 0
        if fd < 0, errno == EEXIST {
            fd = openat(
                directory, fileName, O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        }
        guard fd >= 0 else { throw Failure.unavailable }
        defer { close(fd) }
        try Self.verify(fd, directory: directory, fileName: fileName)
        var ledgerInfo = stat()
        guard fstat(fd, &ledgerInfo) == 0 else { throw Failure.unavailable }
        ledgerDevice = ledgerInfo.st_dev
        ledgerInode = ledgerInfo.st_ino
        if created {
            try Self.write([1, 0] + Array(repeating: 0, count: Self.bucketCount), to: fd)
        }
        // Also complete a creator's directory sync if it died before doing so.
        guard fsync(directory) == 0, fcntl(fd, F_FULLFSYNC) == 0 else {
            throw Failure.unavailable
        }
        // Existing ledgers are validated at admission, not construction. A busy
        // or damaged ledger stops writes without disabling cache reads.
    }

    /// Advisory checks never change the ledger. Contention and all I/O or
    /// integrity failures deny admission; neither threads nor processes wait
    /// for another reservation's flush. Actual disk I/O is still synchronous.
    func admit(bytes: Int, capBytesPerDay: Int, now: Double, consume: Bool) -> Bool {
        admission(bytes: bytes, capBytesPerDay: capBytesPerDay, now: now, consume: consume) == .admitted
    }

    enum Admission: Equatable { case admitted, overCap, unavailable }

    /// `admit`, telling a full rolling day (`overCap`) apart from contention
    /// and I/O or integrity failures (`unavailable`).
    func admission(bytes: Int, capBytesPerDay: Int, now: Double, consume: Bool) -> Admission {
        let hour = (now / 3_600).rounded(.down)
        guard bytes >= 0, capBytesPerDay > 0, now.isFinite, now >= 0,
            hour < Double(UInt64.max)
        else { return .unavailable }
        do {
            let directory = try Self.openRoot(root)
            defer { close(directory) }
            var rootInfo = stat()
            guard fstat(directory, &rootInfo) == 0,
                rootInfo.st_dev == rootDevice, rootInfo.st_ino == rootInode else { return .unavailable }
            // A separate open description per call is essential: flock on a
            // shared descriptor would not exclude concurrent calls on one instance.
            let fd = openat(
                directory, fileName, O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard fd >= 0 else { return .unavailable }
            defer { close(fd) }
            var ledgerInfo = stat()
            guard fstat(fd, &ledgerInfo) == 0,
                ledgerInfo.st_dev == ledgerDevice, ledgerInfo.st_ino == ledgerInode else { return .unavailable }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return .unavailable }
            defer { flock(fd, LOCK_UN) }
            try Self.verify(fd, directory: directory, fileName: fileName)
            var record = try Self.read(fd)
            let currentHour = max(UInt64(hour), record[1])
            let elapsed = Int(min(currentHour - record[1], UInt64(Self.bucketCount)))
            if elapsed > 0 {
                record = [1, currentHour] + Array(record.dropFirst(2 + elapsed))
                    + Array(repeating: 0, count: elapsed)
            }
            // Keep the entire oldest overlapping hour: no write expires before
            // 24 hours, at the cost of up to one extra hour of conservatism.
            let total = record.dropFirst(2).reduce(UInt64(0), +)
            let cap = UInt64(capBytesPerDay)
            guard total <= cap, UInt64(bytes) <= cap - total else { return .overCap }
            if consume, bytes > 0 {
                record[record.count - 1] += UInt64(bytes)
                try Self.verify(fd, directory: directory, fileName: fileName)
                try Self.write(record, to: fd)
                try Self.verify(fd, directory: directory, fileName: fileName)
            }
            return .admitted
        } catch {
            return .unavailable
        }
    }

    private static func read(_ fd: Int32) throws -> [UInt64] {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw Failure.unavailable }
        guard info.st_size == recordBytes else { throw Failure.corrupt }
        var data = Data(count: recordBytes)
        let count = data.withUnsafeMutableBytes {
            pread(fd, $0.baseAddress, $0.count, 0)
        }
        guard count == recordBytes else { throw Failure.unavailable }
        let payload = data.prefix(recordBytes - 32)
        guard Data(SHA256.hash(data: payload)) == data.suffix(32) else {
            throw Failure.corrupt
        }
        let record: [UInt64] = payload.withUnsafeBytes { buffer in
            stride(from: 0, to: payload.count, by: 8).map {
                UInt64(littleEndian: buffer.loadUnaligned(fromByteOffset: $0, as: UInt64.self))
            }
        }
        guard record[0] == 1 else { throw Failure.corrupt }
        var total: UInt64 = 0
        for bytes in record.dropFirst(2) {
            guard bytes <= UInt64(Int.max) - total else { throw Failure.corrupt }
            total += bytes
        }
        return record
    }

    private static func write(_ record: [UInt64], to fd: Int32) throws {
        var data = Data()
        for var word in record.map({ $0.littleEndian }) {
            withUnsafeBytes(of: &word) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: SHA256.hash(data: data))
        // Keep the inode stable for flock. A torn in-place write fails checksum
        // validation permanently, never silently replenishing the allowance.
        let count = data.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) }
        guard count == data.count, fcntl(fd, F_FULLFSYNC) == 0 else {
            throw Failure.unavailable
        }
    }

    private static func verify(_ fd: Int32, directory: Int32, fileName: String) throws {
        var opened = stat()
        var live = stat()
        guard fstat(fd, &opened) == 0,
            fstatat(directory, fileName, &live, AT_SYMLINK_NOFOLLOW) == 0,
            (opened.st_mode & S_IFMT) == S_IFREG, opened.st_nlink == 1,
            (live.st_mode & S_IFMT) == S_IFREG, live.st_nlink == 1,
            opened.st_dev == live.st_dev, opened.st_ino == live.st_ino
        else { throw Failure.unsafePath }
    }

    private static func openRoot(_ root: URL) throws -> Int32 {
        var path = root.path
        guard root.isFileURL, path.hasPrefix("/"), !path.utf8.contains(0) else {
            throw Failure.unsafePath
        }
        // Only macOS's system aliases are normalized, never user-controlled links.
        if path == "/var" || path.hasPrefix("/var/")
            || path == "/tmp" || path.hasPrefix("/tmp/")
        {
            path = "/private" + path
        }
        var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.unavailable }
        do {
            for component in path.split(separator: "/") {
                guard component != ".", component != ".." else { throw Failure.unsafePath }
                let next = openat(
                    fd, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw Failure.unsafePath }
                close(fd)
                fd = next
            }
            return fd
        } catch {
            close(fd)
            throw error
        }
    }
}
