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
    private var pending: [PendingRequest] = []
    private var cancelledUIDs = Set<Int>()
    private var generationEpoch: UInt64 = 0
    private var engineBusy = false

    /// Once every active row has received its first token, run several decode
    /// steps per actor/model hop. A single hop per token starves Gemma-class
    /// models because the CPU actor round trip is larger than one GPU step.
    private let decodeBurstSteps = 32


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

        await stopCurrentEngine()
        let loadEpoch = generationEpoch

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
    }

    public func unloadModel() async {
        await stopCurrentEngine()
    }

    // MARK: - Submit / cancel

    public func submit(
        request: ChatCompletionRequest,
        requestId: String? = nil
    ) -> AsyncStream<GenerationEvent> {
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

    public func cancel(requestId: String) {
        if let uid = requestIdToUid[requestId] {
            finishRequest(uid: uid, error: "Request cancelled")
            return
        }
        guard let index = pending.firstIndex(where: { $0.requestId == requestId }) else { return }
        let entry = pending.remove(at: index)
        entry.continuation.yield(.error("Request cancelled"))
        entry.continuation.finish()
    }

    public func cancelAll() {
        let uids = Array(active.keys)
        for uid in uids {
            finishRequest(uid: uid, error: "Scheduler shutting down")
        }
        for entry in pending {
            entry.continuation.yield(.error("Scheduler shutting down"))
            entry.continuation.finish()
        }
        pending.removeAll()
    }

    // MARK: - Capacity

    public func capacity() -> SchedulerCapacity {
        SchedulerCapacity(
            model: modelId,
            activeRequests: active.count + cancelledUIDs.count,
            pendingRequests: pending.count,
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
            activeTokens: 0,
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
        let epoch = generationEpoch
        expireTimedOutPending()
        applyCancelledRequests(to: gen)
        admitPendingRequests(into: gen)
        if !gen.hasWork { return false }

        let burstSteps = shouldPrioritizeFirstToken ? 1 : decodeBurstSteps
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
        guard epoch == generationEpoch, generator === gen else {
            return false
        }
        applyCancelledRequests(to: gen)
        dispatchResponses(responses, producedAt: .now)
        return true
    }

    private var shouldPrioritizeFirstToken: Bool {
        active.values.contains { $0.completionTokens == 0 }
    }

    private func admitPendingRequests(into gen: BatchGenerator) {
        guard !pending.isEmpty else { return }
        let freeSlots = max(0, maxConcurrentRequests - active.count)
        guard freeSlots > 0 else { return }

        let batch = Array(pending.prefix(freeSlots))
        pending.removeFirst(batch.count)

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
                firstTokenAt: nil,
                lastTokenAt: nil,
                submittedAt: entry.submittedAt
            )
            requestIdToUid[entry.requestId] = uid
        }

        if assignedUids.count < batch.count {
            for entry in batch.dropFirst(assignedUids.count) {
                entry.continuation.yield(.error("BatchGenerator rejected the prompt"))
                entry.continuation.finish()
            }
        }
    }

    private func expireTimedOutPending(now: ContinuousClock.Instant = .now) {
        guard !pending.isEmpty else { return }

        var stillPending: [PendingRequest] = []
        stillPending.reserveCapacity(pending.count)
        for entry in pending {
            if now - entry.submittedAt >= pendingTimeout {
                entry.continuation.yield(.error("Request timed out waiting for capacity"))
                entry.continuation.finish()
            } else {
                stillPending.append(entry)
            }
        }
        pending = stillPending
    }

    private func applyCancelledRequests(to gen: BatchGenerator) {
        guard !cancelledUIDs.isEmpty else { return }
        for uid in cancelledUIDs {
            gen.cancel(uid: uid)
        }
        cancelledUIDs.removeAll()
    }

    private func stopCurrentEngine() async {
        cancelAll()
        generationEpoch &+= 1
        workerTask?.cancel()
        workerTask = nil
        generator = nil
        modelContainer = nil
        tokenizer = nil
        modelWeightBytes = 0
        modelId = ""

        while engineBusy {
            try? await Task.sleep(for: .milliseconds(1))
        }
        cancelledUIDs.removeAll()
    }

    private func dispatchResponses(
        _ responses: [GenerationBatchResponse],
        producedAt: ContinuousClock.Instant
    ) {
        var byUID: [Int: [GenerationBatchResponse]] = [:]
        byUID.reserveCapacity(responses.count)
        for response in responses {
            byUID[response.uid, default: []].append(response)
        }

        for uid in responses.map(\.uid) where byUID[uid] != nil {
            let rowResponses = byUID.removeValue(forKey: uid)!
            dispatchRowResponses(rowResponses, producedAt: producedAt)
        }
    }

    private func dispatchRowResponses(
        _ responses: [GenerationBatchResponse],
        producedAt: ContinuousClock.Instant
    ) {
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

            entry.continuation.yield(.info(
                promptTokens: entry.promptTokens,
                completionTokens: entry.completionTokens,
                tokensPerSecond: tps
            ))
            entry.continuation.finish()
            active.removeValue(forKey: first.uid)
            requestIdToUid.removeValue(forKey: entry.requestId)
        }
    }

    private func finishRequest(uid: Int, error: String) {
        guard let entry = active.removeValue(forKey: uid) else { return }
        cancelledUIDs.insert(uid)
        requestIdToUid.removeValue(forKey: entry.requestId)
        entry.continuation.yield(.error(error))
        entry.continuation.finish()
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
}

private final class TokenizerBox: @unchecked Sendable {
    let inner: any MLXLMCommon.Tokenizer
    init(_ inner: any MLXLMCommon.Tokenizer) { self.inner = inner }
}
