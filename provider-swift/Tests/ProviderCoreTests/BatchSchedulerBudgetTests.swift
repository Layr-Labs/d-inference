// Non-live unit tests for the BatchScheduler cumulative-budget gate
// (P1 fix) and in-flight bridge progress reporting (P2 fix). These
// exercise the actor's bookkeeping directly via `@testable import`
// hooks (`_testSeedBridge`); the full submit -> reject flow is covered
// by the live tests in BatchSchedulerEngineIntegrationTests.

import Foundation
import Testing
@testable import ProviderCore

@Suite("BatchScheduler budget gate + progress reporting")
struct BatchSchedulerBudgetTests {

    // MARK: - P1: cumulative active-bridge gate

    /// Pre-fix: planner validated per-request limits + queue size only,
    /// so a burst of large requests each individually within budget
    /// could overcommit KV memory once they all reached the engine.
    /// Post-fix: `submit()` re-checks `activeTokenBudgetUsed +
    /// requestBudget > tokenBudgetMax` before `engine.core.addRequest`.
    /// This test pins the underlying math.
    @Test("activeTokenBudgetUsed sums (promptTokens + maxTokens) across active bridges")
    func activeTokenBudgetSumsCorrectlyAcrossBridges() async {
        let scheduler = BatchScheduler(
            maxConcurrentRequests: 4,
            defaultMaxTokens: 4096
        )
        // No model loaded → tokenBudgetMax = defaultMaxTokens *
        // maxConcurrentRequests = 16384.
        await scheduler._testSeedBridge(id: "a", promptTokens: 4000, maxTokens: 4000)
        await scheduler._testSeedBridge(id: "b", promptTokens: 4000, maxTokens: 4000)

        let used = await scheduler.activeTokenBudgetUsed
        let budget = await scheduler.tokenBudgetMax
        #expect(used == 16_000, "two bridges of (4000 prompt + 4000 max) = 16000")
        #expect(budget == 16_384, "static budget = defaultMaxTokens * maxConcurrentRequests")

        // A third request of 500 tokens would push cumulative over.
        let requestBudget = 500
        #expect(used + requestBudget > budget,
            "P1 gate: third bridge pushing cumulative over tokenBudgetMax must trigger rejection")
    }

    /// End-to-end exercise of the P1 helper. Two bridges admitted
    /// within budget, a third that pushes cumulative over budget →
    /// helper returns the canonical `token_budget_exhausted: ...`
    /// error string. `submit()` inlines the same check synchronously
    /// before its first await (so it's atomic with respect to actor
    /// reentrancy) and rolls back via `dropBridge` on the cleanup
    /// paths below it.
    @Test("checkCumulativeTokenBudget rejects the third bridge that pushes over")
    func cumulativeGateRejectsOverflowingBridge() async {
        let scheduler = BatchScheduler(
            maxConcurrentRequests: 4,
            defaultMaxTokens: 4096
        )
        // tokenBudgetMax = 16384 (no model loaded).
        await scheduler._testSeedBridge(id: "a", promptTokens: 4000, maxTokens: 4000)
        await scheduler._testSeedBridge(id: "b", promptTokens: 4000, maxTokens: 4000)
        // 16000 used; a 500-token request pushes total to 16500 > 16384.

        let err = await scheduler.checkCumulativeTokenBudget(
            requestId: "third",
            requestBudget: 500
        )
        #expect(err != nil,
            "P1: third bridge that pushes cumulative over tokenBudgetMax must be rejected")
        #expect(err!.hasPrefix("token_budget_exhausted:"),
            "P1: error wording must use the canonical prefix so coordinator parsing stays stable")
        #expect(err!.contains("requires 500 tokens but only 384 available"))
    }

    /// Companion accept-case: same scheduler state, smaller request
    /// budget that fits → gate returns nil.
    @Test("checkCumulativeTokenBudget admits the third bridge that fits in budget")
    func cumulativeGateAdmitsFittingBridge() async {
        let scheduler = BatchScheduler(
            maxConcurrentRequests: 4,
            defaultMaxTokens: 4096
        )
        await scheduler._testSeedBridge(id: "a", promptTokens: 4000, maxTokens: 4000)
        await scheduler._testSeedBridge(id: "b", promptTokens: 4000, maxTokens: 4000)

        let err = await scheduler.checkCumulativeTokenBudget(
            requestId: "third",
            requestBudget: 200
        )
        #expect(err == nil,
            "200 tokens fits: 16000 + 200 = 16200 < 16384, gate must not reject")
    }

    /// Race test: pre-seed bridges so that the next request would
    /// overflow. The bridge that is already in `activeBridges` (via
    /// `_testSeedBridge`) counts toward `activeTokenBudgetUsed`, so a
    /// follow-up request that would push past the budget is rejected
    /// even when no `planner.admit` await has been crossed. This
    /// pins the atomic-slot-reservation property that prevents
    /// concurrent submits from each reading a stale 0 and overcommitting.
    @Test("cumulative gate stays correct under serially-interleaved bridges")
    func cumulativeGateAtomicityUnderSerialPreseed() async {
        let scheduler = BatchScheduler(
            maxConcurrentRequests: 4,
            defaultMaxTokens: 4096
        )
        // Three sequential 5000-token bridges = 15000. Fourth would
        // need at most 1384 to fit (16384 - 15000).
        await scheduler._testSeedBridge(id: "a", promptTokens: 2500, maxTokens: 2500)
        await scheduler._testSeedBridge(id: "b", promptTokens: 2500, maxTokens: 2500)
        await scheduler._testSeedBridge(id: "c", promptTokens: 2500, maxTokens: 2500)

        let fitting = await scheduler.checkCumulativeTokenBudget(
            requestId: "d-small", requestBudget: 1000
        )
        let overflowing = await scheduler.checkCumulativeTokenBudget(
            requestId: "d-big", requestBudget: 2000
        )
        #expect(fitting == nil, "1000-budget fits in remaining 1384")
        #expect(overflowing != nil, "2000-budget exceeds remaining 1384 → reject")
    }

    /// Pin the planner-rejection → error-string mapping. Same coordinator
    /// requirement: `token_budget_exhausted:` prefix must be present so
    /// downstream parsing keeps working.
    @Test("errorMessage(for:) covers every planner rejection reason")
    func errorMessageCoversAllRejectionReasons() {
        let cases: [(BatchRejectionReason, String)] = [
            (.requestExceedsActiveTokenBudget, "active token budget"),
            (.requestExceedsBatchTokenBudget, "batch token budget"),
            (.queueFull, "queue full"),
            (.duplicateRequestID, "duplicate request ID"),
            (.invalidTokenCount, "invalid token count"),
        ]
        for (reason, fragment) in cases {
            let msg = BatchScheduler.errorMessage(for: reason)
            #expect(msg.hasPrefix("token_budget_exhausted:"),
                "\(reason) must emit a token_budget_exhausted: prefixed string")
            #expect(msg.contains(fragment),
                "expected '\(fragment)' in '\(msg)' for \(reason)")
        }
    }

    // MARK: - P2: in-flight bridge progress visible to heartbeats

    /// Pre-fix: `BridgeState.completionTokens` was assigned only in
    /// `recordFinish`, so heartbeats read 0 mid-decode.
    /// Post-fix: `recordProgress` (called from the bridge Task on every
    /// non-empty RequestOutput) keeps it live.
    @Test("backendCapacity reports in-flight completionTokens via recordProgress")
    func backendCapacityReflectsInFlightProgress() async {
        let scheduler = BatchScheduler(
            maxConcurrentRequests: 4,
            defaultMaxTokens: 4096
        )
        await scheduler._testSeedBridge(
            id: "test-req",
            promptTokens: 100,
            maxTokens: 50,
            admitted: true
        )

        // Pre-progress: activeTokens = prompt only (completion = 0).
        var cap = await scheduler.backendCapacity()
        #expect(cap.slots.count == 1)
        #expect(cap.slots[0].activeTokens == 100,
            "pre-progress activeTokens must equal promptTokens (no completion yet)")

        // Simulate stream Task delivering cumulative completion = 3.
        await scheduler.recordProgress(
            requestId: "test-req",
            promptTokens: 100,
            completionTokens: 3
        )

        cap = await scheduler.backendCapacity()
        #expect(cap.slots[0].activeTokens == 103,
            "P2: backendCapacity must reflect in-flight decode (100 prompt + 3 completion)")
    }

    /// `recordProgress` must be monotonic on `completionTokens` so that
    /// an out-of-order stale RequestOutput cannot rewind the counter.
    @Test("recordProgress is monotonic on completionTokens")
    func recordProgressIsMonotonic() async {
        let scheduler = BatchScheduler()
        await scheduler._testSeedBridge(
            id: "r",
            promptTokens: 10,
            maxTokens: 100,
            admitted: true
        )

        await scheduler.recordProgress(requestId: "r", promptTokens: 10, completionTokens: 5)
        await scheduler.recordProgress(requestId: "r", promptTokens: 10, completionTokens: 2)  // stale

        let cap = await scheduler.backendCapacity()
        #expect(cap.slots[0].activeTokens == 15,
            "stale (lower) completionTokens must not rewind activeTokens")
    }

    // MARK: - P2: adaptive cap uses running rows, not all bridges

    /// Pre-fix: `recordBatchPerformance(observedBatchSize:
    /// activeBridges.count + 1)` counted queued-not-yet-admitted
    /// bridges. Post-fix: only bridges with `admittedAt != nil` count.
    /// Seed 2 admitted + 1 queued; finish one admitted bridge; verify
    /// the bucket key landed under 2 (= 1 remaining-running + 1
    /// just-finished), not 3 (would include the queued bridge).
    @Test("recordFinish samples observedBatchSize using admitted-and-running bridges")
    func observedBatchSizeUsesRunningRows() async {
        let scheduler = BatchScheduler()
        await scheduler._testSeedBridge(
            id: "running-1", promptTokens: 10, maxTokens: 10, admitted: true)
        await scheduler._testSeedBridge(
            id: "running-2", promptTokens: 10, maxTokens: 10, admitted: true)
        await scheduler._testSeedBridge(
            id: "queued-1", promptTokens: 10, maxTokens: 10, admitted: false)

        // Finish one of the running bridges. Pre-fix: observedBatchSize
        // = 3 (remaining bridges incl. queued) + 1 = 4 → wrong bucket.
        // Post-fix: = (1 admitted-still-running) + 1 = 2 → correct.
        _ = await scheduler.recordFinish(
            requestId: "running-1",
            promptTokens: 10,
            completionTokens: 5,
            success: true
        )

        let buckets = await scheduler.performanceByBatchSize
        #expect(buckets.keys.contains(2),
            "P2: observedBatchSize must come from admitted-and-running bridges (expected key=2, got \(Array(buckets.keys).sorted()))")
        #expect(!buckets.keys.contains(3),
            "P2: queued-not-admitted bridges must NOT inflate observedBatchSize")
    }
}
