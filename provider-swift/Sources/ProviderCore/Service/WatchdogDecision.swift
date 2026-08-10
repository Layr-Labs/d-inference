/// The crash-recovery policy (pure, no I/O).
///
/// A crash = the provider's launchd job is loaded but not running (`KeepAlive=false`
/// leaves a crashed job loaded). `darkbloom stop` unloads it (`bootout` +
/// persistent `launchctl disable`), so `providerLoaded == false` means the user
/// disabled it — never restarted.
/// `auto_restart = false` opts out. A crashed provider is restarted only after it
/// stays down `graceSeconds` (default 5 min): long enough to clear the
/// self-updater's kill+relaunch and to avoid tight crash-loops.

import Foundation

public enum WatchdogDecision: Equatable, Sendable {
    case disabled                    // auto_restart = false
    case notManaged                  // unloaded: stopped/uninstalled, not a crash
    case healthy                     // running with no attributable stale heartbeat
    case startGrace                  // first tick down: arm the window
    case waiting(remaining: Double)  // down, inside the grace window
    case restart                     // down >= grace
}

public enum WatchdogPolicy {

    /// Grace before a crashed provider is restarted: 5 minutes.
    public static let defaultGraceSeconds: Double = 300

    /// Crash-loop shape bound: a restart counts as CONSECUTIVE with the
    /// previous one when the provider stayed up less than this in between
    /// (measured `downSince − lastRestartAt`, both watchdog-observed).
    ///
    /// 15 minutes, because the bound has to separate two populations:
    ///
    ///   * A paged defect kills the daemon at model load or first decode —
    ///     within seconds-to-minutes of the kickstart, well under the bound
    ///     even after adding the watchdog's ≤60 s detection tick and the
    ///     slowest fleet box's full startup (spawn + config + attestation +
    ///     the largest model's preload, minutes at worst).
    ///   * A box that came up, SERVED, and died much later is not looping —
    ///     organic crashes are hours-to-days apart, so a 15-minute ceiling
    ///     keeps them from ever chaining to the trip threshold.
    ///
    /// The measurement over-counts uptime slightly (downSince lags the real
    /// crash by up to one tick; lastRestartAt precedes the real boot), which
    /// only biases AWAY from tripping — the safe direction.
    public static let crashLoopUptimeBoundSeconds: Double = 15 * 60

    /// Consecutive crash-loop-shaped restarts that trip the KV-backend
    /// guard. 3 deliberately equals `UpdateRecoveryState.rollbackThreshold`:
    /// the fleet already treats "3 failed starts" as the line between bad
    /// luck and a systemic defect, and the two counters watch the same
    /// restarts — with the binary rollback taking precedence when both
    /// could act (see `WatchdogRecoveryService.recoverDownProvider`).
    /// Three ~5-minute grace windows put the trip at roughly 15–20 minutes
    /// of outage, against the unbounded loop it replaces.
    public static let crashLoopTripThreshold = 3

    /// The consecutive-crash-loop counter value a restart issued NOW should
    /// persist, given the outage began at `effectiveDownSince` (the
    /// boot-filtered value `decide` used — never the raw persisted one).
    ///
    /// A restart CONTINUES the chain (`current + 1`) only when a previous
    /// restart exists and the provider's uptime after it stayed under the
    /// bound; anything else — first-ever restart, long uptime, or a missing
    /// outage timestamp — STARTS a chain at 1. A negative gap (clock
    /// rollback between the restart stamp and the outage stamp) counts as
    /// short: in a real loop the gap cannot be materially negative, and the
    /// guard's failure mode is benign (contiguous serving) while the
    /// crash loop's is not.
    public static func crashLoopCount(
        current: WatchdogState,
        effectiveDownSince: Double?,
        uptimeBoundSeconds: Double = crashLoopUptimeBoundSeconds
    ) -> Int {
        guard let lastRestartAt = current.lastRestartAt,
            let downSince = effectiveDownSince,
            downSince - lastRestartAt < uptimeBoundSeconds
        else { return 1 }
        // Total over ALL inputs — clamped-and-saturating, never trapping.
        // `WatchdogStateStore.read` already rejects semantically corrupt
        // counters (negative, absurd) as a corrupt file, but this pure
        // function must not rely on its callers' hygiene: a persisted
        // `Int.max` reaching a trapping `+ 1` here would crash the watchdog,
        // and launchd would relaunch it straight into the same state file
        // and the same trap — a permanent watchdog crash loop that disables
        // provider recovery entirely.
        let previous = max(0, current.consecutiveCrashLoopRestarts)
        let (chained, overflowed) = previous.addingReportingOverflow(1)
        return overflowed ? Int.max : chained
    }

    /// Scope a computed crash-loop count to the INSTALLED daemon version.
    ///
    /// The chain counted the RECORDED version's restarts. When the installed
    /// version differs — a self-update promoted a candidate, or a rollback
    /// restored the predecessor, since the last restart — this restart is the
    /// new binary's FIRST, not the old one's Nth: without the reset, a chain
    /// that reached the trip threshold on v0.8.0 would guard a promoted
    /// v0.8.1 on its first short-lived crash, defeating the
    /// release-clears-the-guard design. A nil recorded version (a pre-guard
    /// legacy state file, or a degraded restart that could not resolve one)
    /// cannot PROVE continuity, so it also resets — the cost is only that a
    /// genuine loop takes a fresh `crashLoopTripThreshold` crashes to re-trip.
    ///
    /// `installedVersion` is resolved by the recovery flow through
    /// `SelfUpdater.effectiveInstalledVersion` — the same source the guard
    /// stamp uses (`WatchdogRecoveryService.recoverDownProvider`), so the
    /// counter and the guard can never disagree about which version crashed.
    ///
    /// `min(count, 1)` rather than a literal 1 so the no-chain callers
    /// (healthy-path re-entries pass 0) stay below the chain's floor.
    public static func versionScopedCrashLoopCount(
        _ count: Int,
        recordedVersion: String?,
        installedVersion: String
    ) -> Int {
        recordedVersion == installedVersion ? count : min(count, 1)
    }

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
        return elapsed >= graceSeconds ? .restart : .waiting(remaining: max(0, graceSeconds - elapsed))
    }

    /// Drop a `downSince` from before `bootTime` so a timer armed in a previous
    /// uptime can't trigger an instant restart after a reboot. Passes through
    /// when `bootTime` is nil.
    public static func effectiveDownSince(_ downSince: Double?, bootTime: Double?) -> Double? {
        guard let downSince else { return nil }
        if let bootTime, downSince < bootTime { return nil }
        return downSince
    }

    /// Timer state to persist after `decision`, or nil when no write is needed.
    ///
    /// `crashLoopCount` is the counter value an ISSUED `.restart` should
    /// persist (from ``crashLoopCount(current:effectiveDownSince:uptimeBoundSeconds:)``,
    /// version-scoped by ``versionScopedCrashLoopCount(_:recordedVersion:installedVersion:)``);
    /// nil keeps the current counter — the caller passes nil when the
    /// recovery outcome shows no restart was actually issued (lock busy,
    /// backoff, provider unloaded), because a restart that never happened
    /// must not walk the chain toward the guard.
    ///
    /// `crashLoopVersion` is the INSTALLED daemon version the issued restart
    /// booted (the version the chain is scoped to); nil — the degraded
    /// session-less restart path, which cannot resolve one — preserves the
    /// recorded version rather than erasing it: erasure reads as "cannot
    /// prove continuity" and would reset a genuine chain on the next crash.
    public static func nextState(
        for decision: WatchdogDecision,
        current: WatchdogState,
        now: Double,
        crashLoopCount: Int? = nil,
        crashLoopVersion: String? = nil
    ) -> WatchdogState? {
        switch decision {
        case .restart:
            return WatchdogState(
                downSince: nil,
                lastRestartAt: now,
                lastRestartVersion: crashLoopVersion ?? current.lastRestartVersion,
                consecutiveCrashLoopRestarts: crashLoopCount
                    ?? current.consecutiveCrashLoopRestarts)
        case .startGrace:
            return WatchdogState(
                downSince: now,
                lastRestartAt: current.lastRestartAt,
                lastRestartVersion: current.lastRestartVersion,
                consecutiveCrashLoopRestarts: current.consecutiveCrashLoopRestarts)
        case .waiting:
            return nil
        case .healthy:
            // Sustained uptime breaks the chain: once a healthy provider
            // outlives the crash-loop bound since its last restart, the
            // counter resets so an unrelated crash next month starts at 1.
            // (The restart-time shape check in `crashLoopCount` would reach
            // the same answer without this write; resetting here keeps the
            // persisted file honest for `status` and for humans reading it.)
            // A non-zero counter with NO restart on record is unreachable
            // through this policy — treat it as corrupt state and reset.
            let resetCounter = current.consecutiveCrashLoopRestarts != 0
                && (current.lastRestartAt.map { now - $0 >= crashLoopUptimeBoundSeconds }
                    ?? true)
            let clearDown = current.downSince != nil
            guard clearDown || resetCounter else { return nil }
            return WatchdogState(
                downSince: nil,
                lastRestartAt: current.lastRestartAt,
                lastRestartVersion: current.lastRestartVersion,
                consecutiveCrashLoopRestarts: resetCounter
                    ? 0 : current.consecutiveCrashLoopRestarts)
        case .disabled, .notManaged:
            // No uptime is being observed in either state (opted out, or the
            // provider is unloaded), so the chain is neither advanced nor
            // reset — only the outage window is cleared, as before.
            return current.downSince == nil
                ? nil
                : WatchdogState(
                    downSince: nil,
                    lastRestartAt: current.lastRestartAt,
                    lastRestartVersion: current.lastRestartVersion,
                    consecutiveCrashLoopRestarts: current.consecutiveCrashLoopRestarts)
        }
    }
}
