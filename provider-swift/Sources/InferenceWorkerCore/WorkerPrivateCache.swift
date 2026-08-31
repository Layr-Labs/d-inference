import Darwin
import Foundation

public enum WorkerPrivateCacheError: Error, Equatable, Sendable {
    case invalidRoot
    case invalidName
    case symbolicLink
    case capacityExceeded
    case io
}

/// Descriptor-relative bounded cache rooted inside the worker's own sandbox
/// container. It never accepts an absolute path and never follows a symlink.
public final class WorkerPrivateCache: @unchecked Sendable {
    public let root: URL
    public let maximumBytes: UInt64
    private let lock = NSLock()
    private var accountedBytes: UInt64

    public init(root: URL, maximumBytes: UInt64) throws {
        guard maximumBytes > 0, maximumBytes <= 32 * 1024 * 1024 * 1024 else {
            throw WorkerPrivateCacheError.capacityExceeded
        }
        let standardized = root.standardizedFileURL
        try FileManager.default.createDirectory(
            at: standardized, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        guard standardized.path == standardized.resolvingSymlinksInPath().path else {
            throw WorkerPrivateCacheError.symbolicLink
        }
        self.root = standardized
        self.maximumBytes = maximumBytes
        self.accountedBytes = try Self.measure(root: standardized, maximum: maximumBytes)
    }

    public func read(name: String, maximumBytes: Int) throws -> Data {
        let url = try child(name)
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw WorkerPrivateCacheError.io }
        defer { close(fd) }
        var statBuffer = stat()
        guard fstat(fd, &statBuffer) == 0, (statBuffer.st_mode & S_IFMT) == S_IFREG,
              statBuffer.st_size >= 0, statBuffer.st_size <= maximumBytes else {
            throw WorkerPrivateCacheError.capacityExceeded
        }
        var data = Data(count: Int(statBuffer.st_size))
        let count = data.withUnsafeMutableBytes { bytes in
            Darwin.read(fd, bytes.baseAddress, bytes.count)
        }
        guard count == data.count else { throw WorkerPrivateCacheError.io }
        return data
    }

    public func write(name: String, data: Data) throws {
        guard UInt64(data.count) <= maximumBytes else { throw WorkerPrivateCacheError.capacityExceeded }
        lock.lock()
        defer { lock.unlock() }
        let destination = try child(name)
        let previous = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init) ?? 0
        let base = accountedBytes >= previous ? accountedBytes - previous : 0
        let (next, overflow) = base.addingReportingOverflow(UInt64(data.count))
        guard !overflow, next <= maximumBytes else { throw WorkerPrivateCacheError.capacityExceeded }
        let temporary = root.appendingPathComponent(".tmp-\(UUID().uuidString)", isDirectory: false)
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw WorkerPrivateCacheError.io }
        var succeeded = false
        defer {
            close(fd)
            if !succeeded { unlink(temporary.path) }
        }
        let written = data.withUnsafeBytes { bytes in
            Darwin.write(fd, bytes.baseAddress, bytes.count)
        }
        guard written == data.count, fsync(fd) == 0,
              rename(temporary.path, destination.path) == 0 else {
            throw WorkerPrivateCacheError.io
        }
        succeeded = true
        accountedBytes = next
    }

    public func remove(name: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let url = try child(name)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init) ?? 0
        guard unlink(url.path) == 0 || errno == ENOENT else { throw WorkerPrivateCacheError.io }
        accountedBytes = accountedBytes >= size ? accountedBytes - size : 0
    }

    private func child(_ name: String) throws -> URL {
        guard !name.isEmpty, name.utf8.count <= 255,
              name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw WorkerPrivateCacheError.invalidName
        }
        let url = root.appendingPathComponent(name, isDirectory: false).standardizedFileURL
        guard url.deletingLastPathComponent().path == root.path else {
            throw WorkerPrivateCacheError.invalidName
        }
        if FileManager.default.fileExists(atPath: url.path),
           url.path != url.resolvingSymlinksInPath().path {
            throw WorkerPrivateCacheError.symbolicLink
        }
        return url
    }

    private static func measure(root: URL, maximum: UInt64) throws -> UInt64 {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles]) else { throw WorkerPrivateCacheError.invalidRoot }
        var total: UInt64 = 0
        for url in contents {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true else {
                throw WorkerPrivateCacheError.symbolicLink
            }
            let (next, overflow) = total.addingReportingOverflow(UInt64(max(0, values.fileSize ?? 0)))
            guard !overflow, next <= maximum else { throw WorkerPrivateCacheError.capacityExceeded }
            total = next
        }
        return total
    }
}
