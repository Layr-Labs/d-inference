import Foundation
import Darwin

/// Bounded, exclusive, private sidecar. Failure may retain a partial new file;
/// it never replaces or removes an existing path. A successful file alone is
/// not a successful process or independent request-correctness receipt.
enum QwenPrefillPhaseFile {
    static let maximumBytes = 512 * 1024

    static func preflight(_ output: URL) throws {
        guard output.isFileURL, output.path.hasPrefix("/"), !output.lastPathComponent.isEmpty else {
            throw QwenPrefillPhaseError("Phase output requires a file path")
        }
        var information = stat()
        let status = output.path.withCString { lstat($0, &information) }
        guard status == -1, errno == ENOENT else {
            throw QwenPrefillPhaseError("Phase output must be a new path")
        }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: output.deletingLastPathComponent().path,
                                             isDirectory: &directory), directory.boolValue else {
            throw QwenPrefillPhaseError("Phase output parent must already exist")
        }
    }

    static func write(_ trace: QwenPrefillPhaseTrace, to output: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(trace)
        data.append(10)
        guard data.count <= maximumBytes else {
            throw QwenPrefillPhaseError("Phase sidecar exceeds its byte bound")
        }
        let descriptor = output.path.withCString {
            open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        }
        guard descriptor >= 0 else {
            throw QwenPrefillPhaseError("Cannot exclusively create phase sidecar (errno \(errno))")
        }
        var closed = false
        defer { if !closed { close(descriptor) } }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw QwenPrefillPhaseError("Cannot set private phase sidecar permissions (errno \(errno))")
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else {
                    throw QwenPrefillPhaseError("Cannot write phase sidecar (errno \(errno))")
                }
                offset += written
            }
        }
        let status = close(descriptor)
        closed = true
        guard status == 0 else {
            throw QwenPrefillPhaseError("Cannot close phase sidecar (errno \(errno))")
        }
    }
}
