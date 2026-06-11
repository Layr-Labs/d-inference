/// WatchdogState -- the watchdog's small, private cross-tick memory.
///
/// The watchdog runs as a one-shot every minute (launchd `StartInterval`), so
/// it can't hold the "provider has been down since T" timer in process memory.
/// It persists that here, at `~/.darkbloom/watchdog-state.json` (override with
/// `DARKBLOOM_WATCHDOG_STATE` for tests). The watchdog is the sole writer —
/// launchd never runs two ticks of the same job concurrently — so no locking is
/// needed.

import Foundation

public struct WatchdogState: Codable, Equatable, Sendable {
    /// Epoch seconds the watchdog first saw the provider down in the current
    /// outage, or nil when the provider is up.
    public var downSince: Double?
    /// Epoch seconds of the most recent watchdog-initiated restart (diagnostic).
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

    /// `~/.darkbloom/watchdog-state.json`, or the `DARKBLOOM_WATCHDOG_STATE`
    /// override.
    public static func path() -> URL {
        if let override = ProcessInfo.processInfo.environment["DARKBLOOM_WATCHDOG_STATE"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".darkbloom/watchdog-state.json")
    }

    /// Read the persisted state. Returns an empty (all-nil) state when the file
    /// is missing or unreadable — a fresh start, never an error.
    public static func read(from url: URL = WatchdogStateStore.path()) -> WatchdogState {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(WatchdogState.self, from: data)
        else {
            return WatchdogState()
        }
        return state
    }

    /// Atomically persist `state`. Best-effort: a failure to write must never
    /// crash the watchdog (worst case it re-arms the grace window next tick).
    public static func write(_ state: WatchdogState, to url: URL = WatchdogStateStore.path()) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(state)
            try data.write(to: url, options: .atomic)
        } catch {
            // Intentionally ignored — see doc comment.
        }
    }
}
