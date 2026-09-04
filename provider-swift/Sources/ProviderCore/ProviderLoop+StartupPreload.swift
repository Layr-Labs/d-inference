/// ProviderLoop -- boot-time model preload + registration readiness gate.
///
/// Fixes the v0.6.30-class cold-restart failure mode: the provider used to
/// register (and attract routing) immediately after a release restart with
/// NOTHING loaded, so the first requests paid the full multi-GB weight load
/// and engine build inside a live request — and at a fleet rollover every box
/// was cold at once (first_chunk_timeout storm).
///
/// Now `run()` calls `runStartupPreloadGate()` BEFORE the coordinator client
/// is created: the previously-served (or operator-configured) model set is
/// loaded via the normal `ensureModelLoaded` path (weights + EngineV2 bridge),
/// optionally followed by a 1-token greedy
/// decode through the real serving path so Metal JIT, compiled buckets, and
/// the chat-template render are warm before the first routed request.
///
/// **Readiness vs availability tradeoff.** Registration is deferred only up
/// to `startup_preload_timeout_secs` (default 120s). If a load exceeds it,
/// the provider registers anyway — a lone provider for a model must still
/// serve it cold, and the existing lazy-load path is unchanged as the
/// fallback — while the remaining preloads continue in the background. The
/// heartbeat's `warm_models` field (which the coordinator's warm-model bonus
/// scores) stays truthful throughout: it is derived from live slots only, so
/// a still-loading model is never advertised as warm.

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

    /// How the startup preload gate resolved (logged; asserted in tests).
    internal enum StartupPreloadGateOutcome: Sendable, Equatable {
        /// `startup_preload = false`.
        case disabled
        /// Nothing to preload (no config list, no persisted set, or nothing
        /// advertised) — legacy register-immediately timing.
        case nothingToPreload
        /// Preload finished within the timeout — registering fully warm.
        case warm
        /// Timeout hit — registering now; loads continue in the background.
        case timedOut
    }

    /// Upper bound on one startup self-test decode so a wedged decode can
    /// never stall the whole preload driver (and with it every later model's
    /// warmup) indefinitely.
    internal static let startupSelfTestTimeout: Duration = .seconds(180)

    /// Cadence for refreshing the daemon-state liveness stamp while the startup
    /// preload gate defers registration. Comfortably under the daemon-state
    /// staleness window (90s) so a slow preload never reads as a wedged/down
    /// process to the crash-recovery watchdog.
    internal static let preloadLivenessRefreshInterval: Duration = .seconds(30)

    /// While the startup preload gate defers registration (up to
    /// `startup_preload_timeout_secs`, which an operator may raise well past the
    /// 90s daemon-state staleness window), keep refreshing the liveness stamp
    /// so the crash-recovery watchdog sees the slow-but-healthy candidate as
    /// alive — and does NOT take the down-grace restart path and charge a false
    /// failed start toward rollback/quarantine. The post-registration
    /// capacity-refresh loop takes over once the gate returns; the caller
    /// cancels this task then.
    internal func startPreloadLivenessRefresh() -> Task<Void, Never> {
        let me = self
        return Task.detached(priority: .utility) {
            while !Task.isCancelled {
                do {
                    try await taskSleep(Self.preloadLivenessRefreshInterval)
                } catch {
                    return  // cancelled
                }
                if Task.isCancelled { return }
                await me.writeDaemonState()
            }
        }
    }

    // MARK: - Loaded-model set persistence

    internal func loadedModelsFileURL() -> URL {
        loadedModelsFileOverride ?? LoadedModelsStore.path()
    }

    /// Persist the current loaded-model set. Called after every successful
    /// load and every NON-shutdown unload (idle timeout, eviction,
    /// retirement); the shutdown teardown skips it so a stop/update/restart
    /// remembers what was being served — that persisted set is the default
    /// startup preload plan.
    internal func persistLoadedModelSet() {
        // Inert until run() (or the test seam) enables it: a ProviderLoop
        // that never serves — every unit test exercising load/unload — must
        // not write the operator's real loaded-models file.
        guard loadedModelsPersistenceEnabled else { return }
        let loaded = modelSlots.keys.filter { !modelsUnloading.contains($0) }.sorted()
        LoadedModelsStore.write(loaded, to: loadedModelsFileURL())
    }

    // MARK: - Preload plan

    /// Build the ordered startup preload plan:
    ///   * `preload_models` non-empty → that list, in operator order;
    ///   * otherwise → the persisted previously-served set, biggest first
    ///     (the largest model loads while memory is emptiest).
    /// Ids not in the advertised set are skipped with a WARN; the plan is
    /// de-duplicated and capped at `maxModelSlots`.
    internal func startupPreloadPlan() -> [StartupPreloader.Candidate] {
        let backend = loopConfig.config.backend
        let ids: [String]
        if !backend.preloadModels.isEmpty {
            ids = backend.preloadModels
        } else {
            ids = LoadedModelsStore.read(from: loadedModelsFileURL()).sorted {
                (advertisedModels[$0]?.estimatedMemoryGb ?? 0)
                    > (advertisedModels[$1]?.estimatedMemoryGb ?? 0)
            }
        }

        var seen = Set<String>()
        var plan: [StartupPreloader.Candidate] = []
        for id in ids {
            guard seen.insert(id).inserted else { continue }
            guard let info = advertisedModels[id] else {
                logger.warning("Startup preload: '\(id)' is not in the advertised model set — skipping")
                continue
            }
            guard plan.count < maxModelSlots else {
                logger.warning(
                    "Startup preload: plan exceeds max_model_slots=\(self.maxModelSlots) — skipping '\(id)'")
                continue
            }
            plan.append(
                StartupPreloader.Candidate(
                    modelId: id,
                    requiredGb: ModelLoadAdmission.requiredToLoadGb(
                        weightsGb: info.estimatedMemoryGb,
                        headroomGb: loadHeadroomGb)))
        }
        return plan
    }

    /// The LIVE preload requirement for a candidate: measured-or-padded
    /// weights plus the CURRENT serving-set headroom. Consulted at each
    /// preloader admission step because a fail-closed retirement earlier in
    /// the run can relax the floor the plan-time figure captured. nil when
    /// the id left the advertised set (the preloader then keeps its planned
    /// figure; the load itself re-guards).
    internal func livePreloadRequiredGb(_ modelId: String) -> Double? {
        guard let info = advertisedModels[modelId] else { return nil }
        return ModelLoadAdmission.requiredToLoadGb(
            weightsGb: info.estimatedMemoryGb,
            headroomGb: loadHeadroomGb)
    }

    // MARK: - Readiness gate

    /// Preload the startup plan, deferring the caller (registration) up to
    /// `startup_preload_timeout_secs`. On timeout the driver keeps running in
    /// the background (`startupPreloadTask`); shutdown cancels it.
    @discardableResult
    internal func runStartupPreloadGate() async -> StartupPreloadGateOutcome {
        let backend = loopConfig.config.backend
        guard backend.startupPreload else {
            logger.info("Startup preload disabled (startup_preload=false)")
            return .disabled
        }
        let plan = startupPreloadPlan()
        guard !plan.isEmpty else {
            logger.info("Startup preload: nothing to preload — registering immediately")
            return .nothingToPreload
        }

        let timeout = Duration.seconds(Int64(max(1, backend.startupPreloadTimeoutSecs)))
        logger.info(
            "Startup preload: \(plan.count) model(s) [\(plan.map(\.modelId).joined(separator: ", "))] — "
                + "deferring registration up to \(backend.startupPreloadTimeoutSecs)s")

        let me = self
        let log = logger
        let failClosed = backend.startupSelftestFailClosed
        var selfTestClosure: (@Sendable (String) async throws -> Duration)?
        if backend.startupSelftest {
            selfTestClosure = { modelId in try await me.startupPreloadSelfTest(modelId: modelId) }
        }
        let onSelfTestFailed: @Sendable (String, String) -> Void = { modelId, message in
            TelemetryClient.shared.emit(
                kind: .engineHealth,
                severity: .warn,
                message: "startup self-test decode failed",
                fields: [
                    "model": .string(modelId),
                    "error": .string(message),
                    "fail_closed": .bool(failClosed),
                ]
            )
        }
        let deps = StartupPreloader.Dependencies(
            freeMemoryGb: { await me.startupPreloadFreeMemoryGb() },
            load: { modelId in try await me.startupPreloadLoad(modelId: modelId) },
            selfTest: selfTestClosure,
            selfTestFailClosed: failClosed,
            retire: { modelId in await me.retireModelAfterFailedSelfTest(modelId: modelId) },
            onSelfTestFailed: onSelfTestFailed,
            log: { line in log.info("\(line)") },
            currentRequiredGb: { modelId in await me.livePreloadRequiredGb(modelId) }
        )

        let preloader = StartupPreloader(deps: deps)
        let clock = ContinuousClock()
        let started = clock.now
        let driver = Task {
            let summary = await preloader.run(candidates: plan)
            await me.finishStartupPreload(summary: summary, elapsed: clock.now - started)
        }
        startupPreloadTask = driver

        let finishedInTime = await waitForPreloads([driver], timeout: timeout)
        if finishedInTime {
            logger.info(
                "Startup preload gate: warm after \(StartupPreloader.secs(clock.now - started)) — registering")
            return .warm
        }
        logger.warning(
            "Startup preload gate: exceeded \(backend.startupPreloadTimeoutSecs)s — registering now; "
                + "remaining loads continue in the background (cold requests use the lazy-load path)")
        return .timedOut
    }

    /// Driver epilogue: log the summary and clear the task handle. Runs on the
    /// actor whether the gate was still waiting or had already timed out.
    private func finishStartupPreload(summary: StartupPreloader.Summary, elapsed: Duration) {
        startupPreloadTask = nil
        var parts = ["loaded=\(summary.loaded.count)"]
        if !summary.skippedInsufficientMemory.isEmpty {
            parts.append("skipped_memory=[\(summary.skippedInsufficientMemory.joined(separator: ", "))]")
        }
        if !summary.failed.isEmpty {
            parts.append("failed=[\(summary.failed.joined(separator: ", "))]")
        }
        if !summary.selfTestFailed.isEmpty {
            parts.append("selftest_failed=[\(summary.selfTestFailed.joined(separator: ", "))]")
        }
        if !summary.retired.isEmpty {
            parts.append("retired=[\(summary.retired.joined(separator: ", "))]")
        }
        logger.info(
            "Startup preload complete in \(StartupPreloader.secs(elapsed)): \(parts.joined(separator: " "))")
        writeDaemonState()
    }

    // MARK: - Preload steps (production wiring, overridable in tests)

    private func startupPreloadFreeMemoryGb() async -> Double {
        if let override = startupPreloadFreeMemoryOverride {
            return await override()
        }
        return await availableMemoryGb()
    }

    private func startupPreloadLoad(modelId: String) async throws {
        if let override = startupPreloadLoadOverride {
            try await override(modelId)
            return
        }
        // allowEviction: false — the preloader's freeMemoryGb pre-check is a
        // fast skip, but the authoritative no-evict enforcement lives INSIDE
        // ensureModelLoaded's serialized critical section, so an interleaved
        // local-endpoint load can't make it stale. A candidate that would
        // require evicting an earlier preload (or any resident model) fails
        // here and is WARN-logged by the preloader; the lazy-load path (which
        // MAY evict, as always) remains the fallback for live traffic.
        try await ensureModelLoaded(modelId: modelId, allowEviction: false)
    }

    private func startupPreloadSelfTest(modelId: String) async throws -> Duration {
        if let override = startupSelfTestOverride {
            return try await override(modelId)
        }
        // Bounded: a wedged decode fails the self-test instead of stalling the
        // driver (and the remaining models' warmup) forever.
        let me = self
        return try await withThrowingTaskGroup(of: Duration.self) { group in
            group.addTask { try await me.runStartupSelfTestDecode(modelId: modelId) }
            group.addTask {
                try await taskSleep( Self.startupSelfTestTimeout)
                throw InferenceError.generationFailed(
                    "startup self-test timed out after \(Self.startupSelfTestTimeout.components.seconds)s")
            }
            guard let first = try await group.next() else { throw CancellationError() }
            group.cancelAll()
            return first
        }
    }

    /// Fail-closed retirement: unload the model and drop it from the
    /// advertised set for this run, so registration (which filters
    /// `loopConfig.models` through `advertisedModels`) never announces it.
    /// The persisted loaded-model set is updated by `unloadModel`.
    ///
    /// Post-registration retirement (the gate timed out, so the coordinator
    /// client is already live and the initial `register` carried this model):
    /// registration is the only wire mechanism that communicates a REMOVAL
    /// from the advertised set (`models_update` is additive), so mirror the
    /// hard-swap drop (`dropAdvertisedBuild`) — remove it from the client's
    /// advertised store — and force a reconnect so a fresh `register`
    /// announces the shrunken set. Pre-registration (the common case:
    /// preload finished inside the gate) both are nil and the `run()` filter
    /// handles it with no extra traffic.
    func retireModelAfterFailedSelfTest(modelId: String) async {
        // Tombstone for the whole retirement, including the unload drain:
        // with the slot still resident, a concurrent same-id prefetch sees
        // `.alreadyAvailable` and its verified-insert would re-advertise the
        // failed model, undoing the fail-closed removal below.
        retiringModels.insert(modelId)
        defer { retiringModels.remove(modelId) }
        // Durable fail-closed mark, keyed by the bytes that failed: the
        // tombstone above dies with this function, but a prefetch whose
        // scan/hash suspension spans this whole retirement must STILL
        // refuse to re-advertise the same weights (`applyVerifiedPrefetch`
        // checks this map). A future build with a different hash clears it
        // there and gets its chance.
        // ALWAYS mark, from the SLOT-BOUND hash or the "" sentinel — never
        // the scanner maps: those keep a previous value when recomputation
        // fails, so a stale H1 could be recorded while H2's bytes actually
        // loaded and failed, and a later verified H2 would sail past the
        // record. `loadedWeightHash` is the slot's own binding for the bytes
        // it loaded (the bracketed hash on paged slots, the published
        // fingerprint-path hash on contiguous ones — T4-01 keeps the record
        // honest now that contiguous slots skip the bracket); absent that
        // (or a cold retire), the sentinel refuses every same-id build until
        // a daemon restart — conservative, fail-closed.
        failedSelfTestHashes[modelId] =
            modelSlots[modelId]?.loadedWeightHash ?? ""
        // Un-advertise BEFORE unloading so unloadModel's own
        // refresh-then-regrow runs against the SHRUNKEN serving set — with
        // the old order the regrow was sized under the retiring model's
        // floor and survivors stayed under-granted until the next lifecycle
        // event (grant clamps are min(granted, current); heartbeats cannot
        // heal upward).
        advertisedModels.removeValue(forKey: modelId)
        // Remove from the client's advertised store BEFORE the drain (any
        // reconnect that happens during it re-registers without the failed
        // model) — but do NOT force the reconnect yet: cancelling the
        // WebSocket here would cancelAllInflight() and interrupt every
        // unrelated in-flight request rather than letting them ride out the
        // target's drain window. Until the post-drain reconnect lands, a
        // newly routed request for the retired id can still arrive and 404
        // at the advertised guard — bounded, and absorbed by the
        // coordinator's dispatch retry machinery.
        await coordinatorClient?.unadvertiseModel(modelId)
        await unloadModel(modelId)
        // Another task may already own the drain (unloadModel returns
        // immediately for modelsUnloading ids) — hold the tombstone until
        // the slot is actually gone, or a same-id prefetch landing between
        // our defer and the real unload end would re-advertise the failed
        // build against a still-resident slot.
        if modelsUnloading.contains(modelId) {
            await waitForModelUnload(modelId)
        }
        // Cold retirement (the model never held a slot): unloadModel
        // no-ops, so relax the reserve and regrow survivors here.
        await refreshActivationReserve()
        await resliceGrowSurvivors()
        await updateAggregateCapacity()
        scheduleRetirementReconnect()
    }

    /// The reconnect that communicates a removal (`models_update` is
    /// additive; a fresh register is the wire mechanism) — DETACHED and
    /// COALESCED. Detached: the startup preloader awaits retirement inline,
    /// so waiting here would stall every remaining preload candidate
    /// behind a busy box. Coalesced: a burst of retirements needs one
    /// re-registration, and the client store already excludes every
    /// retired id (un-advertised synchronously above) by the time it
    /// fires. The wait lets unrelated in-flight work ride out first —
    /// closing the socket cancels EVERY in-flight request on the box
    /// (`.disconnected` → cancelAllInflight), not just the retired
    /// model's (already drained by unloadModel) — bounded by the shutdown
    /// drain budget. Until it lands, a routed request for a retired id
    /// 404s at the advertised guard and the coordinator's dispatch retry
    /// absorbs it: the wait extends that bounded window, it does not add
    /// a failure mode.
    /// True while `modelId` must be refused because of a failed self-test:
    /// mid-retirement (tombstone), or retired and un-advertised with the
    /// durable failed-hash record standing while the coordinator's
    /// registered inventory has not yet converged (reconnect pending). Both
    /// are `slot_state` rejections — the coordinator reroutes to a provider
    /// whose build passed.
    internal func isRefusedByRetirement(_ modelId: String) -> Bool {
        retiringModels.contains(modelId)
            || (advertisedModels[modelId] == nil && failedSelfTestHashes[modelId] != nil)
    }

    private func scheduleRetirementReconnect() {
        guard pendingRetirementReconnect == nil else { return }
        pendingRetirementReconnect = Task { [weak self] in
            guard let self else { return }
            _ = await self.waitForInflightDrain(
                timeout: Self.shutdownDrainTimeout, reason: "retirement reconnect")
            // Shutdown cancels this task (`beginShutdown`); a cancelled
            // reconnect must not re-register a session shutdown is closing.
            guard !Task.isCancelled else { return }
            await self.fireRetirementReconnect()
        }
    }

    private func fireRetirementReconnect() async {
        pendingRetirementReconnect = nil
        guard !isShuttingDown, coordinatorClient != nil else { return }
        // Admission barrier across the reconnect: between the drain's last
        // observation and the socket closing there is an actor hop, and a
        // routed request admitted in it would only be cancelled by the
        // `.disconnected` handler. Raised here, actor-isolated, before any
        // suspension; lifted by the `.connected` event of the new session.
        isReconnectingAfterRetirement = true
        if hasInflightWork {
            // Work landed in the hop after the drain observed empty: let it
            // ride out under the barrier (nothing new is admitted), then close.
            _ = await waitForInflightDrain(
                timeout: Self.shutdownDrainTimeout, reason: "retirement reconnect")
            if isShuttingDown || Task.isCancelled {
                isReconnectingAfterRetirement = false
                return
            }
        }
        await coordinatorClient?.forceReconnect()
    }

    // MARK: - Self-test decode (the serving path)

    /// One-token greedy decode through the SAME path a routed request takes:
    /// `MultiModelBatchSchedulerEngine` over the loaded slot's EngineV2 bridge via
    /// `MLXOpenAIService.streamChatCompletionFrames`. Forces end-to-end
    /// warmth — Metal JIT, compiled decode buckets, chat-template render —
    /// with a tiny prompt. Holds a local reservation so eviction can't pull
    /// the model out from under the decode.
    internal func runStartupSelfTestDecode(modelId: String) async throws -> Duration {
        guard let slot = modelSlots[modelId], !modelsUnloading.contains(modelId) else {
            throw InferenceError.noModelLoaded
        }
        localReservations.reserve(modelId)
        defer {
            localReservations.release(modelId)
            modelSlots[modelId]?.lastInferenceAt = .now
        }

        let tokenizer = slot.tokenizer
        let modelType = slot.modelType
        let slotContainer = slot.container
        let slotIsVLM = slot.isVLM
        let slotEngineV2 = slot.engineV2
        let slotVisionGate = slot.visionGate(kvBudget: kvBudget)

        let request = OpenAIChatCompletionRequest(
            model: modelId,
            messages: [OpenAIChatMessage(role: .user, content: .text("Hi"))],
            reasoningParser: Self.inferReasoningParser(for: modelType),
            stream: true,
            temperature: 0,
            maxTokens: 1
        )

        let engine = MultiModelBatchSchedulerEngine(
            registryProvider: { @Sendable in
                [modelId: .init(
                    tokenizer: tokenizer, modelType: modelType,
                    container: slotContainer, isVLM: slotIsVLM,
                    engineV2Bridge: slotEngineV2,
                    visionGate: slotVisionGate)]
            },
            defaultMaxTokens: Self.schedulerDefaultMaxTokens
        )
        let service = MLXOpenAIService(engine: engine)

        let clock = ContinuousClock()
        let start = clock.now
        let frames = try await service.streamChatCompletionFrames(request: request)
        var frameCount = 0
        for try await _ in frames {
            frameCount += 1
        }
        guard frameCount > 0 else {
            throw InferenceError.generationFailed("startup self-test produced no output frames")
        }
        return clock.now - start
    }
}
