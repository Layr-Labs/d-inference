// Copyright © 2026 Eigen Labs.
//
// BatchScheduler test-only seams (ProviderCoreTests via @testable import):
// inject a checkpoint manager / force prefix-cache active / drive reserve+restore
// paths directly. Not used in production.

import CryptoKit
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import ProviderCoreFoundation
import os

extension BatchScheduler {
    /// Test seam: force `enginePrefixCacheActive` without a real engine-tier owner.
    func _setEnginePrefixCacheActiveForTest(_ active: Bool) {
        _forceEnginePrefixCacheActiveForTest = active
    }

    /// TEST SEAM: pin the live per-token KV rates without loading a model, so
    /// the v2 slot factory's kv_quant → fp16 sizing decision
    /// (`EngineV2KVSizing`) can be exercised end-to-end with scripted hooks.
    /// `kvBytesPerToken` is the quantized (live) rate; `fp16KVBytesPerToken`
    /// is the un-quantized cost the v2 caches actually consume. Not used in
    /// production.
    func _setKVRatesForTest(kvBytesPerToken: Int, fp16KVBytesPerToken: Int) {
        self.kvBytesPerToken = kvBytesPerToken
        self.fp16KVBytesPerToken = fp16KVBytesPerToken
    }

    /// TEST SEAM: pin the resident-weight figure without loading a model, so
    /// the v2 slot factory's FLEET-WIDE KV-capacity derivation
    /// (`EngineV2KVSizing.engineKVBytesCapacity`) can be exercised with
    /// scripted hooks across multiple co-resident slots. Not used in
    /// production.
    func _setModelWeightBytesForTest(_ bytes: Int) {
        self.modelWeightBytes = bytes
    }

    /// TEST SEAM: install a checkpoint manager + capture hook onto the live
    /// engine, replicating exactly what `makeBatchedEngine` wires for a
    /// `.checkpoint` model. Production builds the manager with an SE-wrapped
    /// Keychain KEK, which an UNSIGNED `swift test` binary can't create
    /// (errSecMissingEntitlement) — so the end-to-end serve-loop test injects
    /// a manager with an in-memory KEK here to exercise the real
    /// submit→lookup→admit→capture path that the SE gate otherwise blocks.
    /// Must be called after `loadModel`. Not used in production.
    func _installCheckpointManagerForTest(_ mgr: PrefixCacheManager, boundaries: [Int]) async {
        self.checkpointManager = mgr
        self.checkpointBoundaries = boundaries
        self.checkpointLayerSignatures = await modelContainer?.perform { ctx in
            Self.checkpointLayerSignatures(
                for: ctx.model.newCache(parameters: nil),
                layerShapes: Self.probeLayerShapes(model: ctx.model)
            )
        } ?? []
        engine?.core.scheduler.checkpointBoundaries = boundaries
        // Same bounded + admission-gated wiring production uses, so the test
        // seam exercises the real backpressure path (not the old unbounded one).
        self.capturePipeline?.shutdown()
        let wiring = Self.makeCheckpointCaptureWiring(manager: mgr)
        self.capturePipeline = wiring.pipeline
        engine?.core.scheduler.onCheckpointCapture = wiring.hook
    }

    /// TEST SEAM: drive the real `finalizeRestore` fallback path without a live
    /// engine. `RestoredCheckpointAdmission` is `private` to this file, so the
    /// regression test (in another file) cannot build one — this seam constructs
    /// an admission with the given oversized `reservedTokens` and invokes the
    /// exact production helper the submit paths call. With no `checkpointManager`
    /// installed, `materializeRestoredCheckpoint` short-circuits to `false`, so
    /// this exercises the downgrade-both-systems branch end-to-end. Returns
    /// nothing; the caller inspects `activeTokenBudgetUsed`, the bridge's
    /// `reservedTokens`, and the kvBudget reservation. Not used in production.
    func _testFinalizeRestoreFallback(
        id: String,
        promptTokens: [Int],
        maxTokens: Int,
        reservedTokens: Int,
        requestBudget: Int
    ) async {
        let candidate = PrefixLookupCandidate(
            digest: Data(),
            digestHex: "",
            tokenCount: max(1, promptTokens.count - 1),
            estimatedBytes: 0,
            tier: .ram
        )
        let admission = RestoredCheckpointAdmission(
            candidate: candidate,
            reservedTokens: reservedTokens
        )
        let sp = SamplingParams(maxTokens: maxTokens, temperature: 0.0)
        let req = Request(
            requestId: id,
            prompt: promptTokens as AnyHashable,
            samplingParams: sp
        )
        await finalizeRestore(
            req,
            id: id,
            admission: admission,
            promptTokens: promptTokens,
            scope: "",
            requestBudget: requestBudget
        )
    }

    /// TEST SEAM: drive the real `reserveKVForRequest` and return the outcome so
    /// a non-live test can prove the downgrade path reports `.coldReserved` (so
    /// the submit paths skip restore) rather than secretly holding a cold
    /// reservation while reporting success. `reserveKVForRequest` is `private` to
    /// this file; this thin wrapper invokes the exact production helper. Not used
    /// in production.
    func _testReserveKVForRequest(
        requestId: String,
        requestTokens: Int,
        reservationTokens: Int,
        restorePlanned: Bool
    ) async -> KVReservationOutcome {
        await reserveKVForRequest(
            requestId: requestId,
            requestTokens: requestTokens,
            reservationTokens: reservationTokens,
            restorePlanned: restorePlanned
        )
    }

    /// TEST SEAM: replay the EXACT submit-path restore decision against the real
    /// `reserveKVForRequest`, then apply the same branch the submit paths use:
    /// call `finalizeRestore` ONLY when the outcome is `.restoreReserved`. Builds
    /// a real `Request` and a restore-sized `RestoredCheckpointAdmission` (both
    /// `private` to this file, so the cross-file test cannot construct them) and
    /// reports the outcome plus whether `req.restoredCheckpoint` stayed nil. This
    /// proves the BUG-3 fix end-to-end: a downgraded reserve (.coldReserved) must
    /// NOT attach a restored checkpoint. With no `checkpointManager` installed,
    /// `materializeRestoredCheckpoint` short-circuits to false, so even the
    /// `.restoreReserved` branch leaves the checkpoint nil — the load-bearing
    /// signal here is that the `.coldReserved` branch never calls finalizeRestore
    /// at all. Not used in production.
    func _testReserveThenMaybeRestore(
        id: String,
        promptTokens: [Int],
        maxTokens: Int,
        requestBudget: Int,
        reservationTokens: Int
    ) async -> (outcome: KVReservationOutcome, restoredCheckpointWasNil: Bool) {
        let sp = SamplingParams(maxTokens: maxTokens, temperature: 0.0)
        let req = Request(
            requestId: id,
            prompt: promptTokens as AnyHashable,
            samplingParams: sp
        )
        let candidate = PrefixLookupCandidate(
            digest: Data(),
            digestHex: "",
            tokenCount: max(1, promptTokens.count - 1),
            estimatedBytes: 0,
            tier: .ram
        )
        let admission = RestoredCheckpointAdmission(
            candidate: candidate,
            reservedTokens: reservationTokens
        )
        let outcome = await reserveKVForRequest(
            requestId: id,
            requestTokens: requestBudget,
            reservationTokens: reservationTokens,
            restorePlanned: true
        )
        // Mirror the submit paths: materialize the restore ONLY on .restoreReserved.
        if outcome == .restoreReserved {
            await finalizeRestore(
                req,
                id: id,
                admission: admission,
                promptTokens: promptTokens,
                scope: "",
                requestBudget: requestBudget
            )
        }
        return (outcome, req.restoredCheckpoint == nil)
    }

}
