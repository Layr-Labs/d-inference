/// Disk-backed overflow queue for telemetry events.
///
/// Format: JSONL (one JSON-encoded `TelemetryEvent` per line).
/// Location: `~/.darkbloom/telemetry-queue.jsonl`.
/// Size cap: 5 MB. On overflow, the oldest half of the file is discarded.
///
/// The queue is intentionally simple: open-for-append for writes, read+rewrite
/// for drains. It is NOT a cross-process durable queue -- one provider process
/// owns the file. A crash mid-write may lose the last partial line; that's
/// acceptable because telemetry is best-effort.

import Foundation
#if canImport(os)
import os
#endif

// MARK: - Overflow Queue

public final class TelemetryOverflowQueue: @unchecked Sendable {

    /// Shared instance. Uses the default path `~/.darkbloom/telemetry-queue.jsonl`.
    public static let shared = TelemetryOverflowQueue()

    /// Maximum size of the disk queue before rotation kicks in.
    private static let maxBytes: UInt64 = 5 * 1024 * 1024

    private let path: URL
    private let lock = NSLock()
    private let logger = Logger(subsystem: "dev.darkbloom.provider", category: "telemetry-queue")
    private let encoder = JSONEncoder()

    public init(path: URL? = nil) {
        if let path = path {
            self.path = path
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            self.path = home
                .appendingPathComponent(".darkbloom")
                .appendingPathComponent("telemetry-queue.jsonl")
        }
    }

    // MARK: - Push

    /// Append an event to the disk queue. Thread-safe.
    public func push(_ event: TelemetryEvent) {
        lock.lock()
        defer { lock.unlock() }

        guard let line = try? encoder.encode(event),
              let lineString = String(data: line, encoding: .utf8) else {
            return // unencodable -- best-effort drop
        }

        ensureParentDirectory()
        rotateIfNeeded()

        guard let handle = try? FileHandle(forWritingTo: path) else {
            // File doesn't exist yet -- create it.
            let content = lineString + "\n"
            try? content.write(to: path, atomically: false, encoding: .utf8)
            return
        }

        defer { try? handle.close() }
        handle.seekToEndOfFile()
        if let data = (lineString + "\n").data(using: .utf8) {
            handle.write(data)
        }
    }

    // MARK: - Drain

    /// Drain up to `limit` events from the head of the queue and rewrite the
    /// rest back to disk. Returns the drained events. Thread-safe.
    public func drain(limit: Int) -> [TelemetryEvent] {
        lock.lock()
        defer { lock.unlock() }

        guard FileManager.default.fileExists(atPath: path.path) else {
            return []
        }

        guard let content = try? String(contentsOf: path, encoding: .utf8) else {
            return []
        }

        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        let decoder = JSONDecoder()
        var drained: [TelemetryEvent] = []
        var remaining: [String] = []

        for line in lines {
            if drained.count < limit {
                if let data = line.data(using: .utf8),
                   let ev = try? decoder.decode(TelemetryEvent.self, from: data) {
                    drained.append(ev)
                }
                // Malformed lines: drop silently.
                continue
            }
            remaining.append(line)
        }

        // Rewrite the remaining lines atomically.
        let tmpPath = path.appendingPathExtension("tmp")
        let remainingContent = remaining.isEmpty ? "" : remaining.joined(separator: "\n") + "\n"

        if remaining.isEmpty {
            // Nothing left -- remove the file.
            try? FileManager.default.removeItem(at: path)
        } else {
            do {
                try remainingContent.write(to: tmpPath, atomically: true, encoding: .utf8)
                _ = try FileManager.default.replaceItemAt(path, withItemAt: tmpPath)
            } catch {
                // Best-effort: try a simple overwrite.
                try? remainingContent.write(to: path, atomically: true, encoding: .utf8)
                try? FileManager.default.removeItem(at: tmpPath)
            }
        }

        return drained
    }

    // MARK: - Rotation

    /// Trim the queue to its most recent half when it grows past `maxBytes`.
    /// Caller must hold `lock`.
    private func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
              let size = attrs[.size] as? UInt64,
              size > Self.maxBytes else {
            return
        }

        guard let content = try? String(contentsOf: path, encoding: .utf8) else {
            return
        }

        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        let keepFrom = lines.count / 2
        let kept = Array(lines[keepFrom...])
        let newContent = kept.joined(separator: "\n") + "\n"
        try? newContent.write(to: path, atomically: true, encoding: .utf8)

        logger.debug("Telemetry queue rotated: dropped \(keepFrom) old events, kept \(kept.count)")
    }

    /// Ensure the parent directory exists. Caller must hold `lock`.
    private func ensureParentDirectory() {
        let dir = path.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}

// MARK: - Logger shim

#if !canImport(os)
private struct Logger {
    let subsystem: String
    let category: String
    func debug(_ msg: String) { print("[\(category)] DEBUG: \(msg)") }
}
#endif
