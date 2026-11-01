import Foundation

/// How one supervised cluster-member run ended, as the supervisor classifies
/// it from facts it owns (its own stop request, the child's exit status and
/// how long the run lasted). It never greps logs.
public enum ClusterMemberRunEnd: Equatable, Sendable {
    /// The supervisor itself asked the member to stop (`darkbloom stop`, a
    /// launchd bootout, a coordinated update). Never restarted.
    case operatorStop
    /// The member exited with the JACCL progress-guard code (75): the guard
    /// tore down a wedged collective and released its memory. A self-heal,
    /// budgeted separately from startup failures.
    case guardTeardown
    /// Any other exit, including a zero exit the supervisor did not ask for:
    /// an unrequested clean exit is a crash, not an operator stop.
    case failure(exitCode: Int32)
    /// Killed by a signal the supervisor did not send.
    case signaled(Int32)

    /// The JACCL progress guard's teardown exit code (guard v2, mlx#33).
    public static let guardTeardownExitCode: Int32 = 75

    /// Classify a finished child process. `stopRequested` is the
    /// supervisor's own flag; a signal is reported only when the child did
    /// not exit by itself.
    public static func classify(stopRequested: Bool, exitCode: Int32?, signal: Int32?) -> ClusterMemberRunEnd {
        if stopRequested { return .operatorStop }
        if let signal { return .signaled(signal) }
        let code = exitCode ?? -1
        return code == guardTeardownExitCode ? .guardTeardown : .failure(exitCode: code)
    }
}

/// Restart budget and backoff for a supervised cluster member, ported from the
/// owner's production restart loop (ThunderMLX `auto_restart.sh`, the MiniMax
/// two-Mac pipeline that ran daily on this exact pair):
///
/// - a run shorter than the quick-failure window (120 s) is a quick failure;
///   three quick failures in a row stop the loop ("3 failures in 120 s"), so a
///   member that cannot start never spins against JACCL and Metal memory;
/// - a JACCL guard teardown (exit 75) inside the window is a self-heal with its
///   own budget of six, and a seventh means the link is flapping;
/// - a run of at least the window resets both counters and the backoff;
/// - restarts wait 15 s, doubling to a 300 s cap.
///
/// Pure value type: the supervisor persists it for `darkbloom status`.
public struct ClusterMemberRestartBudget: Codable, Equatable, Sendable {
    public struct Limits: Codable, Equatable, Sendable {
        public var maxQuickFailures: Int
        public var quickFailureWindowSeconds: Double
        public var initialBackoffSeconds: Int
        public var maxBackoffSeconds: Int
        public var maxGuardTeardowns: Int

        public init(maxQuickFailures: Int = 3, quickFailureWindowSeconds: Double = 120,
                    initialBackoffSeconds: Int = 15, maxBackoffSeconds: Int = 300, maxGuardTeardowns: Int = 6) {
            self.maxQuickFailures = max(1, maxQuickFailures)
            self.quickFailureWindowSeconds = max(1, quickFailureWindowSeconds)
            self.initialBackoffSeconds = max(1, initialBackoffSeconds)
            self.maxBackoffSeconds = max(self.initialBackoffSeconds, maxBackoffSeconds)
            self.maxGuardTeardowns = max(1, maxGuardTeardowns)
        }

        /// The owner's production values.
        public static let production = Limits()

        /// Environment overrides, for tests of the supervisor on hardware only
        /// (a shorter window makes a crash-loop proof take seconds, not
        /// minutes). Unparseable or absent values keep production.
        public static func resolve(_ environment: [String: String]) -> Limits {
            func int(_ key: String) -> Int? { environment[key].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } }
            let base = Limits.production
            return Limits(
                maxQuickFailures: int("DARKBLOOM_CLUSTER_RESTART_MAX_QUICK_FAILURES") ?? base.maxQuickFailures,
                quickFailureWindowSeconds: int("DARKBLOOM_CLUSTER_RESTART_WINDOW_SECONDS").map(Double.init)
                    ?? base.quickFailureWindowSeconds,
                initialBackoffSeconds: int("DARKBLOOM_CLUSTER_RESTART_BACKOFF_INITIAL_SECONDS") ?? base.initialBackoffSeconds,
                maxBackoffSeconds: int("DARKBLOOM_CLUSTER_RESTART_BACKOFF_MAX_SECONDS") ?? base.maxBackoffSeconds,
                maxGuardTeardowns: int("DARKBLOOM_CLUSTER_RESTART_MAX_GUARD_TEARDOWNS") ?? base.maxGuardTeardowns)
        }
    }

    public enum Decision: Equatable, Sendable {
        /// Do not restart; the supervisor exits its loop normally.
        case stop
        /// Restart after this many seconds.
        case restart(afterSeconds: Int)
        /// The budget is spent: stop restarting and say why. The supervisor
        /// parks (holding nothing) until the operator restarts it.
        case exhausted(reason: String)
    }

    public private(set) var limits: Limits
    public private(set) var quickFailures: Int
    public private(set) var guardTeardowns: Int
    /// The wait the NEXT restart will use.
    public private(set) var backoffSeconds: Int
    /// Restarts issued by this supervisor (observability only).
    public private(set) var restartsIssued: Int

    public init(limits: Limits = .production) {
        self.limits = limits
        quickFailures = 0
        guardTeardowns = 0
        backoffSeconds = limits.initialBackoffSeconds
        restartsIssued = 0
    }

    /// Record one finished run and decide what happens next. Mirrors the
    /// order of `auto_restart.sh:441-500`: stop flag first, then the window
    /// accounting, then the two breakers, then the backoff.
    public mutating func record(_ end: ClusterMemberRunEnd, runSeconds: Double) -> Decision {
        if end == .operatorStop { return .stop }
        if runSeconds < limits.quickFailureWindowSeconds {
            if end == .guardTeardown { guardTeardowns += 1 } else { quickFailures += 1 }
        } else {
            quickFailures = 0
            guardTeardowns = 0
            backoffSeconds = limits.initialBackoffSeconds
        }
        if quickFailures >= limits.maxQuickFailures {
            return .exhausted(reason: "\(quickFailures) quick failures (each run shorter than "
                + "\(Int(limits.quickFailureWindowSeconds)) s); restarts stopped to protect JACCL and Metal memory")
        }
        if guardTeardowns >= limits.maxGuardTeardowns {
            return .exhausted(reason: "\(guardTeardowns) link guard teardowns inside the failure window; "
                + "the link is flapping, restarts stopped so it can be inspected")
        }
        let wait = backoffSeconds
        backoffSeconds = min(limits.maxBackoffSeconds, backoffSeconds * 2)
        restartsIssued += 1
        return .restart(afterSeconds: wait)
    }
}
