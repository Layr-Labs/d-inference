import Foundation
import Darwin

public enum ClusterDeviceExclusionError: Error, Equatable, CustomStringConvertible {
    case invalid(String)
    public var description: String { switch self { case .invalid(let message): return message } }
}

/// One process's exclusive local device scope. Solo callers retain this object
/// through actual in-process engine teardown. A cluster leader/daemon launcher
/// must not hold it: the native owner child acquires its own scope.
///
/// A native owner's nonempty journal is sticky across process death. Construction
/// never truncates or recovers it, and even the owner SPI can resolve only a
/// journal recorded by this same live object after it acquired an empty file.
public final class ClusterDeviceExclusion: @unchecked Sendable {
    private let lock = NSLock()
    private let directory: Int32
    private let descriptor: Int32
    private let directoryPath: String
    private let directoryIdentity: stat
    private let identity: stat
    private var recorded = false
    private var recordedBytes: Data?
    private var resolved = false

    public convenience init(directoryURL: URL) throws {
        try self.init(directoryURL: directoryURL, beforeFinalValidation: {})
    }

    // Internal deterministic filesystem-race seam; production always uses the
    // public initializer above, with no callback or path replacement.
    init(directoryURL: URL, beforeFinalValidation: () throws -> Void) throws {
        let dir = try Self.openDirectory(directoryURL)
        var dirStat = stat()
        guard fstat(dir, &dirStat) == 0, dirStat.st_uid == geteuid(),
              dirStat.st_mode & S_IFMT == S_IFDIR, dirStat.st_mode & 0o077 == 0 else {
            Darwin.close(dir); throw ClusterDeviceExclusionError.invalid("Lease directory must be private and owned")
        }
        let fd = openat(dir, "native-device.lease", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard fd >= 0 else { Darwin.close(dir); throw ClusterDeviceExclusionError.invalid("Cannot open device lease") }
        var value = stat(), path = stat()
        guard fstat(fd, &value) == 0, fstatat(dir, "native-device.lease", &path, AT_SYMLINK_NOFOLLOW) == 0,
              value.st_dev == path.st_dev, value.st_ino == path.st_ino, value.st_uid == geteuid(), value.st_nlink == 1,
              value.st_mode & S_IFMT == S_IFREG, value.st_mode & 0o077 == 0,
              flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd); Darwin.close(dir); throw ClusterDeviceExclusionError.invalid("Device lease unavailable or unsafe")
        }
        guard fstat(fd, &value) == 0, value.st_size == 0 else {
            Darwin.close(fd); Darwin.close(dir)
            throw ClusterDeviceExclusionError.invalid("Unresolved native ownership journal; explicit recovery required")
        }
        directory = dir; descriptor = fd; identity = value
        directoryPath = directoryURL.path; directoryIdentity = dirStat
        try beforeFinalValidation()
        // Solo never records a journal, so construction itself must establish
        // that the configured path still names this held exclusion.
        try requireSameFile()
        guard fstat(descriptor, &value) == 0, value.st_size == 0 else {
            throw ClusterDeviceExclusionError.invalid("Native ownership journal appeared during device acquisition")
        }
    }

    @_spi(OwnerService) public func recordNativeOwnership(_ data: Data) throws {
        try lock.withLock {
            guard !recorded, !resolved, !data.isEmpty, data.count <= 16_384 else {
                throw ClusterDeviceExclusionError.invalid("Lease journal is repeated or outside its bound")
            }
            try requireSameFile()
            var current = stat()
            guard fstat(descriptor, &current) == 0, current.st_size == 0 else {
                throw ClusterDeviceExclusionError.invalid("Lease journal is no longer empty")
            }
            recorded = true // A partial write is unresolved; it is never retried.
            var offset = 0
            while offset < data.count {
                let count = data.withUnsafeBytes { Darwin.pwrite(descriptor, $0.baseAddress!.advanced(by: offset), data.count - offset, off_t(offset)) }
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw ClusterDeviceExclusionError.invalid("Lease journal write failed") }
                offset += count
            }
            guard fsync(descriptor) == 0, fsync(directory) == 0 else { throw ClusterDeviceExclusionError.invalid("Lease journal sync failed") }
            try requireSameFile()
            try requireContents(data)
            recordedBytes = data
        }
    }

    @_spi(OwnerService) public func resolveNativeOwnership() throws {
        try lock.withLock {
            guard recorded, !resolved, let recordedBytes else { throw ClusterDeviceExclusionError.invalid("No unresolved journal belongs to this device scope") }
            try requireSameFile()
            try requireContents(recordedBytes)
            guard ftruncate(descriptor, 0) == 0, fsync(descriptor) == 0 else { throw ClusterDeviceExclusionError.invalid("Lease clear failed") }
            resolved = true
        }
    }

    private func requireContents(_ expected: Data) throws {
        var information = stat()
        guard fstat(descriptor, &information) == 0, information.st_size == expected.count else {
            throw ClusterDeviceExclusionError.invalid("Native ownership journal content changed")
        }
        var bytes = [UInt8](repeating: 0, count: expected.count)
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeMutableBytes { Darwin.pread(descriptor, $0.baseAddress!.advanced(by: offset), $0.count - offset, off_t(offset)) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw ClusterDeviceExclusionError.invalid("Native ownership journal read failed") }
            offset += count
        }
        guard Data(bytes) == expected else { throw ClusterDeviceExclusionError.invalid("Native ownership journal content changed") }
    }

    private func requireSameFile() throws {
        var current = stat(), path = stat(), directoryNow = stat(), directoryName = stat()
        guard fstat(directory, &directoryNow) == 0, lstat(directoryPath, &directoryName) == 0,
              directoryNow.st_dev == directoryIdentity.st_dev, directoryNow.st_ino == directoryIdentity.st_ino,
              directoryName.st_dev == directoryIdentity.st_dev, directoryName.st_ino == directoryIdentity.st_ino,
              directoryNow.st_uid == geteuid(), directoryNow.st_mode & 0o077 == 0, directoryNow.st_nlink > 0,
              fstat(descriptor, &current) == 0, fstatat(directory, "native-device.lease", &path, AT_SYMLINK_NOFOLLOW) == 0,
              current.st_dev == identity.st_dev, current.st_ino == identity.st_ino,
              path.st_dev == identity.st_dev, path.st_ino == identity.st_ino, current.st_nlink == 1,
              current.st_uid == geteuid(), current.st_mode & S_IFMT == S_IFREG, current.st_mode & 0o077 == 0 else {
            throw ClusterDeviceExclusionError.invalid("Lease journal replaced")
        }
    }

    private static func openDirectory(_ url: URL) throws -> Int32 {
        let pieces = url.path.split(separator: "/", omittingEmptySubsequences: false)
        guard url.isFileURL, url.path.hasPrefix("/"), pieces.count > 1, url.path.utf8.count <= 4096,
              pieces.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !url.path.utf8.contains(where: { $0 < 32 || $0 == 127 }) else {
            throw ClusterDeviceExclusionError.invalid("Invalid lease directory")
        }
        var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw ClusterDeviceExclusionError.invalid("Cannot open lease directory root") }
        do {
            for piece in pieces.dropFirst() {
                let name = String(piece)
                var next = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0 && errno == ENOENT {
                    guard mkdirat(fd, name, 0o700) == 0 || errno == EEXIST else { throw ClusterDeviceExclusionError.invalid("Cannot create lease directory") }
                    next = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else { throw ClusterDeviceExclusionError.invalid("Lease directory is missing or follows a link") }
                Darwin.close(fd); fd = next
            }
            return fd
        } catch { Darwin.close(fd); throw error }
    }

    deinit { Darwin.close(descriptor); Darwin.close(directory) }
}
