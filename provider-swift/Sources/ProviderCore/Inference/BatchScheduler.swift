// Copyright © 2026 Eigen Labs.
//
// Continuous-batching inference scheduler for the Darkbloom provider.
// Wraps `MLXLMCommon.BatchedEngine` with the provider-specific policy
// layer: GPU enforcement, byte-level KV budgets, admission control,
// pending-queue timeouts, and the adaptive concurrency cap.
//
// The engine itself drives the GPU step loop on its own dispatch queue;
// this actor's job is to gate submission, surface capacity, and bridge
// per-request `RequestOutput` streams to our public `GenerationEvent`
// stream.
//
// This file holds the actor declaration, instance state, public
// surface (`init`/`loadModel`/`unloadModel`/`submit`/`cancel`/
// `cancelAll`/`capacity`) and tiny internal helpers used by all
// extensions. Bigger units of behaviour live in:
//
//   * `BatchSchedulerTypes.swift`        — supporting types
//   * `BatchScheduler+EngineBridge.swift`— per-request stream bridge,
//                                           bridge bookkeeping, the
//                                           pending-timeout watchdog
//   * `BatchScheduler+KVEstimation.swift`— pure config.json parsing +
//                                           KV-bytes math (no actor
//                                           state)
//   * `BatchScheduler+Telemetry.swift`   — `backendCapacity` heartbeat,
//                                           EWMA + adaptive cap,
//                                           pending-summary cache

import CryptoKit
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import os

private let prefixCacheLogger = Logger(subsystem: "dev.darkbloom.provider", category: "prefix-cache-wiring")

/// Continuous-batching scheduler. Wraps a single `MLXLMCommon.BatchedEngine`
/// per loaded model. The engine owns the GPU step loop; this actor owns
/// admission control, KV-byte budgeting, the pending-queue timeout, and
/// the adaptive concurrency cap.
public actor BatchScheduler {

    // MARK: - Configuration (immutable after init)

    let maxConcurrentRequests: Int
    let pendingTimeout: Duration
    /// Default max output tokens when the consumer omits `max_tokens`.
    /// Starts at the init value (typically 4096) and is raised post-load
    /// when the model's context length is known.
    var defaultMaxTokens: Int
    let kvBudget: GlobalKVCacheBudget?
    let adaptiveCapPolicy = AdaptiveBatchCapPolicy.default

    // MARK: - Model-specific state (set by `loadModel`)

    var modelContainer: ModelContainer?
    var modelId: String = ""
    var modelWeightBytes: Int = 0
    var kvBytesPerToken: Int = 400_000
    var dynamicTokenBudgetMax: Int = 0
    /// The model's maximum context window read from config.json
    /// (`max_position_embeddings`). Used to size `maxTokensPerBatch`
    /// so prompts up to the model's context length are admissible.
    var maxContextLength: Int = 0
    var tokenizer: TokenizerHandle?
    var engine: BatchedEngine?

    /// Admission control + token budget tracking. `nil` until `loadModel()`.
    var planner: BatchQueuePlanner?

    /// Watchdog for planner-pending requests that exceed `pendingTimeout`.
    var pendingTimeoutTask: Task<Void, Never>?
    /// Bumped on every `loadModel` / `stopCurrentEngine` so stale model
    /// loads can detect they've been superseded.
    var generationEpoch: UInt64 = 0

    // MARK: - Per-request state (mutated by bridge + admission paths)

    /// Populated in `submit(...)` before `engine.core.addRequest`; torn
    /// down by the per-request streaming Task on finish/abort.
    var activeBridges: [String: BridgeState] = [:]
    /// Bridges aborted by the pending-timeout watchdog. Drives the
    /// distinct "request timed out waiting for capacity" error string
    /// (vs. "request cancelled" for client-initiated aborts).
    var timedOutBridges: Set<String> = []

    // MARK: - Telemetry state (read by `backendCapacity`)

    var observedDecodeTpsEwma: Double = 0
    var ewmaInitialized = false
    /// Per-batch-size TPS samples that drive `AdaptiveBatchCapPolicy`.
    var performanceByBatchSize: [Int: AdaptiveBatchPerformanceBucket] = [:]
    var lastBatchSampleAt: ContinuousClock.Instant = .now
    var dynamicMaxConcurrentRequests: Int
    var pendingSummaryCache: PendingSummary = .empty

    /// Memory-kind selector for `gpuMemory(_:)` in the telemetry extension.
    enum MemoryKind { case active, peak, cache }

    // Computed admission / capacity properties (tokenBudgetMax,
    // activeTokenBudgetUsed, effectiveMaxConcurrentRequests, etc.)
    // live in `BatchScheduler+Telemetry.swift` next to the heartbeat
    // surface that consumes them.

    // MARK: - Init

    /// The init-time default; restored on `stopCurrentEngine()`.
    private let initDefaultMaxTokens: Int

    public init(
        maxConcurrentRequests: Int = 4,
        pendingTimeout: Duration = .seconds(120),
        defaultMaxTokens: Int = 4096,
        kvBudget: GlobalKVCacheBudget? = nil
    ) {
        self.maxConcurrentRequests = max(1, maxConcurrentRequests)
        self.pendingTimeout = pendingTimeout
        self.defaultMaxTokens = defaultMaxTokens
        self.initDefaultMaxTokens = defaultMaxTokens
        self.kvBudget = kvBudget
        self.dynamicMaxConcurrentRequests = min(4, max(1, maxConcurrentRequests))
    }

    // MARK: - Model lifecycle

    public func loadModel(container: ModelContainer, modelId: String, weightHash: String? = nil) async {
        // Hard-fail if Metal is unavailable; CPU inference is not acceptable.
        do {
            _ = try GPUEnforcement.requireMetal()
        } catch {
            FileHandle.standardError.write(Data(
                "[FATAL] Cannot load model: \(error)\n".utf8
            ))
            return
        }

        await stopCurrentEngine()
        let loadEpoch = generationEpoch

        let snapshot = await Self.snapshotContainer(container)
        // Detect concurrent reload that won the race; bail before we
        // overwrite the new model's state with our stale snapshot.
        guard loadEpoch == generationEpoch else { return }

        self.modelContainer = container
        self.modelId = modelId
        self.modelWeightBytes = snapshot.bytes
        self.tokenizer = snapshot.tokenizer

        let engine = await Self.makeBatchedEngine(
            container: container,
            modelId: modelId,
            weightHash: weightHash,
            weightBytes: snapshot.bytes,
            maxConcurrentRequests: maxConcurrentRequests,
            eosTokenIds: snapshot.eosTokenIds,
            architecture: snapshot.architecture
        )
        // Re-check epoch after the engine.start suspension. If another
        // load/unload won the race, tear down the engine we just built
        // and bail before we overwrite the winner's state.
        guard loadEpoch == generationEpoch else {
            await engine.stop()
            return
        }
        self.engine = engine
        await engine.start()
        // Final epoch check after start() — start can suspend too.
        guard loadEpoch == generationEpoch else {
            self.engine = nil
            await engine.stop()
            return
        }

        applyPostLoadBudgets(snapshot: snapshot)
        // Apply the conservative startup cap before admitting any request,
        // otherwise the first few submits could run at the hard cap until
        // the adaptive policy kicks in.
        engine.setMaxNumSeqs(dynamicMaxConcurrentRequests)
        self.planner = makePlanner(activeTokenBudget: tokenBudgetMax)
        // Engine has no pending-queue TTL; we enforce `pendingTimeout`.
        startPendingTimeoutWatchdog()
    }

    /// Snapshot model bytes + tokenizer + architecture out of the
    /// container. Runs inside `container.perform` (off-actor); returns
    /// a Sendable struct so the actor can resume on its own executor.
    private static func snapshotContainer(_ container: ModelContainer) async -> LoadSnapshot {
        await container.perform { ctx in
            let bytes = ctx.model.parameters().flattened().reduce(0) { $0 + $1.1.nbytes }

            // Read architecture from config.json: covers hybrid models
            // (Gemma 3/3n/4) that don't conform to KVCacheDimensionProvider.
            let architecture: ModelArchitecture
            if case .directory(let modelDir) = ctx.configuration.id {
                let configURL = modelDir.appendingPathComponent("config.json")
                architecture = KVEstimation.parseModelArchitecture(at: configURL)
            } else {
                architecture = .empty
            }
            return LoadSnapshot(
                bytes: bytes,
                tokenizer: TokenizerHandle(ctx.tokenizer),
                eosTokenIds: ctx.configuration.eosTokenIds,
                architecture: architecture
            )
        }
    }

    /// Build a `BatchedEngine` with our scheduler config. Pulled out
    /// of `loadModel` so the lifecycle code reads as a sequence of
    /// 5-line steps. SECURITY (TB-007): the engine's prefix cache
    /// persists token sequences across requests in process memory.
    /// Cross-tenant data-leak risk; do not enable without a fresh
    /// threat model.
    private static func makeBatchedEngine(
        container: ModelContainer,
        modelId: String,
        weightHash: String?,
        weightBytes: Int,
        maxConcurrentRequests: Int,
        eosTokenIds: Set<Int>,
        architecture: ModelArchitecture
    ) async -> BatchedEngine {
        // TB-007: the engine prefix cache is OFF by default. When the
        // operator sets DARKBLOOM_PREFIX_CACHE, we enable it with an
        // ENCRYPTED-at-rest SSD backend (EncryptedPrefixCachePersistence).
        // This still does NOT close the in-process cross-tenant sharing /
        // TTFT side-channel (the provider can't see tenant identity), so
        // it ships only behind this flag + an explicit threat-model
        // sign-off. See docs/ssd-kv-cache-design.md.
        //
        // Memory guard: the block cache holds up to maxBlocks*blockSize
        // tokens of KV OUTSIDE the scheduler's active kvBudget, so size it
        // by a memory budget (not a fixed 4096) or a huge model would OOM.
        let blockSize = 256
        // Only built when the flag is on + KEK/arch available (nil otherwise),
        // so the budget logging below can't mislead when the cache is off.
        let persistence = await makeEncryptedPrefixPersistenceIfEnabled(
            modelId: modelId, weightHash: weightHash, architecture: architecture
        )
        let kvBytesPerToken = resolvedKVBytesPerToken(architecture: architecture, weightBytes: weightBytes)
        let maxBlocks = prefixCacheMaxBlocks(
            kvBytesPerToken: kvBytesPerToken,
            budgetBytes: prefixCacheBudgetBytes(),
            blockSize: blockSize
        )
        return await container.perform { ctx -> BatchedEngine in
            var prefixCache: PrefixCache? = nil
            if let p = persistence {
                if maxBlocks >= 1 {
                    prefixCacheLogger.info(
                        "prefix cache sized to \(maxBlocks) blocks × \(blockSize) tok (~\(kvBytesPerToken) B/tok)")
                    prefixCache = PrefixCache(
                        config: PrefixCacheConfig(blockSize: blockSize, maxBlocks: maxBlocks),
                        modelName: modelId,
                        persistence: p
                    )
                } else {
                    prefixCacheLogger.warning(
                        "prefix cache disabled: model KV (\(kvBytesPerToken) B/tok) exceeds the memory budget for even one block")
                }
            }
            let scheduler = Scheduler(
                model: ctx.model,
                tokenizer: ctx.tokenizer,
                config: SchedulerConfig(
                    maxNumSeqs: maxConcurrentRequests,
                    maxNumBatchedTokens: 8192,
                    prefillStepSize: 512,
                    streamInterval: 1,
                    maxKVCacheTokens: 0  // unlimited — our kvBudget gates by bytes
                ),
                eosTokenIds: eosTokenIds,
                prefixCache: prefixCache  // nil unless DARKBLOOM_PREFIX_CACHE (TB-007)
            )
            return BatchedEngine(
                scheduler: scheduler,
                tokenizer: ctx.tokenizer,
                modelName: modelId,
                config: ContinuousBatchingConfig(
                    schedulerConfig: scheduler.config,
                    stepInterval: 0.001,
                    prefixCacheConfig: nil,  // cache lives on the scheduler above
                    mtpEnabled: false
                ),
                externalChatTemplate: nil
            )
        }
    }

    /// Build the encrypted SSD prefix-cache backend IFF the operator
    /// opted in via `DARKBLOOM_PREFIX_CACHE`. Returns nil (cache stays
    /// off) when the flag is unset, the model architecture is
    /// incomplete, or the persisted KEK is unavailable (no Secure
    /// Enclave / entitlement) — in the last case we refuse rather than
    /// use an ephemeral key that wouldn't survive restart.
    ///
    /// SECURITY (TB-007): see makeBatchedEngine. The cache is bound to the
    /// WEIGHT identity (`weightHash`) when known, not just the mutable
    /// model id — a re-download under the same id with different weights
    /// must not serve stale KV. Falls back to modelId when no weight hash
    /// is available (no worse than before).
    private static func makeEncryptedPrefixPersistenceIfEnabled(
        modelId: String,
        weightHash: String?,
        architecture: ModelArchitecture
    ) async -> EncryptedPrefixCachePersistence? {
        let env = ProcessInfo.processInfo.environment["DARKBLOOM_PREFIX_CACHE"]
        guard env == "1" || env?.lowercased() == "true" else { return nil }

        prefixCacheLogger.warning(
            "DARKBLOOM_PREFIX_CACHE is ON — engine prefix cache enabled (TB-007: cross-tenant sharing / TTFT side-channel; encrypted-at-rest only)."
        )

        guard let numLayers = architecture.numLayers,
              let kvHeads = architecture.kvHeads,
              let headDim = architecture.headDim else {
            prefixCacheLogger.warning("prefix cache disabled: incomplete model architecture")
            return nil
        }

        // KEK must be SE-wrapped + Keychain-persisted so cache files
        // survive restart. If unavailable, disable rather than fall back
        // to an ephemeral key (which would silently break restart-reuse).
        let kekKey: SymmetricKey
        do {
            let se = try PersistentEnclaveKey.loadOrCreate()
            let kek = KVCacheKEK(
                wrapper: SecureEnclaveKeyWrappingService(enclaveKey: se),
                storage: KeychainWrappedKEKStorage()
            )
            kekKey = try await kek.loadOrCreate()
        } catch {
            prefixCacheLogger.warning("prefix cache disabled: KEK unavailable (\(String(describing: error)))")
            return nil
        }

        // Bind both the on-disk directory key AND the metadata modelHash to
        // the weight identity (weightHash) when available; fall back to the
        // model id. A weight change under the same id then yields a new dir
        // + new binding, so old KV is neither found nor passes MB-1.
        let bindingId = prefixCacheBindingId(modelId: modelId, weightHash: weightHash)
        let modelKey = SHA256.hash(data: Data(bindingId.utf8))
            .map { String(format: "%02x", $0) }.joined().prefix(12)
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = root.appendingPathComponent("darkbloom/kv/\(modelKey)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let binding = PrefixCacheModelBinding(
            modelHash: bindingId, modelDtype: "unknown", modelArch: "unknown",
            vocabSize: 0, numLayers: numLayers, kvHeads: kvHeads, headDim: headDim
        )
        let diskBudget = prefixCacheDiskBudgetBytes()
        prefixCacheLogger.info(
            "encrypted prefix cache active for \(modelId, privacy: .public) (bound to \(weightHash == nil ? "modelId" : "weightHash", privacy: .public)) at \(dir.path, privacy: .public), disk budget \(diskBudget) bytes")
        return EncryptedPrefixCachePersistence(
            kekKey: kekKey, dir: dir, binding: binding, diskBudgetBytes: diskBudget)
    }

    // MARK: - Prefix cache sizing/binding helpers (testable)

    /// Cache identity: bind to the weight hash so a re-download under the
    /// same model id with different weights invalidates old KV. Falls back
    /// to the model id when no weight hash is known.
    static func prefixCacheBindingId(modelId: String, weightHash: String?) -> String {
        if let w = weightHash, !w.isEmpty { return w }
        return modelId
    }

    /// Block count for the engine prefix cache, bounded by a memory budget.
    /// The cache retains up to blocks*blockSize tokens of KV OUTSIDE the
    /// scheduler's active kvBudget, so a fixed 4096 would OOM large models.
    /// Returns 0 when even one block exceeds the budget (caller disables).
    static func prefixCacheMaxBlocks(
        kvBytesPerToken: Int, budgetBytes: Int, blockSize: Int, ceiling: Int = 4096
    ) -> Int {
        let perBlock = max(1, blockSize) * max(1, kvBytesPerToken)
        let fromBudget = max(0, budgetBytes) / perBlock
        return min(ceiling, fromBudget)
    }

    /// In-memory budget for the engine prefix cache. Operator override:
    /// DARKBLOOM_PREFIX_CACHE_MAX_GB; default = 1/8 of physical memory.
    static func prefixCacheBudgetBytes() -> Int {
        if let s = ProcessInfo.processInfo.environment["DARKBLOOM_PREFIX_CACHE_MAX_GB"],
           let gb = Double(s), gb > 0 {
            return Int(gb * 1_073_741_824)
        }
        return Int(ProcessInfo.processInfo.physicalMemory) / 8
    }

    /// On-disk budget for persisted prefix files. Operator override:
    /// DARKBLOOM_PREFIX_CACHE_DISK_GB; default = 10 GB. 0 disables the cap.
    static func prefixCacheDiskBudgetBytes() -> Int {
        if let s = ProcessInfo.processInfo.environment["DARKBLOOM_PREFIX_CACHE_DISK_GB"],
           let gb = Double(s), gb >= 0 {
            return Int(gb * 1_073_741_824)
        }
        return 10 * 1_073_741_824
    }

    /// Set the post-load budgets driven by architecture + physical
    /// memory. Pulled out of `loadModel` so the lifecycle reads as a
    /// short sequence; the arithmetic itself is unchanged.
    private func applyPostLoadBudgets(snapshot: LoadSnapshot) {
        self.kvBytesPerToken = Self.resolvedKVBytesPerToken(
            architecture: snapshot.architecture,
            weightBytes: snapshot.bytes
        )
        let totalMemory = Int(ProcessInfo.processInfo.physicalMemory)
        let osReserve = 4 * 1024 * 1024 * 1024
        let safetyMargin = totalMemory / 10
        let availableForKV = totalMemory - snapshot.bytes - osReserve - safetyMargin
        if availableForKV > 0 && kvBytesPerToken > 0 {
            self.dynamicTokenBudgetMax = max(availableForKV / kvBytesPerToken, 1024)
        } else {
            self.dynamicTokenBudgetMax = 1024
        }

        // Derive context-aware limits from config.json.
        self.maxContextLength = snapshot.architecture.maxContextLength ?? 0
        if maxContextLength > 0 {
            // Raise the default max output tokens so consumers that omit
            // `max_tokens` get a reasonable budget for the model's class.
            // Cap at 8192 so we don't over-reserve with very-long-context
            // models (e.g. 131K Qwen).
            self.defaultMaxTokens = min(maxContextLength, 8192)
        }

        self.dynamicMaxConcurrentRequests = min(4, maxConcurrentRequests)
        self.performanceByBatchSize.removeAll()
        self.lastBatchSampleAt = .now
    }

    public func unloadModel() async {
        await stopCurrentEngine()
    }

    // MARK: - Submit / cancel

    /// Submit a pre-tokenized prompt. Used by `MultiModelBatchSchedulerEngine`
    /// which tokenizes the full OpenAI request (including tools, tool_call_id,
    /// reasoning_content, etc.) itself, then hands the token IDs here.
    ///
    /// This bypasses the lossy `ChatMessage → applyChatTemplate` path in the
    /// `ChatCompletionRequest` overload, which drops tool-related fields.
    public func submitTokenized(
        promptTokens: [Int],
        maxTokens: Int,
        temperature: Float = 0.0,
        topP: Float? = nil,
        topK: Int? = nil,
        seed: UInt64? = nil,
        requestId: String? = nil
    ) async -> AsyncStream<GenerationEvent> {
        let id = requestId ?? "req-\(UUID().uuidString.prefix(12))"
        let (stream, continuation) = AsyncStream<GenerationEvent>.makeStream()

        guard let engine = self.engine else {
            continuation.yield(.error("No model loaded"))
            continuation.finish()
            return stream
        }

        let requestBudget = promptTokens.count + maxTokens
        guard requestBudget <= tokenBudgetMax else {
            continuation.yield(.error(
                "token_budget_exhausted: request requires \(requestBudget) tokens but only \(tokenBudgetMax) available"
            ))
            continuation.finish()
            return stream
        }

        let activeUsed = activeTokenBudgetUsed
        if activeUsed + requestBudget > tokenBudgetMax {
            continuation.yield(.error(
                "token_budget_exhausted: request requires \(requestBudget) tokens but only \(tokenBudgetMax - activeUsed) available"
            ))
            continuation.finish()
            return stream
        }
        let bridge = BridgeState(
            requestId: id,
            promptTokens: promptTokens.count,
            maxTokens: maxTokens,
            submittedAt: .now
        )
        activeBridges[id] = bridge

        if let planner = self.planner {
            await refreshPlannerPolicy(activeTokenBudget: tokenBudgetMax)
            let result = await planner.admit(
                id: id,
                promptTokenCount: promptTokens.count,
                maxOutputTokens: maxTokens
            )
            if case .rejected(_, let reason) = result {
                await dropBridge(requestId: id)
                continuation.yield(.error(Self.errorMessage(for: reason)))
                continuation.finish()
                return stream
            }
            await refreshPendingSummaryCache()
        }

        if let kvBudget {
            let reserved = await kvBudget.reserve(
                requestID: id,
                kvBytesPerToken: kvBytesPerToken,
                tokenCount: requestBudget
            )
            guard reserved else {
                await dropBridge(requestId: id)
                continuation.yield(.error("token_budget_exhausted: insufficient global KV cache headroom"))
                continuation.finish()
                return stream
            }
        }

        var sp = SamplingParams(maxTokens: maxTokens, temperature: temperature)
        if let topP { sp.topP = topP }
        if let topK { sp.topK = topK }
        if let seed { sp.seed = seed }

        let req = Request(
            requestId: id,
            prompt: promptTokens as AnyHashable,
            samplingParams: sp
        )
        _ = await engine.core.addRequest(req)

        runBridge(
            requestId: id,
            outputStream: engine.core.streamOutputs(requestId: id),
            continuation: continuation
        )

        let scheduler = self
        continuation.onTermination = { @Sendable termination in
            if case .cancelled = termination {
                Task { await scheduler.cancel(requestId: id) }
            }
        }

        return stream
    }

    public func submit(
        request: ChatCompletionRequest,
        requestId: String? = nil
    ) async -> AsyncStream<GenerationEvent> {
        let id = requestId ?? "req-\(UUID().uuidString.prefix(12))"
        let (stream, continuation) = AsyncStream<GenerationEvent>.makeStream()

        guard let engine = self.engine, let tk = tokenizer else {
            continuation.yield(.error("No model loaded"))
            continuation.finish()
            return stream
        }

        // Pre-tokenize so chat-template errors surface as `.error` events;
        // engine's internal `buildPrompt` silently falls back to role:content.
        let messages: [[String: any Sendable]] = request.messages.map { msg in
            ["role": msg.role, "content": msg.content]
        }
        let promptTokens: [Int]
        do {
            promptTokens = try tk.inner.applyChatTemplate(
                messages: messages, tools: nil, additionalContext: nil
            )
        } catch {
            continuation.yield(.error("Failed to tokenize: \(error.localizedDescription)"))
            continuation.finish()
            return stream
        }

        let maxTokens = Self.resolvedMaxTokens(
            requested: request.max_tokens, defaultMaxTokens: defaultMaxTokens
        )

        let requestBudget = promptTokens.count + maxTokens
        guard requestBudget <= tokenBudgetMax else {
            continuation.yield(.error(
                "token_budget_exhausted: request requires \(requestBudget) tokens but only \(tokenBudgetMax) available"
            ))
            continuation.finish()
            return stream
        }

        // P1 fix (atomic): the cumulative gate + slot reservation must
        // run in one synchronous block. Actor reentrancy across the
        // upcoming `planner.admit` / `kvBudget.reserve` awaits would
        // otherwise let two concurrent submits both read the same
        // `activeTokenBudgetUsed` and both pass the check.
        //
        // Reserve our slot by inserting the bridge into `activeBridges`
        // BEFORE the first await. Other interleaving submits will see
        // this request's budget in `activeTokenBudgetUsed`. Any early
        // exit below (planner reject, KV reject) must roll back the
        // bridge via `dropBridge(...)`.
        let activeUsed = activeTokenBudgetUsed
        if activeUsed + requestBudget > tokenBudgetMax {
            continuation.yield(.error(
                "token_budget_exhausted: request requires \(requestBudget) tokens but only \(tokenBudgetMax - activeUsed) available"
            ))
            continuation.finish()
            return stream
        }
        let bridge = BridgeState(
            requestId: id,
            promptTokens: promptTokens.count,
            maxTokens: maxTokens,
            submittedAt: .now
        )
        activeBridges[id] = bridge

        if let planner = self.planner {
            await refreshPlannerPolicy(activeTokenBudget: tokenBudgetMax)
            let result = await planner.admit(
                id: id,
                promptTokenCount: promptTokens.count,
                maxOutputTokens: maxTokens
            )
            if case .rejected(_, let reason) = result {
                await dropBridge(requestId: id)
                continuation.yield(.error(Self.errorMessage(for: reason)))
                continuation.finish()
                return stream
            }
            await refreshPendingSummaryCache()
        }

        if let kvBudget {
            let reserved = await kvBudget.reserve(
                requestID: id,
                kvBytesPerToken: kvBytesPerToken,
                tokenCount: requestBudget
            )
            guard reserved else {
                await dropBridge(requestId: id)
                continuation.yield(.error("token_budget_exhausted: insufficient global KV cache headroom"))
                continuation.finish()
                return stream
            }
        }

        // Greedy (temperature == 0) hits the engine's vectorized argmax
        // fast path automatically; just pass the requested value through.
        let temperature = request.temperature ?? 0.0
        var sp = SamplingParams(maxTokens: maxTokens, temperature: temperature)
        if let topP = request.top_p { sp.topP = topP }
        if let topK = request.top_k { sp.topK = topK }
        if let seed = request.seed { sp.seed = seed }

        let req = Request(
            requestId: id,
            prompt: promptTokens as AnyHashable,
            samplingParams: sp
        )
        _ = await engine.core.addRequest(req)

        // Hand the per-request stream to the bridge extension. Bridge
        // teardown / finish-event mapping all live in
        // `BatchScheduler+EngineBridge.swift`.
        runBridge(
            requestId: id,
            outputStream: engine.core.streamOutputs(requestId: id),
            continuation: continuation
        )

        let scheduler = self
        continuation.onTermination = { @Sendable termination in
            if case .cancelled = termination {
                Task { await scheduler.cancel(requestId: id) }
            }
        }

        return stream
    }

    public func cancel(requestId: String) async {
        if let engine = self.engine {
            // Engine delivers a terminal RequestOutput synchronously; the
            // streaming Task handles `recordFinish` + KV release.
            _ = engine.core.abortRequest(requestId)
            return
        }
        // No engine: request may still be planner-pending.
        if let planner = self.planner {
            await planner.cancel(requestID: requestId)
            await refreshPendingSummaryCache()
        }
        await releaseKVReservation(requestID: requestId)
    }

    public func cancelAll() async {
        if let engine = self.engine {
            _ = engine.core.abortAllRequests()
        }
        // Planner pending queue: engine only knows about admitted requests.
        if let planner = self.planner {
            let snapshot = await planner.snapshot()
            for entry in snapshot.pendingRequests {
                await planner.cancel(requestID: entry.id)
            }
            for entry in snapshot.activeRequests {
                await planner.cancel(requestID: entry.id)
            }
            await refreshPendingSummaryCache()
        }
        let bridgeIds = Array(activeBridges.keys)
        for id in bridgeIds {
            await releaseKVReservation(requestID: id)
        }
        activeBridges.removeAll()
        timedOutBridges.removeAll()
    }

    // MARK: - Capacity

    public func capacity() -> SchedulerCapacity {
        SchedulerCapacity(
            model: modelId,
            activeRequests: activeBridges.count,
            pendingRequests: pendingRequestCount,
            maxConcurrent: effectiveMaxConcurrentRequests,
            engineMaxConcurrent: maxConcurrentRequests,
            gpuMemoryActiveBytes: gpuMemory(.active),
            gpuMemoryPeakBytes: gpuMemory(.peak),
            gpuMemoryCacheBytes: gpuMemory(.cache),
            totalMemoryBytes: ProcessInfo.processInfo.physicalMemory
        )
    }

    // MARK: - Internal helpers

    private func stopCurrentEngine() async {
        generationEpoch &+= 1
        pendingTimeoutTask?.cancel()
        pendingTimeoutTask = nil

        if let engine = self.engine {
            _ = engine.core.abortAllRequests()
            await engine.stop()
        }
        self.engine = nil
        modelContainer = nil
        tokenizer = nil

        let bridgeIds = Array(activeBridges.keys)
        for id in bridgeIds {
            await releaseKVReservation(requestID: id)
        }
        activeBridges.removeAll()
        timedOutBridges.removeAll()
        pendingSummaryCache = .empty

        modelWeightBytes = 0
        modelId = ""
        kvBytesPerToken = 400_000
        dynamicTokenBudgetMax = 0
        maxContextLength = 0
        defaultMaxTokens = initDefaultMaxTokens
        planner = nil
        observedDecodeTpsEwma = 0
        ewmaInitialized = false
        performanceByBatchSize.removeAll()
        dynamicMaxConcurrentRequests = min(4, maxConcurrentRequests)
    }

    /// P1 fix: cumulative active-bridge gate, called from tests.
    ///
    /// `submit()` inlines the same check synchronously before its
    /// first `await` (so the gate is atomic with respect to actor
    /// reentrancy). This helper exists so unit tests can probe the
    /// gate without a loaded model + non-nil engine.
    ///
    /// Returns the canonical `token_budget_exhausted:` error string on
    /// rejection, or `nil` on accept. Does NOT reserve a slot — that
    /// happens inline in `submit()` to keep the (check + reserve)
    /// pair atomic.
    func checkCumulativeTokenBudget(
        requestId: String,
        requestBudget: Int
    ) -> String? {
        let activeUsed = activeTokenBudgetUsed
        guard activeUsed + requestBudget > tokenBudgetMax else { return nil }
        return "token_budget_exhausted: request requires \(requestBudget) tokens but only \(tokenBudgetMax - activeUsed) available"
    }

    private func makePlanner(activeTokenBudget: Int) -> BatchQueuePlanner {
        BatchQueuePlanner(
            policy: BatchSchedulingPolicy(
                maxConcurrentRequests: maxConcurrentRequests,
                maxQueuedRequests: 128,
                maxActiveTokenBudget: activeTokenBudget,
                maxTokensPerBatch: resolvedMaxTokensPerBatch(activeTokenBudget: activeTokenBudget)
            )
        )
    }

    private func refreshPlannerPolicy(activeTokenBudget: Int) async {
        guard let planner else { return }
        let updatedPolicy = BatchSchedulingPolicy(
            maxConcurrentRequests: maxConcurrentRequests,
            maxQueuedRequests: 128,
            maxActiveTokenBudget: activeTokenBudget,
            maxTokensPerBatch: resolvedMaxTokensPerBatch(activeTokenBudget: activeTokenBudget)
        )
        let snapshot = await planner.snapshot()
        guard snapshot.policy != updatedPolicy else { return }

        if activeTokenBudget >= snapshot.policy.maxActiveTokenBudget {
            await planner.updatePolicy(updatedPolicy)
            return
        }

        guard snapshot.pendingRequests.isEmpty,
              snapshot.activeRequests.isEmpty else { return }
        await planner.updatePolicy(updatedPolicy)
    }

    /// Derive the per-request prompt admission limit from the model's
    /// context window. Falls back to 8192 when `config.json` is missing
    /// or doesn't declare `max_position_embeddings`. Capped by the live
    /// token budget so we never admit a prompt that couldn't possibly
    /// fit in memory.
    private func resolvedMaxTokensPerBatch(activeTokenBudget: Int) -> Int {
        let contextBased = maxContextLength > 0 ? maxContextLength : 8192
        return min(contextBased, max(activeTokenBudget, 1))
    }

    // Static helpers live in adjacent extensions:
    //   * `resolvedMaxTokens`, `resolvedKVBytesPerToken` →
    //     `BatchScheduler+KVEstimation.swift`
    //   * `errorMessage(for:)` → `BatchSchedulerTypes.swift`
}
