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
///   * v2 slot construction (v0.7.5 ONE ENGINE): the SAME sizing snapshot →
///     KV re-slice → `EngineV2SlotFactory.makeProductionBridge` path the
///     `ProviderLoop` uses, against this server's own shared
///     `GlobalKVCacheBudget`. There is no legacy `BatchScheduler` here
///     anymore; a model whose family has no CBv2 adapter is dropped from
///     the catalog at construction (fail loud, mirrored CLI-side in
///     `darkbloom start --local`).
///
/// HTTP wiring (Hummingbird application builder + `CORSResponder` +
/// OpenAI-shaped error envelope) lives in
/// ``StandaloneServer+HTTP.swift`` so this file can focus on the
/// model lifecycle.
///
/// Endpoints served by the upstream router include `/health`, `/v1/models`,
/// `/v1/chat/completions`, `/v1/completions`, `/v1/responses*`, `/tokenize`,
/// `/detokenize`, `/apply-template`, plus `/metrics` and `/props`.
///
/// KV-grant serialization note: unlike the `ProviderLoop` (whose idle
/// monitor unloads from an independent task and therefore needs the
/// re-slice gate), EVERY grant mutation here — load-side shrink/build and
/// evict-side regrow — happens inside the `isLoadingAny` critical section
/// (eviction only runs from the load path), so the load gate itself is the
/// re-slice serialization and `Σ(grants) ≤ fleet budget` holds throughout.

import Darwin
import Foundation
import Hummingbird
import MLX
import MLXLMCommon
import MLXLMServer
import os

enum StandaloneServerError: Error, LocalizedError {
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
    /// Operator `kv_quant` intent. The v2 engine is fp16-only, so this now
    /// only drives the one-per-load WARN telemetry (config key retires in
    /// the v0.7.5 env/config cleanup).
    public let kvQuant: Bool
    /// Detected local hardware. Was the adaptive-prefill ladder seed;
    /// retained for CLI compatibility, currently unused on the v2 path.
    public let hardware: HardwareInfo?
    /// Box-wide concurrent-decode cap per v2 engine
    /// (`[backend] engine_v2_max_concurrent`), clamped to [1, 8].
    public let engineV2MaxConcurrent: UInt64
    /// Per-model overrides (`engine_v2_max_concurrent_by_model`).
    public let engineV2MaxConcurrentByModel: [String: UInt64]
    /// CBv2 KV-backend selection (`[backend] engine_v2_kv_backend`):
    /// "auto" | "paged" | "contiguous". See `EngineV2KVBackendPolicy`.
    public let engineV2KVBackend: String
    /// Per-model overrides (`engine_v2_kv_backend_by_model`).
    public let engineV2KVBackendByModel: [String: String]
    /// MTP beta configuration. Defaults off; the CLI/config owner passes these
    /// through when standalone MTP is intentionally enabled.
    public let mtp: Bool
    public let mtpDrafterPath: String?

    public init(
        port: UInt16 = 8000,
        host: String = "127.0.0.1",
        maxCachedModels: Int = 3,
        authToken: String? = nil,
        kvQuant: Bool = false,
        hardware: HardwareInfo? = nil,
        engineV2MaxConcurrent: UInt64 = 4,
        engineV2MaxConcurrentByModel: [String: UInt64] = [:],
        engineV2KVBackend: String = "auto",
        engineV2KVBackendByModel: [String: String] = [:],
        mtp: Bool = false,
        mtpDrafterPath: String? = nil
    ) {
        self.port = port
        self.host = host
        self.maxCachedModels = max(1, maxCachedModels)
        self.authToken = authToken
        self.kvQuant = kvQuant
        self.hardware = hardware
        self.engineV2MaxConcurrent = engineV2MaxConcurrent
        self.engineV2MaxConcurrentByModel = engineV2MaxConcurrentByModel
        self.engineV2KVBackend = engineV2KVBackend
        self.engineV2KVBackendByModel = engineV2KVBackendByModel
        self.mtp = mtp
        self.mtpDrafterPath = mtpDrafterPath
    }
}

private let standaloneLogger = Logger(
    subsystem: "dev.darkbloom.provider",
    category: "StandaloneServer"
)

public actor StandaloneServer {

    /// One resident model: its v2 bridge, loaded container (the VLM owns both
    /// vision and the exact text tower served by the bridge), and KV sizing
    /// facts. Mirrors `ProviderLoop.ModelSlot`.
    struct CachedSlot {
        let bundle: ProviderEngineBundle
        var bridge: EngineV2Bridge { bundle.bridge }
        let container: MLXLMCommon.ModelContainer
        let tokenizer: TokenizerHandle
        let modelType: String?
        let isVLM: Bool
        let sizing: SlotSizingSnapshot
        var lastUsedAt: ContinuousClock.Instant

        init(
            bundle: ProviderEngineBundle,
            container: MLXLMCommon.ModelContainer,
            tokenizer: TokenizerHandle,
            modelType: String?,
            isVLM: Bool,
            sizing: SlotSizingSnapshot,
            lastUsedAt: ContinuousClock.Instant
        ) {
            self.bundle = bundle
            self.container = container
            self.tokenizer = tokenizer
            self.modelType = modelType
            self.isVLM = isVLM
            self.sizing = sizing
            self.lastUsedAt = lastUsedAt
        }

        init(
            bridge: EngineV2Bridge,
            container: MLXLMCommon.ModelContainer,
            tokenizer: TokenizerHandle,
            modelType: String?,
            isVLM: Bool,
            sizing: SlotSizingSnapshot,
            lastUsedAt: ContinuousClock.Instant
        ) {
            self.init(
                bundle: ProviderEngineBundle(targetOnly: bridge),
                container: container,
                tokenizer: tokenizer,
                modelType: modelType,
                isVLM: isVLM,
                sizing: sizing,
                lastUsedAt: lastUsedAt)
        }
    }

    /// Test hooks: scripted engine builder + deterministic machine memory
    /// for the re-slice budget + injectable telemetry sink. Mirrors
    /// `ProviderLoop.EngineV2SlotHooks`; nil in production.
    struct V2TestHooks: Sendable {
        let physicalMemoryBytes: UInt64?
        let emitTelemetry: (@Sendable (TelemetryEvent) -> Void)?
        let beforeWeightLoad: (@Sendable (String) async throws -> Void)?
        let assistantLoader: (any ProviderMTPAssistantLoading)?
        let computeWeightHash: (@Sendable (URL, String) -> String?)?
        let onCacheEligibleWeightHash: (@Sendable (String?) -> Void)?
        let clearMemoryCache: (@Sendable () -> Void)?
        let makeEngine: @Sendable (String, Int) throws -> any CBv2Engine

        init(
            physicalMemoryBytes: UInt64? = nil,
            emitTelemetry: (@Sendable (TelemetryEvent) -> Void)? = nil,
            beforeWeightLoad: (@Sendable (String) async throws -> Void)? = nil,
            assistantLoader: (any ProviderMTPAssistantLoading)? = nil,
            computeWeightHash: (@Sendable (URL, String) -> String?)? = nil,
            onCacheEligibleWeightHash: (@Sendable (String?) -> Void)? = nil,
            clearMemoryCache: (@Sendable () -> Void)? = nil,
            makeEngine: @escaping @Sendable (String, Int) throws -> any CBv2Engine
        ) {
            self.physicalMemoryBytes = physicalMemoryBytes
            self.emitTelemetry = emitTelemetry
            self.beforeWeightLoad = beforeWeightLoad
            self.assistantLoader = assistantLoader
            self.computeWeightHash = computeWeightHash
            self.onCacheEligibleWeightHash = onCacheEligibleWeightHash
            self.clearMemoryCache = clearMemoryCache
            self.makeEngine = makeEngine
        }
    }

    /// Internal access so the +HTTP extension can read host/port
    /// when constructing the Hummingbird application.
    let config: StandaloneServerConfig
    private var slots: [String: CachedSlot] = [:]
    private var modelsLoading: Set<String> = []
    private var loadingWaiters: [String: [CheckedContinuation<Void, any Error>]] = [:]
    private var isLoadingAny: Bool = false
    private var loadGateWaiters: [CheckedContinuation<Void, Never>] = []
    private var slotReservations: [String: Int] = [:]
    private var evictingModels: Set<String> = []
    private var models: [ModelInfo]
    private var serverTask: Task<Void, Never>?
    private var shutdownTask: Task<Void, Never>?
    private enum LifecycleState {
        case stopped
        case running
        case stopping
    }
    private var lifecycleState: LifecycleState = .stopped
    private let kvBudget: GlobalKVCacheBudget
    var specDecFunnel: SpecDecArtifactFunnel
    /// Phase 3: global disk accountant (process-wide, shared across models).
    /// Kept on the v2 path for its crash-sweep of stale on-disk KV from
    /// older (legacy-engine) versions; the v2 engine itself never persists.
    /// Test hooks (see `V2TestHooks`); nil in production.
    var v2TestHooks: V2TestHooks?
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
        // Architecture-derived supported set (v0.7.5 fail-loud): the v2
        // engine is the ONLY engine, so a model whose family has no CBv2
        // adapter can never serve — advertising it would invite requests
        // that always fail. Mirrors `ProviderLoop.init`; the CLI
        // (`darkbloom start --local`) applies the same filter with an
        // operator-facing error and refuses to start when nothing remains.
        self.models = Self.filterSupported(models)
        self.kvBudget = GlobalKVCacheBudget()
        self.specDecFunnel = SpecDecArtifactFunnel(
            resolver: SpecDecResolver(),
            catalog: nil)
        // Sweep only the retired checkpoint tier's `darkbloom/kv` directory.
        // EngineV2 SSD data lives under the separate `darkbloom/kv3` root.
        LegacyKVCacheSweeper.sweep()
        // Pin the MLX memory ceiling before any model weights load on this path
        // (the coordinator path does this in ProviderLoop.startMemoryProtection).
        MLXMemoryGuard.configureOnce()
    }

    /// Drop models without a CBv2 adapter from the served catalog, with a
    /// WARN naming each so the operator sees why a model on disk is absent
    /// from `/v1/models`.
    private static func filterSupported(_ models: [ModelInfo]) -> [ModelInfo] {
        let (supported, unsupported) = EngineV2SupportedModels.partition(models)
        if !unsupported.isEmpty {
            let ids = unsupported.map(\.id).sorted().joined(separator: ", ")
            standaloneLogger.warning(
                "Not serving \(unsupported.count) model(s) without a CBv2 adapter (v0.7.5 serves everything through engine v2): \(ids)")
        }
        return supported
    }

    /// Internal access so the +HTTP extension can pass the same
    /// default through to ``MultiModelBatchSchedulerEngine``.
    static let slotDefaultMaxTokens = 4096

    /// Map an engine-side admission error message to an HTTP status. Used
    /// by tests and by any custom error-mapping middleware. The keyword set
    /// matches the canonical `token_budget_exhausted:` message contract the
    /// v2 bridge preserves from the legacy scheduler.
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

    /// Update the advertised model list (e.g. after a rescan). Applies the
    /// same CBv2 supported-set filter as init.
    public func setModels(_ newModels: [ModelInfo]) {
        self.models = Self.filterSupported(newModels)
    }

    /// Start listening for HTTP connections. The server runs in a child task.
    public func start() throws {
        guard lifecycleState == .stopped else { return }

        didBind = false
        bindFailed = false
        let app = makeApplication()
        serverTask = Task {
            do {
                try await app.runService(gracefulShutdownSignals: [])
            } catch is CancellationError {
                standaloneLogger.info("Standalone server cancelled")
            } catch {
                standaloneLogger.error("Standalone server failed to bind \(self.config.host):\(self.config.port): \(error.localizedDescription)")
                self.markBindFailed()
            }
        }
        lifecycleState = .running
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
            try? await taskSleep( .milliseconds(50))
        }
        return didBind
    }

    /// Wait for the Hummingbird service task to exit. Local mode uses this as
    /// its serving lifetime so optional fan control ends only after the HTTP
    /// listener and every resident engine/cache resource have shut down.
    public func waitUntilStopped() async {
        switch lifecycleState {
        case .stopped:
            return
        case .stopping:
            _ = await shutdownTask?.value
        case .running:
            // A bind failure or other natural service exit must use the same
            // teardown path as an explicit stop.
            _ = await serverTask?.value
            await stop()
        }
    }

    /// Stop the server and fully release resident serving resources. Concurrent
    /// callers and `waitUntilStopped()` join one teardown task.
    public func stop() async {
        switch lifecycleState {
        case .stopped:
            return
        case .stopping:
            _ = await shutdownTask?.value
            return
        case .running:
            break
        }

        let serviceTask = serverTask
        lifecycleState = .stopping
        let task = Task {
            await finishShutdown(serviceTask: serviceTask)
        }
        shutdownTask = task
        await task.value
    }

    /// Test helper retained for existing lifecycle tests.
    func stopAndWait() async {
        await stop()
    }

    private func finishShutdown(serviceTask: Task<Void, Never>?) async {
        serviceTask?.cancel()
        _ = await serviceTask?.value
        await specDecFunnel.shutdown()

        // Retain only the bridges needed for their asynchronous drain. Keeping a
        // CachedSlot snapshot here would keep every model container alive until
        // after clearCache and leave its subsequently-freed buffers pooled.
        var residentBridges = slots.values.map(\.bridge)
        for bridge in residentBridges {
            await bridge.shutdown()
        }
        residentBridges.removeAll()

        // Match ProviderLoop.unloadModel: drain first, then release every slot
        // and its model container, and only then clear MLX's allocator cache.
        slots.removeAll()
        slotReservations.removeAll()
        if let clearMemoryCache = v2TestHooks?.clearMemoryCache {
            clearMemoryCache()
        } else {
            MLX.Memory.clearCache()
        }
        serverTask = nil
        didBind = false
        bindFailed = false
        lifecycleState = .stopped
        shutdownTask = nil
    }

    // MARK: - Test/debug surface

    /// Bridge-level active request count for a resident model (admitted +
    /// engine-waiting), or nil when not resident. Live tests use this to
    /// observe stream lifecycle without reaching into the engine.
    func debugActiveRequestCount(modelId: String) async -> Int? {
        guard let slot = slots[modelId] else { return nil }
        return await slot.bridge.activeRequestCount()
    }

    func debugSlotReservationCount(modelId: String) -> Int {
        slotReservations[modelId] ?? 0
    }

    func debugOutstandingKVReservationBytes() async -> UInt64 {
        await kvBudget.outstandingReservedBytes()
    }

    func reservePendingLoadForTesting(requestID: String, bytes: UInt64) async {
        await kvBudget.reservePendingLoad(requestID: requestID, bytes: bytes)
    }

    /// The resident slot's engine KV grant in bytes (re-slice assertions).
    func debugEngineKVGrant(modelId: String) async -> Int? {
        guard let slot = slots[modelId] else { return nil }
        return await slot.bridge.engineKVBytesCapacity()
    }

    /// Install test hooks (scripted engine + deterministic memory).
    /// Test seam: swap the spec-dec funnel so lifecycle tests can gate the
    /// MTP preparation await deterministically.
    func setSpecDecFunnelForTesting(_ funnel: SpecDecArtifactFunnel) {
        specDecFunnel = funnel
    }

    func setV2TestHooksForTesting(_ hooks: V2TestHooks?) {
        v2TestHooks = hooks
    }

    /// Install a fully-formed slot, bypassing the load path (unit tests).
    func installSlotForTesting(
        modelId: String,
        bridge: EngineV2Bridge,
        container: MLXLMCommon.ModelContainer,
        tokenizer: TokenizerHandle,
        sizing: SlotSizingSnapshot,
        modelType: String? = nil,
        isVLM: Bool = false
    ) {
        slots[modelId] = CachedSlot(
            bridge: bridge,
            container: container,
            tokenizer: tokenizer,
            modelType: modelType,
            isVLM: isVLM,
            sizing: sizing,
            lastUsedAt: .now
        )
    }

    /// Drive the real load-time re-slice + bridge build (unit tests: real
    /// orchestration, scripted engine via `setV2TestHooksForTesting`).
    func buildSlotForTesting(
        modelId: String,
        modelType: String?,
        container: MLXLMCommon.ModelContainer,
        tokenizer: TokenizerHandle,
        sizing: SlotSizingSnapshot,
        isVLM: Bool = false,
        cacheEligibleWeightHash: String? = nil
    ) async throws -> EngineV2Bridge {
        // Convenience shape: box the container the way loadModel does (the
        // caller also holds its own reference, so unwind-ordering assertions
        // use the box variant below instead).
        let newcomer = EngineV2NewcomerBox(container)
        let bridge = try await resliceAndBuildSlot(
            modelId: modelId,
            modelType: modelType,
            isVLM: isVLM,
            modelDirectory: nil,
            newcomer: newcomer,
            tokenizer: tokenizer,
            sizing: sizing,
            cacheEligibleWeightHash: cacheEligibleWeightHash)
        guard let installContainer = newcomer.container else {
            throw StandaloneServerError.capacityUnavailable(
                "internal: newcomer container missing at install for '\(modelId)'")
        }
        slots[modelId] = CachedSlot(
            bridge: bridge,
            container: installContainer,
            tokenizer: tokenizer,
            modelType: modelType,
            isVLM: isVLM,
            sizing: sizing,
            lastUsedAt: .now)
        return bridge
    }

    /// Box variant: the caller hands over container OWNERSHIP, so the
    /// unwind-ordering regression test can observe (via a weak reference)
    /// that a failed build releases the newcomer's weights BEFORE survivor
    /// grants are restored.
    func resliceAndBuildSlotForTesting(
        modelId: String,
        modelType: String?,
        isVLM: Bool = false,
        modelDirectory: URL? = nil,
        newcomer: EngineV2NewcomerBox,
        tokenizer: TokenizerHandle,
        sizing: SlotSizingSnapshot,
        cacheEligibleWeightHash: String? = nil
    ) async throws -> EngineV2Bridge {
        try await resliceAndBuildSlot(
            modelId: modelId,
            modelType: modelType,
            isVLM: isVLM,
            modelDirectory: modelDirectory,
            newcomer: newcomer,
            tokenizer: tokenizer,
            sizing: sizing,
            cacheEligibleWeightHash: cacheEligibleWeightHash)
    }

    /// MTP-aware variant of the standalone re-slice seam. It drives the same
    /// assistant load, floor fallback, sizing, and engine construction as a
    /// real local load without publishing the resulting slot.
    func resliceAndBuildMTPBundleForTesting(
        modelId: String,
        modelType: String?,
        newcomer: EngineV2NewcomerBox,
        tokenizer: TokenizerHandle,
        sizing: SlotSizingSnapshot,
        specDecPreparation: SpecDecPreparation
    ) async throws -> (bundle: ProviderEngineBundle, sizing: SlotSizingSnapshot) {
        let build = try await resliceAndBuildBundle(
            modelId: modelId,
            modelType: modelType,
            isVLM: false,
            modelDirectory: nil,
            newcomer: newcomer,
            tokenizer: tokenizer,
            targetSizing: sizing,
            specDecPreparation: specDecPreparation)
        return (build.bundle, build.sizing)
    }

    /// Test seam: the post-bridge-guard failure unwind (retire bridge →
    /// release newcomer weights → regrow survivors, in that order).
    func unwindBuiltSlotAndRegrowForTesting(
        bridge: EngineV2Bridge, newcomer: EngineV2NewcomerBox
    ) async {
        await unwindBuiltSlotAndRegrow(bridge: bridge, newcomer: newcomer)
    }

    /// Drive one LRU idle-eviction pass (unit tests).
    func evictLRUIdleSlotForTesting() async -> Bool {
        await evictLRUIdleSlot()
    }

    /// Returns the port the server is configured on.
    public var port: UInt16 {
        config.port
    }

    // MARK: - Model lifecycle (LRU + memory headroom + reservation)

    /// Effective concurrent-request cap for a v2 engine slot: the
    /// per-model override when configured, else the box-wide value,
    /// clamped to [1, 8] — same policy as `ProviderLoop`.
    private func engineV2MaxConcurrent(forModel modelId: String) -> Int {
        let raw = config.engineV2MaxConcurrentByModel[modelId]
            ?? config.engineV2MaxConcurrent
        return ProviderLoop.clampEngineV2Concurrency(raw)
    }

    /// Fleet KV budget for a prospective residency set: the unified-memory
    /// cap minus Σ resident weights (all slots + the newcomer's), with no
    /// operator reserve (standalone mode has none — the cap-implied reserve
    /// is what holds memory back, exactly as in `availableMemoryGb`).
    private func fleetKVBudgetBytes(extraWeightBytes: Int) -> UInt64 {
        var totalWeights = UInt64(max(0, extraWeightBytes))
        for (_, slot) in slots {
            let (sum, overflow) = totalWeights
                .addingReportingOverflow(UInt64(max(0, slot.sizing.weightsBytes)))
            totalWeights = overflow ? .max : sum
        }
        let physical = v2TestHooks?.physicalMemoryBytes
            ?? ProcessInfo.processInfo.physicalMemory
        return UnifiedMemoryCap.kvBudgetBytes(
            physicalBytes: physical,
            residentWeightBytes: totalWeights,
            configReserveBytes: 0)
    }

    /// One existing slot's re-slice bookkeeping (mirrors the ProviderLoop's
    /// `ExistingSlotGrant`): sizing inputs, the grant BEFORE this re-slice
    /// (the restore point), and the bridge whose ceiling gets updated.
    private struct ExistingSlotGrant {
        let slot: EngineV2KVSizing.ResliceSlot
        let previousGrant: Int
        let bridge: EngineV2Bridge
    }

    private struct SlotBuild {
        let bundle: ProviderEngineBundle
        let sizing: SlotSizingSnapshot
    }

    private func existingSlotGrants(excludingModelId: String) async -> [ExistingSlotGrant] {
        var existing: [ExistingSlotGrant] = []
        for (modelId, slot) in slots
        where modelId != excludingModelId && !evictingModels.contains(modelId) {
            // Exact logical admission target for rollback.
            // A paged slot's larger immutable physical claim is tracked by
            // slotKVBytesClaim(), but must not replace a previously-shrunk
            // logical restore point.
            let currentGrant = await slot.bridge.resliceAdmissionBytesClaim()
            existing.append(
                ExistingSlotGrant(
                    slot: EngineV2KVSizing.ResliceSlot(
                        modelId: modelId,
                        fp16KVBytesPerToken: slot.sizing.fp16KVBytesPerToken,
                        maxContextLength: slot.sizing.maxContextLength),
                    previousGrant: currentGrant,
                    bridge: slot.bridge))
        }
        return existing
    }

    /// Re-slice KV grants for the newcomer + existing slots, shrink existing
    /// engines, and build the newcomer's bridge — the same shrink-first /
    /// restore-on-throw / grow-after sequence as
    /// `ProviderLoop.resliceAndBuildEngineV2Slot`, over the shared pure
    /// policy (`EngineV2KVSizing.resliceGrants`). Unwind ordering MIRRORS the
    /// loop (Codex review): on a construction throw the failed newcomer's
    /// weights are dropped through the `EngineV2NewcomerBox` (release →
    /// `clearCache`) BEFORE survivor grants are restored. Even locally this
    /// matters — a request for an already-loaded model can re-enter the
    /// actor while this load holds `isLoadingAny`, and a survivor whose grant
    /// was restored while the failed weights were still resident would accept
    /// work against capacity that assumes those weights are already gone.
    /// Runs inside the `isLoadingAny` critical section (the standalone
    /// re-slice serialization). Returns the built bridge; the caller installs
    /// the `CachedSlot` only after its post-bridge headroom guard passes.
    private func resliceAndBuildSlot(
        modelId: String,
        modelType: String?,
        isVLM: Bool,
        modelDirectory: URL?,
        newcomer newcomerBox: EngineV2NewcomerBox,
        tokenizer: TokenizerHandle,
        sizing: SlotSizingSnapshot,
        cacheEligibleWeightHash: String? = nil
    ) async throws -> EngineV2Bridge {
        let build = try await resliceAndBuildBundle(
            modelId: modelId,
            modelType: modelType,
            isVLM: isVLM,
            modelDirectory: modelDirectory,
            newcomer: newcomerBox,
            tokenizer: tokenizer,
            targetSizing: sizing,
            specDecPreparation: SpecDecPreparation(
                artifact: nil,
                status: .disabled(.configDisabled, configured: false)),
            cacheEligibleWeightHash: cacheEligibleWeightHash)
        return build.bundle.bridge
    }

    private func resliceAndBuildBundle(
        modelId: String,
        modelType: String?,
        isVLM: Bool,
        modelDirectory: URL?,
        newcomer newcomerBox: EngineV2NewcomerBox,
        tokenizer: TokenizerHandle,
        targetSizing: SlotSizingSnapshot,
        specDecPreparation: SpecDecPreparation,
        cacheEligibleWeightHash: String? = nil
    ) async throws -> SlotBuild {
        var prepared: EngineV2PreparedModel
        do {
            prepared = try await EngineV2SlotFactory.prepareProductionModel(
                modelId: modelId,
                isVLM: isVLM,
                container: newcomerBox.borrow(),
                specDecPreparation: specDecPreparation,
                assistantLoader: v2TestHooks?.assistantLoader
                    ?? Gemma4ProviderMTPAssistantLoader(),
                emitTelemetry: v2TestHooks?.emitTelemetry,
                logInfo: { standaloneLogger.info("\($0)") },
                logWarning: { standaloneLogger.warning("\($0)") })
        } catch {
            newcomerBox.release()
            MLX.Memory.clearCache()
            throw error
        }
        // Prepare-stage fail-open: the drafter never became resident, so drop
        // its share of the pending-load reservation now instead of holding
        // phantom bytes through the re-slice and engine build (mirrors
        // ProviderLoop.resliceAndBuildEngineV2Bundle).
        if prepared.assistant == nil, specDecPreparation.artifact != nil {
            await kvBudget.replacePendingLoadReservation(
                requestID: "pending-load:\(modelId)", bytes: 0)
        }
        var sizing = targetSizing.replacingAuxiliaryWeightBytes(
            prepared.assistantBytes)
        let existing = await existingSlotGrants(excludingModelId: modelId)
        let newcomer = EngineV2KVSizing.ResliceSlot(
            modelId: modelId,
            fp16KVBytesPerToken: sizing.fp16KVBytesPerToken,
            maxContextLength: sizing.maxContextLength)
        var fleetBudget = fleetKVBudgetBytes(extraWeightBytes: sizing.weightsBytes)
        var targets = EngineV2KVSizing.resliceGrants(
            existing: existing.map(\.slot),
            newcomer: newcomer,
            fleetKVBudgetBytes: fleetBudget)

        // Serviceability floor (fail loud): refuse a load that would leave
        // any slot below the minimum serveable live-KV grant.
        if !EngineV2KVSizing.resliceMeetsServiceabilityFloor(
            targets, fixedCarveBytes: [:]), prepared.assistant != nil
        {
            standaloneLogger.warning(
                "mtp: model=\(modelId) fallback reason=\(MTPFallbackReason.assistantResliceFloor.rawValue); retrying target-only before refusing the load")
            prepared.assistant?.release()
            prepared = prepared.fallingBack(.assistantResliceFloor)
            sizing = targetSizing.replacingAuxiliaryWeightBytes(0)
            await kvBudget.replacePendingLoadReservation(
                requestID: "pending-load:\(modelId)", bytes: 0)
            MLX.Memory.clearCache()
            fleetBudget = fleetKVBudgetBytes(extraWeightBytes: sizing.weightsBytes)
            targets = EngineV2KVSizing.resliceGrants(
                existing: existing.map(\.slot),
                newcomer: newcomer,
                fleetKVBudgetBytes: fleetBudget)
        }
        guard EngineV2KVSizing.resliceMeetsServiceabilityFloor(
            targets, fixedCarveBytes: [:])
        else {
            let floorGb = String(
                format: "%.1f",
                Double(EngineV2KVSizing.minimumServiceableGrantBytes) / (1024 * 1024 * 1024))
            EngineV2Factory.emitRefusalTelemetry(
                modelId: modelId,
                reason: .resliceFloor,
                error: nil,
                emitTelemetry: v2TestHooks?.emitTelemetry)
            // Pre-shrink refusal: no grants were mutated, but drop the
            // newcomer's weights promptly (mirrors ProviderLoop) so live
            // residency reflects the refusal before the caller's error
            // handling runs.
            prepared.assistant?.release()
            newcomerBox.release()
            MLX.Memory.clearCache()
            throw StandaloneServerError.capacityUnavailable(
                "loading '\(modelId)' would re-slice some model's KV grant below "
                    + "the \(floorGb) GB serviceability floor "
                    + "(fleet KV budget \(fleetBudget) B across \(existing.count + 1) slots) — refused")
        }

        // Phase 1 — SHRINKS first, so Σ(ceilings) never exceeds the fleet
        // budget at any instant.
        for entry in existing {
            if let target = targets[entry.slot.modelId], target < entry.previousGrant {
                await entry.bridge.updateKVBytesCapacity(target)
            }
        }

        // Phase 2 — build the newcomer with its grant. Restore-on-throw:
        // grow every shrunk engine back to its exact previous grant.
        // `newcomer.borrow()` is evaluated inline (covered by the outer
        // `try`) so the container reference lives only for the duration of
        // the build call — by the time the catch runs, the box holds the
        // last strong reference and `release()` frees the weights.
        let bundle: ProviderEngineBundle
        do {
            v2TestHooks?.onCacheEligibleWeightHash?(cacheEligibleWeightHash)
            bundle = try await EngineV2SlotFactory.makeProductionBundle(
                modelId: modelId,
                modelType: modelType,
                isVLM: isVLM,
                modelDirectory: modelDirectory,
                container: newcomerBox.borrow(),
                tokenizer: tokenizer,
                sizing: sizing,
                kvBytesCapacity: targets[modelId] ?? 0,
                maxConcurrentRequests: engineV2MaxConcurrent(forModel: modelId),
                kvBudget: kvBudget,
                kvQuantConfigured: config.kvQuant,
                kvBackendConfig: config.engineV2KVBackend,
                kvBackendConfigByModel: config.engineV2KVBackendByModel,
                weightHash: cacheEligibleWeightHash,
                specDecPreparation: specDecPreparation,
                preparedModel: prepared,
                emitTelemetry: v2TestHooks?.emitTelemetry,
                makeEngineOverride: v2TestHooks?.makeEngine,
                logInfo: { standaloneLogger.info("\($0)") },
                logWarning: { standaloneLogger.warning("\($0)") })
        } catch {
            // Restore-on-throw in the Codex-review order: (1) release the
            // newcomer's weights, (2) clearCache so the pool returns their
            // buffers, (3) restore every shrunk engine to its previous grant.
            // Restoring before the weights are gone would let Σ(grants)
            // exceed the true fleet budget while the failed container was
            // still resident.
            prepared.assistant?.release()
            newcomerBox.release()
            MLX.Memory.clearCache()
            for entry in existing {
                await entry.bridge.updateKVBytesCapacity(entry.previousGrant)
            }
            throw error
        }

        // Phase 3 — grow-side targets (self-healing when a previous state
        // left a slot under-granted).
        for entry in existing {
            if let target = targets[entry.slot.modelId], target > entry.previousGrant {
                await entry.bridge.updateKVBytesCapacity(target)
            }
        }

        return SlotBuild(bundle: bundle, sizing: sizing)
    }

    /// Post-bridge-guard failure unwind (mirrors
    /// `ProviderLoop.unwindBuiltSlotAndRegrow`): retire the built bridge,
    /// RELEASE the aborted newcomer's weights, and only then regrow the
    /// survivors — in that order, so the regrow's fleet budget reflects true
    /// residency and Σ(grants) never exceeds it. Caller holds `isLoadingAny`.
    private func unwindBuiltSlotAndRegrow(
        bundle: ProviderEngineBundle, newcomer: EngineV2NewcomerBox
    ) async {
        await bundle.bridge.shutdown()
        bundle.releaseAssistant()
        newcomer.release()
        MLX.Memory.clearCache()
        await resliceGrowSurvivors()
    }

    private func unwindBuiltSlotAndRegrow(
        bridge: EngineV2Bridge, newcomer: EngineV2NewcomerBox
    ) async {
        await unwindBuiltSlotAndRegrow(
            bundle: ProviderEngineBundle(targetOnly: bridge), newcomer: newcomer)
    }

    /// Grow the surviving slots back to their re-sliced shares after an
    /// eviction (a lone survivor gets the FULL fleet budget back). Called
    /// from the eviction path, i.e. inside `isLoadingAny`.
    private func resliceGrowSurvivors() async {
        let survivors = await existingSlotGrants(excludingModelId: "")
        guard !survivors.isEmpty else { return }
        let fleetBudget = fleetKVBudgetBytes(extraWeightBytes: 0)
        let targets = EngineV2KVSizing.resliceGrants(
            existing: survivors.map(\.slot),
            newcomer: nil,
            fleetKVBudgetBytes: fleetBudget)
        for entry in survivors {
            if let target = targets[entry.slot.modelId], target < entry.previousGrant {
                await entry.bridge.updateKVBytesCapacity(target)
            }
        }
        for entry in survivors {
            if let target = targets[entry.slot.modelId], target > entry.previousGrant {
                await entry.bridge.updateKVBytesCapacity(target)
            }
        }
    }

    private func evictLRUIdleSlot() async -> Bool {
        let snapshot = slots.map { (key: $0.key, cached: $0.value) }
        var lruKey: String?
        var lruTime: ContinuousClock.Instant?

        for entry in snapshot {
            guard slots[entry.key] != nil,
                  !evictingModels.contains(entry.key),
                  (slotReservations[entry.key] ?? 0) == 0 else { continue }

            let active = await entry.cached.bridge.activeRequestCount()
            guard slots[entry.key] != nil,
                  !evictingModels.contains(entry.key),
                  (slotReservations[entry.key] ?? 0) == 0,
                  active == 0 else { continue }

            if lruTime == nil || entry.cached.lastUsedAt < lruTime! {
                lruKey = entry.key
                lruTime = entry.cached.lastUsedAt
            }
        }

        guard let evictKey = lruKey,
              let evicted = slots[evictKey],
              !evictingModels.contains(evictKey),
              (slotReservations[evictKey] ?? 0) == 0 else {
            return false
        }

        let active = await evicted.bridge.activeRequestCount()
        guard slots[evictKey]?.bridge === evicted.bridge,
              !evictingModels.contains(evictKey),
              (slotReservations[evictKey] ?? 0) == 0,
              active == 0 else {
            return false
        }

        evictingModels.insert(evictKey)
        defer { evictingModels.remove(evictKey) }
        // Drain the v2 bridge (running requests finish, new submissions are
        // rejected by the engine), then release the container reference.
        await evicted.bridge.shutdown()
        evicted.bundle.releaseAssistant()
        if slots[evictKey]?.bridge === evicted.bridge {
            slots.removeValue(forKey: evictKey)
        }
        // Mandatory: freed weights linger in MLX's pool (GPU.cacheMemory), which
        // availableMemoryGb / GlobalKVCacheBudget now count as used — without this
        // the next load's gate and the surviving model's KV budget don't see the
        // freed memory. Mirrors ProviderLoop.unloadModel.
        MLX.Memory.clearCache()
        // Re-slice GROW the survivors: with this model's weights gone the
        // fleet KV budget rises, and the remaining engines take their new
        // fair shares (a lone survivor gets the FULL budget back).
        await resliceGrowSurvivors()
        standaloneLogger.info("Evicted LRU model: \(evictKey)")
        return true
    }

    private func evictIfNeededForLoad() async throws {
        guard slots.count >= config.maxCachedModels else { return }

        guard await evictLRUIdleSlot() else {
            throw StandaloneServerError.capacityUnavailable(
                "All \(config.maxCachedModels) cached model slot(s) are active; try again when a request finishes"
            )
        }
    }

    private func ensureMemoryHeadroomForLoad(requiredGb: Double) async throws {
        guard requiredGb.isFinite, requiredGb > 0 else { return }

        while await availableMemoryGb() < requiredGb {
            guard await evictLRUIdleSlot() else {
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
        // Honor the 90% unified cap here too: with no configured reserve in
        // standalone mode, the cap-implied reserve (physical − cap) is what holds
        // memory back so a load can't push past the cap.
        let reserve = UnifiedMemoryCap.loadReserveBytes(configReserveBytes: 0)
        return ModelLoadAdmission.freeForLoadGb(
            totalBytes: ProcessInfo.processInfo.physicalMemory,
            systemAvailableBytes: SystemMemory.availableBytes() ?? .max,
            gpuActiveBytes: UInt64(max(0, MLX.GPU.activeMemory)),
            gpuCacheBytes: UInt64(max(0, MLX.GPU.cacheMemory)),
            reserveBytes: reserve,
            outstandingReservationBytes: outstanding)
    }

    /// Touch the cached slot's last-used timestamp on access.
    private func touchSlot(_ modelId: String) {
        slots[modelId]?.lastUsedAt = .now
    }

    func reserveSlot(_ modelId: String) {
        slotReservations[modelId, default: 0] += 1
        touchSlot(modelId)
    }

    func releaseSlot(_ modelId: String) {
        guard let count = slotReservations[modelId] else { return }
        if count <= 1 {
            slotReservations.removeValue(forKey: modelId)
        } else {
            slotReservations[modelId] = count - 1
        }
        touchSlot(modelId)
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
    /// `evictLRUIdleSlot`. The reservation guard inside the
    /// evictor (`slotReservations[key] == 0`) is what makes this
    /// safe once we've bumped the count. We therefore lookup the
    /// slot *after* taking the reservation, then drop the
    /// reservation if the lookup somehow fails so a partial-acquire
    /// doesn't pin a missing model forever.
    func acquireModel(_ modelId: String) async throws -> MultiModelBatchSchedulerEngine.AcquiredModel {
        do {
            try await ensureModelLoaded(modelId)
        } catch StandaloneServerError.modelNotFound {
            // Unknown model id → 404 via mapInferenceErrorToStatus.
            // StandaloneServerError never crosses the HTTP layer;
            // translate to the typed engine error.
            throw MultiModelBatchSchedulerEngineError.modelNotLoaded(modelId)
        } catch let StandaloneServerError.capacityUnavailable(message) {
            // Cache full / memory-headroom / re-slice-floor / engine
            // refusal → 503 via mapInferenceErrorToStatus
            // (`.tokenBudgetExhausted` maps to 503, signalling
            // "transient, retry with backoff" so local clients back off
            // exactly like coordinator ones).
            throw MultiModelBatchSchedulerEngineError.tokenBudgetExhausted(
                "token_budget_exhausted: \(message)"
            )
        }
        reserveSlot(modelId)
        guard let slot = slots[modelId], !evictingModels.contains(modelId) else {
            // Roll the reservation back; the model is gone (evicted
            // mid-load) and we cannot honor the acquisition.
            releaseSlot(modelId)
            throw MultiModelBatchSchedulerEngineError.modelNotLoaded(modelId)
        }
        let releaseClosure: @Sendable (String) async -> Void = { [weak self] mid in
            await self?.releaseSlot(mid)
        }
        let token = OneShotRelease(
            release: releaseClosure,
            modelId: modelId
        )
        // ONE ENGINE (v0.7.5): the entry carries the slot's v2 bridge — the
        // same serving path as ProviderLoop slots. No legacy scheduler is
        // constructed anywhere on this server.
        return MultiModelBatchSchedulerEngine.AcquiredModel(
            tokenizer: slot.tokenizer,
            releaseToken: token,
            modelType: slot.modelType,
            container: slot.container,
            isVLM: slot.isVLM,
            engineV2Bridge: slot.bridge,
            visionGate: VisionMemoryGate(
                kvBudget: kvBudget,
                fp16KVBytesPerToken: slot.sizing.fp16KVBytesPerToken,
                contextLength: slot.sizing.maxContextLength)
        )
    }

    /// Resolve a tokenizer for the OpenAI token-utility endpoints
    /// (`/tokenize`, `/detokenize`, `/apply-template`). Unlike
    /// `acquireModel`, this does NOT bump a reservation: tokenizer
    /// access is read-only and finishes synchronously inside the
    /// upstream handler, so eviction races are not a concern.
    func resolveTokenizer(_ modelId: String?) async throws -> TokenizerHandle {
        if let modelId, let slot = slots[modelId] {
            return slot.tokenizer
        }
        if let modelId, slots[modelId] == nil {
            throw MultiModelBatchSchedulerEngineError.modelNotLoaded(modelId)
        }
        if let firstKey = slots.keys.sorted().first,
           let slot = slots[firstKey]
        {
            return slot.tokenizer
        }
        throw MultiModelBatchSchedulerEngineError.noModelLoadedForTokenization
    }

    /// Sorted list of currently-resident model ids. Retained as an
    /// internal capacity-introspection helper for tests and any future
    /// "what is warm right now" surface — it is NOT what `/v1/models`
    /// returns (P2 #3): the discovery endpoint reports the advertised
    /// catalog via `advertisedModelIds()`.
    func loadedModelIds() -> [String] {
        slots.keys.filter { !evictingModels.contains($0) }.sorted()
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

    private func computeStandaloneWeightHash(
        modelPath: URL, modelId: String
    ) async -> String? {
        let override = v2TestHooks?.computeWeightHash
        return await Task.detached(priority: .utility) {
            let hash = override != nil
                ? override!(modelPath, modelId)
                : WeightHasher.computeHash(snapshotDir: modelPath, modelID: modelId)
            return SSDPrefixCacheFactory.verifiedWeightHash(hash)
        }.value
    }

    /// Lazy-load a model if it isn't already resident. Serializes loads and
    /// applies LRU + memory-headroom eviction, then builds the v2 slot
    /// through the shared sizing → re-slice → bridge path.
    func ensureModelLoaded(_ modelId: String) async throws {
        try Task.checkCancellation()
        if slots[modelId] != nil, !evictingModels.contains(modelId) {
            touchSlot(modelId)
            return
        }

        if modelsLoading.contains(modelId) {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
                loadingWaiters[modelId, default: []].append(cont)
            }
            try Task.checkCancellation()
            if slots[modelId] != nil, !evictingModels.contains(modelId) {
                touchSlot(modelId)
                return
            }
            try await ensureModelLoaded(modelId)
            return
        }

        guard let modelInfo = models.first(where: { $0.id == modelId }) else {
            throw StandaloneServerError.modelNotFound(modelId)
        }

        // Loud insurance behind the init/setModels filter: a model without
        // a CBv2 adapter must never reach engine construction (v0.7.5
        // fail-loud — there is no legacy engine to degrade onto).
        guard EngineV2SupportedModels.isSupported(modelType: modelInfo.modelType) else {
            standaloneLogger.error(
                "Model '\(modelId)' (model_type \(modelInfo.modelType ?? "unknown")) has no CBv2 adapter — refusing to load")
            throw StandaloneServerError.modelNotFound(modelId)
        }

        guard let modelPath = ModelScanner.resolveLocalPath(modelID: modelId) else {
            throw StandaloneServerError.modelNotFound(modelId)
        }
        var mtpPreparation = await specDecPreparation(
            modelId: modelId, modelInfo: modelInfo)

        // Re-check residency and in-flight loads after the preparation await:
        // a concurrent request for the same cold model can pass the checks
        // above, complete its ENTIRE load (returning `isLoadingAny` to false)
        // and install the slot while this task was suspended. Without this
        // recheck the continuation would skip the load gate's residency check
        // and start a second load of an already-resident model.
        if slots[modelId] != nil, !evictingModels.contains(modelId) {
            touchSlot(modelId)
            return
        }
        if modelsLoading.contains(modelId) {
            try await ensureModelLoaded(modelId)
            return
        }

        // Serialize loads so concurrent requests for different models don't
        // interleave and overcommit unified memory.
        while isLoadingAny {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                loadGateWaiters.append(cont)
            }
            try Task.checkCancellation()
            if slots[modelId] != nil, !evictingModels.contains(modelId) {
                touchSlot(modelId)
                return
            }
        }
        isLoadingAny = true

        let pendingLoadID = "pending-load:\(modelId)"
        modelsLoading.insert(modelId)
        do {
            try Task.checkCancellation()
            try await evictIfNeededForLoad()
            let targetRequiredGb = ModelLoadAdmission.requiredToLoadGb(
                    weightsGb: modelInfo.estimatedMemoryGb,
                    // Cap-aware: activation reserve + min serveable KV, so a model
                    // that loads can actually serve (matches the runtime KV gate).
                    headroomGb: Double(UnifiedMemoryCap.loadHeadroomBytes()) / (1024.0 * 1024.0 * 1024.0))
            try await ensureMemoryHeadroomForLoad(requiredGb: targetRequiredGb)
            if let artifact = mtpPreparation.artifact {
                if !ProviderLoop.assistantMemoryFits(
                    availableGb: await availableMemoryGb(),
                    targetRequiredGb: targetRequiredGb,
                    assistantBytes: artifact.residentBytes)
                {
                    mtpPreparation = mtpPreparation.fallingBack(
                        .assistantMemoryUnavailable)
                    standaloneLogger.warning(
                        "mtp: model=\(modelId) fallback reason=\(MTPFallbackReason.assistantMemoryUnavailable.rawValue) assistant_bytes=\(artifact.residentBytes)")
                }
            }
            let extraWeightBytes = mtpPreparation.artifact?.residentBytes ?? 0
            try Task.checkCancellation()

            // Keep incoming weights visible to the process-wide KV ledger while
            // loadContainer is suspended. Existing-model requests continue to
            // serve during this await and must not reserve the same headroom.
            let pendingLoadBytes = ProviderLoop.pendingLoadReservationBytes(
                estimatedWeightsGb: modelInfo.estimatedMemoryGb,
                extraWeightBytes: extraWeightBytes)
            await kvBudget.reservePendingLoad(
                requestID: pendingLoadID, bytes: pendingLoadBytes)

            try await v2TestHooks?.beforeWeightLoad?(modelId)
            let reusableSSDRequested = PrefixCachePolicy.isEnabled()
            let preLoadCacheHash = reusableSSDRequested
                ? await computeStandaloneWeightHash(modelPath: modelPath, modelId: modelId)
                : nil
            // Hard-fail without Metal: CPU inference is not acceptable, and
            // with no legacy engine left this is a load failure, not a log
            // line (mirrors ProviderLoop.ensureModelLoaded).
            _ = try GPUEnforcement.requireMetal()
            let slotIsVLM = ProviderLoop.modelIsVLM(at: modelPath)
            // Ownership box (Codex-review unwind ordering): every later
            // access to the loading container goes through this box so
            // failure paths can drop the LAST strong reference to the weights
            // BEFORE survivor grants are restored/regrown. Never bind
            // `borrow()` to a long-lived local — that would keep the weights
            // alive past `release()`.
            let newcomer = EngineV2NewcomerBox(
                try await ModelContainerLoading.loadContainer(from: modelPath))
            try Task.checkCancellation()
            let postLoadCacheHash = reusableSSDRequested
                ? await computeStandaloneWeightHash(modelPath: modelPath, modelId: modelId)
                : nil
            let cacheEligibleWeightHash: String?
            if reusableSSDRequested {
                switch ProviderLoop.reusableSSDWeightHashDecision(
                    preLoadHash: preLoadCacheHash,
                    postLoadHash: postLoadCacheHash
                ) {
                case .eligible(let bracketed):
                    cacheEligibleWeightHash = bracketed
                case .unavailable:
                    standaloneLogger.warning(
                        "Reusable SSD cache disabled for \(modelId) on this load — cryptographic weight hash unavailable")
                    cacheEligibleWeightHash = nil
                case .changed:
                    newcomer.release()
                    MLX.Memory.clearCache()
                    throw StandaloneServerError.capacityUnavailable(
                        "Model '\(modelId)' changed while loading reusable SSD cache state — unloaded")
                }
            } else {
                cacheEligibleWeightHash = nil
            }

            // Scheduler-free sizing snapshot: weight bytes + the engine-truth
            // fp16 KV rate + context window — everything the re-slice and
            // bridge need.
            let targetSizing = try await SlotSizingSnapshot.build(
                container: newcomer.borrow(),
                modelPath: modelPath,
                fallbackDefaultMaxTokens: Self.slotDefaultMaxTokens)
            // The loaded weights are now reflected in MLX memory, so transfer
            // accounting from the pending estimate to the live memory snapshot.
            await kvBudget.replacePendingLoadReservation(
                requestID: pendingLoadID, bytes: extraWeightBytes)
            let tokenizer: TokenizerHandle = try await newcomer.borrow().perform { ctx in
                TokenizerHandle(
                    ctx.tokenizer,
                    toolConstraintContractVerified:
                        Gemma4ToolConstraintContract.isVerified(
                            modelType: modelInfo.modelType,
                            modelDirectory: modelPath))
            }
            if Task.isCancelled {
                newcomer.release()
                MLX.Memory.clearCache()
                throw CancellationError()
            }
            // Trim the cold-load buffer pool BEFORE measuring: a fresh load leaves
            // transient buffers in MLX cacheMemory (no forward pass has trimmed
            // them yet), which would otherwise inflate "used" and false-reject a
            // serveable model. Mirrors ProviderLoop's clearCache-then-measure.
            MLX.Memory.clearCache()
            // Post-load measured-headroom guard (mirrors ProviderLoop): the load
            // gate admitted on an estimate; now that weights are resident, reject
            // a model with no serveable KV headroom under the cap rather than
            // publish a "loaded but every request rejected" model. Serialized by
            // isLoadingAny, so the MLX measurement reflects this load.
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
                throw StandaloneServerError.capacityUnavailable(
                    "Model '\(modelId)' loaded but has insufficient KV headroom under the memory cap "
                    + "(\(headroomGb) GB free, need \(minGb) GB to serve) — unloaded")
            }

            // ONE ENGINE: re-slice co-resident KV grants and build this
            // model's CBv2 engine + bridge with the newcomer's grant.
            // THROWS on any construction failure — refusal telemetry has
            // already fired, and the newcomer's weights are already released
            // + existing grants restored inside the catch (unwind ordering)
            // — the catch below just surfaces it as a 503-shaped capacity
            // error.
            var slotBuild: SlotBuild
            do {
                slotBuild = try await resliceAndBuildBundle(
                    modelId: modelId,
                    modelType: modelInfo.modelType,
                    isVLM: slotIsVLM,
                    modelDirectory: modelPath,
                    newcomer: newcomer,
                    tokenizer: tokenizer,
                    targetSizing: targetSizing,
                    specDecPreparation: mtpPreparation,
                    cacheEligibleWeightHash: cacheEligibleWeightHash)
            } catch let error as StandaloneServerError {
                MLX.Memory.clearCache()
                throw error
            } catch {
                MLX.Memory.clearCache()
                throw StandaloneServerError.capacityUnavailable(
                    "Model '\(modelId)' loaded but its v2 engine construction failed: \(error) — unloaded")
            }
            await kvBudget.release(requestID: pendingLoadID)
            var bundle = slotBuild.bundle
            var sizing = slotBuild.sizing
            var bridge = bundle.bridge

            // Post-BRIDGE measured-headroom re-guard (mirrors ProviderLoop):
            // engine construction/JIT may retain load-time memory beyond the
            // weights. Re-measure so a box with no serveable KV tears down
            // instead of publishing a model whose every request is rejected.
            // BACKEND-AWARE: a PAGED slot commits only its conservative
            // physical plan. Require both a useful pool and residual
            // whole-machine headroom after the build.
            MLX.Memory.clearCache()
            var postBridgeServeable = KVHeadroomProbe.postBuildServeable(
                kvBackendKind: bridge.kvBackendKind,
                pagedPoolBytes: await bridge.kvBackendPoolBytes())
            let runtimeMTPActive = await bridge.mtpStatusSnapshot().active
            if bundle.mtpStatus.active,
                !postBridgeServeable || !runtimeMTPActive
            {
                let reason: MTPFallbackReason = runtimeMTPActive
                    ? .assistantPostBuildHeadroom : .engineInactive
                standaloneLogger.warning(
                    "mtp: model=\(modelId) fallback reason=\(reason.rawValue); rebuilding target-only")
                await bridge.shutdown()
                bundle.releaseAssistant()
                MLX.Memory.clearCache()
                do {
                    slotBuild = try await resliceAndBuildBundle(
                        modelId: modelId,
                        modelType: modelInfo.modelType,
                        isVLM: slotIsVLM,
                        modelDirectory: modelPath,
                        newcomer: newcomer,
                        tokenizer: tokenizer,
                        targetSizing: targetSizing,
                        specDecPreparation: mtpPreparation.fallingBack(reason))
                } catch {
                    await resliceGrowSurvivors()
                    MLX.Memory.clearCache()
                    throw StandaloneServerError.capacityUnavailable(
                        "Model '\(modelId)' MTP fallback engine construction failed: \(error) — unloaded")
                }
                bundle = slotBuild.bundle
                sizing = slotBuild.sizing
                bridge = bundle.bridge
                MLX.Memory.clearCache()
                postBridgeServeable = KVHeadroomProbe.postBuildServeable(
                    kvBackendKind: bridge.kvBackendKind,
                    pagedPoolBytes: await bridge.kvBackendPoolBytes())
            }
            if !postBridgeServeable {
                let headroomGb = String(
                    format: "%.1f",
                    Double(KVHeadroomProbe.measuredLiveKVHeadroomBytes) / (1024.0 * 1024.0 * 1024.0))
                // Retire the bridge, release the newcomer's weights, THEN
                // regrow survivors — in that order (Codex review): regrowing
                // while the aborted newcomer's weights are still resident
                // would let Σ(grants) exceed the true fleet budget.
                await unwindBuiltSlotAndRegrow(bundle: bundle, newcomer: newcomer)
                throw StandaloneServerError.capacityUnavailable(
                    "Model '\(modelId)' loaded but its engine build left insufficient "
                    + "KV headroom under the memory cap (\(headroomGb) GB free) — unloaded")
            }

            // Guards passed — NOW publish the slot.
            guard let installContainer = newcomer.container else {
                // Unreachable (the box is drained only on failure paths) —
                // defensive so a wiring bug can never publish a slot with no
                // container.
                await unwindBuiltSlotAndRegrow(bundle: bundle, newcomer: newcomer)
                throw StandaloneServerError.capacityUnavailable(
                    "internal: newcomer container missing at install for '\(modelId)'")
            }
            slots[modelId] = CachedSlot(
                bundle: bundle,
                container: installContainer,
                tokenizer: tokenizer,
                modelType: modelInfo.modelType,
                isVLM: slotIsVLM,
                sizing: sizing,
                lastUsedAt: .now)
            standaloneLogger.info("Lazy-loaded model: \(modelId) (engine_v2)")

            modelsLoading.remove(modelId)
            isLoadingAny = false
            for waiter in loadingWaiters.removeValue(forKey: modelId) ?? [] {
                waiter.resume()
            }
            releaseLoadGateWaiters()
        } catch {
            modelsLoading.remove(modelId)
            isLoadingAny = false
            // Idempotent when the reservation was never placed or was already
            // handed off to MLX's live-memory view after a successful load.
            await kvBudget.release(requestID: pendingLoadID)
            // Release pool buffers a failed load left behind.
            MLX.Memory.clearCache()
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
