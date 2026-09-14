// Copyright © 2026 Eigen Labs.
//
// In-process backend-liveness decision.
//
// A loaded model can stop serving while the process stays up and the engine
// loop never crashes, so the node keeps advertising slot_state=idle/healthy and
// the coordinator keeps routing to it — a silent wedge. Two failure modes:
//
//   * Wedged: a request was admitted (the engine picked it up) but produced 0
//     tokens for far longer than any real prefill — the GPU step loop has
//     stalled behind a blocked reservation or GPU sync.
//   * Pinned: the global KV budget collapsed to its ~1024-token floor and stays
//     there with 0 successful serves — every request 503s on "insufficient
//     global KV cache headroom" until a process/model reload.
//
// This policy is pure (no GPU, no clocks, no I/O — all timing is passed in as
// seconds) so every branch is unit-testable. The scheduler owns the live state
// (active bridges, token budget, last-success time) and feeds it here; the
// returned diagnosis drives both a truthful heartbeat slot_state and a model
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
    /// A token-budget / KV-headroom admission rejection within this many seconds
    /// counts as DEMAND even when there are no active/queued bridges. A pinned
    /// pool rejects real requests at the early token-budget guards (and the
    /// per-request KV reservation) BEFORE any bridge is inserted, so the
    /// active/pending signal is 0 on every tick even though the box is actively
    /// 503-ing traffic. Without this window the watchdog would see an idle box
    /// and never self-restart the pin.
    public var admissionRejectDemandSeconds: Double

    public static let defaultWedgeStallSeconds: Double = 120
    public static let defaultCollapsedBudgetTokens = 4096
    public static let defaultPinnedSeconds: Double = 180
    /// A reject this recent still indicates live traffic. Comfortably longer than
    /// the ~2s watchdog tick and typical inter-request gaps, but short enough
    /// that a single old reject followed by silence stops counting as demand.
    public static let defaultAdmissionRejectDemandSeconds: Double = 60

    public init(
        wedgeStallSeconds: Double = BackendLivenessPolicy.defaultWedgeStallSeconds,
        collapsedBudgetTokens: Int = BackendLivenessPolicy.defaultCollapsedBudgetTokens,
        pinnedSeconds: Double = BackendLivenessPolicy.defaultPinnedSeconds,
        admissionRejectDemandSeconds: Double = BackendLivenessPolicy.defaultAdmissionRejectDemandSeconds
    ) {
        self.wedgeStallSeconds = wedgeStallSeconds
        self.collapsedBudgetTokens = collapsedBudgetTokens
        self.pinnedSeconds = pinnedSeconds
        self.admissionRejectDemandSeconds = admissionRejectDemandSeconds
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
    ///   - secondsSinceLastAdmissionReject: seconds since a request was last
    ///     rejected at admission BEFORE any bridge was inserted (early
    ///     token-budget guard or per-request KV-headroom failure), or nil if
    ///     none. A reject within ``admissionRejectDemandSeconds`` ALSO counts as
    ///     demand: a pinned pool fails real traffic at those guards, leaving
    ///     `hasDemand` (active/queued) false on every tick, so this is the only
    ///     evidence that the box is actively rejecting requests.
    public func assess(
        longestAdmittedZeroTokenSeconds: Double?,
        budgetCollapsedForSeconds: Double?,
        secondsSinceLastSuccess: Double?,
        hasDemand: Bool,
        secondsSinceLastAdmissionReject: Double? = nil
    ) -> BackendLiveness {
        // Wedge first: a concrete stalled request is the strongest, most specific
        // signal that the backend is not making progress.
        if let stall = longestAdmittedZeroTokenSeconds, stall >= wedgeStallSeconds {
            return .wedged
        }
        // Effective demand = active/queued work right now OR a recent admission
        // rejection. The latter is essential for the pinned case: every request
        // is rejected at the early token-budget / KV-headroom guards before a
        // bridge exists, so `hasDemand` stays false while the box 503s real
        // traffic. A reject older than the window is no longer current demand.
        let recentReject =
            (secondsSinceLastAdmissionReject ?? .greatestFiniteMagnitude) <= admissionRejectDemandSeconds
        let demand = hasDemand || recentReject
        // Pinned: the budget has been collapsed long enough, there is demand, and
        // nothing has succeeded within the same window.
        if let collapsedFor = budgetCollapsedForSeconds,
            collapsedFor >= pinnedSeconds,
            demand {
            let noRecentSuccess = (secondsSinceLastSuccess ?? .greatestFiniteMagnitude) >= pinnedSeconds
            if noRecentSuccess { return .pinned }
        }
        return .healthy
    }
}
