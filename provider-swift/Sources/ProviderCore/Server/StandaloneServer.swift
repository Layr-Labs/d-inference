/// Standalone HTTP server for local/standalone mode.
///
/// Serves OpenAI-compatible inference requests directly without a coordinator.
/// HTTP routing, request decoding, SSE formatting, and non-streaming response
/// assembly are delegated to the upstream `MLXLMServer` library via
/// ``MLXServerApplication/buildRouter(service:)``. This file keeps only the
/// Darkbloom-specific policy layer:
///
///   * Multi-model LRU + idle eviction
///   * Memory-headroom gating before a load
///   * Reservation counters that block eviction of in-flight models
///   * `BatchScheduler` construction with the shared `GlobalKVCacheBudget`
///
/// HTTP wiring (Hummingbird application builder + `CORSResponder` +
/// OpenAI-shaped error envelope) lives in
/// ``StandaloneServer+HTTP.swift`` so this file can focus on the
/// model lifecycle.
///
/// Endpoints served by the upstream router include `/health`, `/v1/models`,
/// `/v1/chat/completions`, `/v1/completions`, `/v1/responses*`, `/tokenize`,
/// `/detokenize`, `/apply-template`, plus `/metrics` and `/props`.

import Darwin
import Foundation
import Hummingbird
import MLX
import MLXLLM
import MLXLMCommon
import MLXLMServer
import os

private enum StandaloneServerError: Error, LocalizedError {
    case modelNotFound(String)
    case capacityUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .modelNotFound(let id): return "Model '\(id)' not found locally"
        case .capacityUnavailable(let message): return message
        }
    }
}

// MARK: - Public API

/// Configuration for the standalone server.
public struct StandaloneServerConfig: Sendable {
    public let port: UInt16
    public let host: String
    public let maxCachedModels: Int
    /// Bearer token required on every inference route (direct/local mode).
    /// nil = no auth (library default / explicit `--no-auth`).
    public let authToken: String?

    public init(port: UInt16 = 8000, host: String = "127.0.0.1", maxCachedModels: Int = 3, authToken: String? = nil) {
        self.port = port
        self.host = host
        self.maxCachedModels = max(1, maxCachedModels)
        self.authToken = authToken
    }
}

private let standaloneLogger = Logger(
    subsystem: "dev.darkbloom.provider",
    category: "StandaloneServer"
)

public actor StandaloneServer {

    /// Tracks a loaded model scheduler and when it was last used for LRU eviction.
    private struct CachedScheduler {
        let scheduler: BatchScheduler
        let tokenizer: TokenizerHandle
        let modelType: String?
        var lastUsedAt: ContinuousClock.Instant
    }

    /// Internal access so the +HTTP extension can read host/port
    /// when constructing the Hummingbird application.
    let config: StandaloneServerConfig
    private var schedulers: [String: CachedScheduler] = [:]
    private var modelsLoading: Set<String> = []
    private var loadingWaiters: [String: [CheckedContinuation<Void, any Error>]] = [:]
    private var isLoadingAny: Bool = false
    private var loadGateWaiters: [CheckedContinuation<Void, Never>] = []
    private var schedulerReservations: [String: Int] = [:]
    private var evictingModels: Set<String> = []
    private var models: [ModelInfo]
    private var serverTask: Task<Void, Never>?
    private let kvBudget: GlobalKVCacheBudget
    /// Bind status, set by Hummingbird's onServerRunning (success) or the server
    /// task's catch (failure). `waitUntilBound` reads these — the authoritative
    /// "did WE bind the port" signal, not an HTTP probe a foreign process on the
    /// same port could answer.
    private var didBind = false
    private var bindFailed = false

    public init(
        config: StandaloneServerConfig = StandaloneServerConfig(),
        models: [ModelInfo] = []
    ) {
        self.config = config
        self.models = models
        self.kvBudget = GlobalKVCacheBudget()
    }

    static let schedulerMaxConcurrent = 24
    static let schedulerPendingTimeout: Duration = .seconds(120)
    /// Internal access so the +HTTP extension can pass the same
    /// default through to ``MultiModelBatchSchedulerEngine``.
    static let schedulerDefaultMaxTokens = 4096

    /// Map a scheduler-side admission error message to an HTTP status. Used
    /// by tests and by any custom error-mapping middleware. Retained here
    /// rather than moved into the upstream library because the keyword set
    /// is specific to ``BatchScheduler``'s admission errors.
    static func schedulerErrorStatus(for message: String) -> HTTPResponse.Status {
        let lowercased = message.lowercased()
        if lowercased.contains("invalid token")
            || lowercased.contains("duplicate request")
            || lowercased.contains("batch token budget")
        {
            return .badRequest
        }
        if lowercased.contains("queue full") {
            return .tooManyRequests
        }
        if lowercased.contains("token_budget_exhausted")
            || lowercased.contains("timed out waiting for capacity")
            || lowercased.contains("insufficient global kv cache headroom")
        {
            return .serviceUnavailable
        }
        return .internalServerError
    }

    /// Update the advertised model list (e.g. after a rescan).
    public func setModels(_ newModels: [ModelInfo]) {
        self.models = newModels
    }

    /// Start listening for HTTP connections. The server runs in a child task.
    public func start() throws {
        guard serverTask == nil else { return }

        let app = makeApplication()
        serverTask = Task {
            do {
                try await app.runService(gracefulShutdownSignals: [])
            } catch is CancellationError {
                standaloneLogger.info("Standalone server cancelled")
            } catch {
                standaloneLogger.error("Standalone server failed to bind \(self.config.host):\(self.config.port): \(error.localizedDescription)")
                await self.markBindFailed()
            }
        }
    }

    /// Called by Hummingbird's onServerRunning once the socket is actually bound.
    func markBound() {
        didBind = true
        standaloneLogger.info("Standalone server listening on \(self.config.host):\(self.config.port)")
    }

    private func markBindFailed() {
        bindFailed = true
    }

    /// Wait until the server has confirmed it bound the port (true) or failed /
    /// timed out (false). Polls the actor flags set by onServerRunning / the
    /// server task — never an HTTP probe, so a foreign process holding the port
    /// can't produce a false positive.
    public func waitUntilBound(timeoutSeconds: Double = 5.0) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeoutSeconds))
        while ContinuousClock.now < deadline {
            if didBind { return true }
            if bindFailed || serverTask == nil { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return didBind
    }

    /// Stop the server.
    public func stop() {
        serverTask?.cancel()
        serverTask = nil
    }

    /// Test helper: wait for the Hummingbird service task to finish after
    /// cancellation so socket-level tests don't leak listeners across cases.
    func stopAndWait() async {
        let task = serverTask
        serverTask = nil
        task?.cancel()
        _ = await task?.value
        for cached in schedulers.values {
            await cached.scheduler.unloadModel()
        }
        schedulers.removeAll()
        schedulerReservations.removeAll()
    }

    func debugCapacity(modelId: String) async -> SchedulerCapacity? {
        guard let cached = schedulers[modelId] else { return nil }
        return await cached.scheduler.capacity()
    }

    func debugSchedulerReservationCount(modelId: String) -> Int {
        schedulerReservations[modelId] ?? 0
    }

    /// Returns the port the server is configured on.
    public var port: UInt16 {
        config.port
    }

    // MARK: - Registry snapshot consumed by MultiModelBatchSchedulerEngine

    fileprivate func snapshotRegistry() -> [String: MultiModelBatchSchedulerEngine.ModelRegistryEntry] {
        var registry: [String: MultiModelBatchSchedulerEngine.ModelRegistryEntry] = [:]
        for (modelId, cached) in schedulers {
            if evictingModels.contains(modelId) { continue }
            registry[modelId] = .init(
                scheduler: cached.scheduler,
                tokenizer: cached.tokenizer
            )
        }
        return registry
    }

    // MARK: - Model lifecycle (LRU + memory headroom + reservation)

    private func loadModel(_ modelId: String, container: MLXLMCommon.ModelContainer) async {
        let scheduler = BatchScheduler(
            maxConcurrentRequests: Self.schedulerMaxConcurrent,
            pendingTimeout: Self.schedulerPendingTimeout,
            defaultMaxTokens: Self.schedulerDefaultMaxTokens,
            kvBudget: kvBudget
        )
        await scheduler.loadModel(container: container, modelId: modelId)
        let tokenizer: TokenizerHandle = await container.perform { ctx in
            TokenizerHandle(ctx.tokenizer)
        }
        let modelType = models.first(where: { $0.id == modelId })?.modelType
        schedulers[modelId] = CachedScheduler(
            scheduler: scheduler,
            tokenizer: tokenizer,
            modelType: modelType,
            lastUsedAt: .now
        )
    }

    private func evictLRUIdleScheduler() async -> Bool {
        let snapshot = schedulers.map { (key: $0.key, cached: $0.value) }
        var lruKey: String?
        var lruTime: ContinuousClock.Instant?

        for entry in snapshot {
            guard schedulers[entry.key] != nil,
                  !evictingModels.contains(entry.key),
                  (schedulerReservations[entry.key] ?? 0) == 0 else { continue }

            let cap = await entry.cached.scheduler.capacity()
            guard schedulers[entry.key] != nil,
                  !evictingModels.contains(entry.key),
                  (schedulerReservations[entry.key] ?? 0) == 0,
                  cap.activeRequests == 0,
                  cap.pendingRequests == 0 else { continue }

            if lruTime == nil || entry.cached.lastUsedAt < lruTime! {
                lruKey = entry.key
                lruTime = entry.cached.lastUsedAt
            }
        }

        guard let evictKey = lruKey,
              let evicted = schedulers[evictKey],
              !evictingModels.contains(evictKey),
              (schedulerReservations[evictKey] ?? 0) == 0 else {
            return false
        }

        let cap = await evicted.scheduler.capacity()
        guard schedulers[evictKey] != nil,
              !evictingModels.contains(evictKey),
              (schedulerReservations[evictKey] ?? 0) == 0,
              cap.activeRequests == 0,
              cap.pendingRequests == 0 else {
            return false
        }

        evictingModels.insert(evictKey)
        defer { evictingModels.remove(evictKey) }
        await evicted.scheduler.unloadModel()
        if schedulers[evictKey]?.scheduler === evicted.scheduler {
            schedulers.removeValue(forKey: evictKey)
        }
        standaloneLogger.info("Evicted LRU model: \(evictKey)")
        return true
    }

    private func evictIfNeededForLoad() async throws {
        guard schedulers.count >= config.maxCachedModels else { return }

        guard await evictLRUIdleScheduler() else {
            throw StandaloneServerError.capacityUnavailable(
                "All \(config.maxCachedModels) cached model slot(s) are active; try again when a request finishes"
            )
        }
    }

    private func ensureMemoryHeadroomForLoad(requiredGb: Double) async throws {
        guard requiredGb.isFinite, requiredGb > 0 else { return }

        while await availableMemoryGb() < requiredGb {
            guard await evictLRUIdleScheduler() else {
                throw StandaloneServerError.capacityUnavailable(
                    String(format: "Insufficient memory headroom to load model (needs %.1f GB available)", requiredGb)
                )
            }
        }
    }

    /// Free memory (GB) for loading a model, via the shared OOM-safe arithmetic:
    /// clamped to real OS-available memory (`SystemMemory`) and minus any KV
    /// already promised to in-flight requests (`kvBudget`). See
    /// `ModelLoadAdmission` for the rationale.
    private func availableMemoryGb() async -> Double {
        let outstanding = await kvBudget.outstandingReservedBytes()
        return ModelLoadAdmission.freeForLoadGb(
            totalBytes: ProcessInfo.processInfo.physicalMemory,
            systemAvailableBytes: SystemMemory.availableBytes() ?? .max,
            gpuActiveBytes: UInt64(max(0, MLX.GPU.activeMemory)),
            gpuCacheBytes: UInt64(max(0, MLX.GPU.cacheMemory)),
            reserveBytes: 0,
            outstandingReservationBytes: outstanding)
    }

    /// Touch the cached scheduler's last-used timestamp on access.
    private func touchScheduler(_ modelId: String) {
        schedulers[modelId]?.lastUsedAt = .now
    }

    func reserveScheduler(_ modelId: String) {
        schedulerReservations[modelId, default: 0] += 1
        touchScheduler(modelId)
    }

    func releaseScheduler(_ modelId: String) {
        guard let count = schedulerReservations[modelId] else { return }
        if count <= 1 {
            schedulerReservations.removeValue(forKey: modelId)
        } else {
            schedulerReservations[modelId] = count - 1
        }
        touchScheduler(modelId)
    }

    /// I1: atomic `ensureLoaded + lookup + reserve`. All three steps
    /// happen inside this single actor-isolated method so a concurrent
    /// eviction cannot select the just-loaded model between
    /// `ensureModelLoaded` returning and the reservation being
    /// recorded. The returned `AcquiredModel` carries a one-shot
    /// release token; the caller (the engine's streaming task) MUST
    /// fire it exactly once when the request completes.
    ///
    /// Note: `ensureModelLoaded` can suspend and re-enter the actor
    /// (it awaits `loadContainer` etc.), so between an `await` and
    /// resumption another inflight method *could* call
    /// `evictLRUIdleScheduler`. The reservation guard inside the
    /// evictor (`schedulerReservations[key] == 0`) is what makes this
    /// safe once we've bumped the count. We therefore lookup the
    /// scheduler *after* taking the reservation, then drop the
    /// reservation if the lookup somehow fails so a partial-acquire
    /// doesn't pin a missing model forever.
    func acquireModel(_ modelId: String) async throws -> MultiModelBatchSchedulerEngine.AcquiredModel {
        do {
            try await ensureModelLoaded(modelId)
        } catch StandaloneServerError.modelNotFound {
            // Unknown model id → 404 via mapInferenceErrorToStatus.
            // StandaloneServerError is fileprivate so CORSResponder
            // can't catch it; translate to the typed engine error.
            throw MultiModelBatchSchedulerEngineError.modelNotLoaded(modelId)
        } catch StandaloneServerError.capacityUnavailable {
            // Cache full / memory-headroom failure → 503 via
            // mapInferenceErrorToStatus (`.queueFull` maps to 503
            // already, which signals "transient, retry with backoff").
            throw MultiModelBatchSchedulerEngineError.queueFull(
                "standalone capacity unavailable for \(modelId)"
            )
        }
        reserveScheduler(modelId)
        guard let cached = schedulers[modelId], !evictingModels.contains(modelId) else {
            // Roll the reservation back; the model is gone (evicted
            // mid-load) and we cannot honor the acquisition.
            releaseScheduler(modelId)
            throw MultiModelBatchSchedulerEngineError.modelNotLoaded(modelId)
        }
        let releaseClosure: @Sendable (String) async -> Void = { [weak self] mid in
            await self?.releaseScheduler(mid)
        }
        let token = OneShotRelease(
            release: releaseClosure,
            modelId: modelId
        )
        return MultiModelBatchSchedulerEngine.AcquiredModel(
            scheduler: cached.scheduler,
            tokenizer: cached.tokenizer,
            releaseToken: token,
            modelType: cached.modelType
        )
    }

    /// Resolve a tokenizer for the OpenAI token-utility endpoints
    /// (`/tokenize`, `/detokenize`, `/apply-template`). Unlike
    /// `acquireModel`, this does NOT bump a reservation: tokenizer
    /// access is read-only and finishes synchronously inside the
    /// upstream handler, so eviction races are not a concern.
    func resolveTokenizer(_ modelId: String?) async throws -> TokenizerHandle {
        if let modelId, let cached = schedulers[modelId] {
            return cached.tokenizer
        }
        if let modelId, schedulers[modelId] == nil {
            throw MultiModelBatchSchedulerEngineError.modelNotLoaded(modelId)
        }
        if let firstKey = schedulers.keys.sorted().first,
           let cached = schedulers[firstKey]
        {
            return cached.tokenizer
        }
        throw MultiModelBatchSchedulerEngineError.noModelLoadedForTokenization
    }

    /// Sorted list of currently-resident model ids. Retained as an
    /// internal capacity-introspection helper for tests and any future
    /// "what is warm right now" surface — it is NOT what `/v1/models`
    /// returns (P2 #3): the discovery endpoint reports the advertised
    /// catalog via `advertisedModelIds()`.
    func loadedModelIds() -> [String] {
        schedulers.keys.filter { !evictingModels.contains($0) }.sorted()
    }

    /// Sorted list of model ids the provider advertises in
    /// `/v1/models`. This is the catalog the operator configured the
    /// provider to serve (passed at init or via ``setModels(_:)``),
    /// not the currently-loaded subset.
    ///
    /// P2 #3: `/v1/models` is a discovery endpoint — clients hit it
    /// before their first request to pick a valid model id. An empty
    /// list at cold start (when no model is resident) would make them
    /// give up. The pre-MLXLMServer implementation returned the
    /// catalog here; this method restores that behaviour.
    func advertisedModelIds() -> [String] {
        models.map { $0.id }.sorted()
    }

    /// Lazy-load a model if it isn't already resident. Serializes loads and
    /// applies LRU + memory-headroom eviction. Identical contract to the
    /// pre-MLXLMServer implementation.
    func ensureModelLoaded(_ modelId: String) async throws {
        try Task.checkCancellation()
        if schedulers[modelId] != nil, !evictingModels.contains(modelId) {
            touchScheduler(modelId)
            return
        }

        if modelsLoading.contains(modelId) {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
                loadingWaiters[modelId, default: []].append(cont)
            }
            try Task.checkCancellation()
            if schedulers[modelId] != nil, !evictingModels.contains(modelId) {
                touchScheduler(modelId)
                return
            }
            try await ensureModelLoaded(modelId)
            return
        }

        guard let modelInfo = models.first(where: { $0.id == modelId }) else {
            throw StandaloneServerError.modelNotFound(modelId)
        }

        guard let modelPath = ModelScanner.resolveLocalPath(modelID: modelId) else {
            throw StandaloneServerError.modelNotFound(modelId)
        }

        // Serialize loads so concurrent requests for different models don't
        // interleave and overcommit unified memory.
        while isLoadingAny {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                loadGateWaiters.append(cont)
            }
            try Task.checkCancellation()
            if schedulers[modelId] != nil, !evictingModels.contains(modelId) {
                touchScheduler(modelId)
                return
            }
        }
        isLoadingAny = true

        modelsLoading.insert(modelId)
        do {
            try Task.checkCancellation()
            try await evictIfNeededForLoad()
            try await ensureMemoryHeadroomForLoad(
                requiredGb: ModelLoadAdmission.requiredToLoadGb(
                    weightsGb: modelInfo.estimatedMemoryGb,
                    headroomGb: ModelLoadAdmission.defaultLoadHeadroomGb)
            )
            try Task.checkCancellation()
            let container = try await LLMModelFactory.shared.loadContainer(
                from: modelPath,
                using: LocalTokenizerLoader()
            )
            try Task.checkCancellation()
            await loadModel(modelId, container: container)
            if Task.isCancelled, let cached = schedulers.removeValue(forKey: modelId) {
                await cached.scheduler.unloadModel()
                throw CancellationError()
            }
            standaloneLogger.info("Lazy-loaded model: \(modelId)")

            modelsLoading.remove(modelId)
            isLoadingAny = false
            for waiter in loadingWaiters.removeValue(forKey: modelId) ?? [] {
                waiter.resume()
            }
            releaseLoadGateWaiters()
        } catch {
            modelsLoading.remove(modelId)
            isLoadingAny = false
            for waiter in loadingWaiters.removeValue(forKey: modelId) ?? [] {
                waiter.resume(throwing: error)
            }
            releaseLoadGateWaiters()
            throw error
        }
    }

    private func releaseLoadGateWaiters() {
        let waiters = loadGateWaiters
        loadGateWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

