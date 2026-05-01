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
    public let activeTokens: Int
    public let maxConcurrent: Int
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

    private var modelContainer: ModelContainer?
    private var modelId: String = ""
    private var modelWeightBytes: Int = 0

    private var tokenizer: TokenizerBox?
    private var generator: BatchGenerator?
    private var workerTask: Task<Void, Never>?

    private var active: [Int: ActiveRequest] = [:]
    private var requestIdToUid: [String: Int] = [:]

    public init(
        maxConcurrentRequests: Int = 4,
        pendingTimeout: Duration = .seconds(120),
        defaultMaxTokens: Int = 4096
    ) {
        self.maxConcurrentRequests = max(1, maxConcurrentRequests)
        self.pendingTimeout = pendingTimeout
        self.defaultMaxTokens = defaultMaxTokens
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

        cancelAll()
        self.modelContainer = container
        self.modelId = modelId

        let snapshot: LoadSnapshot = await container.perform { ctx in
            let bytes = ctx.model.parameters().flattened().reduce(0) { $0 + $1.1.nbytes }
            var eos: [[Int]] = []
            if let id = ctx.tokenizer.convertTokenToId(ctx.tokenizer.eosToken ?? "") {
                eos.append([id])
            }
            return LoadSnapshot(
                bytes: bytes,
                eos: eos,
                tokenizer: TokenizerBox(ctx.tokenizer),
                model: ctx.model
            )
        }
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
    }

    public func unloadModel() {
        cancelAll()
        workerTask?.cancel()
        workerTask = nil
        generator?.close()
        generator = nil
        modelContainer = nil
        modelId = ""
        modelWeightBytes = 0
        tokenizer = nil
    }

    // MARK: - Submit / cancel

    public func submit(
        request: ChatCompletionRequest,
        requestId: String? = nil
    ) -> AsyncStream<GenerationEvent> {
        let id = requestId ?? "req-\(UUID().uuidString.prefix(12))"
        let (stream, continuation) = AsyncStream<GenerationEvent>.makeStream()

        guard let gen = generator, let tk = tokenizer else {
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

        let maxTokens = request.max_tokens ?? defaultMaxTokens
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
        let admitStartedAt = ContinuousClock.now
        let assignedUids = gen.insert(
            prompts: [promptTokens],
            maxTokens: [maxTokens],
            samplers: [sampler]
        )
        let admittedAt = ContinuousClock.now
        guard let uid = assignedUids.first else {
            continuation.yield(.error("BatchGenerator rejected the prompt"))
            continuation.finish()
            return stream
        }

        active[uid] = ActiveRequest(
            requestId: id,
            continuation: continuation,
            detokenizer: NaiveStreamingDetokenizer(tokenizer: tk.inner),
            promptTokens: promptTokens.count,
            completionTokens: 0,
            submittedAt: admitStartedAt,
            admittedAt: admittedAt,
            firstTokenAt: nil,
            model: telemetryModelId(for: request)
        )
        requestIdToUid[id] = uid

        emitLifecycle(.schedulerAdmit, entry: active[uid]!, activeCount: active.count)

        let scheduler = self
        continuation.onTermination = { @Sendable termination in
            if case .cancelled = termination {
                Task { await scheduler.cancel(requestId: id) }
            }
        }

        return stream
    }

    public func cancel(requestId: String) {
        guard let uid = requestIdToUid[requestId] else { return }
        finishRequest(uid: uid, error: "Request cancelled")
    }

    public func cancelAll() {
        let uids = Array(active.keys)
        for uid in uids {
            finishRequest(uid: uid, error: "Scheduler shutting down")
        }
    }

    // MARK: - Capacity

    public func capacity() -> SchedulerCapacity {
        let counters = capacityCounters()
        return SchedulerCapacity(
            model: modelId,
            activeRequests: counters.activeRequests,
            pendingRequests: counters.pendingRequests,
            activeTokens: counters.activeTokens,
            maxConcurrent: maxConcurrentRequests,
            gpuMemoryActiveBytes: gpuMemory(.active),
            gpuMemoryPeakBytes: gpuMemory(.peak),
            gpuMemoryCacheBytes: gpuMemory(.cache),
            totalMemoryBytes: ProcessInfo.processInfo.physicalMemory
        )
    }

    public func backendCapacity() -> BackendCapacity {
        let cap = capacity()
        let gbDivisor = 1024.0 * 1024.0 * 1024.0
        let slot = BackendSlotCapacity(
            model: cap.model,
            state: cap.activeRequests > 0 ? "running" : "idle",
            numRunning: UInt32(cap.activeRequests),
            numWaiting: UInt32(cap.pendingRequests),
            activeTokens: Int64(cap.activeTokens),
            maxTokensPotential: Int64(defaultMaxTokens * maxConcurrentRequests)
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
        if !gen.hasWork { return false }

        let responses: [GenerationBatchResponse] = await container.perform { _ in
            gen.next()
        }
        for r in responses {
            dispatchResponse(r)
        }
        return true
    }

    private func dispatchResponse(_ response: GenerationBatchResponse) {
        guard var entry = active[response.uid] else { return }

        entry.detokenizer.append(token: response.token)
        entry.completionTokens += 1
        if entry.firstTokenAt == nil {
            entry.firstTokenAt = .now
            emitLifecycle(.firstToken, entry: entry, activeCount: active.count)
        }
        if let chunk = entry.detokenizer.next() {
            entry.continuation.yield(.chunk(chunk))
        }
        active[response.uid] = entry

        if response.finishReason != nil {
            // One final flush. `NaiveStreamingDetokenizer.next()` returns
            // the substring added since the last call; once the segment is
            // fully consumed it returns "" (not nil), so calling it in a
            // loop would spin forever re-decoding the same prefix.
            if let tail = entry.detokenizer.next(), !tail.isEmpty {
                entry.continuation.yield(.chunk(tail))
            }

            let elapsed = ContinuousClock.now - entry.submittedAt
            let elapsedSeconds = Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1e18
            let tps = elapsedSeconds > 0
                ? Double(entry.completionTokens) / elapsedSeconds : 0

            entry.continuation.yield(.info(
                promptTokens: entry.promptTokens,
                completionTokens: entry.completionTokens,
                tokensPerSecond: tps
            ))
            entry.continuation.finish()
            active.removeValue(forKey: response.uid)
            requestIdToUid.removeValue(forKey: entry.requestId)
            emitLifecycle(.inferenceComplete, entry: entry, activeCount: active.count)
        }
    }

    private func finishRequest(uid: Int, error: String) {
        guard let entry = active.removeValue(forKey: uid) else { return }
        requestIdToUid.removeValue(forKey: entry.requestId)
        entry.continuation.yield(.error(error))
        entry.continuation.finish()
        let stage: InferenceLifecycleTelemetryStage = error == "Request cancelled"
            ? .inferenceCancel
            : .inferenceError
        emitLifecycle(stage, entry: entry, activeCount: active.count, error: error, reason: error)
    }

    private func capacityCounters() -> SchedulerCapacityCounters {
        SchedulerCapacityCounters.from(active.values.map { entry in
            InferenceRequestProgress(
                promptTokens: entry.promptTokens,
                completionTokens: entry.completionTokens,
                firstTokenReceived: entry.firstTokenAt != nil
            )
        })
    }

    private func emitLifecycle(
        _ stage: InferenceLifecycleTelemetryStage,
        entry: ActiveRequest,
        activeCount: Int,
        error: String? = nil,
        reason: String? = nil
    ) {
        TelemetryClient.shared.emit(InferenceLifecycleTelemetry.event(
            stage,
            snapshot: InferenceLifecycleTelemetrySnapshot(
                requestId: entry.requestId,
                model: entry.model,
                promptTokens: entry.promptTokens,
                completionTokens: entry.completionTokens,
                queueMilliseconds: InferenceLifecycleTelemetry.milliseconds(entry.admittedAt - entry.submittedAt),
                admitMilliseconds: InferenceLifecycleTelemetry.milliseconds(entry.admittedAt - entry.submittedAt),
                ttftMilliseconds: entry.firstTokenAt.map { InferenceLifecycleTelemetry.milliseconds($0 - entry.submittedAt) },
                totalMilliseconds: InferenceLifecycleTelemetry.milliseconds(ContinuousClock.now - entry.submittedAt),
                activeCount: activeCount
            ),
            error: error,
            reason: reason
        ))
    }

    private func telemetryModelId(for request: ChatCompletionRequest) -> String {
        if !request.model.isEmpty { return request.model }
        return modelId
    }

    private enum MemoryKind { case active, peak, cache }

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
}

// MARK: - Supporting types

private struct ActiveRequest {
    let requestId: String
    let continuation: AsyncStream<GenerationEvent>.Continuation
    var detokenizer: NaiveStreamingDetokenizer
    var promptTokens: Int
    var completionTokens: Int
    let submittedAt: ContinuousClock.Instant
    let admittedAt: ContinuousClock.Instant
    var firstTokenAt: ContinuousClock.Instant?
    let model: String
}

private struct LoadSnapshot: @unchecked Sendable {
    let bytes: Int
    let eos: [[Int]]
    let tokenizer: TokenizerBox
    let model: any LanguageModel
}

private final class TokenizerBox: @unchecked Sendable {
    let inner: any MLXLMCommon.Tokenizer
    init(_ inner: any MLXLMCommon.Tokenizer) { self.inner = inner }
}
