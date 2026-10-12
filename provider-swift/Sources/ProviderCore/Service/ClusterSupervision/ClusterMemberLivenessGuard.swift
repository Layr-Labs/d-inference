import Foundation

/// The supervisor's liveness guard for a running member, ported from the
/// owner's `api_liveness_guard` (`auto_restart.sh:302-410`). Two signals:
///
/// - **down:** after a start grace, the member's heartbeat has not been
///   rewritten for the down budget while its process is still alive (a wedged
///   loop: alive, not dead, so nothing else would notice);
/// - **no start:** the pair's active request has made no prefill or decode
///   progress at all for a limit scaled by its prompt
///   (`clamp(base, margin + prompt / contextTPS, max)`); this also respects the
///   start grace, because a heartbeat inherited from the previous process can
///   name ITS stale request (the 2026-07-06 cascade that leaked 156 GB wired).
///
/// A third signal comes from the leader's pair engine itself: its watchdog's
/// wedge verdict, held for `engineWedgedSeconds`.
///
/// "Busy is not dead": a slow heartbeat inside the budget is never acted on.
public struct ClusterMemberLivenessGuard: Equatable, Sendable {
    public struct Limits: Equatable, Sendable {
        public var intervalSeconds: Double = 15
        public var startGraceSeconds: Double = 180
        public var downSeconds: Double = 75
        public var noStartBaseSeconds: Double = 120
        public var noStartContextTokensPerSecond: Double = 1000
        public var noStartMarginSeconds: Double = 120
        public var noStartMaxSeconds: Double = 900
        /// A pair engine its own watchdog has called wedged for this long is
        /// recycled (the verdict itself already needs a 120 s stall).
        public var engineWedgedSeconds: Double = 180

        public init() {}

        public static let production = Limits()

        /// Hardware tests shorten the timers; absent or invalid values keep production.
        public static func resolve(_ environment: [String: String]) -> Limits {
            func value(_ key: String) -> Double? {
                environment[key].flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }.flatMap { $0 > 0 ? $0 : nil }
            }
            var limits = Limits.production
            limits.intervalSeconds = value("DARKBLOOM_CLUSTER_GUARD_INTERVAL_SECONDS") ?? limits.intervalSeconds
            limits.startGraceSeconds = value("DARKBLOOM_CLUSTER_GUARD_START_GRACE_SECONDS") ?? limits.startGraceSeconds
            limits.downSeconds = value("DARKBLOOM_CLUSTER_GUARD_DOWN_SECONDS") ?? limits.downSeconds
            return limits
        }

        /// The no-start limit for a prompt of this many tokens.
        public func noStartLimit(promptTokens: Int) -> Double {
            let scaled = noStartMarginSeconds + Double(max(0, promptTokens)) / max(1, noStartContextTokensPerSecond)
            return max(noStartBaseSeconds, min(max(noStartBaseSeconds, noStartMaxSeconds), scaled))
        }
    }

    public enum Decision: Equatable, Sendable {
        case healthy
        /// Inside the start grace with no usable heartbeat yet.
        case starting
        /// Heartbeat missing or stale, budget not yet spent.
        case downFor(seconds: Double)
        /// Ask the member to stop cooperatively, then restart through the budget.
        case recycle(reason: String)
    }

    public let limits: Limits
    /// When the guard first saw the member down in this run (epoch seconds).
    public private(set) var downSince: Double?

    public init(limits: Limits = .production) {
        self.limits = limits
    }

    /// One probe. `health` is the member's latest heartbeat, or nil when none
    /// can be read; a heartbeat written by another process id is ignored.
    public mutating func observe(health: ClusterMemberHealth?, childPID: Int32,
                                 runStartedAt: Double, now: Double) -> Decision {
        let age = now - runStartedAt
        let usable = health.flatMap { $0.pid == childPID ? $0 : nil }
        let fresh = usable.map { now - $0.writtenAt < limits.downSeconds } ?? false
        guard fresh, let current = usable else {
            if age < limits.startGraceSeconds { return .starting }
            let since = downSince ?? (usable?.writtenAt).map { max($0, runStartedAt) } ?? now
            downSince = since
            let down = now - since
            if down >= limits.downSeconds {
                return .recycle(reason: "member heartbeat missing for \(Int(down)) s while its process is alive")
            }
            return .downFor(seconds: down)
        }
        downSince = nil
        if let wedged = current.engineWedgedSeconds, wedged >= limits.engineWedgedSeconds, age >= limits.startGraceSeconds {
            return .recycle(reason: "the pair's engine has been wedged for \(Int(wedged)) s (no engine steps)")
        }
        if let active = current.activeRequest, active.tokensEmitted == 0, active.prefillProcessedTokens == 0 {
            let limit = limits.noStartLimit(promptTokens: active.promptTokens)
            if active.secondsSinceProgress >= limit {
                guard age >= limits.startGraceSeconds else { return .healthy }
                return .recycle(reason: "active request \(active.id) made no prefill or decode progress for "
                    + "\(Int(active.secondsSinceProgress)) s (limit \(Int(limit)) s, prompt \(active.promptTokens) tokens)")
            }
        }
        return .healthy
    }
}
