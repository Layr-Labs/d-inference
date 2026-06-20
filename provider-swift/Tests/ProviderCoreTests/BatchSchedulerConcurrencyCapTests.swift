// Non-live unit tests for the engine concurrency-cap sync (perf fix).
//
// THE bug: the continuous-batching engine's per-step concurrency is set via
// `engine.setMaxNumSeqs(...)`. Pre-fix the engine was told the cold-start cap
// ONCE at load (pinned to 4) and never heard the adaptive ramp, so a configured
// `maxConcurrentRequests = 8` (with memory admitting) ran as two serialized
// waves of 4 — roughly halving aggregate throughput at concurrency.
//
// These tests pin the corrected behavior WITHOUT loading a model (no GPU). They
// assert on the effective-cap computation (`effectiveMaxConcurrentRequests`) and
// on what `syncEngineConcurrency()` would push (its return value + the recorded
// `lastPushedMaxNumSeqs`). `BatchedEngine` is concrete and can't be stubbed in a
// non-live test, so there is no setMaxNumSeqs spy; the return value IS the
// observable contract (the value sent to `engine?.setMaxNumSeqs`).

import Foundation
import Testing
@testable import ProviderCore

@Suite("BatchScheduler engine concurrency-cap sync")
struct BatchSchedulerConcurrencyCapTests {

    /// THE regression. With `maxConcurrentRequests = 8` and memory admitting,
    /// the engine must be told 8 — not the old cold-start pin of 4.
    ///
    /// No model loaded ⇒ `tokenBudgetMax == defaultMaxTokens *
    /// maxConcurrentRequests == 4096 * 8 == 32768`, and with no active requests
    /// `averageReservedTokensForAdmission == defaultMaxTokens == 4096`, so
    /// `memoryBoundMaxConcurrentRequests == min(8, 32768/4096) == 8`. The
    /// effective cap is therefore the full 8.
    @Test("effective cap reaches the configured max and syncEngineConcurrency pushes it")
    func effectiveCapReachesConfiguredMaxWhenMemoryAdmits() async {
        let scheduler = BatchScheduler(
            maxConcurrentRequests: 8,
            defaultMaxTokens: 4096
        )

        // Cold-start seed must NOT be the old hard pin to 4.
        #expect(await scheduler.dynamicMaxConcurrentRequests == 8,
            "cold-start seed must start at the configured ceiling (8), not a pin to 4")

        #expect(await scheduler.effectiveMaxConcurrentRequests == 8,
            "memory admits (budget 32768 / avgReserved 4096 = 8) → effective cap is the full 8")

        // `syncEngineConcurrency()` returns the value it pushes to the engine.
        let pushed = await scheduler.syncEngineConcurrency()
        #expect(pushed == 8,
            "engine must be told 8, not 4 — otherwise 8 concurrent requests run as two waves of 4")
        #expect(await scheduler.lastPushedMaxNumSeqs == 8,
            "the pushed value must be recorded so subsequent syncs are change-gated")
    }

    /// OOM safety: the pushed value must NEVER exceed
    /// `memoryBoundMaxConcurrentRequests`. Two admitted bridges of (4000 prompt +
    /// 4000 max) make `averageReservedTokensForAdmission == 16000/2 == 8000`, so
    /// `memoryBoundMaxConcurrentRequests == min(8, 32768/8000) == 4`. Even though
    /// `dynamicMaxConcurrentRequests` is seeded optimistically at 8, the effective
    /// cap — and the value pushed — clamp to 4.
    @Test("syncEngineConcurrency never exceeds the memory-bound cap")
    func syncNeverExceedsMemoryBound() async {
        let scheduler = BatchScheduler(
            maxConcurrentRequests: 8,
            defaultMaxTokens: 4096
        )
        await scheduler._testSeedBridge(
            id: "a", promptTokens: 4000, maxTokens: 4000, admitted: true)
        await scheduler._testSeedBridge(
            id: "b", promptTokens: 4000, maxTokens: 4000, admitted: true)

        #expect(await scheduler.dynamicMaxConcurrentRequests == 8,
            "seed stays at the optimistic ceiling; the memory clamp does the limiting")
        #expect(await scheduler.effectiveMaxConcurrentRequests == 4,
            "the memory-bound clamp must hold the effective cap at 4 (32768 / 8000)")

        let pushed = await scheduler.syncEngineConcurrency()
        #expect(pushed == 4,
            "OOM safety: the engine must never be told more than memoryBoundMaxConcurrentRequests")
        #expect(pushed <= 8,
            "the pushed value must never exceed maxConcurrentRequests")
    }

    /// `syncEngineConcurrency()` is change-gated: a second call with no state
    /// change returns the same value and leaves `lastPushedMaxNumSeqs` stable, so
    /// it does not spam the engine with redundant `setMaxNumSeqs` calls.
    @Test("syncEngineConcurrency is idempotent when the effective cap is unchanged")
    func syncIsIdempotentWhenCapUnchanged() async {
        let scheduler = BatchScheduler(
            maxConcurrentRequests: 8,
            defaultMaxTokens: 4096
        )
        let first = await scheduler.syncEngineConcurrency()
        let second = await scheduler.syncEngineConcurrency()
        #expect(first == 8)
        #expect(second == 8, "a no-change re-sync must return the same effective cap")
        #expect(await scheduler.lastPushedMaxNumSeqs == 8)
    }

    /// A configured cap of 1 must stay at 1 (no spurious widening from the
    /// `max(1, …)` floor or the optimistic seed).
    @Test("a single-slot configuration stays at 1")
    func singleSlotConfigurationStaysAtOne() async {
        let scheduler = BatchScheduler(
            maxConcurrentRequests: 1,
            defaultMaxTokens: 4096
        )
        #expect(await scheduler.dynamicMaxConcurrentRequests == 1)
        #expect(await scheduler.effectiveMaxConcurrentRequests == 1)
        #expect(await scheduler.syncEngineConcurrency() == 1,
            "maxConcurrentRequests=1 must clamp the effective cap (and the pushed value) to 1")
    }
}
