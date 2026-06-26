/// ClusterBatchScheduler -- the HEAD-side continuous-batching scheduler
/// (Phase 3). Mirrors the single-node `BatchGenerator` (queue → admit → decode →
/// evict) but drives the RING primitives instead of `model.callAsFunction`.
///
/// The head is the only rank with a coordinator connection and the request
/// queue. Each step it: evicts finished rows, admits queued rows (prefill), runs
/// one decode step, samples per-row tokens, and routes each token to its
/// request's stream. It broadcasts the composition so peers stay row-aligned.
///
/// Concurrency model: `enqueue` is called from the coordinator event loop
/// (any thread); `run` is the single dedicated ring thread (the only one that
/// touches MLX collectives, exactly like the B=1 cluster-provider design).

import Foundation
import MLX

/// A request submitted to the batched scheduler.
public struct ClusterBatchRequest: Sendable {
    public let requestId: String
    public let promptTokens: [Int]
    public let maxTokens: Int
    public init(requestId: String, promptTokens: [Int], maxTokens: Int) {
        self.requestId = requestId
        self.promptTokens = promptTokens
        self.maxTokens = maxTokens
    }
}

/// Per-token callback (head): (requestId, tokenId).
public typealias ClusterBatchOnToken = (String, Int) -> Void
/// Completion callback (head): (requestId, totalGeneratedTokens).
public typealias ClusterBatchOnComplete = (String, Int) -> Void

public final class ClusterBatchScheduler: @unchecked Sendable {
    private let server: ClusterBatchServer
    private let plan: ClusterPlan
    private let group: MLXDistributedGroup
    private let shard: any PipelineModelShard
    private let hiddenSize: Int
    private let eosTokenIds: Set<Int>
    private let maxConcurrent: Int

    // Shared queue (multi-producer).
    private let lock = NSLock()
    private var queue: [ClusterBatchRequest] = []
    private var shuttingDown = false

    // Active batch rows (ring thread only) — order MUST match peers' cache order.
    private struct Row { let requestId: String; let maxTokens: Int; var position: Int; var generated: Int; var lastToken: Int; var done: Bool }
    private var rows: [Row] = []

    public init(server: ClusterBatchServer, plan: ClusterPlan, group: MLXDistributedGroup,
                shard: any PipelineModelShard, hiddenSize: Int, eosTokenIds: Set<Int>,
                maxConcurrent: Int = 8) {
        self.server = server
        self.plan = plan
        self.group = group
        self.shard = shard
        self.hiddenSize = hiddenSize
        self.eosTokenIds = eosTokenIds
        self.maxConcurrent = maxConcurrent
    }

    public func enqueue(_ req: ClusterBatchRequest) {
        lock.lock(); queue.append(req); lock.unlock()
    }

    public func requestShutdown() {
        lock.lock(); shuttingDown = true; lock.unlock()
    }

    private func drainQueue(upTo n: Int) -> [ClusterBatchRequest] {
        guard n > 0 else { return [] }
        lock.lock(); defer { lock.unlock() }
        let take = min(n, queue.count)
        let out = Array(queue.prefix(take))
        queue.removeFirst(take)
        return out
    }

    private var isShuttingDown: Bool { lock.lock(); defer { lock.unlock() }; return shuttingDown }

    /// The ring thread. Loops the composition control round + batched decode
    /// until shutdown. Calls `onToken`/`onComplete` for each row's output.
    public func run(makeChannels: () -> (ClusterSealingChannel?, ClusterOpeningChannel?),
                    onToken: ClusterBatchOnToken, onComplete: ClusterBatchOnComplete) throws {
        let (sealCh, openCh) = makeChannels()
        var stepCounter = 0
        var sealSeq: UInt64 = 0   // head is rank 0: only seals (sends). One increment per hop.
        var recvSeq: UInt64 = 0   // used only if head is also tail (worldSize 1) — unused in 2-node
        _ = openCh; _ = recvSeq
        var started = false

        while true {
            if isShuttingDown && rows.isEmpty && queueIsEmpty() {
                _ = try server.exchangeComposition(.shutdown)
                return
            }

            // 1. Compute evictions: rows that finished last step drop out.
            let keepIndices = rows.enumerated().filter { !$0.element.done }.map { $0.offset }
            let survivors = keepIndices.map { rows[$0] }

            // 2. Admit from queue up to capacity.
            let capacity = maxConcurrent - survivors.count
            let admitted = drainQueue(upTo: capacity)
            let admitRows = admitted.map { req -> ClusterAdmitRow in
                ClusterAdmitRow(promptTokens: req.promptTokens, leftPadding: 0, maxTokens: req.maxTokens)
            }

            // Idle keepalive when there's nothing to do.
            if survivors.isEmpty && admitRows.isEmpty {
                _ = try server.exchangeComposition(.idle)
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }

            // 3. Broadcast composition.
            let bNext = survivors.count + admitRows.count
            let comp = ClusterBatchComposition(
                command: .step, bNext: bNext, keepIndices: keepIndices, admit: admitRows)
            _ = try server.exchangeComposition(comp)

            let prevLive = rows.count

            // 4. Apply eviction locally (head), keeping rows row-aligned with peers.
            //    Empty keep set => batch fully drained: re-init a fresh empty
            //    batch (filter with [] traps in BatchKVCache.min). Otherwise
            //    filter only when the keep set actually changes the batch.
            if keepIndices.isEmpty {
                if prevLive > 0 || !started { shard.beginBatch(leftPadding: []); started = true }
            } else {
                if !started { shard.beginBatch(leftPadding: []); started = true }
                if keepIndices != Array(0..<prevLive) {
                    shard.filterBatch(keepIndices: keepIndices)
                }
            }
            rows = survivors

            // 5. Admit: embed + prefill admitted rows over the ring, sample first tokens.
            if !admitRows.isEmpty {
                let prompts = admitRows.map(\.promptTokens)
                let leftPad = admitRows.map(\.leftPadding)
                let embedded = shard.embedBatch(rows: prompts, leftPadding: leftPad)
                let out = shard.admitPrefill(embedded, leftPadding: leftPad)
                if !plan.isTail {
                    try server.sendHead(out, frameSeq: sealSeq, sealCh: sealCh!)
                    sealSeq += 1
                }
                let firstTokens = try server.broadcast(plan.isTail ? out : nil, B: admitRows.count)
                for (i, req) in admitted.enumerated() {
                    var r = Row(requestId: req.requestId, maxTokens: req.maxTokens,
                                position: req.promptTokens.count, generated: 0,
                                lastToken: firstTokens[i], done: false)
                    r.generated = 1
                    onToken(req.requestId, firstTokens[i])
                    if eosTokenIds.contains(firstTokens[i]) || r.generated >= r.maxTokens {
                        r.done = true; onComplete(req.requestId, r.generated)
                    }
                    rows.append(r)
                }
            }

            // 6. Decode step over the full live batch.
            let B = rows.count
            if B == 0 { stepCounter += 1; continue }
            let lastTokens = rows.map(\.lastToken)
            let embedded = shard.embedBatch(rows: lastTokens.map { [$0] },
                                            leftPadding: Array(repeating: 0, count: B))
            let out = shard.runOwnedLayersBatched(embedded)
            if !plan.isTail {
                try server.sendHead(out, frameSeq: sealSeq, sealCh: sealCh!)
                sealSeq += 1
            }
            let toks = try server.broadcast(plan.isTail ? out : nil, B: B)
            for i in 0..<B where !rows[i].done {
                rows[i].lastToken = toks[i]
                rows[i].generated += 1
                rows[i].position += 1
                onToken(rows[i].requestId, toks[i])
                if eosTokenIds.contains(toks[i]) || rows[i].generated >= rows[i].maxTokens {
                    rows[i].done = true
                    onComplete(rows[i].requestId, rows[i].generated)
                }
            }
            stepCounter += 1
        }
    }

    private func queueIsEmpty() -> Bool { lock.lock(); defer { lock.unlock() }; return queue.isEmpty }
}
