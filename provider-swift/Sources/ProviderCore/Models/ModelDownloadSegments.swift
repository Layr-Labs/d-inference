/// Ranged model-file downloads: how many byte ranges one large manifest file
/// is fetched over (`DARKBLOOM_DOWNLOAD_SEGMENTS`), and the resumable on-disk
/// state of such a download (a pre-sized `.part` plus its range record, and
/// the writer that keeps them). The transfer itself is in
/// `ModelDownloader+Segments.swift`.

import Darwin
import Foundation

enum ModelDownloadSegments {
    static let environmentKey = "DARKBLOOM_DOWNLOAD_SEGMENTS"
    static let defaultCount = 4
    static let maximumCount = 8
    /// Connections one download opens at most, over every file it fetches at once.
    static let maximumConnections = 16
    /// Smaller files stay on one connection: a probe and several connections
    /// would cost about what they save.
    static let minimumFileBytes: Int64 = 256 << 20

    /// Unset or unreadable: `defaultCount`. `1`, `0` or an off word (`off`,
    /// `false`, `no`; trimmed, any case): one connection per file, the
    /// single-stream download. `2`…`8`: that many ranges; more is `8`.
    static func count(environment: [String: String] = ProcessInfo.processInfo.environment) -> Int {
        guard let raw = environment[environmentKey]?.trimmingCharacters(in: .whitespaces).lowercased(),
              !raw.isEmpty else { return defaultCount }
        if ["0", "off", "false", "no"].contains(raw) { return 1 }
        guard let value = Int(raw), value >= 1 else { return defaultCount }
        return min(value, maximumCount)
    }

    /// Ranges per file when `filesAtOnce` files download together, so that
    /// all of them open at most `maximumConnections` connections.
    static func perFile(requested: Int, filesAtOnce: Int) -> Int {
        max(1, min(requested, maximumConnections / max(1, filesAtOnce)))
    }
}

/// The byte ranges of a ranged download and how many bytes of each are on
/// disk, saved beside the `.part` (`SegmentedPartFile.recordURL`). A range's
/// `done` bytes are always its first ones, written and synced before the
/// record that counts them is saved.
struct SegmentedPartLayout: Codable, Equatable {
    struct ByteRange: Codable, Equatable {
        let start: Int64
        /// Exclusive.
        let end: Int64
        var done: Int64

        var length: Int64 { end - start }
        var isComplete: Bool { done == length }
        /// The next byte this range still needs.
        var next: Int64 { start + done }
    }

    static let currentVersion = 1

    let version: Int
    let size: Int64
    var ranges: [ByteRange]

    /// `count` equal ranges over `size` bytes (the last takes the remainder),
    /// crediting the `prefix` bytes a single-stream `.part` already holds.
    static func planned(size: Int64, count: Int, prefix: Int64) -> SegmentedPartLayout {
        let count = Int64(max(1, min(count, Int(clamping: max(1, size)))))
        let length = size / count
        let ranges = (0..<count).map { index -> ByteRange in
            let start = index * length
            let end = index == count - 1 ? size : start + length
            return ByteRange(start: start, end: end, done: min(max(0, prefix - start), end - start))
        }
        return SegmentedPartLayout(version: currentVersion, size: size, ranges: ranges)
    }

    var doneBytes: Int64 { ranges.reduce(0) { $0 + $1.done } }

    /// Bytes from offset 0 that are on disk with no gap.
    var contiguousPrefix: Int64 {
        var prefix: Int64 = 0
        for range in ranges {
            prefix += range.done
            guard range.isComplete else { break }
        }
        return prefix
    }

    /// The record describes `size` bytes in contiguous ranges from offset 0,
    /// and every byte it counts lies inside the `.part` as it is now.
    func isConsistent(size expected: Int64, partBytes: Int64) -> Bool {
        guard version == Self.currentVersion, size == expected, size > 0, partBytes <= size,
              let first = ranges.first, first.start == 0, ranges.last?.end == size else { return false }
        for (index, range) in ranges.enumerated() {
            guard range.start < range.end, (0...range.length).contains(range.done),
                  index == 0 || ranges[index - 1].end == range.start,
                  range.done == 0 || range.next <= partBytes else { return false }
        }
        return true
    }
}

/// The resumable state of one file's ranged download: its `.part`, pre-sized
/// to the manifest size (sparse until written), and the range record beside it.
/// A `.part` without a record is a single-stream prefix, as before.
enum SegmentedPartFile {
    enum Saved: Equatable {
        /// No record: any `.part` is a single-stream prefix.
        case noRecord
        case valid(SegmentedPartLayout)
        /// A record that cannot be read or does not match the `.part`: none of
        /// the `.part`'s bytes can be accounted for.
        case unusable
    }

    static func recordURL(for partial: URL) -> URL {
        partial.appendingPathExtension("segments")
    }

    static func saved(partial: URL, size: Int64) -> Saved {
        let record = recordURL(for: partial)
        guard FileManager.default.fileExists(atPath: record.path) else { return .noRecord }
        guard let data = try? Data(contentsOf: record),
              let layout = try? JSONDecoder().decode(SegmentedPartLayout.self, from: data),
              layout.isConsistent(size: size, partBytes: byteCount(partial)) else { return .unusable }
        return .valid(layout)
    }

    /// Bytes of the file already downloaded and accounted for: the record's
    /// counted bytes, else a single-stream `.part`'s length. Never the
    /// pre-sized `.part`'s apparent size.
    static func accountedBytes(partial: URL, size: Int64) -> Int64 {
        switch saved(partial: partial, size: size) {
        case .noRecord: return byteCount(partial)
        case .valid(let layout): return layout.doneBytes
        case .unusable: return 0
        }
    }

    /// The layout to resume, after making the `.part` match it: a usable
    /// record as saved, else `count` new ranges crediting a single-stream
    /// prefix. The record is saved before the `.part` grows, so a stop in
    /// between leaves a prefix the record still describes.
    static func prepare(partial: URL, size: Int64, count: Int) throws -> SegmentedPartLayout {
        let layout: SegmentedPartLayout
        switch saved(partial: partial, size: size) {
        case .valid(let saved):
            layout = saved
        case .unusable:
            try remove(partial: partial)
            layout = .planned(size: size, count: count, prefix: 0)
            try save(layout, partial: partial)
        case .noRecord:
            var prefix = byteCount(partial)
            if prefix > size {
                try FileManager.default.removeItem(at: partial)
                prefix = 0
            }
            layout = .planned(size: size, count: count, prefix: prefix)
            try save(layout, partial: partial)
        }
        if !FileManager.default.fileExists(atPath: partial.path) {
            guard FileManager.default.createFile(atPath: partial.path, contents: nil) else {
                throw ModelCatalogError.downloadFailed("\(partial.lastPathComponent): could not create")
            }
        }
        if byteCount(partial) < size, Darwin.truncate(partial.path, off_t(size)) != 0 {
            throw ModelCatalogError.downloadFailed(
                "\(partial.lastPathComponent): could not size to \(size) bytes (\(String(cString: strerror(errno))))")
        }
        return layout
    }

    /// Atomic, so a stop mid-write leaves the previous record.
    static func save(_ layout: SegmentedPartLayout, partial: URL) throws {
        try JSONEncoder().encode(layout).write(to: recordURL(for: partial), options: .atomic)
    }

    /// Before a single-stream download of the file: keep the record's
    /// gap-free prefix as an ordinary `.part`, or nothing when the record is
    /// unusable. Without a record the `.part` is already a prefix.
    static func collapseToPrefix(partial: URL, size: Int64) throws {
        switch saved(partial: partial, size: size) {
        case .noRecord:
            return
        case .unusable:
            try remove(partial: partial)
        case .valid(let layout):
            if Darwin.truncate(partial.path, off_t(layout.contiguousPrefix)) != 0 {
                try remove(partial: partial)
                return
            }
            try removeRecord(partial: partial)
        }
    }

    /// The `.part` and its record.
    static func remove(partial: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: partial.path) { try fm.removeItem(at: partial) }
        try removeRecord(partial: partial)
    }

    static func removeRecord(partial: URL) throws {
        let record = recordURL(for: partial)
        if FileManager.default.fileExists(atPath: record.path) { try FileManager.default.removeItem(at: record) }
    }

    private static func byteCount(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }
}

/// Writes the ranges of one ranged download into its pre-sized `.part` and
/// keeps its record (`SegmentedPartFile`). Bytes are written at each range's
/// next offset; the record is saved only after the `.part` is synced, so it
/// never counts a byte that is not on disk. Progress (`onChunk`) is the sum of
/// every range's bytes, reported in order under one lock, so it only grows.
final class SegmentedPartWriter: @unchecked Sendable {
    /// Bytes written between two saves of the record.
    static let checkpointBytes: Int64 = 32 << 20

    let size: Int64
    /// The `.part`'s descriptor took `F_NOCACHE`: every `pwrite` on it skips the file cache.
    let cachingDisabled: Bool
    private let partial: URL
    private let descriptor: Int32
    private let onChunk: (@Sendable (Int64) -> Void)?

    private let lock = NSLock()
    private var layout: SegmentedPartLayout
    private var unsavedBytes: Int64 = 0
    private var closed = false
    /// Serializes record saves, so a later save never precedes an earlier one.
    private let checkpointLock = NSLock()

    init(partial: URL, layout: SegmentedPartLayout, uncached: Bool, onChunk: (@Sendable (Int64) -> Void)?) throws {
        let descriptor = Darwin.open(partial.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw ModelCatalogError.downloadFailed(
                "\(partial.lastPathComponent): could not open for writing (\(String(cString: strerror(errno))))")
        }
        self.descriptor = descriptor
        self.cachingDisabled = uncached && fcntl(descriptor, F_NOCACHE, 1) == 0
        self.partial = partial
        self.layout = layout
        self.size = layout.size
        self.onChunk = onChunk
        onChunk?(layout.doneBytes)
    }

    /// The bytes range `index` still needs; nil once it is complete.
    func remaining(_ index: Int) -> Range<Int64>? {
        lock.withLock {
            let range = layout.ranges[index]
            return range.isComplete ? nil : range.next..<range.end
        }
    }

    /// Write `data` at range `index`'s next offset. Only that range's one
    /// request calls this, one chunk at a time.
    func write(_ data: Data, range index: Int) throws {
        let (offset, end, open) = lock.withLock { (layout.ranges[index].next, layout.ranges[index].end, !closed) }
        let count = Int64(data.count)
        guard open else { throw CancellationError() }
        guard count <= end - offset else {
            throw ModelCatalogError.downloadFailed("\(partial.lastPathComponent): response exceeds its byte range")
        }
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var written = 0
            while written < buffer.count {
                let result = Darwin.pwrite(descriptor, buffer.baseAddress! + written, buffer.count - written,
                                           off_t(offset) + off_t(written))
                if result < 0 {
                    if errno == EINTR { continue }
                    throw ModelCatalogError.downloadFailed(
                        "\(partial.lastPathComponent): write failed (\(String(cString: strerror(errno))))")
                }
                written += result
            }
        }
        let checkpointDue: Bool = lock.withLock {
            layout.ranges[index].done += count
            onChunk?(layout.doneBytes)
            unsavedBytes += count
            guard unsavedBytes >= Self.checkpointBytes else { return false }
            unsavedBytes = 0
            return true
        }
        if checkpointDue { try checkpoint() }
    }

    /// Sync the `.part`, then save the record of what was written before the sync.
    func checkpoint() throws {
        try checkpointLock.withLock {
            let snapshot = lock.withLock { layout }
            guard fsync(descriptor) == 0 else {
                throw ModelCatalogError.downloadFailed(
                    "\(partial.lastPathComponent): sync failed (\(String(cString: strerror(errno))))")
            }
            try SegmentedPartFile.save(snapshot, partial: partial)
        }
    }

    /// Save the record a last time and close the `.part`. Idempotent.
    func close() throws {
        let first = lock.withLock { () -> Bool in
            defer { closed = true }
            return !closed
        }
        guard first else { return }
        defer { Darwin.close(descriptor) }
        try checkpoint()
    }
}
