import Darwin
import Foundation

enum SafeFile {
    /// Open the leaf without following symlinks. No model weights or prompt
    /// caches are read by the companion. Directory traversal is bounded below.
    static func read(_ url: URL, limit: Int = 1_048_576) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw ConnectError.unsafeFile }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0, info.st_size <= limit else { throw ConnectError.unsafeFile }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { return data }
            if count < 0 { if errno == EINTR { continue }; throw ConnectError.unsafeFile }
            guard count <= limit - data.count else { throw ConnectError.oversized }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
}
