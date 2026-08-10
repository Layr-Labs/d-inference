/// Disk-backed overflow queue for telemetry events.
///
/// Format: JSONL (one JSON-encoded `TelemetryEvent` per line).
/// Location: `~/.darkbloom/telemetry-queue.jsonl`.
/// Size cap: 5 MB. On overflow, the oldest half of the file is discarded.
///
/// The queue is intentionally simple: open-for-append for writes, read+rewrite
/// for drains. TWO processes share the file: the daemon (panic hook pushes,
/// TelemetryClient drains) and the persistent watchdog (crash-loop guard trip
/// events, `KVBackendCrashLoopGuard`). A drain is a read-then-replace, so an
/// unsynchronized watchdog push landing between the daemon's read and its
/// replace would be silently clobbered — and the trip event is exactly the one
/// operators alert on. Every mutation therefore takes an exclusive `flock` on
/// a dedicated sidecar lock file (`<queue>.lock`) in addition to the
/// in-process NSLock:
///
///   * the LOCK FILE, not the queue file, is flocked — a drain replaces the
///     queue's inode (`replaceItemAt`), and a lock taken on the old inode
///     would not exclude a writer that opened the path after the swap. The
///     sidecar is created once and never replaced, so the lock identity is
///     stable across drains.
///   * `flock` over `NSFileCoordinator`: both processes are plain CLI
///     processes on one machine writing one small file — flock is the
///     smallest primitive that gives cross-process mutual exclusion, needs no
///     coordination daemon, and (unlike a watchdog-suffixed second queue)
///     leaves ONE file with ONE drain path instead of a merge-and-ordering
///     question at every consumer.
///   * fail-open: if the lock file cannot be opened or flocked, the mutation
///     proceeds unlocked. Telemetry is best-effort; a lock failure must never
///     make the daemon drop events it could have written, and the pre-lock
///     behavior is the worst case.
///
/// A crash mid-write may lose the last partial line; that's acceptable
/// because telemetry is best-effort.

import Foundation
#if canImport(os)
import os
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
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

    // MARK: - Cross-process lock

    /// Acquire the exclusive cross-process lock (see the header). Returns the
    /// open lock-file descriptor, or nil on failure (the caller proceeds
    /// unlocked — fail-open). Caller must hold `lock` and must pass the
    /// result to `releaseFileLock`.
    private func acquireFileLock() -> Int32? {
        ensureParentDirectory()
        let lockPath = path.path + ".lock"
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX) == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    private func releaseFileLock(_ fd: Int32?) {
        guard let fd else { return }
        flock(fd, LOCK_UN)
        close(fd)
    }

    // MARK: - Push

    /// Append an event to the disk queue. Thread-safe within the process and
    /// across processes (daemon + watchdog — see the header).
    public func push(_ event: TelemetryEvent) {
        lock.lock()
        defer { lock.unlock() }
        let fileLock = acquireFileLock()
        defer { releaseFileLock(fileLock) }

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
    /// rest back to disk. Returns the drained events. Thread-safe within the
    /// process and across processes: the read-then-replace runs under the
    /// exclusive file lock, so a concurrent watchdog push cannot land between
    /// the read and the replace and be clobbered.
    public func drain(limit: Int) -> [TelemetryEvent] {
        lock.lock()
        defer { lock.unlock() }
        let fileLock = acquireFileLock()
        defer { releaseFileLock(fileLock) }

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
