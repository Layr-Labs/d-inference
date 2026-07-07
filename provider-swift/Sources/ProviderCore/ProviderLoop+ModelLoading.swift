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

    /// Outcome of one weight-hash refresh: the snapshot fingerprint the recorded
    /// hash corresponds to (nil if the dir couldn't be stat'd), and whether the
    /// `liveModelHashes` entry now reflects bytes on disk. `effectiveFingerprint`
    /// is what the after-load TOCTOU check compares against to decide whether the
    /// bytes drifted between hashing and loading.
    private struct WeightHashRefreshResult {
        /// Fingerprint that `liveModelHashes[modelId]` now corresponds to, or nil
        /// if we have no trustworthy fingerprint (stat failed / recompute failed).
        let effectiveFingerprint: String?
    }

    /// Re-hash the weights for `modelId` and update `liveModelHashes` /
    /// `modelHashFingerprints` to match the bytes on disk, pushing any change into
    /// the coordinator client. The expensive SHA-256 read runs off-actor (hashing
    /// a large model takes seconds and must not block heartbeats or challenge
    /// handling). A snapshot fingerprint (paths + sizes + mtimes) skips the full
    /// re-read when nothing changed since the last hash, so routine idle-reload
    /// cycles stay cheap.
    ///
    /// The model may have been re-published and re-downloaded since the last hash;
    /// a stale hash would make the coordinator hard-untrust this provider for a
    /// "model swap" even though the disk is correct. Returns the fingerprint the
    /// recorded hash now corresponds to so the caller can detect a post-load drift.
    private func refreshWeightHash(modelId: String, modelPath: URL) async throws -> WeightHashRefreshResult {
        let priorFingerprint = modelHashFingerprints[modelId]
        let hasPriorHash = liveModelHashes[modelId] != nil
        let refresh = await Task.detached(priority: .utility) {
            () -> (fingerprint: String?, hash: String?, skipped: Bool) in
            let fingerprint = WeightHasher.snapshotFingerprint(snapshotDir: modelPath)
            if let fingerprint, fingerprint == priorFingerprint, hasPriorHash {
                return (fingerprint, nil, true)  // unchanged — keep cached hash
            }
            return (fingerprint, WeightHasher.computeHash(snapshotDir: modelPath, modelID: modelId), false)
        }.value
        try Task.checkCancellation()
        if isShuttingDown { throw CancellationError() }

        // Record the fingerprint ONLY when we have a hash that corresponds to it
        // (fresh or skip-confirmed). Caching it after a FAILED re-hash would make
        // the next reload fingerprint-match against the stale hash and silently
        // skip the retry — turning a transient read failure into a persistently
        // stale report.
        let haveTrustworthyHash = refresh.hash != nil || refresh.skipped
        if let fingerprint = refresh.fingerprint, haveTrustworthyHash {
            modelHashFingerprints[modelId] = fingerprint
        }
        if let freshHash = refresh.hash {
            if liveModelHashes[modelId] != freshHash {
                let previous = liveModelHashes[modelId]?.prefix(16) ?? "unset"
                logger.info("Weight hash refreshed for \(modelId): \(freshHash.prefix(16))... (was \(previous))")
                liveModelHashes[modelId] = freshHash
                // Push into the client so a later reconnect re-registers with
                // current models[].weight_hash (the coordinator's per-model
                // catalog filter uses the register-time value).
                if let client = coordinatorClient {
                    await client.updateModelWeightHashes(liveModelHashes)
                }
            }
        } else if !refresh.skipped {
            // Recompute failed: keep the previous value but say so — a stale hash
            // here is operator-visible as a model-swap untrust.
            logger.warning("Weight hash recompute failed for \(modelId) — keeping previous value")
        }

        // The effective fingerprint is the one the recorded hash corresponds to.
        // nil when we couldn't establish a trustworthy hash/fingerprint pair, in
        // which case the after-load check should re-hash (safe direction).
        return WeightHashRefreshResult(
            effectiveFingerprint: haveTrustworthyHash ? refresh.fingerprint : nil
        )
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
    internal func ensureModelLoaded(modelId: String, allowEviction: Bool = true) async throws {
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
            try await ensureModelLoaded(modelId: modelId, allowEviction: allowEviction)
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
            let requiredGb = ModelLoadAdmission.requiredToLoadGb(
                weightsGb: modelInfo.estimatedMemoryGb,
                headroomGb: Self.loadHeadroomGb)
            do {
                try await evictUntilAvailable(requiredGb: requiredGb, allowEviction: allowEviction)
            } catch let InferenceError.modelLoadFailed(message) {
                // Record for diagnostics so `doctor` shows the operator the exact
                // "Insufficient memory …" reason, then rethrow unchanged.
                recordModelLoadError(model: modelId, message: message)
                throw InferenceError.modelLoadFailed(message)
            }
            try Task.checkCancellation()
            if isShuttingDown { throw CancellationError() }

            // Q6: reserve this load's weight footprint in the shared KV budget so
            // a concurrent KV reservation on an already-loaded model can't grant
            // headroom that, plus these incoming (not-yet-in-mlxUsed) weights,
            // blows the unified-memory cap. Released once the weights are resident.
            let pendingLoadGiB = modelInfo.estimatedMemoryGb * 1_073_741_824
            let pendingLoadBytes: UInt64 =
                pendingLoadGiB.isFinite && pendingLoadGiB > 0
                ? (pendingLoadGiB >= Double(UInt64.max) ? .max : UInt64(pendingLoadGiB))
                : 0
            await kvBudget.reservePendingLoad(requestID: pendingLoadID, bytes: pendingLoadBytes)

            logger.info("Loading model: \(modelId) from \(modelPath.path)")
            // Cold-start load timing (slot-level `model_load_time_ms`): from
            // here to slot install — covering the weight load, sizing, and
            // engine build the coordinator's cold-load routing pays for.
            let loadStartedAt = ContinuousClock.now

            // Re-hash the weights about to be loaded. Refreshing BEFORE the slot
            // goes active guarantees a challenge arriving mid-serve reports the
            // hash of the bytes actually loaded — not the disk state at daemon
            // start. (See `refreshWeightHash` for the full rationale.)
            let preLoadRefresh = try await refreshWeightHash(modelId: modelId, modelPath: modelPath)

            if let beforeModelLoad {
                await beforeModelLoad(modelId)
                try Task.checkCancellation()
                if isShuttingDown { throw CancellationError() }
            }
            let container = try await loadModelContainer(from: modelPath)
            try Task.checkCancellation()
            if isShuttingDown { throw CancellationError() }

            // TOCTOU guard: the hash above was computed BEFORE loadModelContainer
            // read the weights. If a re-download landed in that window,
            // liveModelHashes would describe different bytes than what was
            // actually loaded. Re-stat the snapshot fingerprint (cheap) and, only
            // if it drifted from what the recorded hash corresponds to, recompute
            // so liveModelHashes/modelHashFingerprints reflect the loaded bytes.
            // The common case (fingerprint unchanged) costs one stat-based
            // fingerprint and no re-read. A nil pre-load fingerprint also forces a
            // re-hash here — we never recorded a trustworthy hash, so re-deriving
            // it post-load is the safe direction.
            let postLoadFingerprint = WeightHasher.snapshotFingerprint(snapshotDir: modelPath)
            if preLoadRefresh.effectiveFingerprint == nil
                || postLoadFingerprint != preLoadRefresh.effectiveFingerprint {
                logger.warning(
                    "Snapshot fingerprint drifted between hash and load for \(modelId) — recomputing weight hash for the bytes actually loaded")
                _ = try await refreshWeightHash(modelId: modelId, modelPath: modelPath)
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
            MLXMemoryGuard.configureOnce(log: { limits in
                FileHandle.standardError.write(Data(
                    "[mlx] memory ceiling set: limit=\(limits.memoryLimitBytes / (1024*1024*1024))GB cache=\(limits.cacheLimitBytes / (1024*1024*1024))GB\n".utf8
                ))
            })

            // Scheduler-free sizing snapshot (v0.7.5): weight bytes + the
            // engine-truth fp16 KV rate + context window — everything the
            // re-slice, bridge, heartbeat, and vision gate need.
            let sizing = await SlotSizingSnapshot.build(
                container: container,
                modelPath: modelPath,
                fallbackDefaultMaxTokens: Self.schedulerDefaultMaxTokens)

            // Weights are resident now (reflected in MLX active/cache), so hand
            // off from the pending-load reservation to the live mlxUsed view —
            // concurrent KV reservations see the weights from here on. (Also
            // released in catch for the error paths above.)
            await kvBudget.release(requestID: pendingLoadID)
            if isShuttingDown || Task.isCancelled {
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
                MLX.Memory.clearCache()
                let message = "Model '\(modelId)' loaded but has insufficient KV headroom "
                    + "under the memory cap (\(headroomGb) GB free, need \(minGb) GB to serve) — unloaded"
                recordModelLoadError(model: modelId, message: message)
                throw InferenceError.modelLoadFailed(message)
            }

            let tokenizer: TokenizerHandle = await container.perform { ctx in
                TokenizerHandle(ctx.tokenizer)
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
            let engineV2Bridge: EngineV2Bridge
            do {
                engineV2Bridge = try await resliceAndBuildEngineV2Slot(
                    modelId: modelId,
                    modelType: modelInfo.modelType,
                    isVLM: slotIsVLM,
                    modelDirectory: modelPath,
                    container: container,
                    tokenizer: tokenizer,
                    sizing: sizing
                )
            } catch let error as InferenceError {
                // Already shaped (e.g. the re-slice floor refusal) — record +
                // rethrow unchanged so loadErrorStatusCode sees the original.
                MLX.Memory.clearCache()
                if case .modelLoadFailed(let message) = error {
                    recordModelLoadError(model: modelId, message: message)
                }
                throw error
            } catch {
                MLX.Memory.clearCache()
                let message =
                    "Model '\(modelId)' loaded but its v2 engine construction failed: \(error) — unloaded"
                recordModelLoadError(model: modelId, message: message)
                throw InferenceError.modelLoadFailed(message)
            }

            // Post-BRIDGE measured-headroom re-guard (v0.7.3, kept): the
            // engine build (and, for VLM slots, the text-model extraction +
            // parity probe) can retain additional load-time memory beyond
            // the weights the check above measured. Re-measure so a box
            // whose full load-time footprint leaves no serveable KV unloads
            // and 503s instead of advertising a model whose every request
            // the shared KV gate rejects — the v0.7.2 black-hole shape.
            MLX.Memory.clearCache()
            if !KVHeadroomProbe.hasServeableKVHeadroom() {
                let headroomGb = String(
                    format: "%.1f",
                    Double(KVHeadroomProbe.measuredLiveKVHeadroomBytes) / (1024.0 * 1024.0 * 1024.0))
                await engineV2Runtime.unregister(modelId: modelId)
                await engineV2Bridge.shutdown()
                MLX.Memory.clearCache()
                // The aborted newcomer's grant was carved out of the fleet
                // budget — grow the survivors back to their shares.
                await resliceGrowSurvivors()
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

            modelSlots[modelId] = ModelSlot(
                engineV2: engineV2Bridge,
                container: container,
                tokenizer: tokenizer,
                sizing: sizing,
                isVLM: slotIsVLM,
                modelType: modelInfo.modelType,
                lastInferenceAt: .now
            )

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
        guard let slot = modelSlots[modelId], !modelsUnloading.contains(modelId) else { return }
        modelsUnloading.insert(modelId)
        // Retire the slot's v2 bridge: unregister so heartbeats/cancellation
        // stop fanning out to it, then drain the engine gracefully (running
        // requests finish, new submissions are rejected).
        await engineV2Runtime.unregister(modelId: modelId)
        await slot.engineV2.shutdown()
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

    /// Weight hashes for ONLY the models currently loaded in memory this session.
    /// A model is "currently loaded" iff it has a live slot (and isn't tearing
    /// down) AND we have a known live hash for it. Used by the attestation
    /// challenge response so the coordinator's model-swap hard-untrust check only
    /// ever sees hashes for weights we are actually serving — idle/unloaded
    /// advertised models drop out because they have no slot.
    internal func loadedModelHashesSnapshot() -> [String: String] {
        var result: [String: String] = [:]
        for modelId in modelSlots.keys where !modelsUnloading.contains(modelId) {
            if let hash = liveModelHashes[modelId] {
                result[modelId] = hash
            }
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
        // Hold back enough to honor the 90% unified cap: max(configured reserve,
        // physical − cap). Without this the free-memory gate would load models
        // until only `configReserve` (4 GiB) remained — past the cap on big boxes.
        let reserve = UnifiedMemoryCap.loadReserveBytes(
            configReserveBytes: Self.memoryReserveBytes(forGiB: loopConfig.config.provider.memoryReserveGB))
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
        // batched engine since VLMModel refines LanguageModel.
        if Self.modelIsVLM(at: directory) {
            return try await VLMModelFactory.shared.loadContainer(
                from: directory,
                using: LocalTokenizerLoader()
            )
        }
        return try await LLMModelFactory.shared.loadContainer(
            from: directory,
            using: LocalTokenizerLoader()
        )
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
