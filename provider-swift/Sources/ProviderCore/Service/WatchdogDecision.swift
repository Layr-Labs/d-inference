/// The crash-recovery policy (pure, no I/O).
///
/// A crash = the provider's launchd job is loaded but not running (`KeepAlive=false`
/// leaves a crashed job loaded). `darkbloom stop` unloads it (`bootout`), so
/// `providerLoaded == false` means the user disabled it — never restarted.
/// `auto_restart = false` opts out. A crashed provider is restarted only after it
/// stays down `graceSeconds` (default 5 min): long enough to clear the
/// self-updater's kill+relaunch and to avoid tight crash-loops.

import Foundation

public enum WatchdogDecision: Equatable, Sendable {
    case disabled                    // auto_restart = false
    case notManaged                  // unloaded: stopped/uninstalled, not a crash
    case healthy                     // running
    case startGrace                  // first tick down: arm the window
    case waiting(remaining: Double)  // down, inside the grace window
    case restart                     // down >= grace
}

public enum WatchdogPolicy {

    /// Grace before a crashed provider is restarted: 5 minutes.
    public static let defaultGraceSeconds: Double = 300

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
    public static func nextState(for decision: WatchdogDecision, current: WatchdogState, now: Double) -> WatchdogState? {
        switch decision {
        case .restart:
            return WatchdogState(downSince: nil, lastRestartAt: now)
        case .startGrace:
            return WatchdogState(downSince: now, lastRestartAt: current.lastRestartAt)
        case .waiting:
            return nil
        case .disabled, .notManaged, .healthy:
            return current.downSince == nil ? nil : WatchdogState(downSince: nil, lastRestartAt: current.lastRestartAt)
        }
    }
}
