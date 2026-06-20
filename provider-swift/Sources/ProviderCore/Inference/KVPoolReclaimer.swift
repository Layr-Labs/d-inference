// Copyright © 2026 Eigen Labs.
//
// Off-actor reclaimer for the MLX reclaimable KV pool.
//
// The reclaim flush is `MLX.Stream().synchronize()` + `MLX.Memory.clearCache()`
// — a blocking GPU synchronize that waits for in-flight inference GPU work to
// drain. It used to run inside the `GlobalKVCacheBudget` actor (the per-request
// KV admission gate). A synchronous GPU sync on an actor blocks that actor's
// executor for its whole duration, so every other reservation serialized behind
// it: under sustained load the reclaimable pool grew, near-miss admissions
// chained one blocking sync per second on the admission actor, slots could not
// be granted, requests aborted on the pending timeout, and the node kept
// advertising itself as healthy — the fleet-wide wedge.
//
// This actor owns the flush and runs it off the budget actor. Callers signal
// pressure with the non-isolated, fire-and-forget `scheduleReclaim` /
// `scheduleSweep` (they return instantly — they only spawn a task), and the GPU
// sync runs later on this actor's executor, never the budget actor's. The flush
// is rate-limited (at most one per `minInterval`) and shortfall/threshold-gated,
// so a flood of near-misses can never chain syncs.
//
// Invariant: nothing here ever runs on, awaits, or blocks the
// `GlobalKVCacheBudget` actor. The admission decision is made against the
// current memory snapshot and returns immediately; this reclaimer keeps the
// pool small over time so most admissions succeed without any inline flush.
import Foundation
import MLX

actor KVPoolReclaimer {
    /// The blocking GPU flush. Injected so tests can observe invocations
    /// (count/timing) deterministically without a GPU. Production fences async
    /// GPU completion before freeing buffers (matches the engine reclaim paths /
    /// the M4 IOKit completeMemory guard).
    private let clearCache: @Sendable () -> Void
    /// Current reclaimable MLX pool size in bytes (the cache pool that a flush
    /// would return to the OS). Used to gate both reclaim paths so we never run
    /// a GPU sync that could not help.
    private let reclaimableBytes: @Sendable () -> UInt64
    /// At most one flush per this interval. The flush blocks a GPU stream, so
    /// this bounds how often pressure can drive a sync (shared by the on-pressure
    /// and proactive paths — either one flushing satisfies the other).
    private let minInterval: Duration
    /// Proactive sweep only flushes when the reclaimable pool has grown to at
    /// least this many bytes, so a small/healthy cache is never thrashed.
    private let proactiveThresholdBytes: UInt64
    private var lastReclaimAt: ContinuousClock.Instant?

    /// Total flushes performed (test observability).
    private(set) var reclaimCount = 0

    static let defaultMinInterval: Duration = .seconds(1)
    /// 2 GiB: a pool this large is materially eating admission headroom; below it
    /// the on-pressure path (which gates on the exact shortfall) handles flushing.
    static let defaultProactiveThresholdBytes: UInt64 = 2 * 1024 * 1024 * 1024

    init(
        clearCache: @escaping @Sendable () -> Void,
        reclaimableBytes: @escaping @Sendable () -> UInt64,
        minInterval: Duration = KVPoolReclaimer.defaultMinInterval,
        proactiveThresholdBytes: UInt64 = KVPoolReclaimer.defaultProactiveThresholdBytes
    ) {
        self.clearCache = clearCache
        self.reclaimableBytes = reclaimableBytes
        self.minInterval = minInterval
        self.proactiveThresholdBytes = proactiveThresholdBytes
    }

    // MARK: - Fire-and-forget signals (called from the budget actor)

    /// On-pressure signal from the admission path. Non-isolated so the caller
    /// (the budget actor) returns instantly: this only spawns a task; the GPU
    /// sync happens later on this reclaimer's executor.
    nonisolated func scheduleReclaim(shortfall: UInt64) {
        Task { await self.reclaimIfNeeded(shortfall: shortfall) }
    }

    /// Proactive signal from the periodic scheduler watchdog. Non-isolated, same
    /// contract as `scheduleReclaim`.
    nonisolated func scheduleSweep() {
        Task { await self.sweep() }
    }

    // MARK: - Reclaim execution (runs on this actor, never the budget actor)

    /// On-pressure reclaim: flush iff the reclaimable pool can actually cover the
    /// shortfall the request is short by (a flush that still leaves it rejected —
    /// e.g. active memory, not the pool, is what's full — is skipped) and we are
    /// outside the rate-limit window. Returns true iff it flushed. The GPU sync
    /// runs on this actor's executor.
    @discardableResult
    func reclaimIfNeeded(shortfall: UInt64) -> Bool {
        guard shortfall > 0, reclaimableBytes() >= shortfall else { return false }
        return flushIfDue()
    }

    /// Proactive sweep: flush iff the reclaimable pool has grown past the
    /// threshold and we are outside the rate-limit window. Keeps admission
    /// headroom healthy under sustained load so most admissions never near-miss.
    @discardableResult
    func sweep() -> Bool {
        guard reclaimableBytes() >= proactiveThresholdBytes else { return false }
        return flushIfDue()
    }

    private func flushIfDue() -> Bool {
        let now = ContinuousClock.now
        if let last = lastReclaimAt, now - last < minInterval { return false }
        lastReclaimAt = now
        clearCache()
        reclaimCount += 1
        return true
    }
}
