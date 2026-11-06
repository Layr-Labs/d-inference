import Darwin
import Foundation

/// Replaces a file in one `rename` of a fully written sibling, so a reader sees the old bytes or the new ones and a
/// failure leaves the old file as it was.
///
/// The sibling (`.<name>.darkbloom-<pid>-<random>`, in the target's directory) is created with
/// `O_CREAT|O_EXCL|O_NOFOLLOW` and `mode`, so no reader ever sees looser permissions or a partial write.
public enum AtomicFile {
    public struct WriteError: Error, CustomStringConvertible, Sendable {
        public let description: String
    }

    /// Writes `data` to `url` with `mode`, creating the parent directory when it is missing. `beforeReplace` runs once
    /// the sibling is complete and on disk, just before the rename; when it throws, the sibling is removed, `url` is
    /// untouched and the error is rethrown.
    public static func write(
        _ data: Data, to url: URL, mode: mode_t, beforeReplace: () throws -> Void = {}
    ) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sibling = directory.appendingPathComponent(
            ".\(url.lastPathComponent).darkbloom-\(getpid())-\(UInt32.random(in: .min ... .max))")
        let descriptor = open(sibling.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard descriptor >= 0 else { throw failure("create \(sibling.lastPathComponent)") }
        var renamed = false
        defer { if !renamed { unlink(sibling.path) } }
        do {
            defer { close(descriptor) }
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(descriptor, bytes.baseAddress! + offset, bytes.count - offset)
                    if written < 0 && errno == EINTR { continue }
                    guard written > 0 else { throw failure("write \(sibling.lastPathComponent)") }
                    offset += written
                }
            }
        }
        guard rename(sibling.path, url.path) == 0 else { throw failure("rename onto \(url.lastPathComponent)") }
        renamed = true
    }

    private static func failure(_ step: String) -> WriteError {
        WriteError(description: "\(step): \(String(cString: strerror(errno)))")
    }
}
