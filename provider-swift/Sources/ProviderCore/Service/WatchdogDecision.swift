/// WatchdogDecision -- the pure crash-recovery policy.
///
/// The watchdog (`darkbloom watchdog`, run every minute by `WatchdogAgent`)
/// answers one question each tick: *should I restart the provider right now?*
/// All of the I/O — querying launchd, reading the timer state, restarting —
/// lives in the command; this enum encodes the decision itself so it is
/// deterministic and exhaustively testable.
///
/// The policy distinguishes a **crash** from an **intentional stop** using the
/// launchd job state, which is exact (no guessing):
///
///   - The provider plist sets `KeepAlive = false`, so when the daemon crashes
///     launchd leaves the job *loaded but not running*. `providerLoaded == true
///     && providerRunning == false` is therefore the precise crash signal.
///   - `darkbloom stop` runs `launchctl bootout`, which *unloads* the job, and
///     `darkbloom stop --uninstall` additionally deletes the plist. Either way
///     `providerLoaded == false` — the user disabled it, so we never restart.
///   - `auto_restart = false` in the provider config is an explicit opt-out
///     that wins over everything (`autoRestartEnabled == false`).
///
/// A crashed provider is not restarted immediately: the caller arms a grace
/// window on first observation and only restarts once the daemon has stayed
/// down for `graceSeconds` (default 5 minutes). The delay sidesteps the
/// self-updater (its kill+relaunch completes in seconds) and prevents a
/// genuinely broken binary from tight-looping.

import Foundation

public enum WatchdogDecision: Equatable, Sendable {
    /// Auto-restart is disabled by config — clear any pending timer, do nothing.
    case disabled
    /// The provider isn't managed by launchd right now (stopped via `bootout`,
    /// or uninstalled). Not a crash — clear any timer, do nothing.
    case notManaged
    /// The provider is running normally — clear any pending timer.
    case healthy
    /// First tick that observed the provider down — start the grace window
    /// (caller persists `downSince = now`).
    case startGrace
    /// The provider is down but still inside the grace window; `remaining`
    /// seconds until it becomes eligible for restart.
    case waiting(remaining: Double)
    /// The provider has been down for at least `graceSeconds` — restart it.
    case restart
}

public enum WatchdogPolicy {

    /// Default grace period before a crashed provider is restarted: 5 minutes.
    public static let defaultGraceSeconds: Double = 300

    /// Decide what the watchdog should do this tick.
    ///
    /// - Parameters:
    ///   - autoRestartEnabled: provider config `auto_restart` (false = opt-out).
    ///   - providerLoaded: launchd has the provider job registered (loaded).
    ///   - providerRunning: the provider process is actually alive.
    ///   - downSince: epoch seconds the watchdog first observed the provider
    ///     down, or nil if it wasn't down on the previous tick.
    ///   - now: current epoch seconds.
    ///   - graceSeconds: how long the provider must stay down before a restart.
    public static func decide(
        autoRestartEnabled: Bool,
        providerLoaded: Bool,
        providerRunning: Bool,
        downSince: Double?,
        now: Double,
        graceSeconds: Double = defaultGraceSeconds
    ) -> WatchdogDecision {
        guard autoRestartEnabled else { return .disabled }
        guard providerLoaded else { return .notManaged }
        if providerRunning { return .healthy }

        guard let downSince else { return .startGrace }

        let elapsed = now - downSince
        if elapsed >= graceSeconds { return .restart }
        return .waiting(remaining: max(0, graceSeconds - elapsed))
    }

    /// Discard a `downSince` that predates the current boot. A timer armed in a
    /// previous uptime is meaningless after a reboot — both the provider and the
    /// watchdog reload via RunAtLoad at login, and we want a *fresh* grace window
    /// per outage, not an instant restart driven by a days-old timestamp. If
    /// `bootTime` is unavailable (nil), the value is passed through unchanged.
    public static func effectiveDownSince(_ downSince: Double?, bootTime: Double?) -> Double? {
        guard let downSince else { return nil }
        if let bootTime, downSince < bootTime { return nil }
        return downSince
    }

    /// The timer state to persist after acting on `decision`, or nil when no
    /// write is needed. Pure, so the watchdog's persistence logic is unit-tested
    /// independently of launchd I/O.
    public static func nextState(
        for decision: WatchdogDecision,
        current: WatchdogState,
        now: Double
    ) -> WatchdogState? {
        switch decision {
        case .restart:
            // Window consumed; record the attempt and re-arm fresh next tick.
            return WatchdogState(downSince: nil, lastRestartAt: now)
        case .startGrace:
            return WatchdogState(downSince: now, lastRestartAt: current.lastRestartAt)
        case .waiting:
            return nil // leave the armed window untouched
        case .disabled, .notManaged, .healthy:
            // Clear an armed window, but skip the write when nothing changes so
            // quiet ticks don't churn the file.
            return current.downSince == nil
                ? nil
                : WatchdogState(downSince: nil, lastRestartAt: current.lastRestartAt)
        }
    }
}
