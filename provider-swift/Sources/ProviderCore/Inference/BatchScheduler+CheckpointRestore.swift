// Copyright © 2026 Eigen Labs.
//
// BatchScheduler prefix-cache checkpoint restore: plan/materialize/finalize a
// restored KV checkpoint, validate restored layer shapes, and size the
// restored-token budget before it reaches the engine.

import CryptoKit
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import ProviderCoreFoundation
import os

extension BatchScheduler {
    /// Checkpoint-tier preflight: find a restore candidate and estimate its
    /// memory cost without copying RAM caches or decrypting SSD chunks. The
    /// caller reserves budget before `materializeRestoredCheckpoint` touches
    /// tensors.
    ///
    /// MLX shape/runtime errors are fatal traps, not Swift throws. Validate the
    /// restored checkpoint after materialization but before it reaches
    /// `EngineCore.addRequest`; any uncertainty becomes a cold prefill.
    internal func planRestoredCheckpoint(
        promptTokens: [Int],
        scope: String,
        maxTokens: Int
    ) async -> RestoredCheckpointAdmission? {
        guard let mgr = checkpointManager else { return nil }
        guard let candidate = await mgr.lookupCandidate(tokens: promptTokens, scope: scope),
              candidate.tokenCount >= 1, candidate.tokenCount < promptTokens.count
        else { return nil }

        return RestoredCheckpointAdmission(
            candidate: candidate,
            reservedTokens: restoredCheckpointReservedTokens(
                restoredBytes: candidate.estimatedBytes,
                promptTokenCount: promptTokens.count,
                restoredTokenCount: candidate.tokenCount,
                maxTokens: maxTokens
            )
        )
    }

    /// Materialize an already-admitted checkpoint candidate and attach it to the
    /// MLX request. This intentionally runs after KV reservation.
    ///
    /// Returns `true` iff the restore was actually attached to `req`
    /// (`req.restoredCheckpoint` set). All four fallback branches — no manager,
    /// materialize returned nil, geometry unusable, or the materialized KV
    /// exceeded the admitted estimate — return `false` so the caller can
    /// downgrade BOTH the scheduler token budget and the global KV-byte
    /// reservation back to the cold-prefill footprint (otherwise the
    /// restore-sized reservation leaks for the request's whole life → admission
    /// starvation under exactly the OOM pressure that triggers restore failures).
    private func materializeRestoredCheckpoint(
        _ req: Request,
        admission: RestoredCheckpointAdmission,
        promptTokens: [Int],
        scope: String
    ) async -> Bool {
        guard let mgr = checkpointManager else { return false }
        guard let hit = await mgr.materialize(
            candidate: admission.candidate,
            tokens: promptTokens,
            scope: scope
        ) else { return false }

        // Use-after-release guard: `mgr.materialize` is an expensive await (RAM
        // copy / SSD decrypt). A cancel or pending-timeout can run the bridge's
        // cancel path (releaseKVReservation + bridge drop) while it is in flight.
        // If the bridge is gone, the reservation these caches were sized against
        // has already been released — attaching them would allocate KV against a
        // freed reservation. Discard the materialized caches and report failure;
        // the cancel path already released the reservation, and the submit path's
        // `confirmEnqueuedOrAbort` will refuse to runBridge on the missing bridge.
        // `activeBridges` is this actor's own state — no extra lock needed.
        guard activeBridges[req.requestId] != nil else { return false }

        guard Self.restoredCheckpointIsUsable(
            caches: hit.caches,
            expected: checkpointLayerSignatures,
            tokenCount: hit.tokenCount,
            promptTokenCount: promptTokens.count
        ) else {
            prefixCacheLogger.warning(
                "prefix cache restore rejected: invalid checkpoint geometry; falling back to cold prefill")
            return false
        }

        let actualReservation = restoredCheckpointReservedTokens(
            caches: hit.caches,
            promptTokenCount: promptTokens.count,
            restoredTokenCount: hit.tokenCount,
            maxTokens: req.maxTokens
        )
        guard actualReservation <= admission.reservedTokens else {
            prefixCacheLogger.warning(
                "prefix cache restore skipped: materialized KV exceeded admitted estimate; falling back to cold prefill")
            return false
        }

        req.restoredCheckpoint = (caches: hit.caches, tokenCount: hit.tokenCount)
        // Record the restored prefix length on the bridge so `recordFinish`
        // excludes it from the prefill-rate EWMA: the admitted→first-token window
        // only covers prefilling the UNCACHED suffix, so dividing the FULL prompt
        // by it would inflate `observed_prefill_tps` far above the true
        // cold-prefill rate (now consumed by routing-v2 for TTFT estimates).
        // The bridge is guaranteed present here (checked above, no awaits since).
        if var bridge = activeBridges[req.requestId] {
            bridge.restoredPrefixTokens = hit.tokenCount
            activeBridges[req.requestId] = bridge
        }
        return true
    }

    /// Shared restore finalizer for both submit paths. Runs the expensive
    /// materialize and, when it falls back (returns false), downgrades BOTH
    /// accounting systems from the restore-sized reservation back to the cold
    /// `requestBudget` footprint:
    ///
    ///   1. scheduler token budget — clear `bridge.reservedTokens` so
    ///      `activeTokenBudgetUsed` falls back to (promptTokens + maxTokens),
    ///      mirroring the downgrade in `reserveKVForRequest`.
    ///   2. global KV bytes — `reduceReservation` shrinks the live reservation to
    ///      the cold size, atomically freeing the over-charged difference.
    ///
    /// When materialize SUCCEEDS both reservations stay at the restore-sized
    /// amount — the restored KV is really materialized, so that charge is correct.
    /// Factored out so the two submit paths share one definition (no drift).
    internal func finalizeRestore(
        _ req: Request,
        id: String,
        admission: RestoredCheckpointAdmission,
        promptTokens: [Int],
        scope: String,
        requestBudget: Int
    ) async {
        let attached = await materializeRestoredCheckpoint(
            req,
            admission: admission,
            promptTokens: promptTokens,
            scope: scope
        )
        guard !attached else { return }
        // Restore was planned + accepted (oversized reservations charged) but did
        // not materialize. Drop both systems back to the cold-prefill size.
        if var bridge = activeBridges[id] {
            bridge.reservedTokens = nil
            activeBridges[id] = bridge
        }
        await kvBudget?.reduceReservation(
            requestID: id,
            kvBytesPerToken: kvBytesPerToken,
            tokenCount: requestBudget
        )
    }

    static func restoredCheckpointIsUsable(
        caches: [any KVCache],
        expected: [CheckpointLayerSignature],
        tokenCount: Int,
        promptTokenCount: Int
    ) -> Bool {
        guard tokenCount >= 1, tokenCount < promptTokenCount else { return false }
        guard caches.count == expected.count, !caches.isEmpty else { return false }

        for (restored, signature) in zip(caches, expected) {
            guard restoredLayerIsUsable(restored, expected: signature, tokenCount: tokenCount) else {
                return false
            }
        }
        return true
    }

    private static func restoredLayerIsUsable(
        _ restored: any KVCache,
        expected: CheckpointLayerSignature,
        tokenCount: Int
    ) -> Bool {
        if restored is ArraysCache { return false }
        if restored is ChunkedKVCache { return false }
        if restored is QuantizedKVCache { return false }

        guard let shape = restoredKVShape(restored) else { return false }

        switch expected {
        case .rotating(let window, let expectedShape):
            guard let rot = restored as? RotatingKVCache, window > 0 else { return false }
            guard let restoredWindow = rot.maxSize, restoredWindow == window else { return false }
            guard restoredShapeMatches(shape, expected: expectedShape) else { return false }
            let storedTokens = shape.tokenCount
            let expectedStoredTokens = min(tokenCount, window)
            return storedTokens == expectedStoredTokens
        case .simple(let expectedShape):
            guard let simple = restored as? KVCacheSimple, !(restored is RotatingKVCache) else {
                return false
            }
            guard restoredShapeMatches(shape, expected: expectedShape) else { return false }
            return simple.offset == tokenCount && shape.tokenCount == tokenCount
        case .unsupported:
            return false
        }
    }

    private struct RestoredKVShape {
        let tokenCount: Int
        let kvHeads: Int
        let headDim: Int
    }

    private static func restoredKVShape(_ cache: any KVCache) -> RestoredKVShape? {
        let state = cache.state
        guard state.count >= 2 else { return nil }
        let k = state[0]
        let v = state[1]
        guard k.shape.count == 4, v.shape.count == 4 else { return nil }
        guard k.dim(0) == 1, v.dim(0) == 1 else { return nil }
        guard k.dim(1) == v.dim(1), k.dim(2) == v.dim(2) else { return nil }
        guard k.dim(3) == v.dim(3) else { return nil }
        guard k.dim(1) > 0, k.dim(2) > 0, k.dim(3) > 0 else { return nil }
        return RestoredKVShape(tokenCount: k.dim(2), kvHeads: k.dim(1), headDim: k.dim(3))
    }

    private static func restoredShapeMatches(_ restored: RestoredKVShape, expected: CheckpointLayerShape?) -> Bool {
        guard let expected else { return true }
        return restored.kvHeads == expected.kvHeads && restored.headDim == expected.headDim
    }

    /// Reserve for the original request plus restored-KV materialization.
    ///
    /// A checkpoint hit can hold multiple live copies briefly: the RAM/SSD hit
    /// copy returned by `PrefixCacheManager`, plus the B==1 batched cache that
    /// MLX builds for decode. Charge those copies explicitly so a restore that
    /// would fit as a cold prefill but not as restored KV is skipped before MLX
    /// can hit a fatal `metal::malloc`.
    private func restoredCheckpointReservedTokens(
        caches: [any KVCache],
        promptTokenCount: Int,
        restoredTokenCount: Int,
        maxTokens: Int
    ) -> Int {
        restoredCheckpointReservedTokens(
            restoredBytes: PrefixCacheRAM.byteSize(of: caches),
            promptTokenCount: promptTokenCount,
            restoredTokenCount: restoredTokenCount,
            maxTokens: maxTokens
        )
    }

    private func restoredCheckpointReservedTokens(
        restoredBytes: Int,
        promptTokenCount: Int,
        restoredTokenCount: Int,
        maxTokens: Int
    ) -> Int {
        let requestTokens = promptTokenCount + maxTokens
        guard kvBytesPerToken > 0 else { return requestTokens }
        let extraRestoredCopies = 2
        let chargedBytes = restoredBytes.multipliedReportingOverflow(by: extraRestoredCopies)
        let restoredEquivalentTokens: Int
        if chargedBytes.overflow {
            restoredEquivalentTokens = Int.max
        } else {
            let roundedBytes = chargedBytes.partialValue.addingReportingOverflow(kvBytesPerToken - 1)
            restoredEquivalentTokens = roundedBytes.overflow
                ? Int.max
                : roundedBytes.partialValue / kvBytesPerToken
        }
        let suffixAndOutputTokens = max(0, promptTokenCount - restoredTokenCount) + maxTokens
        let restoredTotal = restoredEquivalentTokens.addingReportingOverflow(suffixAndOutputTokens)
        return max(requestTokens, restoredTotal.overflow ? Int.max : restoredTotal.partialValue)
    }

    internal func acceptRestoredCheckpointBudget(
        requestId: String,
        requestTokens: Int,
        admission: RestoredCheckpointAdmission?
    ) -> RestoredCheckpointAdmission? {
        guard let admission, admission.reservedTokens > requestTokens else {
            return admission
        }
        let usedWithoutThis = max(0, activeTokenBudgetUsed - requestTokens)
        let projected = usedWithoutThis.addingReportingOverflow(admission.reservedTokens)
        guard !projected.overflow, projected.partialValue <= tokenBudgetMax else {
            prefixCacheLogger.warning(
                "prefix cache restore skipped: restored KV exceeds token budget; falling back to cold prefill")
            return nil
        }
        if var bridge = activeBridges[requestId] {
            bridge.reservedTokens = admission.reservedTokens
            activeBridges[requestId] = bridge
        }
        return admission
    }

}
