// Copyright © 2026 Eigen Labs.
//
// DAR-337 / DAR-338 in-process backend-liveness decision.
//
// A loaded model can stop serving while the process stays up and the engine
// loop never crashes, so the node keeps advertising slot_state=idle/healthy and
// the coordinator keeps routing to it — a silent wedge. Two failure modes:
//
//   * WEDGE (DAR-338 safety net): a request was admitted (the engine picked it
//     up) but produced 0 tokens for far longer than any real prefill — the GPU
//     step loop has stalled behind a blocked reservation / GPU sync.
//   * PINNED (DAR-337): the global KV budget collapsed to its ~1024-token floor
//     and stays there with 0 successful serves — every request 503s on
//     "insufficient global KV cache headroom" until a process/model reload.
//
// This policy is PURE (no GPU, no clocks, no I/O — all timing is passed in as
// seconds) so every branch is unit-testable. The scheduler owns the live state
// (active bridges, token budget, last-success time) and feeds it here; the
// returned diagnosis drives both a TRUTHFUL heartbeat slot_state and a model
// self-restart.

import Foundation

/// Backend-liveness diagnosis produced by ``BackendLivenessPolicy``.
public enum BackendLiveness: Equatable, Sendable {
    /// Serving normally (or idle-but-ready).
    case healthy
    /// A request was admitted but the backend produced no tokens for too long.
    case wedged
    /// The KV budget has collapsed and nothing can be served.
    case pinned
}

/// Pure decision for the in-process backend-liveness watchdog.
public struct BackendLivenessPolicy: Sendable, Equatable {
    /// An admitted request that has produced 0 tokens for at least this many
    /// seconds means the engine step loop is stalled. Defaults to the
    /// pending-timeout window: no legitimate cold prefill takes this long to emit
    /// its first token.
    public var wedgeStallSeconds: Double
    /// A token budget at or below this is "collapsed" — the 1024-token floor plus
    /// slack. A healthy budget is on the order of a million tokens.
    public var collapsedBudgetTokens: Int
    /// The budget must stay collapsed AND produce 0 successes for at least this
    /// many seconds before it is declared pinned — a brief, self-healing dip is
    /// not a restart trigger.
    public var pinnedSeconds: Double

    public static let defaultWedgeStallSeconds: Double = 120
    public static let defaultCollapsedBudgetTokens = 4096
    public static let defaultPinnedSeconds: Double = 180

    public init(
        wedgeStallSeconds: Double = BackendLivenessPolicy.defaultWedgeStallSeconds,
        collapsedBudgetTokens: Int = BackendLivenessPolicy.defaultCollapsedBudgetTokens,
        pinnedSeconds: Double = BackendLivenessPolicy.defaultPinnedSeconds
    ) {
        self.wedgeStallSeconds = wedgeStallSeconds
        self.collapsedBudgetTokens = collapsedBudgetTokens
        self.pinnedSeconds = pinnedSeconds
    }

    /// Decide backend liveness from the current scheduler state.
    ///
    /// - Parameters:
    ///   - longestAdmittedZeroTokenSeconds: how long the longest-stalled admitted
    ///     request has produced 0 tokens, or nil if no admitted request is
    ///     currently producing 0 tokens.
    ///   - budgetCollapsedForSeconds: how long the token budget has been
    ///     CONTINUOUSLY at/below ``collapsedBudgetTokens``, or nil if it is not
    ///     currently collapsed. (The scheduler maintains this window using
    ///     ``collapsedBudgetTokens`` so the threshold has a single definition.)
    ///   - secondsSinceLastSuccess: seconds since the last successful completion,
    ///     or nil if nothing has succeeded since the model loaded.
    ///   - hasDemand: whether there is any active or queued request right now (an
    ///     idle box with a momentarily small budget is failing no one).
    public func assess(
        longestAdmittedZeroTokenSeconds: Double?,
        budgetCollapsedForSeconds: Double?,
        secondsSinceLastSuccess: Double?,
        hasDemand: Bool
    ) -> BackendLiveness {
        // Wedge first: a concrete stalled request is the strongest, most specific
        // signal that the backend is not making progress.
        if let stall = longestAdmittedZeroTokenSeconds, stall >= wedgeStallSeconds {
            return .wedged
        }
        // Pinned: the budget has been collapsed long enough, there is demand, and
        // nothing has succeeded within the same window.
        if let collapsedFor = budgetCollapsedForSeconds,
            collapsedFor >= pinnedSeconds,
            hasDemand {
            let noRecentSuccess = (secondsSinceLastSuccess ?? .greatestFiniteMagnitude) >= pinnedSeconds
            if noRecentSuccess { return .pinned }
        }
        return .healthy
    }
}
