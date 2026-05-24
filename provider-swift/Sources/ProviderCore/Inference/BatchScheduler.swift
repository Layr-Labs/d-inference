// Copyright © 2026 Eigen Labs.
//
// Continuous-batching inference scheduler for the Darkbloom provider.
// All concurrent requests share one `BatchGenerator`, which runs one
// batched forward pass per step and emits per-row decoded tokens.

import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// Events emitted by the scheduler for a single inference request.
public enum GenerationEvent: Sendable {
    case chunk(String)
    case info(promptTokens: Int, completionTokens: Int, tokensPerSecond: Double)
    case error(String)
}

/// Snapshot of the scheduler's capacity, reported to the coordinator in heartbeats.
public struct SchedulerCapacity: Sendable {
    public let model: String
    public let activeRequests: Int
    public let pendingRequests: Int
    public let maxConcurrent: Int
    public let engineMaxConcurrent: Int
    public let gpuMemoryActiveBytes: Int
    public let gpuMemoryPeakBytes: Int
    public let gpuMemoryCacheBytes: Int
    public let totalMemoryBytes: UInt64
}

/// Continuous-batching scheduler. One shared `BatchGenerator` runs all
/// concurrent requests through one batched forward pass per step.
///
/// Lifecycle:
///   1. `loadModel(container:modelId:)` snapshots the tokenizer + EOS
///      tokens and starts a long-running worker task.
///   2. `submit(request:requestId:)` tokenizes the chat-template prompt,
///      enqueues into the BatchGenerator, and returns an
///      `AsyncStream<GenerationEvent>`.
///   3. The detached worker calls `stepEngine()` repeatedly, dispatching
///      per-row tokens as detokenized text chunks.
///   4. `unloadModel()` cancels everything.
public actor BatchScheduler {

    private let maxConcurrentRequests: Int
    private let pendingTimeout: Duration
    private let defaultMaxTokens: Int
    private let kvBudget: GlobalKVCacheBudget?

    private var modelContainer: ModelContainer?
    private var modelId: String = ""
    private var modelWeightBytes: Int = 0
    private var kvBytesPerToken: Int = 400_000
    private var dynamicTokenBudgetMax: Int = 0

    /// Queue planner for admission control, token budget tracking, and request
    /// phase management. Created in `loadModel()` once the dynamic token budget
    /// is known; `nil` before a model is loaded (inline fallback is used).
    private var planner: BatchQueuePlanner?

    private var tokenizer: TokenizerBox?
    private var generator: BatchGenerator?
    private var workerTask: Task<Void, Never>?

    private var active: [Int: ActiveRequest] = [:]
    private var requestIdToUid: [String: Int] = [:]
    private var pending: [PendingRequest] = []
    private var cancelledUIDs = Set<Int>()
    private var generationEpoch: UInt64 = 0
    private var engineBusy = false
    private var observedDecodeTpsEwma: Double = 0
    private var ewmaInitialized = false
    private var performanceByBatchSize: [Int: AdaptiveBatchPerformanceBucket] = [:]
    private var dynamicMaxConcurrentRequests: Int

    /// Once every active row has received its first token, run several decode
    /// steps per actor/model hop. A single hop per token starves Gemma-class
    /// models because the CPU actor round trip is larger than one GPU step.
    private let decodeBurstSteps = 32
    private let adaptiveCapPolicy = AdaptiveBatchCapPolicy.default
    static let maxConfigJSONBytes = 4 * 1024 * 1024

    private var tokenBudgetMax: Int {
        let staticBudget = dynamicTokenBudgetMax > 0
            ? dynamicTokenBudgetMax
            : defaultMaxTokens * maxConcurrentRequests
        guard modelWeightBytes > 0, kvBytesPerToken > 0 else {
            return staticBudget
        }

        let totalMemory = Int(ProcessInfo.processInfo.physicalMemory)
        let osReserve = 4 * 1024 * 1024 * 1024
        let safetyMargin = totalMemory / 10
        let globalUsed = Int(MLX.GPU.activeMemory) + Int(MLX.GPU.cacheMemory)
        let availableHeadroom = max(0, totalMemory - osReserve - safetyMargin - globalUsed)
        let liveBudget = activeTokenBudgetUsed + (availableHeadroom / kvBytesPerToken)
        return max(1024, min(staticBudget, liveBudget))
    }

    private var activeTokenBudgetUsed: Int {
        active.values.reduce(0) { $0 + $1.promptTokens + $1.maxTokens }
    }

    private var queuedTokenBudget: Int {
        pending.reduce(0) { $0 + $1.promptTokens.count + $1.maxTokens }
    }

    private var currentTokenBudgetUsed: Int {
        activeTokenBudgetUsed + queuedTokenBudget
    }

    private var averageReservedTokensForAdmission: Int {
        let requestCount = active.count + pending.count
        guard requestCount > 0 else { return defaultMaxTokens }
        return max(1, currentTokenBudgetUsed / requestCount)
    }

    private var memoryBoundMaxConcurrentRequests: Int {
        let budget = tokenBudgetMax
        let averageReserved = averageReservedTokensForAdmission
        guard budget > 0, averageReserved > 0 else { return 1 }
        return max(1, min(maxConcurrentRequests, budget / averageReserved))
    }

    private var effectiveMaxConcurrentRequests: Int {
        max(1, min(maxConcurrentRequests, dynamicMaxConcurrentRequests, memoryBoundMaxConcurrentRequests))
    }

    public init(
        maxConcurrentRequests: Int = 4,
        pendingTimeout: Duration = .seconds(120),
        defaultMaxTokens: Int = 4096,
        kvBudget: GlobalKVCacheBudget? = nil
    ) {
        self.maxConcurrentRequests = max(1, maxConcurrentRequests)
        self.pendingTimeout = pendingTimeout
        self.defaultMaxTokens = defaultMaxTokens
        self.kvBudget = kvBudget
        self.dynamicMaxConcurrentRequests = min(4, max(1, maxConcurrentRequests))
    }

    // MARK: - Model lifecycle

    public func loadModel(container: ModelContainer, modelId: String) async {
        // Hard-fail before we touch any model weights if the GPU is
        // unavailable. CPU fallback for inference would be a silent
        // 100\u{D7} performance regression; never acceptable for the
        // production provider.
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

        let snapshot: LoadSnapshot = await container.perform { ctx in
            let bytes = ctx.model.parameters().flattened().reduce(0) { $0 + $1.1.nbytes }
            var eos: [[Int]] = []
            if let id = ctx.tokenizer.convertTokenToId(ctx.tokenizer.eosToken ?? "") {
                eos.append([id])
            }

            // Read architecture metadata from config.json. This is more
            // universal than the KVCacheDimensionProvider protocol (which
            // some models like Gemma 3/3n don't conform to) and gives us
            // access to hybrid-architecture fields (num_kv_shared_layers,
            // global_head_dim, sliding_window_pattern, etc.).
            var numLayers: Int?
            var kvHeads: Int?
            var headDim: Int?
            var numKvSharedLayers: Int = 0
            var globalHeadDim: Int?
            var numGlobalKvHeads: Int?
            var slidingWindowPattern: Int?
            var layerTypes: [String]?

            if case .directory(let modelDir) = ctx.configuration.id {
                let configURL = modelDir.appendingPathComponent("config.json")
                if let data = Self.readBoundedConfigJSON(configURL),
                    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    // Resolve nested text_config if present (Gemma 4 VLM wraps everything there)
                    let cfg: [String: Any]
                    if let textConfig = json["text_config"] as? [String: Any] {
                        cfg = textConfig
                    } else {
                        cfg = json
                    }

                    numLayers = cfg["num_hidden_layers"] as? Int
                    kvHeads = cfg["num_key_value_heads"] as? Int
                        ?? cfg["num_attention_heads"] as? Int  // MHA fallback

                    headDim = cfg["head_dim"] as? Int
                    if headDim == nil,
                       let hs = cfg["hidden_size"] as? Int,
                       let nh = cfg["num_attention_heads"] as? Int, nh > 0 {
                        headDim = hs / nh
                    }

                    // Hybrid architecture fields (Gemma 4, Gemma 3n)
                    numKvSharedLayers = cfg["num_kv_shared_layers"] as? Int ?? 0
                    globalHeadDim = cfg["global_head_dim"] as? Int
                    numGlobalKvHeads = cfg["num_global_key_value_heads"] as? Int
                    // sliding_window_pattern is an Int in Gemma 3/3n/4:
                    // e.g. 5 means [sliding, sliding, sliding, sliding, full] repeating
                    slidingWindowPattern = cfg["sliding_window_pattern"] as? Int
                    layerTypes = cfg["layer_types"] as? [String]
                }
            }

            // Clamp architecture values to prevent absurd token budgets from
            // crafted config.json (operator-writable model directory).
            let maxLayersBound = 1024
            let maxHeadsBound = 1024
            let maxHeadDimBound = 2048

            if let l = numLayers { numLayers = min(max(l, 1), maxLayersBound) }
            if let h = kvHeads { kvHeads = min(max(h, 1), maxHeadsBound) }
            if let hd = headDim { headDim = min(max(hd, 1), maxHeadDimBound) }
            if let ghd = globalHeadDim { globalHeadDim = min(max(ghd, 1), maxHeadDimBound) }
            if let gkh = numGlobalKvHeads { numGlobalKvHeads = min(max(gkh, 1), maxHeadsBound) }
            // Clamp numKvSharedLayers to [0, numLayers]
            if let l = numLayers {
                numKvSharedLayers = min(max(numKvSharedLayers, 0), l)
            } else {
                numKvSharedLayers = max(numKvSharedLayers, 0)
            }
            // Clamp slidingWindowPattern to [0, numLayers]
            if let swp = slidingWindowPattern {
                let upperBound = numLayers ?? maxLayersBound
                slidingWindowPattern = min(max(swp, 0), upperBound)
            }
            // Cap layerTypes to first numLayers entries
            if let lt = layerTypes, let l = numLayers, lt.count > l {
                layerTypes = Array(lt.prefix(l))
            }

            return LoadSnapshot(
                bytes: bytes,
                eos: eos,
                tokenizer: TokenizerBox(ctx.tokenizer),
                model: ctx.model,
                numLayers: numLayers,
                kvHeads: kvHeads,
                headDim: headDim,
                numKvSharedLayers: numKvSharedLayers,
                globalHeadDim: globalHeadDim,
                numGlobalKvHeads: numGlobalKvHeads,
                slidingWindowPattern: slidingWindowPattern,
                layerTypes: layerTypes
            )
        }
        guard loadEpoch == generationEpoch else { return }

        self.modelContainer = container
        self.modelId = modelId
        self.modelWeightBytes = snapshot.bytes
        self.tokenizer = snapshot.tokenizer
        self.generator = BatchGenerator(
            model: snapshot.model,
            eosTokens: snapshot.eos,
            defaultMaxTokens: defaultMaxTokens,
            prefillBatchSize: maxConcurrentRequests,
            completionBatchSize: maxConcurrentRequests
        )
        startWorker()

        // Compute per-token KV cache cost from architecture metadata in
        // config.json.  This handles:
        //   - Standard uniform models (Llama, Qwen, Mistral, Gemma 2)
        //   - GQA / MQA (fewer KV heads than query heads)
        //   - Hybrid sliding + global attention (Gemma 4, GPT-OSS)
        //   - KV sharing (Gemma 4, Gemma 3n): only non-shared layers
        //     allocate KV caches
        //   - Differing head dimensions per attention type (Gemma 4:
        //     sliding layers use head_dim, full-attention layers use
        //     global_head_dim and possibly num_global_key_value_heads)
        // Falls back to a weight-bytes heuristic when config metadata is
        // unavailable (e.g. non-HuggingFace model directories).
        let estimatedKV: Int
        if let layers = snapshot.numLayers, let kvH = snapshot.kvHeads,
           let hd = snapshot.headDim, layers > 0, kvH > 0, hd > 0 {
            estimatedKV = Self.computeKVBytesPerToken(
                numLayers: layers,
                kvHeads: kvH,
                headDim: hd,
                numKvSharedLayers: snapshot.numKvSharedLayers,
                globalHeadDim: snapshot.globalHeadDim,
                numGlobalKvHeads: snapshot.numGlobalKvHeads,
                slidingWindowPattern: snapshot.slidingWindowPattern,
                layerTypes: snapshot.layerTypes
            )
        } else {
            estimatedKV = max(snapshot.bytes / 25_000, 100_000)
        }

        // Cross-check: no real model has KV cache cost below ~1000 bytes per
        // token (even tiny 2-layer models exceed this). If config.json
        // produced an implausibly small value, log a warning and fall back
        // to the weight-bytes heuristic to avoid an absurdly large token
        // budget that could OOM the system.
        let kvFloor = 1_000
        let finalKV: Int
        if estimatedKV < kvFloor && snapshot.numLayers != nil {
            let heuristicKV = max(snapshot.bytes / 25_000, 100_000)
            FileHandle.standardError.write(Data(
                "[WARN] config.json produced implausibly small kvBytesPerToken=\(estimatedKV); falling back to heuristic=\(heuristicKV)\n".utf8
            ))
            finalKV = heuristicKV
        } else {
            finalKV = estimatedKV
        }

        self.kvBytesPerToken = finalKV
        let totalMemory = Int(ProcessInfo.processInfo.physicalMemory)
        let osReserve = 4 * 1024 * 1024 * 1024
        let safetyMargin = totalMemory / 10
        let availableForKV = totalMemory - snapshot.bytes - osReserve - safetyMargin
        if availableForKV > 0 && finalKV > 0 {
            self.dynamicTokenBudgetMax = max(availableForKV / finalKV, 1024)
        } else {
            self.dynamicTokenBudgetMax = 1024
        }
        self.dynamicMaxConcurrentRequests = min(4, maxConcurrentRequests)
        self.performanceByBatchSize.removeAll()

        // Create the planner now that tokenBudgetMax is determined.
        self.planner = makePlanner(activeTokenBudget: tokenBudgetMax)
    }

    public func unloadModel() async {
        await stopCurrentEngine()
    }

    // MARK: - Submit / cancel

    public func submit(
        request: ChatCompletionRequest,
        requestId: String? = nil
    ) async -> AsyncStream<GenerationEvent> {
        let id = requestId ?? "req-\(UUID().uuidString.prefix(12))"
        let (stream, continuation) = AsyncStream<GenerationEvent>.makeStream()

        guard generator != nil, let tk = tokenizer else {
            continuation.yield(.error("No model loaded"))
            continuation.finish()
            return stream
        }

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

        let maxTokens = Self.resolvedMaxTokens(requested: request.max_tokens, defaultMaxTokens: defaultMaxTokens)

        // Admission control: use planner when available, fall back to inline check.
        let requestBudget = promptTokens.count + maxTokens
        guard requestBudget <= tokenBudgetMax else {
            continuation.yield(.error("token_budget_exhausted: request requires \(requestBudget) tokens but only \(tokenBudgetMax) available"))
            continuation.finish()
            return stream
        }

        if let planner = self.planner {
            await refreshPlannerPolicy(activeTokenBudget: tokenBudgetMax)
            let planner = self.planner ?? planner
            let result = await planner.admit(
                id: id,
                promptTokenCount: promptTokens.count,
                maxOutputTokens: maxTokens
            )
            if case .rejected(_, let reason) = result {
                let errorMsg: String
                switch reason {
                case .requestExceedsActiveTokenBudget:
                    errorMsg = "token_budget_exhausted: request exceeds active token budget"
                case .requestExceedsBatchTokenBudget:
                    errorMsg = "token_budget_exhausted: request exceeds batch token budget"
                case .queueFull:
                    errorMsg = "token_budget_exhausted: request queue full"
                case .duplicateRequestID:
                    errorMsg = "token_budget_exhausted: duplicate request ID"
                case .invalidTokenCount:
                    errorMsg = "token_budget_exhausted: invalid token count"
                }
                continuation.yield(.error(errorMsg))
                continuation.finish()
                return stream
            }
        } else if currentTokenBudgetUsed + requestBudget > tokenBudgetMax {
            // Fallback: inline check when planner is not yet initialized (no model loaded).
            continuation.yield(.error("token_budget_exhausted: request requires \(requestBudget) tokens but only \(tokenBudgetMax - currentTokenBudgetUsed) available"))
            continuation.finish()
            return stream
        }

        if let kvBudget {
            let reserved = await kvBudget.reserve(
                requestID: id,
                kvBytesPerToken: kvBytesPerToken,
                tokenCount: requestBudget
            )
            guard reserved else {
                if let planner = self.planner {
                    await planner.cancel(requestID: id)
                }
                continuation.yield(.error("token_budget_exhausted: insufficient global KV cache headroom"))
                continuation.finish()
                return stream
            }
        }

        let temperature = request.temperature ?? 0.0
        // Pass `nil` for greedy rows so GenerationBatch.step takes its
        // vectorized fast path (one batched argMax across all rows)
        // instead of per-row slice + sample + concat. With temperature=0
        // the fallback sampler is also greedy, so the result is
        // identical -- only the dispatch path changes.
        let sampler: RowSampler? = temperature <= 0
            ? nil
            : makeRowSampler(
                temperature: temperature,
                topP: request.top_p ?? 1.0,
                topK: request.top_k ?? 0,
                seed: request.seed
            )
        pending.append(PendingRequest(
            requestId: id,
            continuation: continuation,
            promptTokens: promptTokens,
            detokenizer: NaiveStreamingDetokenizer(tokenizer: tk.inner),
            maxTokens: maxTokens,
            sampler: sampler,
            submittedAt: .now
        ))

        let scheduler = self
        continuation.onTermination = { @Sendable termination in
            if case .cancelled = termination {
                Task { await scheduler.cancel(requestId: id) }
            }
        }

        return stream
    }

    public func cancel(requestId: String) async {
        if let uid = requestIdToUid[requestId] {
            await finishRequest(uid: uid, error: "Request cancelled")
            return
        }
        guard let index = pending.firstIndex(where: { $0.requestId == requestId }) else { return }
        let entry = pending.remove(at: index)
        await releaseKVReservation(requestID: entry.requestId)
        entry.continuation.yield(.error("Request cancelled"))
        entry.continuation.finish()

        // Also remove from the planner's pending queue.
        if let planner = self.planner {
            Task { await planner.cancel(requestID: requestId) }
        }
    }

    public func cancelAll() async {
        let activeEntries = active
        let pendingEntries = pending
        active.removeAll()
        pending.removeAll()

        var releaseIDs: [String] = []
        releaseIDs.reserveCapacity(activeEntries.count + pendingEntries.count)

        for (uid, entry) in activeEntries {
            cancelledUIDs.insert(uid)
            requestIdToUid.removeValue(forKey: entry.requestId)
            releaseIDs.append(entry.requestId)
            entry.continuation.yield(.error("Scheduler shutting down"))
            entry.continuation.finish()
            if let planner = self.planner {
                let cancelledId = entry.requestId
                Task { await planner.cancel(requestID: cancelledId) }
            }
        }

        for entry in pendingEntries {
            releaseIDs.append(entry.requestId)
            entry.continuation.yield(.error("Scheduler shutting down"))
            entry.continuation.finish()
            if let planner = self.planner {
                let cancelledId = entry.requestId
                Task { await planner.cancel(requestID: cancelledId) }
            }
        }

        for requestID in releaseIDs {
            await releaseKVReservation(requestID: requestID)
        }
    }

    // MARK: - Capacity

    public func capacity() -> SchedulerCapacity {
        SchedulerCapacity(
            model: modelId,
            activeRequests: active.count,
            pendingRequests: pending.count,
            maxConcurrent: effectiveMaxConcurrentRequests,
            engineMaxConcurrent: maxConcurrentRequests,
            gpuMemoryActiveBytes: gpuMemory(.active),
            gpuMemoryPeakBytes: gpuMemory(.peak),
            gpuMemoryCacheBytes: gpuMemory(.cache),
            totalMemoryBytes: ProcessInfo.processInfo.physicalMemory
        )
    }

    public func backendCapacity() async -> BackendCapacity {
        let cap = capacity()
        let gbDivisor = 1024.0 * 1024.0 * 1024.0

        var activeTokens: Int64 = 0
        var maxTokensPotential: Int64 = 0
        for entry in active.values {
            activeTokens += Int64(entry.promptTokens + entry.completionTokens)
            maxTokensPotential += Int64(entry.promptTokens + entry.maxTokens)
        }

        let budgetMax = Int64(tokenBudgetMax)

        let slot = BackendSlotCapacity(
            model: cap.model,
            state: cap.activeRequests > 0 ? "running" : "idle",
            numRunning: UInt32(cap.activeRequests),
            numWaiting: UInt32(cap.pendingRequests),
            activeTokens: activeTokens,
            maxTokensPotential: maxTokensPotential,
            maxConcurrency: UInt32(cap.maxConcurrent),
            observedDecodeTps: observedDecodeTpsEwma,
            activeTokenBudgetUsed: Int64(activeTokenBudgetUsed),
            activeTokenBudgetMax: budgetMax,
            queuedTokenBudget: Int64(queuedTokenBudget),
            kvBytesPerToken: Int64(kvBytesPerToken)
        )
        return BackendCapacity(
            slots: [slot],
            gpuMemoryActiveGb: Double(cap.gpuMemoryActiveBytes) / gbDivisor,
            gpuMemoryPeakGb: Double(cap.gpuMemoryPeakBytes) / gbDivisor,
            gpuMemoryCacheGb: Double(cap.gpuMemoryCacheBytes) / gbDivisor,
            totalMemoryGb: Double(cap.totalMemoryBytes) / gbDivisor
        )
    }

    // MARK: - Worker (runs in a detached Task; calls into actor only briefly)

    private func startWorker() {
        workerTask?.cancel()
        let scheduler = self
        workerTask = Task.detached {
            while !Task.isCancelled {
                let didStep = await scheduler.stepEngine()
                if !didStep {
                    try? await Task.sleep(for: .milliseconds(5))
                }
            }
        }
    }

    private func stepEngine() async -> Bool {
        guard let gen = generator, let container = modelContainer else { return false }
        let epoch = generationEpoch
        await expireTimedOutPending()
        guard epoch == generationEpoch, generator === gen else {
            return false
        }
        applyCancelledRequests(to: gen)
        await admitPendingRequests(into: gen)
        guard epoch == generationEpoch, generator === gen else {
            return false
        }
        if !gen.hasWork { return false }

        let prioritizeFirstToken = shouldPrioritizeFirstToken
        let burstSteps = prioritizeFirstToken ? 1 : decodeBurstSteps
        let activeBefore = max(1, gen.activeCount)
        let startedAt = ContinuousClock.now
        engineBusy = true
        let responses: [GenerationBatchResponse] = await container.perform { _ in
            var all: [GenerationBatchResponse] = []
            all.reserveCapacity(max(1, gen.activeCount) * burstSteps)
            for _ in 0 ..< burstSteps {
                if !gen.hasWork { break }
                all.append(contentsOf: gen.next())
            }
            return all
        }
        engineBusy = false
        let elapsed = Self.seconds(between: startedAt, and: .now)
        guard epoch == generationEpoch, generator === gen else {
            return false
        }
        if !prioritizeFirstToken, !responses.isEmpty, elapsed > 0 {
            recordBatchPerformance(
                batchSize: activeBefore,
                tokenCount: responses.count,
                elapsedSeconds: elapsed
            )
        }
        applyCancelledRequests(to: gen)
        await dispatchResponses(responses, producedAt: .now)
        return true
    }

    private var shouldPrioritizeFirstToken: Bool {
        active.values.contains { $0.completionTokens == 0 }
    }

    private func admitPendingRequests(into gen: BatchGenerator) async {
        guard !pending.isEmpty else { return }
        let freeSlots = max(0, effectiveMaxConcurrentRequests - active.count)
        guard freeSlots > 0 else { return }

        var activeBudgetAfterAdmission = activeTokenBudgetUsed
        let budgetMax = tokenBudgetMax
        var batch: [PendingRequest] = []
        var rejected: [(entry: PendingRequest, error: String)] = []
        batch.reserveCapacity(freeSlots)

        var pendingIndex = 0
        while batch.count < freeSlots, pendingIndex < pending.count {
            let next = pending[pendingIndex]
            let requestBudget = next.promptTokens.count + next.maxTokens
            if requestBudget > budgetMax {
                pending.remove(at: pendingIndex)
                rejected.append((
                    entry: next,
                    error: "token_budget_exhausted: request requires \(requestBudget) tokens but only \(budgetMax) available"
                ))
                continue
            }
            if activeBudgetAfterAdmission + requestBudget > budgetMax {
                pendingIndex += 1
                continue
            }
            batch.append(pending.remove(at: pendingIndex))
            activeBudgetAfterAdmission += requestBudget
        }

        guard !batch.isEmpty else {
            await rejectPendingRequests(rejected)
            return
        }

        let assignedUids = gen.insert(
            prompts: batch.map(\.promptTokens),
            maxTokens: batch.map(\.maxTokens),
            samplers: batch.map(\.sampler)
        )

        for (uid, entry) in zip(assignedUids, batch) {
            active[uid] = ActiveRequest(
                requestId: entry.requestId,
                continuation: entry.continuation,
                detokenizer: entry.detokenizer,
                promptTokens: entry.promptTokens.count,
                completionTokens: 0,
                maxTokens: entry.maxTokens,
                firstTokenAt: nil,
                lastTokenAt: nil,
                submittedAt: entry.submittedAt
            )
            requestIdToUid[entry.requestId] = uid
        }

        if assignedUids.count < batch.count {
            for entry in batch.dropFirst(assignedUids.count) {
                rejected.append((entry: entry, error: "BatchGenerator rejected the prompt"))
            }
        }

        await rejectPendingRequests(rejected)
    }

    private func rejectPendingRequests(_ rejected: [(entry: PendingRequest, error: String)]) async {
        guard !rejected.isEmpty else { return }
        let planner = self.planner
        for rejection in rejected {
            await releaseKVReservation(requestID: rejection.entry.requestId)
            rejection.entry.continuation.yield(.error(rejection.error))
            rejection.entry.continuation.finish()
            if let planner {
                let rejectedId = rejection.entry.requestId
                Task { await planner.cancel(requestID: rejectedId) }
            }
        }
    }

    private func expireTimedOutPending(now: ContinuousClock.Instant = .now) async {
        guard !pending.isEmpty else { return }

        var stillPending: [PendingRequest] = []
        var timedOut: [PendingRequest] = []
        stillPending.reserveCapacity(pending.count)
        for entry in pending {
            if now - entry.submittedAt >= pendingTimeout {
                timedOut.append(entry)
            } else {
                stillPending.append(entry)
            }
        }
        pending = stillPending

        for entry in timedOut {
            entry.continuation.yield(.error("Request timed out waiting for capacity"))
            entry.continuation.finish()
            if let planner = self.planner {
                let timedOutId = entry.requestId
                Task { await planner.cancel(requestID: timedOutId) }
            }
        }
        for entry in timedOut {
            await releaseKVReservation(requestID: entry.requestId)
        }
    }

    private func applyCancelledRequests(to gen: BatchGenerator) {
        guard !cancelledUIDs.isEmpty else { return }
        for uid in cancelledUIDs {
            gen.cancel(uid: uid)
        }
        cancelledUIDs.removeAll()
    }

    private func stopCurrentEngine() async {
        generationEpoch &+= 1
        workerTask?.cancel()
        workerTask = nil
        generator = nil
        modelContainer = nil
        tokenizer = nil
        await cancelAll()
        modelWeightBytes = 0
        modelId = ""
        kvBytesPerToken = 400_000
        dynamicTokenBudgetMax = 0
        planner = nil
        observedDecodeTpsEwma = 0
        ewmaInitialized = false
        performanceByBatchSize.removeAll()
        dynamicMaxConcurrentRequests = min(4, maxConcurrentRequests)

        while engineBusy {
            try? await Task.sleep(for: .milliseconds(1))
        }
        cancelledUIDs.removeAll()
    }

    private func dispatchResponses(
        _ responses: [GenerationBatchResponse],
        producedAt: ContinuousClock.Instant
    ) async {
        var byUID: [Int: [GenerationBatchResponse]] = [:]
        byUID.reserveCapacity(responses.count)
        for response in responses {
            byUID[response.uid, default: []].append(response)
        }

        for uid in responses.map(\.uid) where byUID[uid] != nil {
            let rowResponses = byUID.removeValue(forKey: uid)!
            await dispatchRowResponses(rowResponses, producedAt: producedAt)
        }
    }

    private func dispatchRowResponses(
        _ responses: [GenerationBatchResponse],
        producedAt: ContinuousClock.Instant
    ) async {
        guard let first = responses.first, var entry = active[first.uid] else { return }

        var finalResponse: GenerationBatchResponse?
        for response in responses {
            entry.detokenizer.append(token: response.token)
            entry.completionTokens += 1
            if entry.firstTokenAt == nil {
                entry.firstTokenAt = producedAt
            }
            entry.lastTokenAt = producedAt
            if response.finishReason != nil {
                finalResponse = response
            }
        }

        if let chunk = entry.detokenizer.next(), !chunk.isEmpty {
            entry.continuation.yield(.chunk(chunk))
        }
        active[first.uid] = entry

        if finalResponse != nil {
            // One final flush. `NaiveStreamingDetokenizer.next()` returns
            // the substring added since the last call; once the segment is
            // fully consumed it returns "" (not nil), so calling it in a
            // loop would spin forever re-decoding the same prefix.
            if let tail = entry.detokenizer.next(), !tail.isEmpty {
                entry.continuation.yield(.chunk(tail))
            }

            let tps: Double
            if let firstTokenAt = entry.firstTokenAt, let lastTokenAt = entry.lastTokenAt,
                entry.completionTokens > 1
            {
                let decodeElapsed = lastTokenAt - firstTokenAt
                let elapsedSeconds = Double(decodeElapsed.components.seconds)
                    + Double(decodeElapsed.components.attoseconds) / 1e18
                tps = elapsedSeconds > 0
                    ? Double(entry.completionTokens - 1) / elapsedSeconds : 0
            } else {
                let elapsed = ContinuousClock.now - entry.submittedAt
                let elapsedSeconds = Double(elapsed.components.seconds)
                    + Double(elapsed.components.attoseconds) / 1e18
                tps = elapsedSeconds > 0
                    ? Double(entry.completionTokens) / elapsedSeconds : 0
            }

            if tps > 0 {
                let alpha = 0.3
                if ewmaInitialized {
                    observedDecodeTpsEwma = alpha * tps + (1 - alpha) * observedDecodeTpsEwma
                } else {
                    observedDecodeTpsEwma = tps
                    ewmaInitialized = true
                }
            }

            entry.continuation.yield(.info(
                promptTokens: entry.promptTokens,
                completionTokens: entry.completionTokens,
                tokensPerSecond: tps
            ))
            entry.continuation.finish()
            active.removeValue(forKey: first.uid)
            requestIdToUid.removeValue(forKey: entry.requestId)
            await releaseKVReservation(requestID: entry.requestId)

            // Notify planner that this request is done so its token budget
            // is released for future admissions. Use cancel() instead of
            // complete() because the planner's nextBatch() is never called
            // (BatchScheduler manages its own pending→active promotion),
            // so entries remain in the planner's pending queue. cancel()
            // removes from both pending and active; complete() only checks
            // active, causing a permanent leak that eventually triggers
            // queueFull rejection.
            if let planner = self.planner {
                let completedId = entry.requestId
                Task { await planner.cancel(requestID: completedId) }
            }
        }
    }

    private func recordBatchPerformance(
        batchSize: Int,
        tokenCount: Int,
        elapsedSeconds: Double
    ) {
        guard batchSize > 0, tokenCount > 0, elapsedSeconds > 0 else { return }

        let aggregateTps = Double(tokenCount) / elapsedSeconds
        let perRequestTps = aggregateTps / Double(batchSize)
        performanceByBatchSize[batchSize, default: AdaptiveBatchPerformanceBucket()]
            .record(aggregateTps: aggregateTps, perRequestTps: perRequestTps)
        updateDynamicMaxConcurrentRequests(observedBatchSize: batchSize)
    }

    private func updateDynamicMaxConcurrentRequests(observedBatchSize: Int) {
        dynamicMaxConcurrentRequests = adaptiveCapPolicy.nextCap(
            currentCap: dynamicMaxConcurrentRequests,
            hardCap: maxConcurrentRequests,
            observedBatchSize: observedBatchSize,
            performanceByBatchSize: performanceByBatchSize
        )
    }

    private static func seconds(
        between start: ContinuousClock.Instant,
        and end: ContinuousClock.Instant
    ) -> Double {
        let elapsed = end - start
        return Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
    }

    private func finishRequest(uid: Int, error: String) async {
        guard let entry = active.removeValue(forKey: uid) else { return }
        cancelledUIDs.insert(uid)
        let cancelledId = entry.requestId
        requestIdToUid.removeValue(forKey: cancelledId)
        await releaseKVReservation(requestID: cancelledId)
        entry.continuation.yield(.error(error))
        entry.continuation.finish()

        // Release the request's token budget in the planner.
        if let planner = self.planner {
            Task { await planner.cancel(requestID: cancelledId) }
        }
    }

    private enum MemoryKind { case active, peak, cache }

    private func releaseKVReservation(requestID: String) async {
        guard let kvBudget else { return }
        await kvBudget.release(requestID: requestID)
    }

    static func resolvedMaxTokens(requested: Int?, defaultMaxTokens: Int) -> Int {
        requested ?? defaultMaxTokens
    }

    private func makePlanner(activeTokenBudget: Int) -> BatchQueuePlanner {
        BatchQueuePlanner(
            policy: BatchSchedulingPolicy(
                maxConcurrentRequests: maxConcurrentRequests,
                maxQueuedRequests: 128,
                maxActiveTokenBudget: activeTokenBudget,
                maxTokensPerBatch: 4096
            )
        )
    }

    private func refreshPlannerPolicy(activeTokenBudget: Int) async {
        guard let planner else { return }
        let updatedPolicy = BatchSchedulingPolicy(
            maxConcurrentRequests: maxConcurrentRequests,
            maxQueuedRequests: 128,
            maxActiveTokenBudget: activeTokenBudget,
            maxTokensPerBatch: 4096
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

    static func readBoundedConfigJSON(_ url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxConfigJSONBytes + 1),
              data.count <= maxConfigJSONBytes else { return nil }
        return data
    }

    private func gpuMemory(_ kind: MemoryKind) -> Int {
        #if canImport(Metal)
        switch kind {
        case .active: return MLX.GPU.activeMemory
        case .peak: return MLX.GPU.peakMemory
        case .cache: return MLX.GPU.cacheMemory
        }
        #else
        return 0
        #endif
    }

    // MARK: - KV cache cost computation

    /// Compute total KV cache bytes per token across all layers, accounting
    /// for architecture-specific differences:
    ///
    /// - **KV sharing** (Gemma 4, Gemma 3n): only the first
    ///   `numLayers - numKvSharedLayers` layers allocate real KV caches.
    /// - **Hybrid attention** (Gemma 4, GPT-OSS): sliding-attention layers
    ///   use `headDim` / `kvHeads`, while full-attention layers can use
    ///   `globalHeadDim` / `numGlobalKvHeads`.
    /// - **Standard models** (Llama, Qwen, Mistral, Gemma 2): all layers
    ///   are uniform; degenerates to `cachedLayers * kvHeads * headDim * 4`.
    static func computeKVBytesPerToken(
        numLayers: Int,
        kvHeads: Int,
        headDim: Int,
        numKvSharedLayers: Int,
        globalHeadDim: Int?,
        numGlobalKvHeads: Int?,
        slidingWindowPattern: Int?,
        layerTypes: [String]?
    ) -> Int {
        let bytesPerElement = 2  // float16
        let kvTensors = 2        // K + V

        let cachedLayers = numLayers - numKvSharedLayers
        guard cachedLayers > 0 else { return 0 }

        // Determine per-layer attention type. Three sources of truth:
        //   1. Explicit layer_types array from config.json (Gemma 4, GPT-OSS)
        //   2. slidingWindowPattern Int: e.g. 5 means [S,S,S,S,F] repeating
        //      (Gemma 3, Gemma 3n, Gemma 4)
        //   3. Neither: assume all layers are uniform full-attention
        let resolvedLayerTypes: [String]?
        if let lt = layerTypes, lt.count >= cachedLayers {
            resolvedLayerTypes = lt
        } else if let swp = slidingWindowPattern, swp > 1 {
            // Derive the repeating pattern: first (swp-1) are sliding,
            // last one is full attention.
            var pattern = [String]()
            for i in 0..<swp {
                pattern.append(i == swp - 1 ? "full_attention" : "sliding_attention")
            }
            var types = [String]()
            while types.count < cachedLayers {
                types.append(contentsOf: pattern)
            }
            resolvedLayerTypes = Array(types.prefix(cachedLayers))
        } else {
            resolvedLayerTypes = nil
        }

        // Layer types that use fixed-size recurrent state (e.g. GatedDeltaNet/Mamba)
        // instead of per-token KV cache. These contribute zero per-token KV bytes.
        let recurrentLayerTypes: Set<String> = [
            "linear_attention",   // Qwen3.5 GatedDeltaNet
            "recurrent",          // Generic recurrent layers
        ]

        // If we have per-layer type information, sum only layers with KV cache.
        let hasHybridDims = globalHeadDim != nil && globalHeadDim != headDim
            || numGlobalKvHeads != nil && numGlobalKvHeads != kvHeads

        if let types = resolvedLayerTypes {
            var totalBytesPerToken = 0
            for i in 0..<cachedLayers {
                let layerType = types[i]

                // Recurrent layers (linear_attention, etc.) use fixed-size
                // state, not per-token KV cache. Skip them.
                if recurrentLayerTypes.contains(layerType) {
                    continue
                }

                let layerKvHeads: Int
                let layerHeadDim: Int

                if hasHybridDims && layerType == "full_attention" {
                    // Full/global attention layer with different dimensions
                    layerKvHeads = numGlobalKvHeads ?? kvHeads
                    layerHeadDim = globalHeadDim ?? headDim
                } else {
                    // Sliding attention or standard full attention
                    layerKvHeads = kvHeads
                    layerHeadDim = headDim
                }

                totalBytesPerToken += layerKvHeads * layerHeadDim * kvTensors * bytesPerElement
            }
            return totalBytesPerToken
        }

        // If we have global_head_dim but no layer type information to
        // distinguish which layers use it, conservatively use the larger
        // dimension for all cached layers.
        if let ghd = globalHeadDim, ghd > headDim {
            let maxKvHeads = max(kvHeads, numGlobalKvHeads ?? kvHeads)
            return cachedLayers * maxKvHeads * ghd * kvTensors * bytesPerElement
        }

        // Standard uniform architecture (no layer_types, no hybrid dims)
        return cachedLayers * kvHeads * headDim * kvTensors * bytesPerElement
    }
}

// MARK: - Supporting types

private struct ActiveRequest {
    let requestId: String
    let continuation: AsyncStream<GenerationEvent>.Continuation
    var detokenizer: NaiveStreamingDetokenizer
    var promptTokens: Int
    var completionTokens: Int
    let maxTokens: Int
    var firstTokenAt: ContinuousClock.Instant?
    var lastTokenAt: ContinuousClock.Instant?
    let submittedAt: ContinuousClock.Instant
}

private struct PendingRequest {
    let requestId: String
    let continuation: AsyncStream<GenerationEvent>.Continuation
    let promptTokens: [Int]
    var detokenizer: NaiveStreamingDetokenizer
    let maxTokens: Int
    let sampler: RowSampler?
    let submittedAt: ContinuousClock.Instant
}

private struct LoadSnapshot: @unchecked Sendable {
    let bytes: Int
    let eos: [[Int]]
    let tokenizer: TokenizerBox
    let model: any LanguageModel
    let numLayers: Int?
    let kvHeads: Int?
    let headDim: Int?
    let numKvSharedLayers: Int
    let globalHeadDim: Int?
    let numGlobalKvHeads: Int?
    let slidingWindowPattern: Int?
    let layerTypes: [String]?
}

private final class TokenizerBox: @unchecked Sendable {
    let inner: any MLXLMCommon.Tokenizer
    init(_ inner: any MLXLMCommon.Tokenizer) { self.inner = inner }
}
