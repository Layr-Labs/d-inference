// Non-live unit tests for the BatchScheduler cumulative-budget gate
// (P1 fix) and in-flight bridge progress reporting (P2 fix). These
// exercise the actor's bookkeeping directly via `@testable import`
// hooks (`_testSeedBridge`); the full submit -> reject flow is covered
// by the live tests in BatchSchedulerEngineIntegrationTests.

import Foundation
import Testing
@testable import MLX
@testable import MLXLMCommon
@testable import ProviderCore

private let restoreB = 1
private let restoreH = 1
private let restoreD = 2

private func schedulerSimpleCache(tokens n: Int, heads: Int = restoreH, dim: Int = restoreD) -> KVCacheSimple {
    let cache = KVCacheSimple()
    let k = MLXArray.ones([restoreB, heads, n, dim])
    let v = MLXArray.ones([restoreB, heads, n, dim]) * Float32(2)
    _ = cache.update(keys: k, values: v)
    eval(cache.innerState())
    return cache
}

private func schedulerRotatingCache(
    tokens n: Int,
    maxSize: Int,
    heads: Int = restoreH,
    dim: Int = restoreD
) -> RotatingKVCache {
    let cache = RotatingKVCache(maxSize: maxSize, keep: 0, step: maxSize)
    for _ in 0..<n {
        let k = MLXArray.ones([restoreB, heads, 1, dim])
        let v = MLXArray.ones([restoreB, heads, 1, dim]) * Float32(2)
        _ = cache.update(keys: k, values: v)
        eval(cache.innerState())
    }
    return cache
}

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

    /// Restored checkpoint hits can hold more live KV than their prompt+decode
    /// token count because the restored cache is already materialized. The
    /// scheduler's active-budget view must charge the explicit reservation, not
    /// the billing prompt count, or concurrent restored hits can overcommit MLX.
    @Test("activeTokenBudgetUsed uses restored checkpoint reservation when present")
    func activeTokenBudgetUsesRestoredReservation() async {
        let scheduler = BatchScheduler(
            maxConcurrentRequests: 4,
            defaultMaxTokens: 4096
        )

        await scheduler._testSeedBridge(
            id: "restore",
            promptTokens: 100,
            maxTokens: 20,
            reservedTokens: 500
        )

        #expect(await scheduler.activeTokenBudgetUsed == 500,
            "restored checkpoint bridges must charge their memory reservation, not prompt+max tokens")
    }

    /// Guard the pre-MLX restore gate. The crash class here is fatal inside MLX,
    /// so a bad checkpoint must be rejected before `EngineCore.addRequest`.
    @Test("restored checkpoint geometry rejects unsafe cache layouts")
    func restoredCheckpointGeometryRejectsUnsafeLayouts() {
        let shape = CheckpointLayerShape(kvHeads: restoreH, headDim: restoreD)
        let expected: [CheckpointLayerSignature] = [
            .simple(shape: shape),
            .rotating(window: 4, shape: shape),
        ]
        let valid: [any KVCache] = [
            schedulerSimpleCache(tokens: 6),
            schedulerRotatingCache(tokens: 6, maxSize: 4),
        ]

        #expect(BatchScheduler.restoredCheckpointIsUsable(
            caches: valid,
            expected: expected,
            tokenCount: 6,
            promptTokenCount: 9
        ))

        let wrongSimpleCount: [any KVCache] = [
            schedulerSimpleCache(tokens: 5),
            schedulerRotatingCache(tokens: 6, maxSize: 4),
        ]
        #expect(!BatchScheduler.restoredCheckpointIsUsable(
            caches: wrongSimpleCount,
            expected: expected,
            tokenCount: 6,
            promptTokenCount: 9
        ))

        let wrongRotatingWindow: [any KVCache] = [
            schedulerSimpleCache(tokens: 6),
            schedulerRotatingCache(tokens: 6, maxSize: 8),
        ]
        #expect(!BatchScheduler.restoredCheckpointIsUsable(
            caches: wrongRotatingWindow,
            expected: expected,
            tokenCount: 6,
            promptTokenCount: 9
        ))

        let wrongHeadShape: [any KVCache] = [
            schedulerSimpleCache(tokens: 6, heads: 2),
            schedulerRotatingCache(tokens: 6, maxSize: 4),
        ]
        #expect(!BatchScheduler.restoredCheckpointIsUsable(
            caches: wrongHeadShape,
            expected: expected,
            tokenCount: 6,
            promptTokenCount: 9
        ))

        let wrongLayerOrder: [any KVCache] = [
            schedulerRotatingCache(tokens: 6, maxSize: 4),
            schedulerSimpleCache(tokens: 6),
        ]
        #expect(!BatchScheduler.restoredCheckpointIsUsable(
            caches: wrongLayerOrder,
            expected: expected,
            tokenCount: 6,
            promptTokenCount: 9
        ))

        #expect(!BatchScheduler.restoredCheckpointIsUsable(
            caches: valid,
            expected: expected,
            tokenCount: 9,
            promptTokenCount: 9
        ), "full-prompt restore is not a suffix decode and must be skipped")
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

    // MARK: - Billing-zero leak: terminal must not zero observed tokens

    /// Regression for the revenue leak: when the engine's terminal
    /// `RequestOutput` reports fewer tokens (often 0) than were already observed
    /// streaming, `recordFinish` must return the MAX of observed-vs-terminal,
    /// not the terminal value. Pre-fix it overwrote the live count, so a
    /// completed request settled at (0,0) → coordinator billed $0 and refunded.
    @Test("recordFinish bills max(observed, terminal) completion tokens")
    func recordFinishUsesMaxObservedTokens() async {
        let scheduler = BatchScheduler()
        await scheduler._testSeedBridge(
            id: "bill-1", promptTokens: 12, maxTokens: 100, admitted: true)

        // Streaming observed 20 completion tokens (and 12 prompt tokens)...
        await scheduler.recordProgress(
            requestId: "bill-1", promptTokens: 12, completionTokens: 20)

        // ...but the terminal output under-reports both as 0 (the bug trigger).
        let usage = await scheduler.recordFinish(
            requestId: "bill-1", promptTokens: 0, completionTokens: 0, success: true)

        #expect(usage.completionTokens == 20,
            "terminal zero must not zero out the 20 observed completion tokens (billing-zero leak)")
        #expect(usage.promptTokens == 12,
            "prompt tokens must survive a terminal that under-reports them")
    }

    // MARK: - Cancel/timeout cleanup for a not-yet-engine-registered request

    /// A request can sit in `activeBridges` with a KV
    /// reservation BEFORE it is registered with EngineCore (still mid-submit, or
    /// its `addRequest` engineQueue block hasn't run). `EngineCore.abortRequest`
    /// returns false for such an id (no collector), so the pre-fix `cancel()`
    /// — which early-returned right after `abortRequest` in the engine branch —
    /// left the bridge + KV reservation + planner entry stranded. Post-fix:
    /// `cancel` falls through to `dropBridge` (+ planner/KV release) when the
    /// engine abort no-ops. Here `engine == nil` exercises that fall-through
    /// deterministically. Revert-guard: restore the early `return` after
    /// abortRequest (or drop the dropBridge call) and the KV bytes leak → fails.
    @Test("cancel() releases bridge + KV reservation for a not-yet-registered request")
    func cancelDropsUnregisteredBridgeAndKV() async {
        let kvBudget = GlobalKVCacheBudget()
        let scheduler = BatchScheduler(
            maxConcurrentRequests: 4, defaultMaxTokens: 4096, kvBudget: kvBudget)

        // Simulate a submitted-but-not-yet-engine-registered request: a bridge
        // in activeBridges plus a live KV reservation under the same id.
        await scheduler._testSeedBridge(id: "r1", promptTokens: 100, maxTokens: 100)
        let reserved = await kvBudget.reserve(requestID: "r1", kvBytesPerToken: 1024, tokenCount: 200)
        #expect(reserved, "precondition: KV reservation succeeds")
        #expect(await kvBudget.outstandingReservedBytes() > 0, "precondition: bytes reserved")
        #expect(await scheduler.activeTokenBudgetUsed == 200, "precondition: bridge counted")

        // Cancel. With no engine, the fixed cancel() must still drop the bridge
        // and release the KV reservation (the leak the pre-fix code left behind).
        await scheduler.cancel(requestId: "r1")

        #expect(await scheduler.activeTokenBudgetUsed == 0,
            "Cancel must drop the bridge for a not-yet-registered request")
        #expect(await kvBudget.outstandingReservedBytes() == 0,
            "Cancel must release the KV reservation for a not-yet-registered request")
    }

    /// Regression for the residual gap after the pre-registration cleanup fix:
    /// a request cancelled WHILE its submit task is suspended (planner.admit /
    /// KV reserve / checkpoint restore) has its bridge `dropBridge`'d by the
    /// cancel path. When the submit task later resumes and enqueues, the
    /// post-`addRequest` guard (`confirmEnqueuedOrAbort`) must detect the missing
    /// bridge and refuse to proceed — otherwise the cancelled request runs
    /// untracked and leaks its KV reservation. This pins the SIGNAL that guard
    /// uses: after a cancel, the bridge is gone. (The full submit→suspend→cancel→
    /// resume interleaving needs a live engine — `BatchedEngine` is concrete and
    /// can't be stubbed — so the guard wiring itself is verified by inspection;
    /// this test pins the bridge-presence signal it keys on.)
    @Test("a cancelled request's bridge is gone, so the post-addRequest guard bails")
    func cancelledRequestBridgeIsDroppedBeforeResume() async {
        let kvBudget = GlobalKVCacheBudget()
        let scheduler = BatchScheduler(
            maxConcurrentRequests: 4, defaultMaxTokens: 4096, kvBudget: kvBudget)

        await scheduler._testSeedBridge(id: "r1", promptTokens: 100, maxTokens: 100)
        _ = await kvBudget.reserve(requestID: "r1", kvBytesPerToken: 1024, tokenCount: 200)
        #expect(await scheduler._bridgeIsActiveForTest("r1"), "precondition: bridge tracked")

        // Cancel arrives while the (hypothetical) submit task is still suspended
        // pre-addRequest. The bridge must be gone afterward — the exact condition
        // confirmEnqueuedOrAbort checks (`activeBridges[id] == nil`) to bail.
        await scheduler.cancel(requestId: "r1")

        #expect(await scheduler._bridgeIsActiveForTest("r1") == false,
            "a cancelled request must leave no bridge for the resumed submit to proceed on")
        #expect(await kvBudget.outstandingReservedBytes() == 0,
            "the cancelled request's KV reservation must be released, not leaked")
    }

    /// Regression for the LATE-reservation leak: cancel can drop the bridge
    /// BEFORE the submit task reserves KV (cancel fires during planner.admit;
    /// the resumed submit then calls kvBudget.reserve). The bail-path cleanup
    /// (releaseRequestResources, invoked by confirmEnqueuedOrAbort) must release
    /// that reservation even though the bridge is already gone — dropBridge alone
    /// no-ops in that case (it guards on bridge-present), leaking the bytes.
    /// Revert-guard: drop the unconditional releaseKVReservation from
    /// releaseRequestResources and outstandingReservedBytes stays > 0 → fails.
    @Test("late KV reservation is released when the bridge was already cancelled")
    func lateKVReservationReleasedAfterCancel() async {
        let kvBudget = GlobalKVCacheBudget()
        let scheduler = BatchScheduler(
            maxConcurrentRequests: 4, defaultMaxTokens: 4096, kvBudget: kvBudget)

        // 1. Bridge seeded (submit past the cumulative gate), no KV reserved yet.
        await scheduler._testSeedBridge(id: "r1", promptTokens: 100, maxTokens: 100)
        // 2. Cancel fires while submit is suspended in planner.admit: drops the
        //    bridge; the KV release inside it is a no-op (nothing reserved yet).
        await scheduler.cancel(requestId: "r1")
        #expect(await scheduler._bridgeIsActiveForTest("r1") == false, "bridge dropped by cancel")
        // 3. Submit RESUMES and reserves KV for the (already-cancelled) request.
        let reserved = await kvBudget.reserve(requestID: "r1", kvBytesPerToken: 1024, tokenCount: 200)
        #expect(reserved, "the resumed submit reserves KV after the cancel")
        #expect(await kvBudget.outstandingReservedBytes() > 0, "reservation now live")

        // 4. confirmEnqueuedOrAbort sees the missing bridge and bails via
        //    releaseRequestResources — which must release the late reservation.
        await scheduler.releaseRequestResources("r1")

        #expect(await kvBudget.outstandingReservedBytes() == 0,
            "the late KV reservation must be released on the bail path (dropBridge alone no-ops)")
    }

    // MARK: - PR #325 review: reservation leak on materialize fallback (BUG 1)

    /// A planned + accepted restore charges BOTH accounting systems with the
    /// restore-sized (oversized) amount up front: (1) `bridge.reservedTokens`
    /// feeding `activeTokenBudgetUsed`, and (2) the global kvBudget byte
    /// reservation. When `materializeRestoredCheckpoint` then FALLS BACK
    /// (manager missing, materialize nil, bad geometry, or actual > estimate),
    /// `req.restoredCheckpoint` stays nil — correct cold prefill — but pre-fix
    /// BOTH reservations stayed at the restore size for the request's whole life,
    /// permanently over-charging admission under exactly the OOM pressure that
    /// triggers restore failures. Post-fix `finalizeRestore` downgrades both to
    /// the cold `requestBudget` footprint.
    ///
    /// This drives the REAL `finalizeRestore` via `_testFinalizeRestoreFallback`
    /// (no checkpointManager → materialize short-circuits to false → the
    /// downgrade branch runs). Revert-guard: remove the downgrade in
    /// `finalizeRestore` and both assertions below flip to the restore-sized
    /// amount → fails.
    @Test("materialize fallback downgrades BOTH reservations to the cold footprint")
    func materializeFallbackDowngradesBothReservations() async {
        let kvBudget = GlobalKVCacheBudget()
        let scheduler = BatchScheduler(
            maxConcurrentRequests: 4, defaultMaxTokens: 4096, kvBudget: kvBudget)
        await scheduler._setKvBytesPerTokenForTest(1024)

        // Cold footprint = prompt(100) + max(20) = 120 tokens. Restore was
        // accepted at an oversized 500-token reservation.
        let promptTokens = Array(repeating: 1, count: 100)
        let coldBudget = 120
        let restoreTokens = 500

        await scheduler._testSeedBridge(
            id: "restore", promptTokens: 100, maxTokens: 20, reservedTokens: restoreTokens)
        let reserved = await kvBudget.reserve(
            requestID: "restore", kvBytesPerToken: 1024, tokenCount: restoreTokens)
        #expect(reserved, "precondition: oversized restore reservation succeeds")
        #expect(await scheduler.activeTokenBudgetUsed == restoreTokens,
            "precondition: scheduler budget charges the restore-sized reservation")
        #expect(await kvBudget.outstandingReservedBytes() == UInt64(restoreTokens) * 1024,
            "precondition: global KV bytes charge the restore-sized reservation")

        // Materialize falls back (no manager) → both systems must downgrade.
        await scheduler._testFinalizeRestoreFallback(
            id: "restore",
            promptTokens: promptTokens,
            maxTokens: 20,
            reservedTokens: restoreTokens,
            requestBudget: coldBudget
        )

        // (1) global KV reservation == cold bytes, NOT the restore-sized amount.
        #expect(await kvBudget.outstandingReservedBytes() == UInt64(coldBudget) * 1024,
            "BUG 1: global KV reservation must shrink to the cold requestBudget bytes on fallback")
        // (2) bridge.reservedTokens == nil → (3) activeTokenBudgetUsed reflects
        // cold (prompt + max), not the restore-sized reservation.
        #expect(await scheduler.activeTokenBudgetUsed == coldBudget,
            "BUG 1: scheduler budget must fall back to (prompt + max), proving reservedTokens == nil")
    }

    /// `reduceReservation` is shrink-only and atomic: it must never raise an
    /// existing reservation, and must no-op on an unknown id (so a fallback for a
    /// request whose reservation was already released by a concurrent cancel does
    /// not resurrect bytes).
    @Test("reduceReservation only ever shrinks and no-ops on unknown ids")
    func reduceReservationShrinksOnly() async {
        let kvBudget = GlobalKVCacheBudget()
        _ = await kvBudget.reserve(requestID: "r", kvBytesPerToken: 1024, tokenCount: 500)
        let before = await kvBudget.outstandingReservedBytes()
        #expect(before == UInt64(500) * 1024)

        // Attempt to GROW → must be ignored.
        await kvBudget.reduceReservation(requestID: "r", kvBytesPerToken: 1024, tokenCount: 900)
        #expect(await kvBudget.outstandingReservedBytes() == before,
            "reduceReservation must never grow a reservation")

        // Shrink → frees the difference.
        await kvBudget.reduceReservation(requestID: "r", kvBytesPerToken: 1024, tokenCount: 120)
        #expect(await kvBudget.outstandingReservedBytes() == UInt64(120) * 1024,
            "reduceReservation must shrink to the smaller footprint")

        // Unknown id → no-op (does not create a reservation).
        await kvBudget.reduceReservation(requestID: "ghost", kvBytesPerToken: 1024, tokenCount: 50)
        #expect(await kvBudget.outstandingReservedBytes() == UInt64(120) * 1024,
            "reduceReservation on an unknown id must not resurrect/create bytes")
    }

    // MARK: - PR #325 review: use-after-release during materialization (BUG 2)

    /// During the expensive `mgr.materialize` await, a cancel/timeout can run the
    /// bridge cancel path (releaseKVReservation + bridge drop). If materialize
    /// then attached the restored caches, they would be allocated against an
    /// already-released reservation. The post-materialize guard re-checks
    /// `activeBridges[req.requestId]`; if the bridge is gone it returns false
    /// WITHOUT setting `req.restoredCheckpoint`, and `finalizeRestore`'s downgrade
    /// then no-ops on KV (release already happened) without resurrecting bytes.
    ///
    /// The full submit→suspend-in-materialize→cancel interleaving needs a live
    /// engine + checkpoint manager (BatchedEngine is concrete and cannot be
    /// stubbed in a non-live unit test). Here we pin the SIGNAL the guard keys
    /// on — once a cancel has dropped the bridge, the fallback path attaches no
    /// checkpoint and leaves no dangling reservation. (The guard's exact wiring
    /// inside materializeRestoredCheckpoint is verified by inspection; the live
    /// submit→cancel interleaving is covered by BatchSchedulerEngineIntegration.)
    @Test("a cancel during restore leaves no checkpoint and no dangling reservation")
    func cancelDuringRestoreLeavesNoDanglingReservation() async {
        let kvBudget = GlobalKVCacheBudget()
        let scheduler = BatchScheduler(
            maxConcurrentRequests: 4, defaultMaxTokens: 4096, kvBudget: kvBudget)
        await scheduler._setKvBytesPerTokenForTest(1024)

        let promptTokens = Array(repeating: 1, count: 100)
        await scheduler._testSeedBridge(
            id: "restore", promptTokens: 100, maxTokens: 20, reservedTokens: 500)
        _ = await kvBudget.reserve(requestID: "restore", kvBytesPerToken: 1024, tokenCount: 500)

        // Cancel fires during materialization: drops the bridge + releases KV
        // (exactly what the EngineBridge cancel path does).
        await scheduler.cancel(requestId: "restore")
        #expect(await scheduler._bridgeIsActiveForTest("restore") == false,
            "precondition: cancel dropped the bridge mid-materialize")
        #expect(await kvBudget.outstandingReservedBytes() == 0,
            "precondition: cancel released the KV reservation")

        // The resumed materialize/finalize must NOT resurrect any reservation:
        // the bridge-presence guard returns false before attaching, and the
        // downgrade's reduceReservation no-ops on the already-released id.
        await scheduler._testFinalizeRestoreFallback(
            id: "restore",
            promptTokens: promptTokens,
            maxTokens: 20,
            reservedTokens: 500,
            requestBudget: 120
        )
        #expect(await kvBudget.outstandingReservedBytes() == 0,
            "BUG 2: a cancel during restore must leave no dangling KV reservation")
        #expect(await scheduler.activeTokenBudgetUsed == 0,
            "BUG 2: no bridge, no charge — the cancelled request must hold no budget")
    }

    // MARK: - Under-reserved restore on reserve downgrade (BUG 3)

    /// The reserve-time downgrade leak. `reserveKVForRequest` tries the
    /// restore-sized reservation first; when that fails under memory pressure it
    /// clears `bridge.reservedTokens` and reserves only the COLD footprint. The
    /// submit paths capture `acceptedRestore != nil` BEFORE the reserve, so
    /// pre-fix they still called `finalizeRestore` → `materializeRestoredCheckpoint`
    /// afterward. That helper's `actualReservation <= admission.reservedTokens`
    /// guard compares actual-vs-estimate (both restore-sized) and never against
    /// the cold reservation actually held, so it ATTACHED restore-sized KV backed
    /// by only a cold reservation → under-reserved → OOM under exactly the memory
    /// pressure that forced the downgrade. The whole point of #324/#325 is
    /// "restore never OOMs," so this must be closed.
    ///
    /// Post-fix `reserveKVForRequest` reports WHICH reservation it secured. When
    /// the restore-sized reserve fails but the cold reserve succeeds, the outcome
    /// is `.coldReserved`, and the submit paths SKIP restore entirely (the
    /// request runs as a cold prefill). This drives the REAL `reserveKVForRequest`
    /// via `_testReserveKVForRequest`, using a `GlobalKVCacheBudget` whose memory
    /// snapshot fits the cold footprint but not the restore-sized one, and proves:
    /// (1) outcome == .coldReserved, (2) the held reservation == cold bytes (not
    /// restore-sized), (3) bridge.reservedTokens was cleared by the downgrade so
    /// the request attaches NO restored checkpoint (activeTokenBudgetUsed == cold
    /// prompt+max). Revert-guard: make `reserveKVForRequest` return a Bool again
    /// (so the submit path materializes the restore against the cold reservation)
    /// and the outcome can no longer distinguish restore from cold → fails.
    @Test("a reserve downgrade reports .coldReserved and holds only the cold footprint")
    func reserveDowngradeReportsColdReservedAndHoldsColdBytes() async {
        // total memory fits the cold reservation (120 * 1024 = 122_880 B) but not
        // the restore-sized one (500 * 1024 = 512_000 B). safetyFactor 1.0,
        // reserveBytes 0, active/cache 0 → availableReservationBytes() == total.
        let kvBudget = GlobalKVCacheBudget(
            reserveBytes: 0,
            safetyFactor: 1.0,
            memorySnapshot: { GlobalKVCacheBudget.MemorySnapshot(total: 200_000, active: 0, cache: 0, systemAvailable: .max) }
        )
        let scheduler = BatchScheduler(
            maxConcurrentRequests: 4, defaultMaxTokens: 4096, kvBudget: kvBudget)
        await scheduler._setKvBytesPerTokenForTest(1024)

        let promptTokens = Array(repeating: 1, count: 100)
        let coldBudget = 120  // prompt(100) + max(20)
        let restoreTokens = 500

        // Submit seeds the bridge with the restore-sized reservation BEFORE the
        // reserve runs (acceptRestoredCheckpointBudget set bridge.reservedTokens).
        await scheduler._testSeedBridge(
            id: "restore", promptTokens: 100, maxTokens: 20, reservedTokens: restoreTokens)
        #expect(await scheduler.activeTokenBudgetUsed == restoreTokens,
            "precondition: bridge charges the restore-sized reservation before reserve")

        // Drive the REAL reserve followed by the REAL submit-path restore
        // decision (materialize iff outcome == .restoreReserved). restore-sized
        // fails (512_000 > 200_000), cold succeeds (122_880 <= 200_000) →
        // .coldReserved → restore SKIPPED → req.restoredCheckpoint stays nil.
        let result = await scheduler._testReserveThenMaybeRestore(
            id: "restore",
            promptTokens: promptTokens,
            maxTokens: 20,
            requestBudget: coldBudget,
            reservationTokens: restoreTokens
        )
        #expect(result.outcome == .coldReserved,
            "BUG 3: a restore that downgrades to cold must report .coldReserved, not success")

        // (1) Only the cold reservation is held — NOT the restore-sized amount.
        #expect(await kvBudget.outstandingReservedBytes() == UInt64(coldBudget) * 1024,
            "BUG 3: the downgrade must hold exactly the cold requestBudget bytes")

        // (2) bridge.reservedTokens was cleared by the downgrade → the scheduler
        // budget falls back to (prompt + max), proving the restore is dropped.
        #expect(await scheduler.activeTokenBudgetUsed == coldBudget,
            "BUG 3: the downgrade must clear bridge.reservedTokens so no restore-sized charge survives")

        // (3) The submit path branched on .coldReserved → never called
        // finalizeRestore → req.restoredCheckpoint stayed nil (cold prefill).
        #expect(result.restoredCheckpointWasNil,
            "BUG 3: a .coldReserved request must attach NO restored checkpoint")
    }

    /// Companion happy-path: when the restore-sized reservation DOES fit, the
    /// outcome is `.restoreReserved` and the full restore-sized amount is held —
    /// so the submit path proceeds to materialize the restore. Guards against an
    /// over-eager downgrade that would turn every restore into a cold prefill.
    @Test("a restore that fits reports .restoreReserved and holds the restore footprint")
    func reserveThatFitsReportsRestoreReserved() async {
        let kvBudget = GlobalKVCacheBudget(
            reserveBytes: 0,
            safetyFactor: 1.0,
            memorySnapshot: { GlobalKVCacheBudget.MemorySnapshot(total: 1_000_000, active: 0, cache: 0, systemAvailable: .max) }
        )
        let scheduler = BatchScheduler(
            maxConcurrentRequests: 4, defaultMaxTokens: 4096, kvBudget: kvBudget)
        await scheduler._setKvBytesPerTokenForTest(1024)

        let restoreTokens = 500
        await scheduler._testSeedBridge(
            id: "restore", promptTokens: 100, maxTokens: 20, reservedTokens: restoreTokens)

        let outcome = await scheduler._testReserveKVForRequest(
            requestId: "restore",
            requestTokens: 120,
            reservationTokens: restoreTokens,
            restorePlanned: true
        )
        #expect(outcome == .restoreReserved,
            "a restore-sized reservation that fits must report .restoreReserved")
        #expect(await kvBudget.outstandingReservedBytes() == UInt64(restoreTokens) * 1024,
            "the held reservation must be the full restore-sized amount when it fits")
        #expect(await scheduler.activeTokenBudgetUsed == restoreTokens,
            "the restore-sized bridge charge must survive when the reserve succeeds")
    }

    /// A cold (no-restore) request must reserve + run exactly as before. With no
    /// restore planned the requested amount IS the cold footprint, so a
    /// successful reserve reports `.coldReserved` (the submit path then skips the
    /// restore block, which is correct — there was never a restore). A failed
    /// reserve reports `.failed`.
    @Test("a plain cold request reports .coldReserved on success and .failed on overflow")
    func plainColdRequestOutcomes() async {
        let fits = GlobalKVCacheBudget(
            reserveBytes: 0, safetyFactor: 1.0,
            memorySnapshot: { GlobalKVCacheBudget.MemorySnapshot(total: 1_000_000, active: 0, cache: 0, systemAvailable: .max) })
        let schedulerFits = BatchScheduler(
            maxConcurrentRequests: 4, defaultMaxTokens: 4096, kvBudget: fits)
        await schedulerFits._setKvBytesPerTokenForTest(1024)
        await schedulerFits._testSeedBridge(id: "cold", promptTokens: 100, maxTokens: 20)

        let coldOK = await schedulerFits._testReserveKVForRequest(
            requestId: "cold", requestTokens: 120, reservationTokens: 120, restorePlanned: false)
        #expect(coldOK == .coldReserved,
            "a plain cold request that fits must report .coldReserved (no restore to materialize)")
        #expect(await fits.outstandingReservedBytes() == UInt64(120) * 1024,
            "the cold reservation must be exactly the request footprint")

        // Tiny budget → even the cold reservation fails → .failed (no restore to
        // downgrade to). Mirrors the old `false` return.
        let tiny = GlobalKVCacheBudget(
            reserveBytes: 0, safetyFactor: 1.0,
            memorySnapshot: { GlobalKVCacheBudget.MemorySnapshot(total: 1_000, active: 0, cache: 0, systemAvailable: .max) })
        let schedulerTiny = BatchScheduler(
            maxConcurrentRequests: 4, defaultMaxTokens: 4096, kvBudget: tiny)
        await schedulerTiny._setKvBytesPerTokenForTest(1024)
        await schedulerTiny._testSeedBridge(id: "cold", promptTokens: 100, maxTokens: 20)

        let coldFail = await schedulerTiny._testReserveKVForRequest(
            requestId: "cold", requestTokens: 120, reservationTokens: 120, restorePlanned: false)
        #expect(coldFail == .failed,
            "a plain cold request that overflows must report .failed")
        #expect(await tiny.outstandingReservedBytes() == 0,
            "a failed cold reserve must hold no bytes")
    }

    /// No-budgeting path (kvBudget == nil): preserve the legacy "always proceed"
    /// behavior. A planned restore reports `.restoreReserved` (so the restore
    /// still materializes when budgeting is disabled); a cold request reports
    /// `.coldReserved`. Neither can fail.
    @Test("no-budgeting path proceeds: restore→.restoreReserved, cold→.coldReserved")
    func noBudgetingPathPreservesHappyPath() async {
        let scheduler = BatchScheduler(maxConcurrentRequests: 4, defaultMaxTokens: 4096)
        await scheduler._testSeedBridge(id: "r", promptTokens: 100, maxTokens: 20)

        let restore = await scheduler._testReserveKVForRequest(
            requestId: "r", requestTokens: 120, reservationTokens: 500, restorePlanned: true)
        #expect(restore == .restoreReserved,
            "with no kvBudget, a planned restore must still materialize (.restoreReserved)")

        let cold = await scheduler._testReserveKVForRequest(
            requestId: "r", requestTokens: 120, reservationTokens: 120, restorePlanned: false)
        #expect(cold == .coldReserved,
            "with no kvBudget, a cold request proceeds as .coldReserved")
    }
}
