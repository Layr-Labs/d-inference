// Copyright © 2026 Eigen Labs.
//
// BatchScheduler KV reservation + admission: reserve byte budget for a request
// (restore- vs cold-sized), confirm enqueue, and release per-request resources.

import CryptoKit
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import ProviderCoreFoundation
import os

extension BatchScheduler {
    /// Which reservation `reserveKVForRequest` actually secured. The submit
    /// paths MUST branch on this — capturing `acceptedRestore != nil` before the
    /// reserve is not enough, because the reserve can DOWNGRADE a restore to a
    /// cold prefill when the restore-sized headroom is unavailable. Materializing
    /// the restore-sized KV against a cold-sized reservation under-reserves and
    /// OOMs under exactly the memory pressure that forced the downgrade.
    enum KVReservationOutcome {
        /// The restore-sized reservation is held; the restore may materialize.
        case restoreReserved
        /// Only the cold (requestTokens) reservation is held — either no restore
        /// was planned, or a planned restore was downgraded. The restore must be
        /// SKIPPED entirely; the request proceeds as a cold prefill.
        case coldReserved
        /// No reservation could be secured; the submit must reject the request.
        case failed
    }

    internal func reserveKVForRequest(
        requestId: String,
        requestTokens: Int,
        reservationTokens: Int,
        restorePlanned: Bool
    ) async -> KVReservationOutcome {
        // No budgeting: preserve the legacy "always proceed" behavior. If a
        // restore was planned, treat it as restore-reserved so the restore still
        // materializes when budgeting is disabled (the happy path is unchanged).
        guard let kvBudget else {
            return restorePlanned ? .restoreReserved : .coldReserved
        }
        if await kvBudget.reserve(
            requestID: requestId,
            kvBytesPerToken: kvBytesPerToken,
            tokenCount: reservationTokens
        ) {
            // The reservation we asked for landed. When a restore was planned
            // the requested amount IS the restore-sized reservation; otherwise
            // it's the cold footprint (reservationTokens == requestTokens).
            return restorePlanned ? .restoreReserved : .coldReserved
        }

        // A restored checkpoint hit can require materially more headroom than
        // a cold prefill because restored KV is already materialized. If that
        // larger reservation fails, drop the restore and retry the normal
        // request reservation so the cache miss is slow, not fatal.
        guard restorePlanned, reservationTokens > requestTokens else {
            return .failed
        }

        if var bridge = activeBridges[requestId] {
            bridge.reservedTokens = nil
            activeBridges[requestId] = bridge
        }
        prefixCacheLogger.warning(
            "prefix cache restore skipped: insufficient KV headroom; falling back to cold prefill")

        let coldReserved = await kvBudget.reserve(
            requestID: requestId,
            kvBytesPerToken: kvBytesPerToken,
            tokenCount: requestTokens
        )
        // Downgraded to cold: the caller MUST NOT materialize the restore — only
        // the cold reservation is held. bridge.reservedTokens is already nil
        // (cleared above) so activeTokenBudgetUsed already reflects the cold size.
        return coldReserved ? .coldReserved : .failed
    }

    /// Stale-engine enqueue guard: `submit`/`submitTokenized` capture
    /// `engine` at the top, then `await` planner admission, KV reservation, and
    /// checkpoint restore before `engine.core.addRequest`. A concurrent
    /// `stopCurrentEngine()`/`loadModel()` can bump `generationEpoch` and
    /// `engine.stop()` the captured engine during those awaits — enqueuing onto a
    /// stopped/superseded engine (request hangs / lands on the wrong model).
    /// Returns true iff `capturedEpoch` still matches AND `self.engine` is still
    /// the captured instance, so the caller may proceed to addRequest. The
    /// epoch + identity pair mirrors the load-side guards in `loadModel`.
    internal func engineStillCurrent(_ capturedEpoch: UInt64, _ capturedEngine: BatchedEngine) -> Bool {
        capturedEpoch == generationEpoch && self.engine === capturedEngine
    }

    /// Stale-engine enqueue guard, part 2: the pre-`addRequest` guard
    /// (`engineStillCurrent`) is necessary but NOT sufficient. `EngineCore.addRequest`
    /// does the real `scheduler.addRequest` inside an `engineQueue.async` block
    /// with no `_running` check, and `stopCurrentEngine`'s `abortAllRequests()`
    /// snapshots the collector keys BEFORE dispatching aborts — so a stop that
    /// interleaves between our guard and the queued add executing will (a) miss
    /// this request in the abort snapshot and (b) still run `scheduler.addRequest`
    /// on a stopped scheduler → the request never steps and the stream hangs.
    /// `addRequest`'s continuation resumes only AFTER its queued block ran, so by
    /// the time this is called the request IS registered. Two ways it can be
    /// unsafe to proceed to `runBridge`:
    ///
    ///   1. The engine was superseded (reload/unload) during the submit awaits —
    ///      `!engineStillCurrent`. The add landed on a stopped/replaced engine.
    ///   2. The request was cancelled or timed out WHILE the submit task was
    ///      suspended (planner.admit / KV reserve / checkpoint restore). The
    ///      cancel path / pending-timeout watchdog called `abortRequest` — which
    ///      no-op'd because the engine had no collector yet — and `dropBridge`'d
    ///      this id, so its bridge is gone from `activeBridges`. The submit task
    ///      then resumed and enqueued the request anyway; without this check it
    ///      would run untracked (KV/planner budget not accounted, no bridge to
    ///      tear it down) — the residual gap left after the pre-registration
    ///      cleanup fix.
    ///
    /// In either case abort the just-added request on the engine we added to
    /// (removes it from the scheduler and delivers a terminal output to unblock
    /// any stream) and release this request's resources. Returns true iff safe
    /// to runBridge.
    internal func confirmEnqueuedOrAbort(
        requestId: String, capturedEpoch: UInt64, capturedEngine: BatchedEngine
    ) async -> Bool {
        let superseded = !engineStillCurrent(capturedEpoch, capturedEngine)
        let bridgeDropped = activeBridges[requestId] == nil
        if !superseded && !bridgeDropped { return true }
        _ = capturedEngine.core.abortRequest(requestId)
        await releaseRequestResources(requestId)
        return false
    }

    /// Release everything a request holds, regardless of how far submit got.
    /// dropBridge handles the normal case (bridge still present → removes it,
    /// releases KV, cancels the planner, refreshes the summary), but it guards
    /// ALL of that behind "bridge was present", so it's a full no-op when the
    /// cancel/timeout path already removed the bridge — and that path can run
    /// BEFORE this submit reserved KV (cancel fires during planner.admit; the
    /// resumed submit then reserves at kvBudget.reserve). That late reservation
    /// would otherwise leak. So also release KV + cancel the planner entry
    /// UNCONDITIONALLY (both are idempotent: release/cancel on an unknown id is a
    /// no-op). Safe to call whether or not the bridge is still present.
    /// `internal` (not `private`) so the leak regression test can drive it
    /// directly — the full submit→cancel→resume interleaving needs a live engine.
    func releaseRequestResources(_ requestId: String) async {
        await dropBridge(requestId: requestId)
        await releaseKVReservation(requestID: requestId)
        if let planner = self.planner {
            _ = await planner.cancel(requestID: requestId)
        }
    }

}
