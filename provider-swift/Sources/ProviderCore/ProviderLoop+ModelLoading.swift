/// ProviderLoop -- model load/unload + memory admission.
///
/// `ensureModelLoaded` (weight-hash refresh, KV-budget + free-memory admission,
/// eviction, container/tokenizer/scheduler construction), unload, and the
/// memory-accounting helpers shared by the admission path.

import CryptoKit
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXLMServer
import MLXVLM
#if canImport(os)
import os
#endif

extension ProviderLoop {
    // MARK: - Model Loading

    /// One immutable observation of the model artifacts on disk. Capture and
    /// publication are deliberately separate: reusable SSD loads take two fresh
    /// cryptographic observations around container loading, then publish only
    /// after both hashes match.
    struct WeightHashSnapshot: Sendable {
        let fingerprint: String?
        let hash: String?
        let recomputed: Bool
    }

    /// Capture a hash observation without mutating provider-visible state. The
    /// expensive SHA-256 read runs off-actor so heartbeats and challenges remain
    /// responsive. Non-SSD loads may reuse an unchanged fingerprint/hash pair;
    /// reusable SSD loads always request a fresh cryptographic read.
    func captureWeightHash(
        modelId: String,
        modelPath: URL,
        requireFreshCryptographicHash: Bool = false
    ) async throws -> WeightHashSnapshot {
        if requireFreshCryptographicHash {
            return try await captureFreshCryptographicWeightHash(
                modelId: modelId,
                modelPath: modelPath)
        }
        let priorFingerprint = modelHashFingerprints[modelId]
        let priorHash = SSDPrefixCacheFactory.verifiedWeightHash(liveModelHashes[modelId])
        let refresh = await Task.detached(priority: .utility) {
            () -> WeightHashSnapshot in
            let fingerprint = WeightHasher.snapshotFingerprint(snapshotDir: modelPath)
            if let fingerprint, fingerprint == priorFingerprint, priorHash != nil
            {
                return WeightHashSnapshot(
                    fingerprint: fingerprint,
                    hash: priorHash,
                    recomputed: false)
            }
            return WeightHashSnapshot(
                fingerprint: fingerprint,
                hash: SSDPrefixCacheFactory.verifiedWeightHash(
                    WeightHasher.computeHash(snapshotDir: modelPath, modelID: modelId)),
                recomputed: true)
        }.value
        try Task.checkCancellation()
        if isShuttingDown { throw CancellationError() }
        return refresh
    }

    /// Read the full cryptographic hash without a redundant metadata-fingerprint
    /// walk. Callers that already observed a post-load fingerprint can attach it
    /// so publication keeps the cheap non-SSD reload cache coherent.
    private func captureFreshCryptographicWeightHash(
        modelId: String,
        modelPath: URL,
        fingerprint: String? = nil
    ) async throws -> WeightHashSnapshot {
        let hash = await Task.detached(priority: .utility) {
            SSDPrefixCacheFactory.verifiedWeightHash(
                WeightHasher.computeHash(snapshotDir: modelPath, modelID: modelId))
        }.value
        try Task.checkCancellation()
        if isShuttingDown { throw CancellationError() }
        return WeightHashSnapshot(
            fingerprint: fingerprint,
            hash: hash,
            recomputed: true)
    }

    /// Publish a trustworthy observation to attestation/registration state.
    /// Failed observations never replace the last known hash or fingerprint.
    func publishWeightHash(modelId: String, snapshot: WeightHashSnapshot) async {
        guard let hash = snapshot.hash else {
            if snapshot.recomputed {
                logger.warning("Weight hash recompute failed for \(modelId) — keeping previous value")
            }
            return
        }
        if let fingerprint = snapshot.fingerprint {
            modelHashFingerprints[modelId] = fingerprint
        }
        if liveModelHashes[modelId] != hash {
            let previous = liveModelHashes[modelId]?.prefix(16) ?? "unset"
            logger.info("Weight hash refreshed for \(modelId): \(hash.prefix(16))... (was \(previous))")
            liveModelHashes[modelId] = hash
            // Push into the client so a later reconnect re-registers with
            // current models[].weight_hash (the coordinator's per-model
            // catalog filter uses the register-time value).
            if let client = coordinatorClient {
                await client.updateModelWeightHashes(liveModelHashes)
            }
        }
    }

    /// Remove an unverifiable hash from every live attestation/registration
    /// view. Cold serving remains available, but neither cache identity nor a
    /// future reconnect may reuse the daemon-start hash.
    func markWeightHashUnavailable(modelId: String) async {
        let previous = liveModelHashes.removeValue(forKey: modelId)
        modelHashes.removeValue(forKey: modelId)
        modelHashFingerprints.removeValue(forKey: modelId)
        if var model = advertisedModels[modelId] {
            model.weightHash = nil
            advertisedModels[modelId] = model
        }
        if let previous {
            logger.warning(
                "Weight hash unavailable for \(modelId) — removed stale value \(previous.prefix(16))... and disabled reusable SSD cache")
        } else {
            logger.warning(
                "Weight hash unavailable for \(modelId) — reusable SSD cache disabled")
        }
        if let client = coordinatorClient {
            await client.updateModelWeightHashes(liveModelHashes)
        }
    }

    enum ReusableSSDWeightHashDecision: Equatable {
        case eligible(String)
        case unavailable
        case changed
    }

    static func reusableSSDWeightHashDecision(
        preLoadHash: String?, postLoadHash: String?
    ) -> ReusableSSDWeightHashDecision {
        guard let preLoadHash = SSDPrefixCacheFactory.verifiedWeightHash(preLoadHash),
            let postLoadHash = SSDPrefixCacheFactory.verifiedWeightHash(postLoadHash)
        else { return .unavailable }
        return preLoadHash == postLoadHash
            ? .eligible(preLoadHash)
            : .changed
    }

    /// Complete a reusable SSD load as one fail-closed lifecycle transition.
    /// A missing observation disables SSD reuse for this load while preserving
    /// ordinary cold serving. Two available but different hashes prove artifact
    /// mutation during the load and abort before engine/slot installation.
    func finalizeReusableSSDLoad(
        modelId: String,
        preLoad: WeightHashSnapshot,
        postLoad: WeightHashSnapshot,
        newcomer: EngineV2NewcomerBox
    ) async throws -> String? {
        switch Self.reusableSSDWeightHashDecision(
            preLoadHash: preLoad.hash,
            postLoadHash: postLoad.hash
        ) {
        case .eligible(let cacheHash):
            await publishWeightHash(modelId: modelId, snapshot: postLoad)
            return cacheHash
        case .unavailable:
            await markWeightHashUnavailable(modelId: modelId)
            return nil
        case .changed:
            newcomer.release()
            MLX.Memory.clearCache()
            let message =
                "Model '\(modelId)' changed while loading reusable SSD cache state — unloaded"
            recordModelLoadError(model: modelId, message: message)
            throw InferenceError.modelLoadFailed(message)
        }
    }

    /// Load `modelId` if it is not already resident.
    ///
    /// `allowEviction` (default true) gates BOTH eviction points — the
    /// slot-cap LRU eviction and `evictUntilAvailable`'s memory reclamation.
    /// The startup preload passes `false`: a later preload candidate must
    /// never churn out an earlier one (it is skipped with a WARN and left to
    /// the lazy-load path instead). Live traffic keeps the default. The
    /// checks run INSIDE the `isLoadingAny` critical section, so an
    /// interleaved local-endpoint load cannot make the no-evict verdict
    /// stale.
    ///
    /// When MTP is configured, the shared spec-dec funnel resolves and sizes
    /// the assistant before admission. The target remains independently
    /// loadable: assistant headroom failure selects target-only decode.
    internal func ensureModelLoaded(
        modelId: String, allowEviction: Bool = true
    ) async throws {
        if isShuttingDown {
            throw CancellationError()
        }

        while modelsUnloading.contains(modelId) {
            await waitForModelUnload(modelId)
            if isShuttingDown { throw CancellationError() }
        }

        if modelSlots[modelId] != nil {
            return
        }

        if modelsLoading.contains(modelId) {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
                loadingWaiters[modelId, default: []].append(cont)
            }
            try Task.checkCancellation()
            if isShuttingDown { throw CancellationError() }
            while modelsUnloading.contains(modelId) {
                await waitForModelUnload(modelId)
                if isShuttingDown { throw CancellationError() }
            }
            if modelSlots[modelId] != nil { return }
            try await ensureModelLoaded(
                modelId: modelId, allowEviction: allowEviction)
            return
        }

        guard let modelPath = ModelScanner.resolveLocalPath(modelID: modelId) else {
            throw InferenceError.invalidModelDirectory(
                "Model '\(modelId)' not found in local HuggingFace cache"
            )
        }

        guard let modelInfo = advertisedModels[modelId] else {
            throw InferenceError.invalidModelDirectory(
                "Model '\(modelId)' not in advertised model list"
            )
        }
        var mtpPreparation = await specDecPreparation(
            modelId: modelId, modelInfo: modelInfo)

        // Re-check residency and in-flight loads after the preparation await:
        // a concurrent request for the same cold model can pass the checks
        // above, complete its ENTIRE load (returning `isLoadingAny` to false),
        // and install the slot while this task was suspended. Without this
        // recheck the continuation would start a second load of a resident
        // model — double pending-load reservation, possible eviction of the
        // warm slot, and a leaked bridge.
        while modelsUnloading.contains(modelId) {
            await waitForModelUnload(modelId)
            if isShuttingDown { throw CancellationError() }
        }
        if modelSlots[modelId] != nil { return }
        if modelsLoading.contains(modelId) {
            try await ensureModelLoaded(
                modelId: modelId, allowEviction: allowEviction)
            return
        }

        // Serialize loads so concurrent eviction decisions don't interleave
        while isLoadingAny {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                loadGateWaiters.append(cont)
            }
            // Honor cancellation (e.g. shutdown cancelled this preload task
            // while it was suspended at the gate).
            try Task.checkCancellation()
            if isShuttingDown { throw CancellationError() }
            while modelsUnloading.contains(modelId) {
                await waitForModelUnload(modelId)
                if isShuttingDown { throw CancellationError() }
            }
            if modelSlots[modelId] != nil { return }
        }
        isLoadingAny = true

        // Re-check slot cap after gate (another load may have consumed a slot)
        if modelSlots.count >= maxModelSlots {
            let modelsWithInflight = Set(requestToModel.values)
            let evictable = modelSlots.filter {
                !modelsWithInflight.contains($0.key) && !hasLocalReservation($0.key) && !modelsUnloading.contains($0.key)
            }
            if evictable.isEmpty || !allowEviction {
                isLoadingAny = false
                releaseLoadGateWaiters()
                // Both messages contain "slot" so loadErrorStatusCode maps
                // them to 503 (transient capacity, coordinator reroutes).
                throw InferenceError.invalidModelDirectory(
                    allowEviction
                        ? "All \(maxModelSlots) model slot(s) are active; cannot load '\(modelId)'"
                        : "All \(maxModelSlots) model slot(s) are occupied and eviction is disabled for this load; cannot load '\(modelId)'"
                )
            }
            if let lru = evictable.min(by: { $0.value.lastInferenceAt < $1.value.lastInferenceAt }) {
                await unloadModel(lru.key)
            }
        }

        // Q6 (serve-while-load): id for the pending-load reservation placed in
        // kvBudget once the gate passes and released once the weights are
        // resident. Declared out here so the catch can release it on any path.
        let pendingLoadID = "pending-load:\(modelId)"
        modelsLoading.insert(modelId)
        do {
            try Task.checkCancellation()
            if isShuttingDown { throw CancellationError() }

            // Load gate: require room for the WEIGHTS plus headroom for ONE
            // request, not a full-concurrency multiple. Concurrency beyond one
            // request is sized dynamically at runtime by the live token budget +
            // GlobalKVCacheBudget (which strictly rejects any request whose KV
            // won't fit real free memory, so this looser gate cannot OOM — worst
            // case a box serves one request at a time). The old gate demanded
            // free ≥ weights × 2.86 (a `× 2.0` here on top of a `× 0.7` discount
            // in availableMemoryGb) and left every small/mid machine unable to
            // load a model it could actually serve. `availableMemoryGb` now
            // clamps to real OS-available memory and subtracts in-flight KV
            // reservations, so dropping the multiplier here is still OOM-safe.
            let targetWeightsGb = Self.loadGateWeightsGb(
                estimatedWeightsGb: modelInfo.estimatedMemoryGb,
                extraWeightBytes: 0)
            let requiredGb = ModelLoadAdmission.requiredToLoadGb(
                weightsGb: targetWeightsGb,
                headroomGb: Self.loadHeadroomGb)
            do {
                try await evictUntilAvailable(requiredGb: requiredGb, allowEviction: allowEviction)
            } catch let InferenceError.modelLoadFailed(message) {
                // Record for diagnostics so `doctor` shows the operator the exact
                // "Insufficient memory …" reason, then rethrow unchanged.
                recordModelLoadError(model: modelId, message: message)
                throw InferenceError.modelLoadFailed(message)
            }
            // The assistant is optional and must never make an otherwise
            // loadable target fail. It is charged before allocation when it
            // fits; otherwise this load continues target-only.
            mtpPreparation = await admitSpecDecIfMemoryAllows(
                mtpPreparation, targetRequiredGb: requiredGb)
            let extraWeightBytes = mtpPreparation.artifact?.residentBytes ?? 0
            try Task.checkCancellation()
            if isShuttingDown { throw CancellationError() }

            // Q6: reserve this load's weight footprint in the shared KV budget so
            // a concurrent KV reservation on an already-loaded model can't grant
            // headroom that, plus these incoming (not-yet-in-mlxUsed) weights,
            // blows the unified-memory cap. Released once the weights are resident.
            // Includes `extraWeightBytes` (the drafter): those bytes land in
            // mlxUsed during this load window just like the target's.
            let pendingLoadBytes = Self.pendingLoadReservationBytes(
                estimatedWeightsGb: modelInfo.estimatedMemoryGb,
                extraWeightBytes: extraWeightBytes)
            await kvBudget.reservePendingLoad(requestID: pendingLoadID, bytes: pendingLoadBytes)

            logger.info("Loading model: \(modelId) from \(modelPath.path)")
            // Cold-start load timing (slot-level `model_load_time_ms`): from
            // here to slot install — covering the weight load, sizing, and
            // engine build the coordinator's cold-load routing pays for.
            let loadStartedAt = ContinuousClock.now

            // Re-hash the weights about to be loaded. Refreshing BEFORE the slot
            // goes active guarantees a challenge arriving mid-serve reports the
            // hash of the bytes actually loaded — not the disk state at daemon
            // start. (See `captureWeightHash` for the full rationale.)
            let reusableSSDRequested = PrefixCachePolicy.isEnabled()
            let preLoadHash = try await captureWeightHash(
                modelId: modelId,
                modelPath: modelPath,
                requireFreshCryptographicHash: reusableSSDRequested)
            if !reusableSSDRequested {
                await publishWeightHash(modelId: modelId, snapshot: preLoadHash)
            }

            if let beforeModelLoad {
                await beforeModelLoad(modelId)
                try Task.checkCancellation()
                if isShuttingDown { throw CancellationError() }
            }
            // Ownership box (Codex-review unwind ordering): every later
            // access to the loading container goes through this box so
            // failure paths can drop the LAST strong reference to the
            // weights BEFORE survivor grants are restored/regrown. Never
            // bind `borrow()` to a long-lived local — that would keep the
            // weights alive past `release()`.
            let newcomer = EngineV2NewcomerBox(try await loadModelContainer(from: modelPath))
            try Task.checkCancellation()
            if isShuttingDown { throw CancellationError() }

            // TOCTOU guard: reusable SSD cache participation requires two fresh
            // cryptographic reads bracketing the container load. Unlike the old
            // refresh path, neither observation is published until equality is
            // established. A missing observation serves cold; an actual mismatch
            // proves artifact mutation and fails before engine construction or
            // slot installation.
            let cacheEligibleWeightHash: String?
            if reusableSSDRequested {
                let postLoadHash = try await captureWeightHash(
                    modelId: modelId,
                    modelPath: modelPath,
                    requireFreshCryptographicHash: true)
                cacheEligibleWeightHash = try await finalizeReusableSSDLoad(
                    modelId: modelId,
                    preLoad: preLoadHash,
                    postLoad: postLoadHash,
                    newcomer: newcomer)
            } else {
                let postLoadFingerprint = await Task.detached(priority: .utility) {
                    WeightHasher.snapshotFingerprint(snapshotDir: modelPath)
                }.value
                try Task.checkCancellation()
                if preLoadHash.fingerprint == nil
                    || postLoadFingerprint != preLoadHash.fingerprint
                {
                    logger.warning(
                        "Snapshot fingerprint drifted between hash and load for \(modelId) — recomputing weight hash for the bytes actually loaded")
                    let postLoadHash = try await captureFreshCryptographicWeightHash(
                        modelId: modelId,
                        modelPath: modelPath,
                        fingerprint: postLoadFingerprint)
                    await publishWeightHash(modelId: modelId, snapshot: postLoadHash)
                }
                cacheEligibleWeightHash = nil
            }
            // Hard-fail without Metal (moved from the legacy scheduler's
            // loadModel): CPU inference is not acceptable, and with no
            // legacy engine left this is a load failure, not a log line.
            do {
                _ = try GPUEnforcement.requireMetal()
            } catch {
                let message = "Cannot load model '\(modelId)': \(error)"
                recordModelLoadError(model: modelId, message: message)
                throw InferenceError.modelLoadFailed(message)
            }
            // Pin MLX's memory ceiling below physical RAM (idempotent). MLX's
            // default (1.5× working set) otherwise allows a jetsam OOM.
            MLXMemoryGuard.configureOnce(
                operatorReserveBytes: loopConfig.config.provider.effectiveReserveBytes(),
                limitBytes: loopConfig.config.provider.memoryLimitBytes(),
                log: { limits in
                    FileHandle.standardError.write(Data(
                        "[mlx] memory ceiling set: limit=\(limits.memoryLimitBytes / (1024*1024*1024))GB cache=\(limits.cacheLimitBytes / (1024*1024*1024))GB\n".utf8
                    ))
                })

            // Target-only sizing snapshot. After assistant load/bind, the slot
            // factory replaces its auxiliary component with the bytes actually
            // retained before final re-slicing and installation.
            let targetSizing = try await SlotSizingSnapshot.build(
                container: newcomer.borrow(),
                modelPath: modelPath,
                fallbackDefaultMaxTokens: Self.schedulerDefaultMaxTokens)

            // Weights are resident now (reflected in MLX active/cache), so hand
            // off from the pending-load reservation to the live mlxUsed view —
            // concurrent KV reservations see the weights from here on. (Also
            // released in catch for the error paths above.)
            await kvBudget.replacePendingLoadReservation(
                requestID: pendingLoadID, bytes: extraWeightBytes)
            if isShuttingDown || Task.isCancelled {
                newcomer.release()
                MLX.Memory.clearCache()
                throw CancellationError()
            }

            // Post-load measured-headroom guard: the load gate admitted on an
            // ESTIMATE (estimatedMemoryGb = on-disk × 1.2). Now that the weights
            // are actually resident, check the MEASURED live KV headroom under the
            // cap — if the real footprint exceeded the estimate there may be no
            // room to serve, and keeping the model would just reject every request
            // at the KV gate. Unload + reclaim + reject so the coordinator
            // reroutes, instead of advertising a dead model. Safe to measure here:
            // we're inside the `isLoadingAny` critical section, so MLX usage
            // reflects this load and no concurrent load/unload can race it.
            //
            // Trim the cold-load buffer pool FIRST: a fresh load leaves transient
            // buffers in MLX cacheMemory (no forward pass has trimmed them yet),
            // which the measurement counts as "used" and would false-reject a
            // serveable model. Mirrors evictUntilAvailable / fastAdmissionReject's
            // clearCache-then-measure self-heal.
            MLX.Memory.clearCache()
            if !KVHeadroomProbe.hasServeableKVHeadroom() {
                let headroomGb = String(
                    format: "%.1f",
                    Double(KVHeadroomProbe.measuredLiveKVHeadroomBytes) / (1024.0 * 1024.0 * 1024.0))
                let minGb = String(
                    format: "%.1f", Double(UnifiedMemoryCap.minimumLoadKVBytes) / (1024.0 * 1024.0 * 1024.0))
                // Pre-shrink failure: no grants were mutated, so ordering is
                // moot — but drop the weights promptly all the same.
                newcomer.release()
                MLX.Memory.clearCache()
                let message = "Model '\(modelId)' loaded but has insufficient KV headroom "
                    + "under the memory cap (\(headroomGb) GB free, need \(minGb) GB to serve) — unloaded"
                recordModelLoadError(model: modelId, message: message)
                throw InferenceError.modelLoadFailed(message)
            }

            let tokenizer: TokenizerHandle = try await newcomer.borrow().perform { ctx in
                TokenizerHandle(
                    ctx.tokenizer,
                    toolConstraintContractVerified:
                        Gemma4ToolConstraintContract.isVerified(
                            modelType: modelInfo.modelType,
                            modelDirectory: modelPath))
            }

            // ONE ENGINE (v0.7.5): re-slice co-resident KV grants (shrink
            // existing engines to fair shares) and build this model's CBv2
            // engine + bridge with the newcomer's grant. THROWS on any
            // construction failure — refusal telemetry has already fired,
            // existing grants are already restored — and the catch below
            // maps it to a 503 so the coordinator reroutes (and coordinator
            // pushes get `load_model_status: failed`). There is no legacy
            // fallback: a model that cannot build a v2 engine does not load.
            let slotIsVLM = Self.modelIsVLM(at: modelPath)
            // The re-slice gate is held across the WHOLE shrink → build →
            // guard → install-slot sequence: a concurrent idle-timeout
            // unload's regrow parked on the gate must not run in the gap
            // between the newcomer's grant being carved out and its slot
            // appearing in `modelSlots` — it would recompute without the
            // newcomer and re-inflate survivors past the fleet budget.
            await acquireResliceGate()
            var slotBuild: EngineV2SlotBuild
            do {
                slotBuild = try await resliceAndBuildEngineV2Bundle(
                    modelId: modelId,
                    modelType: modelInfo.modelType,
                    isVLM: slotIsVLM,
                    modelDirectory: modelPath,
                    newcomer: newcomer,
                    tokenizer: tokenizer,
                    targetSizing: targetSizing,
                    specDecPreparation: mtpPreparation,
                    cacheEligibleWeightHash: cacheEligibleWeightHash
                )
            } catch let error as InferenceError {
                // Already shaped (e.g. the re-slice floor refusal) — record +
                // rethrow unchanged so loadErrorStatusCode sees the original.
                // The unwind ordering (release newcomer weights → clearCache
                // → restore survivor grants) already ran inside
                // `resliceAndBuildEngineV2Slot`'s catch, before this one.
                releaseResliceGate()
                MLX.Memory.clearCache()
                if case .modelLoadFailed(let message) = error {
                    recordModelLoadError(model: modelId, message: message)
                }
                throw error
            } catch {
                releaseResliceGate()
                MLX.Memory.clearCache()
                let message =
                    "Model '\(modelId)' loaded but its v2 engine construction failed: \(error) — unloaded"
                recordModelLoadError(model: modelId, message: message)
                throw InferenceError.modelLoadFailed(message)
            }
            // Assistant construction has completed. Its bytes are now either
            // live and reflected in MLX, or fully released on fallback.
            await kvBudget.release(requestID: pendingLoadID)
            var engineBundle = slotBuild.bundle
            var sizing = slotBuild.sizing
            var engineV2Bridge = engineBundle.bridge

            // Post-BRIDGE measured-headroom re-guard (v0.7.3, kept): the
            // engine build (and, for VLM slots, the text-model extraction +
            // parity probe) can retain additional load-time memory beyond
            // the weights the check above measured. Re-measure so a box
            // whose full load-time footprint leaves no serveable KV unloads
            // and 503s instead of advertising a model whose every request
            // the shared KV gate rejects — the v0.7.2 black-hole shape.
            // BACKEND-AWARE: a PAGED slot's slabs are committed lazily at
            // the pool's FIRST ADMISSION (`.atFirstAdmission`, the D1 fix),
            // NOT at construction — so the measured headroom taken here
            // does not yet include the pool's future residency, and cannot:
            // that deferral is exactly what lets a second model's post-load
            // probe pass beside an idle paged slot. The guard therefore
            // asks two separate questions for paged: is the PLANNED pool
            // itself serveable (`kvBackendPoolBytes()` — construction-fixed
            // page arithmetic, valid whether or not the slabs are resident
            // yet), and does the machine retain the minimum residual
            // headroom on top of what is actually resident now. The
            // conservative physical-capacity policy (pool ≤ ¼ of live
            // headroom at plan time) is what keeps the deferred commitment
            // from later eating the headroom this measurement approved.
            MLX.Memory.clearCache()
            var postBridgeServeable = KVHeadroomProbe.postBuildServeable(
                kvBackendKind: engineV2Bridge.kvBackendKind,
                pagedPoolBytes: await engineV2Bridge.kvBackendPoolBytes())
            let runtimeMTPActive = await engineV2Bridge.mtpStatusSnapshot().active
            if engineBundle.mtpStatus.active,
                !postBridgeServeable || !runtimeMTPActive
            {
                let reason: MTPFallbackReason = runtimeMTPActive
                    ? .assistantPostBuildHeadroom : .engineInactive
                logger.warning(
                    "mtp: model=\(modelId) fallback reason=\(reason.rawValue); rebuilding target-only")
                await engineV2Runtime.unregister(modelId: modelId)
                await engineV2Bridge.shutdown()
                engineBundle.releaseAssistant()
                MLX.Memory.clearCache()
                do {
                    slotBuild = try await resliceAndBuildEngineV2Bundle(
                        modelId: modelId,
                        modelType: modelInfo.modelType,
                        isVLM: slotIsVLM,
                        modelDirectory: modelPath,
                        newcomer: newcomer,
                        tokenizer: tokenizer,
                        targetSizing: targetSizing,
                        specDecPreparation: mtpPreparation.fallingBack(reason),
                        cacheEligibleWeightHash: cacheEligibleWeightHash)
                } catch {
                    // The retry released the target on failure. Recompute from
                    // actual survivor residency, not the first attempt's
                    // assistant-conservative grants.
                    await resliceGrowSurvivorsLocked()
                    releaseResliceGate()
                    MLX.Memory.clearCache()
                    let message = "Model '\(modelId)' MTP fallback engine construction failed: \(error) — unloaded"
                    recordModelLoadError(model: modelId, message: message)
                    throw InferenceError.modelLoadFailed(message)
                }
                engineBundle = slotBuild.bundle
                sizing = slotBuild.sizing
                engineV2Bridge = engineBundle.bridge
                MLX.Memory.clearCache()
                postBridgeServeable = KVHeadroomProbe.postBuildServeable(
                    kvBackendKind: engineV2Bridge.kvBackendKind,
                    pagedPoolBytes: await engineV2Bridge.kvBackendPoolBytes())
            }
            if !postBridgeServeable {
                let headroomGb = String(
                    format: "%.1f",
                    Double(KVHeadroomProbe.measuredLiveKVHeadroomBytes) / (1024.0 * 1024.0 * 1024.0))
                // Retire the bridge, release the newcomer's weights, THEN
                // regrow survivors — in that order (Codex review): regrowing
                // while the aborted newcomer's weights are still resident
                // would let Σ(grants) exceed the true fleet budget. Still
                // holding the re-slice gate; release only after.
                await unwindBuiltSlotAndRegrow(
                    modelId: modelId, bundle: engineBundle, newcomer: newcomer)
                releaseResliceGate()
                let message = "Model '\(modelId)' loaded but its engine build left insufficient "
                    + "KV headroom under the memory cap (\(headroomGb) GB free) — unloaded"
                recordModelLoadError(model: modelId, message: message)
                throw InferenceError.modelLoadFailed(message)
            }

            // Slot-level cold-start load time (heartbeat `model_load_time_ms`).
            let loadElapsed = ContinuousClock.now - loadStartedAt
            let loadMs = Double(loadElapsed.components.seconds) * 1000.0
                + Double(loadElapsed.components.attoseconds) / 1e15
            await engineV2Bridge.recordModelLoadTime(ms: Int64(max(0, loadMs.rounded())))

            guard let installContainer = newcomer.container else {
                // Unreachable (the box is drained only on failure paths) —
                // defensive so a wiring bug can never leak the re-slice gate
                // and wedge every future load.
                await unwindBuiltSlotAndRegrow(
                    modelId: modelId, bundle: engineBundle, newcomer: newcomer)
                releaseResliceGate()
                throw InferenceError.modelLoadFailed(
                    "internal: newcomer container missing at install for '\(modelId)'")
            }
            modelSlots[modelId] = ModelSlot(
                engineBundle: engineBundle,
                container: installContainer,
                tokenizer: tokenizer,
                sizing: sizing,
                cacheEligibleWeightHash: cacheEligibleWeightHash,
                isVLM: slotIsVLM,
                modelType: modelInfo.modelType,
                lastInferenceAt: .now
            )
            // Newcomer installed — parked regrows now see the full slot set.
            releaseResliceGate()

            syncWarmModelState()
            // Remember the serving set across restarts: the persisted file is
            // the default startup preload plan (ProviderLoop+StartupPreload).
            persistLoadedModelSet()
            await updateAggregateCapacity()
            logger.info("Model loaded: \(modelId) (\(modelSlots.count) model(s) in memory)")

            modelsLoading.remove(modelId)
            isLoadingAny = false
            for waiter in loadingWaiters.removeValue(forKey: modelId) ?? [] {
                waiter.resume()
            }
            releaseLoadGateWaiters()
        } catch {
            modelsLoading.remove(modelId)
            isLoadingAny = false
            // Release the pending-load reservation on every failure path (no-op
            // if it was never placed, or already released on the success path).
            await kvBudget.release(requestID: pendingLoadID)
            // Release pool buffers a failed load left behind (same wedge as unload).
            MLX.Memory.clearCache()
            for waiter in loadingWaiters.removeValue(forKey: modelId) ?? [] {
                waiter.resume(throwing: error)
            }
            releaseLoadGateWaiters()
            throw error
        }
    }

    // MARK: - Load-gate arithmetic (pure, unit-tested by SpecDecCapacityTests)

    /// The load gate's weight figure (GB): the scan-time snapshot estimate
    /// plus any auxiliary weight bytes the load will make resident OUTSIDE
    /// the snapshot (the MTP drafter — plan D5: scan-time estimates never
    /// include it, so the gate must add it explicitly).
    internal static func loadGateWeightsGb(
        estimatedWeightsGb: Double, extraWeightBytes: UInt64
    ) -> Double {
        estimatedWeightsGb + Double(extraWeightBytes) / 1_073_741_824.0
    }

    /// The pending-load reservation (bytes) for an in-flight load: the
    /// estimated snapshot footprint plus auxiliary weight bytes, saturating.
    /// A non-finite/non-positive estimate contributes nothing (the pre-MTP
    /// behavior), leaving just the auxiliary bytes.
    internal static func pendingLoadReservationBytes(
        estimatedWeightsGb: Double, extraWeightBytes: UInt64
    ) -> UInt64 {
        let weightBytes = estimatedWeightsGb * 1_073_741_824
        guard weightBytes.isFinite, weightBytes > 0 else { return extraWeightBytes }
        if weightBytes >= Double(UInt64.max) { return .max }
        let (sum, overflow) = UInt64(weightBytes).addingReportingOverflow(extraWeightBytes)
        return overflow ? .max : sum
    }

    internal func releaseLoadGateWaiters() {
        let waiters = loadGateWaiters
        loadGateWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    internal func waitForModelUnload(_ modelId: String) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            unloadingWaiters[modelId, default: []].append(cont)
        }
    }

    internal func unloadModel(_ modelId: String) async {
        // Bind ONLY the bridge, never the whole slot: the slot value is the
        // last owner of the container AND the opaque MTP drafter handle, and
        // both must be released at `removeValue` below — BEFORE the cache
        // purge — not kept alive by a local until this function returns.
        guard let engineBundle = modelSlots[modelId]?.engineBundle,
            !modelsUnloading.contains(modelId)
        else { return }
        let engineV2 = engineBundle.bridge
        modelsUnloading.insert(modelId)
        // Retire the slot's v2 bridge: unregister so heartbeats/cancellation
        // stop fanning out to it, then drain the engine gracefully (running
        // requests finish, new submissions are rejected).
        await engineV2Runtime.unregister(modelId: modelId)
        await engineV2.shutdown()
        engineBundle.releaseAssistant()
        // Drops the slot's container and MTP drafter references with the
        // target (the drafter is slot-owned — plan D5 teardown).
        modelSlots.removeValue(forKey: modelId)
        modelsUnloading.remove(modelId)
        // Mandatory: freed weights linger in MLX's pool (GPU.cacheMemory), which
        // load-admission counts as used — without this the box 503s every load
        // until restart.
        MLX.Memory.clearCache()
        // Re-slice GROW the survivors: with this model's weights gone the
        // fleet KV budget rises, and the remaining engines take their new
        // fair shares (a lone survivor gets the FULL budget back).
        await resliceGrowSurvivors()
        let waiters = unloadingWaiters.removeValue(forKey: modelId) ?? []
        for waiter in waiters { waiter.resume() }
        syncWarmModelState()
        // A NON-shutdown unload (idle timeout, eviction, retirement) drops the
        // model from the persisted serving set. Shutdown teardown skips this on
        // purpose: a stop/update/restart must remember what was being served so
        // the next boot's startup preload can re-warm it.
        if !isShuttingDown {
            persistLoadedModelSet()
        }
        await updateAggregateCapacity()
        logger.info("Unloaded model: \(modelId) (\(modelSlots.count) model(s) remaining)")
    }

    /// Weight-hash observations for only the models currently loaded in memory.
    /// An unavailable hash is represented by an explicit empty value so the
    /// coordinator clears any registration-time hash instead of retaining stale
    /// state. Idle/unloaded advertised models remain absent.
    internal func loadedModelHashesSnapshot() -> [String: String] {
        var result: [String: String] = [:]
        for modelId in modelSlots.keys where !modelsUnloading.contains(modelId) {
            result[modelId] = liveModelHashes[modelId] ?? ""
        }
        return result
    }

    internal func syncWarmModelState() {
        let loaded = modelSlots.keys.filter { !modelsUnloading.contains($0) }.sorted()
        state.warmModels = loaded
        let activeSlots = modelSlots.filter { !modelsUnloading.contains($0.key) }
        let inflightModels = Set(requestToModel.values)
        let currentCandidates = activeSlots.filter { inflightModels.contains($0.key) }
        let candidates = currentCandidates.isEmpty ? activeSlots : currentCandidates
        if let mostRecent = candidates.max(by: { $0.value.lastInferenceAt < $1.value.lastInferenceAt }) {
            state.currentModel = mostRecent.key
            state.currentModelHash = liveModelHashes[mostRecent.key]
        } else {
            state.currentModel = nil
            state.currentModelHash = nil
        }
    }

    /// Physical memory (GB) available to LOAD a model. No 0.7 KV-safety discount
    /// here — weights are a known one-time allocation, and the 0.7 runtime
    /// safety is already enforced per request by GlobalKVCacheBudget. Applying it
    /// twice was the double-count that kept capable machines from ever loading a
    /// model they could serve.
    ///
    /// Two OOM-safety clamps make the looser gate sound:
    ///   1. The free figure is clamped to what the OS actually reports available
    ///      (`SystemMemory.availableBytes`), not just `total − MLX.active −
    ///      MLX.cache`, which over-reports whenever the OS/other processes hold
    ///      RAM.
    ///   2. KV already promised to in-flight requests
    ///      (`kvBudget.outstandingReservedBytes`) is subtracted, so a concurrent
    ///      load can't consume memory a mid-decode request is counting on.
    ///
    /// `doctor`'s model-fit check shares the SAME arithmetic via
    /// `ModelLoadAdmission`, so the operator-facing verdict can never drift from
    /// what this method enforces at load time.
    ///
    /// `internal` (not `private`): also the admission probe for the startup
    /// preload (`ProviderLoop+StartupPreload`), which must skip — never evict
    /// for — a preload candidate that doesn't fit.
    internal func availableMemoryGb() async -> Double {
        let outstanding = await kvBudget.outstandingReservedBytes()
        // Hold back enough to honor the 90% unified cap: max(effective reserve,
        // physical − cap), where the effective reserve folds `memory_reserve_gb`
        // and the absolute `memory_limit_gb` together (MemoryLimit). Without this
        // the free-memory gate would load models until only the reserve remained
        // — past the cap on big boxes, past the operator's limit on capped ones.
        let reserve = UnifiedMemoryCap.loadReserveBytes(
            configReserveBytes: loopConfig.config.provider.effectiveReserveBytes())
        return ModelLoadAdmission.freeForLoadGb(
            totalBytes: ProcessInfo.processInfo.physicalMemory,
            systemAvailableBytes: SystemMemory.availableBytes() ?? .max,
            gpuActiveBytes: UInt64(max(0, MLX.GPU.activeMemory)),
            gpuCacheBytes: UInt64(max(0, MLX.GPU.cacheMemory)),
            reserveBytes: reserve,
            outstandingReservationBytes: outstanding)
    }

    /// Headroom (GB) reserved above the weights at load time. Must be at least
    /// the runtime activation reserve + a minimum serveable KV, or the gate would
    /// admit a near-cap model that GlobalKVCacheBudget then rejects every request
    /// for (the old flat 2 GiB was LESS than the 3 GiB activation reserve). Sized
    /// from UnifiedMemoryCap so the load gate and the runtime KV path agree.
    static let loadHeadroomGb =
        Double(UnifiedMemoryCap.loadHeadroomBytes()) / (1024.0 * 1024.0 * 1024.0)

    private static func saturatingAdd(_ values: UInt64...) -> UInt64 {
        var total: UInt64 = 0
        for value in values {
            let (sum, overflow) = total.addingReportingOverflow(value)
            if overflow { return UInt64.max }
            total = sum
        }
        return total
    }

    /// Evict idle models (LRU order) until `requiredGb` is available or
    /// no more idle models remain. Re-checks in-flight state before each
    /// eviction since `await unloadModel` is a suspension point.
    /// Throws if the memory target cannot be met after exhausting evictable models.
    ///
    /// `allowEviction: false` (startup preload) never considers a candidate:
    /// it degrades to a pure availability check (with the clearCache
    /// self-heal) that throws instead of reclaiming — a later preload must
    /// not churn out an earlier one.
    private func evictUntilAvailable(requiredGb: Double, allowEviction: Bool = true) async throws {
        while await availableMemoryGb() < requiredGb {
            let modelsWithInflight = Set(requestToModel.values)
            let candidate = allowEviction
                ? modelSlots
                    .filter { !modelsWithInflight.contains($0.key) && !hasLocalReservation($0.key) && !modelsUnloading.contains($0.key) }
                    .min(by: { $0.value.lastInferenceAt < $1.value.lastInferenceAt })
                : nil

            guard let (modelId, _) = candidate else {
                // Nothing idle to evict — drop the reclaimable pool and resample
                // before failing, so a pool-inflated box isn't refused a load
                // that fits. Same self-heal as fastAdmissionReject.
                MLX.Memory.clearCache()
                let retried = await availableMemoryGb()
                if retried >= requiredGb { return }
                let available = String(format: "%.1f", retried)
                let required = String(format: "%.1f", requiredGb)
                throw InferenceError.modelLoadFailed(
                    allowEviction
                        ? "Insufficient memory (\(available) GB free, need \(required) GB) and all loaded models are actively serving"
                        : "Insufficient memory (\(available) GB free, need \(required) GB) to load without evicting resident models"
                )
            }

            logger.info("Evicting idle model \(modelId) to free memory")
            await unloadModel(modelId)
        }
    }

    /// Fast, non-mutating pre-accept admission check used by
    /// ``handleInferenceRequest``. Returns `true` only when loading `modelId`
    /// right now is *certain* to fail, so the coordinator can reroute instead
    /// of us accepting-then-failing (which it counts as a provider fault).
    ///
    /// It mirrors the terminal failure points in ``ensureModelLoaded`` /
    /// ``evictUntilAvailable`` WITHOUT loading anything and is deliberately
    /// conservative: anything that *could* succeed (including via eviction of
    /// an idle model) is admitted and left for the post-accept load path.
    internal func fastAdmissionReject(modelId: String) async -> Bool {
        // Already resident — definitely serviceable.
        if modelSlots[modelId] != nil {
            return false
        }

        // Without advertised model info we cannot size the load here; let the
        // post-accept path surface the proper 404 rather than guessing.
        guard let modelInfo = advertisedModels[modelId] else {
            return false
        }
        // The optional assistant deliberately plays NO role here: it cannot
        // cause a fast rejection (a target that fits must remain loadable and
        // can fall back to plain decode), and this pre-accept path must not
        // touch the spec-dec funnel at all — admission is non-mutating and
        // must not schedule catalog or artifact prefetch work for requests
        // that may be rejected. The accepted load path performs the real
        // preparation (and any prefetch) itself.
        let requiredGb = ModelLoadAdmission.requiredToLoadGb(
            weightsGb: modelInfo.estimatedMemoryGb,
            headroomGb: Self.loadHeadroomGb)

        // Sample live memory FIRST — this is the only suspension point in the
        // method (it awaits the KV-budget actor). Reading all the actor-local
        // slot/in-flight state AFTER the await means the decision below is made
        // atomically with respect to this actor: nothing can mutate slots
        // between the reads and the verdict, so there is no TOCTOU window.
        let available = await availableMemoryGb()

        // Re-check residency after the suspension: the model may have been
        // loaded by a concurrent request while we were awaiting memory.
        if modelSlots[modelId] != nil {
            return false
        }

        // An idle slot (loaded, no in-flight work, not already unloading) can be
        // evicted to make room, so its presence means we must NOT pre-reject.
        let modelsWithInflight = Set(requestToModel.values)
        let hasEvictable = modelSlots.contains {
            !modelsWithInflight.contains($0.key) && !hasLocalReservation($0.key) && !modelsUnloading.contains($0.key)
        }

        // Not enough free memory and nothing idle to evict. Drop the reclaimable
        // pool and resample once before rejecting (the wedge self-heal).
        if available < requiredGb && !hasEvictable {
            MLX.Memory.clearCache()
            let retried = await availableMemoryGb()
            if modelSlots[modelId] != nil {  // a concurrent load won the race
                return false
            }
            if retried < requiredGb {
                return true
            }
        }

        // Mirrors the slot-cap guard in ensureModelLoaded: all slots full and
        // none idle to evict.
        if modelSlots.count >= maxModelSlots && !hasEvictable {
            return true
        }

        return false
    }

    /// Map a model-load failure to an HTTP status code so the coordinator can
    /// react appropriately: transient capacity/memory pressure should reroute
    /// (503) and genuinely missing/unadvertised models are 404; anything else
    /// is treated as a real provider fault (500).
    static func loadErrorStatusCode(for error: any Error) -> UInt16 {
        guard let inferenceError = error as? InferenceError else {
            return 500
        }
        switch inferenceError {
        case .modelLoadFailed:
            // Out-of-memory / eviction failure from evictUntilAvailable —
            // transient capacity pressure, so let the coordinator reroute.
            return 503
        case .invalidModelDirectory(let message):
            let lowered = message.lowercased()
            if lowered.contains("slot") {
                // "All N model slot(s) are active; cannot load ..." — transient
                // capacity, not a fault.
                return 503
            }
            if lowered.contains("not found") || lowered.contains("advertised") {
                // Missing on disk or not in the advertised model list.
                return 404
            }
            return 500
        case .noModelLoaded, .generationFailed, .unsupportedRole:
            return 500
        }
    }

    private func loadModelContainer(from directory: URL) async throws -> MLXLMCommon.ModelContainer {
        // Vision-language models (config declares `vision_config`) load via
        // VLMModelFactory so image/video requests can run the container's
        // prepare/generate vision path. Their text path still works through the
        // batched engine since VLMModel refines LanguageModel. Shared with the
        // standalone server via `ModelContainerLoading`.
        try await ModelContainerLoading.loadContainer(from: directory)
    }

    /// A model is a vision-language model when its `config.json` declares a
    /// `vision_config`. Cheap, dependency-free check used to pick the model
    /// factory and to route multimodal requests.
    static func modelIsVLM(at directory: URL) -> Bool {
        let configURL = directory.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: configURL),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return json["vision_config"] != nil
    }

}
