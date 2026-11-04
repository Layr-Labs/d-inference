import Darwin
import Foundation

/// Persists active holds so a restarted or updated provider comes back held.
/// Owner-only like the lifecycle mailbox: `0600` file in the `0700` runtime
/// directory, written by atomic rename, read without following links or
/// blocking: a FIFO at the path would otherwise wait for a writer forever.
struct AddonHoldStore: Sendable {
    enum Contents: Sendable, Equatable {
        case absent
        case holds([AddonHold])
        /// Present but not a valid owner-only record.
        case invalid
    }

    private struct Record: Codable {
        static let currentSchema = 1
        var schema: Int
        var holds: [AddonHold]
    }

    static let maximumBytes = 64 * 1024

    let url: URL

    func read() -> Contents {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return errno == ENOENT ? .absent : .invalid }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o077 == 0, info.st_size <= Self.maximumBytes,
              let data = try? file.read(upToCount: Self.maximumBytes + 1),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.schema == Record.currentSchema,
              record.holds.allSatisfy({ AddonHold.leaseSecondsRange.contains($0.leaseSeconds) }) else {
            return .invalid
        }
        return .holds(record.holds)
    }

    /// No active hold removes the record: its absence means "not held".
    func write(_ holds: [AddonHold]) throws {
        guard !holds.isEmpty else {
            if unlink(url.path) != 0, errno != ENOENT { throw CocoaError(.fileWriteUnknown) }
            return
        }
        let directory = url.deletingLastPathComponent()
        try AddonRuntimeDirectory.prepare(directory)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Record(schema: Record.currentSchema, holds: holds))
        let temporary = directory.appendingPathComponent(".addon-hold-\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close(); unlink(temporary.path) }
        try file.write(contentsOf: data)
        try file.synchronize()
        guard rename(temporary.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}
