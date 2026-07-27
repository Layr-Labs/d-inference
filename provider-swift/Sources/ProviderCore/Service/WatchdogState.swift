/// The watchdog's cross-tick timer, persisted at
/// `~/.darkbloom/watchdog-state.json` (override `DARKBLOOM_WATCHDOG_STATE`).
/// The single persistent watchdog process is the only writer, and its
/// scheduler runs ticks strictly sequentially — ticks never overlap.

import Foundation

public struct WatchdogState: Codable, Equatable, Sendable {
    /// When the watchdog first saw the current outage, or nil when up.
    public var downSince: Double?
    /// When the watchdog last restarted the provider. Policy-bearing since
    /// the crash-loop guard: it is the base the NEXT restart's uptime is
    /// measured from (`WatchdogPolicy.crashLoopCount`), no longer merely
    /// diagnostic.
    public var lastRestartAt: Double?
    /// The INSTALLED daemon version the last restart booted (resolved by the
    /// recovery flow through `SelfUpdater.effectiveInstalledVersion` — the
    /// same source the KV-backend guard stamp uses, so the two can never
    /// disagree). The crash-loop chain is scoped to this version: a restart
    /// of a DIFFERENT installed version starts a fresh chain
    /// (`WatchdogPolicy.versionScopedCrashLoopCount`) — the old binary's
    /// crashes must not be charged against the release that replaced it.
    /// nil in pre-guard state files and when the degraded (session-less)
    /// restart path could not resolve a version.
    public var lastRestartVersion: String?
    /// Consecutive crash-loop-SHAPED restarts (each issued after the
    /// provider stayed up less than
    /// `WatchdogPolicy.crashLoopUptimeBoundSeconds` since the previous
    /// restart). Reset to 0 once a healthy provider outlives that bound,
    /// and restarted at 1 when a restart follows long uptime. At
    /// `WatchdogPolicy.crashLoopTripThreshold` the recovery path persists
    /// the KV-backend guard (`KVBackendGuard`).
    public var consecutiveCrashLoopRestarts: Int

    public init(
        downSince: Double? = nil,
        lastRestartAt: Double? = nil,
        lastRestartVersion: String? = nil,
        consecutiveCrashLoopRestarts: Int = 0
    ) {
        self.downSince = downSince
        self.lastRestartAt = lastRestartAt
        self.lastRestartVersion = lastRestartVersion
        self.consecutiveCrashLoopRestarts = consecutiveCrashLoopRestarts
    }

    enum CodingKeys: String, CodingKey {
        case downSince = "down_since"
        case lastRestartAt = "last_restart_at"
        case lastRestartVersion = "last_restart_version"
        case consecutiveCrashLoopRestarts = "consecutive_crash_loop_restarts"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        downSince = try container.decodeIfPresent(Double.self, forKey: .downSince)
        lastRestartAt = try container.decodeIfPresent(Double.self, forKey: .lastRestartAt)
        // Absent in pre-guard state files (nil is the "cannot prove chain
        // continuity" signal — see `versionScopedCrashLoopCount`).
        lastRestartVersion =
            try container.decodeIfPresent(String.self, forKey: .lastRestartVersion)
        // Absent in every pre-guard state file. Defaulted rather than left
        // to fail the decode: `WatchdogStateStore.read` maps a failed decode
        // to a FRESH state, which would silently discard a live `downSince`
        // window on the first post-upgrade tick.
        consecutiveCrashLoopRestarts =
            try container.decodeIfPresent(Int.self, forKey: .consecutiveCrashLoopRestarts) ?? 0
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

    /// Upper bound a genuinely-accumulated crash-loop counter can plausibly
    /// reach. The counter increments at most once per issued restart and a
    /// restart costs at least the ~5-minute grace window, so nonstop looping
    /// accrues ~100k/year; 1,000,000 is roughly a decade of it. Anything
    /// beyond did not come from this watchdog — it is a corrupt or hostile
    /// file.
    public static let maxPlausibleCrashLoopRestarts = 1_000_000

    /// Empty state when the file is missing, unreadable, or SEMANTICALLY
    /// corrupt (a fresh start — the same fail-open posture as an
    /// undecodable file).
    ///
    /// Semantic bounds matter because valid JSON can still carry a counter
    /// no honest run produces: `consecutive_crash_loop_restarts: Int.max`
    /// decodes fine and would trap the `+ 1` in
    /// `WatchdogPolicy.crashLoopCount` before recovery could act — and
    /// launchd restarts the crashed watchdog against the same file, turning
    /// one corrupt write into a permanent watchdog crash loop. A negative or
    /// implausibly large counter therefore rejects the whole file. (The
    /// arithmetic in `crashLoopCount` is additionally saturating, so even a
    /// state constructed around this validation cannot trap.)
    public static func read(from url: URL = WatchdogStateStore.path()) -> WatchdogState {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(WatchdogState.self, from: data),
              state.consecutiveCrashLoopRestarts >= 0,
              state.consecutiveCrashLoopRestarts <= maxPlausibleCrashLoopRestarts
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
