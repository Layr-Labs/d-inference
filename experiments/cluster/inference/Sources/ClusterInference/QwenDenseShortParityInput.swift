import Darwin
import Foundation

enum QwenDenseShortParityInput {
    /// Capture one regular, bounded raw token file through one descriptor.
    /// Nonblocking open refuses a FIFO before any potentially blocking read.
    static func tokens(_ url: URL, expectedSHA256: String) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw ProbeError("Short parity could not open its raw token file") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat(), after = stat()
        guard fstat(descriptor, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG,
              before.st_size > 0, before.st_size <= 4096 else {
            throw ProbeError("Short parity requires a regular token file of at most 4096 bytes")
        }
        let data = try handle.read(upToCount: 4097) ?? Data()
        guard data.count == Int(before.st_size), fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, before.st_mode == after.st_mode,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              QwenDenseProfileIdentity.isSHA256(expectedSHA256), sha256(data) == expectedSHA256 else {
            throw ProbeError("Short parity raw token bytes changed or differ from their pin")
        }
        try handle.close()
        return data
    }
}
