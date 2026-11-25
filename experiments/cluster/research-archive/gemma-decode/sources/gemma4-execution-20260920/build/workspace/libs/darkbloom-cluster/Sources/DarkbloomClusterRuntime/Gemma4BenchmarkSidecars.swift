import Darwin
import Foundation

/// Exclusive durable sidecars. Failed operations leave partial evidence in place.
final class Gemma4BenchmarkSidecars {
    private let directory: String, fd: Int32, identity: stat
    private(set) var files: [Gemma4ShortFile] = []
    private var totalBytes = 0

    init(directory: String) throws {
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        guard url.deletingLastPathComponent().resolvingSymlinksInPath().path == url.deletingLastPathComponent().path,
              mkdir(directory, 0o700) == 0 else { throw ProbeError("Gemma evidence directory must be fresh beneath a canonical parent") }
        let handle = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard handle >= 0 else { throw ProbeError("Gemma evidence directory open failed") }
        var info = stat()
        guard fstat(handle, &info) == 0, info.st_uid == geteuid(), (info.st_mode & 0o777) == 0o700,
              (info.st_mode & S_IFMT) == S_IFDIR else {
            close(handle); throw ProbeError("Gemma evidence directory ownership/mode differs")
        }
        self.directory = directory; fd = handle; identity = info
    }
    deinit { close(fd) }

    private func requireDirectory() throws {
        var path = stat(), opened = stat()
        guard lstat(directory, &path) == 0, fstat(fd, &opened) == 0,
              path.st_dev == identity.st_dev, path.st_ino == identity.st_ino,
              opened.st_dev == identity.st_dev, opened.st_ino == identity.st_ino,
              path.st_uid == geteuid(), (path.st_mode & 0o777) == 0o700,
              (path.st_mode & S_IFMT) == S_IFDIR else { throw ProbeError("Gemma evidence directory identity changed") }
    }

    func write(_ name: String, data: Data, check: () throws -> Void) throws -> Gemma4ShortFile {
        try check(); try requireDirectory()
        guard (1...128).contains(name.utf8.count), name.utf8.allSatisfy({
            (48...57).contains($0) || (97...122).contains($0) || [45,46,95].contains($0)
        }), !name.hasPrefix("."), !files.contains(where: { $0.name == name }), files.count < 512,
              (1...67_108_864).contains(data.count), totalBytes <= 4_294_967_296 - data.count else {
            throw ProbeError("Gemma sidecar name/count/byte bound differs")
        }
        let file = openat(fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw ProbeError("Gemma sidecar must be a new exclusive regular file") }
        defer { close(file) }
        var initial = stat()
        guard fstat(file, &initial) == 0, (initial.st_mode & S_IFMT) == S_IFREG,
              initial.st_uid == geteuid(), (initial.st_mode & 0o777) == 0o600, initial.st_nlink == 1 else {
            throw ProbeError("Gemma sidecar owner/type/mode differs")
        }
        // Evidence is outside request timing and is read only after owner retirement.
        // Avoid retaining its data pages across the next measured request.
        // All original writes, fsync, identity checks and byte bounds remain.
        guard fcntl(file, F_NOCACHE, 1) == 0 else {
            throw ProbeError("Gemma sidecar uncached IO policy failed")
        }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                try check()
                let n = Darwin.write(file, buffer.baseAddress!.advanced(by: offset), min(65_536, buffer.count-offset))
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw ProbeError("Gemma sidecar write failed") }; offset += n
            }
        }
        try check()
        guard fsync(file) == 0, fsync(fd) == 0 else { throw ProbeError("Gemma sidecar durability failed") }
        try requireDirectory()
        var final = stat(), path = stat()
        guard fstat(file, &final) == 0, fstatat(fd, name, &path, AT_SYMLINK_NOFOLLOW) == 0,
              final.st_dev == initial.st_dev, final.st_ino == initial.st_ino,
              path.st_dev == final.st_dev, path.st_ino == final.st_ino,
              final.st_size == data.count, final.st_nlink == 1, final.st_uid == geteuid(),
              (final.st_mode & 0o777) == 0o600 else { throw ProbeError("Gemma sidecar identity/length changed") }
        let receipt = Gemma4ShortFile(name: name, bytes: data.count, sha256: sha256(data))
        files.append(receipt); totalBytes += data.count; try check(); return receipt
    }
}
