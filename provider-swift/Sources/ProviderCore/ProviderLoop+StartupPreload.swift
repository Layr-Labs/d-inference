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
/// loaded via the normal `ensureModelLoaded` path (weights + legacy scheduler
/// + v2 bridge/warmup when flagged), optionally followed by a 1-token greedy
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
                        headroomGb: Self.loadHeadroomGb)))
        }
        return plan
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
            log: { line in log.info("\(line)") }
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
                try await Task.sleep(for: Self.startupSelfTestTimeout)
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
    private func retireModelAfterFailedSelfTest(modelId: String) async {
        await unloadModel(modelId)
        advertisedModels.removeValue(forKey: modelId)
        if let client = coordinatorClient {
            await client.unadvertiseModel(modelId)
            await client.forceReconnect()
        }
    }

    // MARK: - Self-test decode (the serving path)

    /// One-token greedy decode through the SAME path a routed request takes:
    /// `MultiModelBatchSchedulerEngine` over the loaded slot (v2 bridge when
    /// the slot carries one, else the legacy scheduler) via
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

        let sched = slot.scheduler
        let tokenizer = slot.tokenizer
        let modelType = slot.modelType
        let slotContainer = slot.container
        let slotIsVLM = slot.isVLM
        let slotEngineV2 = slot.engineV2

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
                    scheduler: sched, tokenizer: tokenizer, modelType: modelType,
                    container: slotContainer, isVLM: slotIsVLM,
                    engineV2Bridge: slotEngineV2)]
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
