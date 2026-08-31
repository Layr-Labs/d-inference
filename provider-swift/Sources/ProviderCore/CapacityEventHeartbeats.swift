// Copyright © 2026 Eigen Labs.
//
// Event-triggered heartbeat policy (routing v2, Phase 1).
//
// The 5s heartbeat interval is the staleness window that produced the
// gray-box incident (coordinator/registry/budget_clamp.go: 11,581
// capacity-shaped 503s in 6h from boxes whose heartbeats looked ~1.4%
// utilized). The fix is push-based freshness: when slot state materially
// changes, send the EXISTING heartbeat payload immediately instead of waiting
// out the interval. The baseline periodic heartbeat remains as liveness.
//
// Two pure value types, deliberately free of clocks, tasks, and actors:
//   * `CapacityHeartbeatMateriality` decides whether a freshly rebuilt
//     capacity payload differs enough from the last SENT one to justify an
//     out-of-band heartbeat.
//   * `CapacityHeartbeatThrottle` rate-caps event sends at 2/s per connection
//     with trailing-edge coalescing: a change landing inside the cap window
//     is never dropped — it is guaranteed exactly one heartbeat at window
//     end. Callers inject `now` (deterministic clock seam) and own the timer
//     that services `.scheduled` verdicts.
//
// The ProviderLoop drives both from `updateAggregateCapacity()` — the single
// choke point every trigger in the contract already flows through: request
// admission and completion/cancellation, model load/unload/evict, wedge
// recovery ("crashed"/"reloading" slot states surface in the rebuilt
// payload), and token-budget drift.

import Foundation

/// Decides whether a rebuilt capacity payload warrants an immediate
/// out-of-band heartbeat, by comparison against the payload of the last
/// heartbeat actually sent (the published snapshot). Comparing against the
/// last SENT payload — not the previous rebuild — makes the decision
/// idempotent across redundant rebuilds and self-healing: once an event
/// heartbeat (or the 5s baseline) ships the new state, the delta collapses
/// to nothing.
public enum CapacityHeartbeatMateriality {
    /// Token-budget materiality thresholds from the plan: a shift of ≥1024
    /// tokens or ≥10% of the previously reported figure.
    public static let tokenShiftFloor: Int64 = 1024
    public static let tokenShiftFraction = 0.10

    public static func isMaterial(
        previous: BackendCapacity?,
        current: BackendCapacity
    ) -> Bool {
        // Nothing published yet on this connection: the first rebuild is
        // always worth pushing (the baseline heartbeat would send it anyway).
        guard let previous else { return true }

        // Slot roster: a model loaded, unloaded, or evicted.
        let previousSlots = Dictionary(
            uniqueKeysWithValues: previous.slots.map { ($0.model, $0) })
        if previousSlots.count != current.slots.count { return true }

        var previousBudget: Int64 = 0
        var currentBudget: Int64 = 0
        for slot in current.slots {
            guard let before = previousSlots[slot.model] else { return true }
            // Slot health transitions (idle/running/crashed/reloading) and
            // admission/completion (running/waiting counts) are always
            // material — these are exactly the events the coordinator's
            // ledger debits against.
            if before.state != slot.state { return true }
            if before.numRunning != slot.numRunning { return true }
            if before.numWaiting != slot.numWaiting { return true }
            // Token budget drifting without an admission-count change
            // (re-slice, queued work retiring, KV reclaim) is compared PER
            // SLOT: the coordinator's ledger is per-model, so opposing
            // per-model deltas (A −50k, B +50k) must never cancel into a
            // fleet-level "nothing changed" — that leaves A's ledger
            // stale-optimistic, the exact staleness this policy exists to
            // push out. Providers host multiple model slots in production.
            let beforeTokens = admittableTokens(before)
            let nowTokens = admittableTokens(slot)
            if budgetShiftIsMaterial(previous: beforeTokens, current: nowTokens) {
                return true
            }
            previousBudget += beforeTokens
            currentBudget += nowTokens
        }

        // The aggregate check still adds signal on top of the per-slot one:
        // several slots each drifting just below the per-slot thresholds can
        // sum to a fleet-level shift the coordinator's total-capacity view
        // cares about (e.g. three slots each +400 tokens ≥ the 1024 floor).
        return budgetShiftIsMaterial(previous: previousBudget, current: currentBudget)
    }

    /// Materiality of one budget figure moving to another: a shift of
    /// ≥ ``tokenShiftFloor`` tokens, or ≥ ``tokenShiftFraction`` of the
    /// previous figure. Applied per slot AND to the roster aggregate.
    static func budgetShiftIsMaterial(previous: Int64, current: Int64) -> Bool {
        let shift = (current - previous).magnitude
        if shift >= UInt64(tokenShiftFloor) { return true }
        if previous > 0, Double(shift) >= tokenShiftFraction * Double(previous) {
            return true
        }
        return false
    }

    /// The live admittable token budget a slot reports: max − used − queued,
    /// floored at zero. Same arithmetic the quote path reports as
    /// `available_token_budget`, so materiality and quotes move together.
    public static func admittableTokens(_ slot: BackendSlotCapacity) -> Int64 {
        max(0, slot.activeTokenBudgetMax - slot.activeTokenBudgetUsed - slot.queuedTokenBudget)
    }
}

/// Rate cap for event-triggered heartbeats: at most one send per
/// ``minInterval`` (2/s), with trailing-edge coalescing. Pure state machine —
/// the caller supplies `now` and runs the timer for `.scheduled` verdicts, so
/// tests drive it with a synthetic clock and zero sleeps.
public struct CapacityHeartbeatThrottle: Sendable {
    /// 2 events/second per connection (plan Phase 1).
    public static let minInterval: Duration = .milliseconds(500)

    public enum Verdict: Equatable, Sendable {
        /// Send an event heartbeat immediately.
        case sendNow
        /// Inside the cap window: one trailing send is now scheduled after
        /// this delay. The caller must arrange a timer that then calls
        /// ``takeScheduledSend(now:)``.
        case scheduled(after: Duration)
        /// Inside the cap window with a trailing send already scheduled —
        /// this change coalesces into it (never dropped: the trailing send
        /// ships the then-current payload).
        case coalesced
    }

    private var lastEventSendAt: ContinuousClock.Instant?
    private var trailingScheduled = false

    public init() {}

    /// A material change occurred at `now`.
    public mutating func noteMaterialChange(
        now: ContinuousClock.Instant
    ) -> Verdict {
        if trailingScheduled { return .coalesced }
        if let last = lastEventSendAt, now - last < Self.minInterval {
            trailingScheduled = true
            return .scheduled(after: last + Self.minInterval - now)
        }
        lastEventSendAt = now
        return .sendNow
    }

    /// The trailing timer fired. Returns true when the caller must send the
    /// heartbeat now (and the send is accounted against the rate cap); false
    /// when the scheduled send was already serviced (defensive — one timer
    /// per `.scheduled` verdict makes this unreachable in practice).
    public mutating func takeScheduledSend(
        now: ContinuousClock.Instant
    ) -> Bool {
        guard trailingScheduled else { return false }
        trailingScheduled = false
        lastEventSendAt = now
        return true
    }
}
