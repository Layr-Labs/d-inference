/// ProviderLoop -- test-only seams.
///
/// Internal accessors used exclusively by ProviderCoreTests (via
/// `@testable import`) to drive otherwise-private flows without the real
/// coordinator event loop or download path. Not used by production code.

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
    /// Test seam: number of advertised models (startup ∪ prefetched).
    func advertisedModelCount() -> Int { advertisedModels.count }

    /// Test seam: whether a model id is currently advertised.
    func isModelAdvertised(_ id: String) -> Bool { advertisedModels[id] != nil }

    /// Test seam: recorded weight hash for a model (nil when unknown).
    func modelHashForTesting(_ id: String) -> String? { modelHashes[id] }

    /// Test seam: exposes the prefetch pre-check decision.
    func prefetchPreCheckForTesting(_ id: String) -> PrefetchPreCheck { prefetchPreCheck(modelId: id) }

    /// Test seam: drive the declarative `desired_models` reconcile directly (the
    /// real entry point, `reconcileDesiredModels`, is private and otherwise only
    /// reached via the coordinator event loop). Lets a unit test prove that a
    /// desired build the provider lacks triggers a prefetch, and that the
    /// previous build is recorded for the hard-swap drop.
    func reconcileDesiredModelsForTesting(_ entries: [CoordinatorMessage.DesiredModelEntry], send: SendHandle) async {
        await reconcileDesiredModels(entries, send: send)
    }

    /// Test seam: the current effective concurrent-slot cap (tracks the live
    /// advertised set, clamped to `[1, backend.maxModelSlots]`).
    func maxModelSlotsForTesting() -> Int { maxModelSlots }

    /// Test seam: hide or reveal a resident model as unload-in-progress without
    /// running the real scheduler teardown.
    func setModelUnloadingForTesting(_ id: String, _ unloading: Bool) {
        if unloading {
            modelsUnloading.insert(id)
        } else {
            modelsUnloading.remove(id)
        }
    }

    /// Test seam: reserve or release a future resident slot without loading
    /// model weights.
    func setModelLoadingForTesting(_ id: String, _ loading: Bool) {
        if loading {
            modelsLoading.insert(id)
        } else {
            modelsLoading.remove(id)
        }
    }

    /// Test seam: reserve or release a distinct model commitment queued behind
    /// the global load gate.
    func setModelWaitingForLoadGateForTesting(_ id: String, _ waiting: Bool) {
        if waiting {
            loadGateWaitingModels[id] = 1
        } else {
            loadGateWaitingModels.removeValue(forKey: id)
        }
    }

    /// Test seam: override the desired-build prefetch retry backoff schedule
    /// (the production default waits tens of seconds between attempts).
    func setDesiredPrefetchRetryDelaysForTesting(_ delays: [Duration]) {
        desiredPrefetchRetryDelays = delays
    }

    /// Test seam: number of scheduled (not yet fired) desired-prefetch retries.
    func pendingDesiredPrefetchRetriesForTesting() -> Int { desiredPrefetchRetryTasks.count }

    /// Test seam: install a fake prefetcher and (re)build the prefetch
    /// coordinator against a given coordinator client. Used by unit tests to
    /// exercise the handler without the real download path.
    func installPrefetchCoordinatorForTesting(
        _ coordinator: ModelPrefetchCoordinator,
        client: CoordinatorClient,
        send: SendHandle? = nil
    ) {
        self.coordinatorClient = client
        self.prefetchCoordinator = coordinator
        if let send { self.outboundSend = send }
    }

    // MARK: - Startup preload seams

    /// Test seam: redirect the loaded-models persistence file to a temp path
    /// so persistence tests never touch the operator's real
    /// `~/.darkbloom/loaded-models.json`, and arm the persistence gate
    /// (production arms it in `run()`).
    func setLoadedModelsFileForTesting(_ url: URL?) {
        loadedModelsFileOverride = url
        loadedModelsPersistenceEnabled = url != nil
    }

    /// Test seam: toggle the persistence gate independently of the path
    /// override (pins the "inert unless serving" guard).
    func setLoadedModelsPersistenceEnabledForTesting(_ enabled: Bool) {
        loadedModelsPersistenceEnabled = enabled
    }

    /// Test seam: replace `ensureModelLoaded` in the startup preload driver
    /// with a scripted loader (no weights, no disk).
    func setStartupPreloadLoadOverrideForTesting(
        _ load: (@Sendable (String) async throws -> Void)?
    ) {
        startupPreloadLoadOverride = load
    }

    /// Test seam: replace the startup self-test decode with a scripted stub.
    func setStartupSelfTestOverrideForTesting(
        _ selfTest: (@Sendable (String) async throws -> Duration)?
    ) {
        startupSelfTestOverride = selfTest
    }

    /// Test seam: replace the preload admission's free-memory probe with a
    /// scripted value (the real probe reads live machine memory).
    func setStartupPreloadFreeMemoryOverrideForTesting(
        _ freeMemoryGb: (@Sendable () async -> Double)?
    ) {
        startupPreloadFreeMemoryOverride = freeMemoryGb
    }

    /// Test seam: the ordered startup preload plan (config list vs persisted
    /// set, dedup, advertised filter, slot cap).
    func startupPreloadPlanForTesting() -> [StartupPreloader.Candidate] {
        startupPreloadPlan()
    }

    /// Test seam: run the registration readiness gate (the production entry
    /// point is `run()`, which needs a live coordinator).
    func runStartupPreloadGateForTesting() async -> StartupPreloadGateOutcome {
        await runStartupPreloadGate()
    }

    /// Test seam: write the current loaded-model set to the persistence file
    /// (production write points are `ensureModelLoaded` / `unloadModel`).
    func persistLoadedModelSetForTesting() {
        persistLoadedModelSet()
    }

    /// Test seam: mark the loop as shutting down, so tests can assert the
    /// shutdown-teardown guard (unloads during shutdown must NOT rewrite the
    /// persisted serving set).
    func beginShutdownForTesting() {
        isShuttingDown = true
    }

    /// Test seam: whether the startup preload driver is still running.
    func startupPreloadTaskRunningForTesting() -> Bool {
        startupPreloadTask != nil
    }

    /// Test seam: install a live coordinator client (without the prefetch
    /// machinery `installPrefetchCoordinatorForTesting` requires) so the
    /// post-registration fail-closed retirement path can be exercised
    /// against a real client + mock coordinator.
    func setCoordinatorClientForTesting(_ client: CoordinatorClient) {
        coordinatorClient = client
    }

    // MARK: - ContinuousBatchingV2 seams

    /// Test seam: swap the process-global v2 runtime for an isolated
    /// instance so registration/consult assertions can't race other tests.
    func setEngineV2RuntimeForTesting(_ runtime: EngineV2Runtime) {
        engineV2Runtime = runtime
    }

    /// Test seam: install slot-factory hooks (environment + EOS snapshot +
    /// engine builder) so `makeEngineV2BridgeForSlot` runs end-to-end with a
    /// scripted `CBv2Engine` — no model weights, no container reads.
    func setEngineV2SlotHooksForTesting(_ hooks: EngineV2SlotHooks?) {
        engineV2SlotHooks = hooks
    }

    /// Test seam: drive the model-load slot factory directly (production
    /// entry point is `ensureModelLoaded`, which needs real weights).
    func makeEngineV2BridgeForSlotForTesting(
        modelId: String,
        modelType: String?,
        isVLM: Bool = false,
        modelDirectory: URL? = nil,
        container: MLXLMCommon.ModelContainer,
        tokenizer: TokenizerHandle,
        scheduler: BatchScheduler
    ) async -> EngineV2Bridge? {
        await makeEngineV2BridgeForSlot(
            modelId: modelId,
            modelType: modelType,
            isVLM: isVLM,
            modelDirectory: modelDirectory,
            container: container,
            tokenizer: tokenizer,
            scheduler: scheduler
        )
    }

    /// Test seam: install a fully-formed model slot (optionally carrying a
    /// v2 bridge) so capacity/cancellation guard tests can exercise the
    /// slot-dependent paths without loading weights.
    func installModelSlotForTesting(
        modelId: String,
        scheduler: BatchScheduler,
        container: MLXLMCommon.ModelContainer,
        tokenizer: TokenizerHandle,
        engineV2: EngineV2Bridge? = nil,
        modelType: String? = nil
    ) {
        modelSlots[modelId] = ModelSlot(
            scheduler: scheduler,
            engineV2: engineV2,
            container: container,
            tokenizer: tokenizer,
            isVLM: false,
            modelType: modelType,
            lastInferenceAt: .now
        )
    }

    /// Test seam: whether any live slot carries a v2 bridge (the capacity/
    /// cancellation zero-overhead guard).
    func hasEngineV2SlotsForTesting() -> Bool { hasEngineV2Slots }

    /// Test seam: the current aggregate backend capacity snapshot.
    func backendCapacityForTesting() -> BackendCapacity? { state.backendCapacity }

}
