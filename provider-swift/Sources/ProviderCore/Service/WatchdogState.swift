/// The watchdog's cross-tick timer, persisted at
/// `~/.darkbloom/watchdog-state.json` (override `DARKBLOOM_WATCHDOG_STATE`).
/// The watchdog is the only writer — launchd never overlaps ticks.

import Foundation

public struct WatchdogState: Codable, Equatable, Sendable {
    /// When the watchdog first saw the current outage, or nil when up.
    public var downSince: Double?
    /// When the watchdog last restarted the provider (diagnostic).
    public var lastRestartAt: Double?

    public init(downSince: Double? = nil, lastRestartAt: Double? = nil) {
        self.downSince = downSince
        self.lastRestartAt = lastRestartAt
    }

    enum CodingKeys: String, CodingKey {
        case downSince = "down_since"
        case lastRestartAt = "last_restart_at"
    }
}

public enum WatchdogStateStore {

    public static func path() -> URL {
        if let override = ProcessInfo.processInfo.environment["DARKBLOOM_WATCHDOG_STATE"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".darkbloom/watchdog-state.json")
    }

    /// Empty state when the file is missing or unreadable (a fresh start).
    public static func read(from url: URL = WatchdogStateStore.path()) -> WatchdogState {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(WatchdogState.self, from: data)
        else { return WatchdogState() }
        return state
    }

    /// Atomically persist `state`. Returns false on failure so the caller can
    /// log it: a persistent write failure would otherwise keep the grace window
    /// from ever advancing, silently disabling recovery.
    @discardableResult
    public static func write(_ state: WatchdogState, to url: URL = WatchdogStateStore.path()) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(state).write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
