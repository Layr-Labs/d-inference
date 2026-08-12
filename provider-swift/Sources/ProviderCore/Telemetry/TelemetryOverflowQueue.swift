/// Privacy-disabled compatibility facade for the retired telemetry disk queue.
///
/// Older provider builds wrote free-form events to
/// `~/.darkbloom/telemetry-queue.jsonl`. New builds retain the source API only
/// so crash/watchdog call sites cannot revive the sink during a mixed-version
/// rollout. Every push is dropped, every drain is empty, and purge removes only
/// the two exact legacy queue artifacts.

import Foundation

public final class TelemetryOverflowQueue: @unchecked Sendable {
    public static let shared = TelemetryOverflowQueue()

    private let path: URL
    private let lock = NSLock()

    public init(path: URL? = nil) {
        if let path {
            self.path = path
        } else {
            self.path = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".darkbloom")
                .appendingPathComponent("telemetry-queue.jsonl")
        }
    }

    /// Deliberately drops every event before encoding or I/O.
    public func push(_ event: TelemetryEvent) {
        _ = event
    }

    /// The retired queue can never produce an event.
    public func drain(limit: Int) -> [TelemetryEvent] {
        _ = limit
        return []
    }

    /// Removes data persisted by an older build without creating a directory,
    /// lock file, or replacement artifact when nothing exists.
    public func purge() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: path)
        try? FileManager.default.removeItem(at: path.appendingPathExtension("tmp"))
    }
}
