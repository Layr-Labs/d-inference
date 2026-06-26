/// ClusterBatchServer -- the continuous-batching ring server (Phase 3).
///
/// Drives the batched ring decode loop under a per-step composition control
/// round. The head computes each step's batch composition (evict finished rows,
/// admit queued rows) and broadcasts it; peers replay it. Every rank, every
/// step, in identical order:
///   1. all_gather the composition vector (peers contribute zeros).
///   2. shutdown -> return; idle -> continue (keeps the collective alive).
///   3. evict: filterBatch(keepIndices) on the local batched KV caches.
///   4. admit: if nAdmit>0, prefill the admitted rows (their own ring hops) and
///      extend the live caches; the tail samples their first tokens.
///   5. decode: one [B,1,hidden] step; tail samples [B]; all_gather the [B]
///      token vector so every rank advances all rows.
///
/// This reuses the proven transport (send/recvLike/allGather + sealed channels)
/// and the batched shard primitives validated single-node in Phase 1/2.

import Foundation
import MLX

public struct ClusterBatchServer {
    let plan: ClusterPlan
    let group: MLXDistributedGroup
    let shard: any PipelineModelShard
    let hiddenSize: Int
    let eosTokenIds: Set<Int>

    public init(plan: ClusterPlan, group: MLXDistributedGroup, shard: any PipelineModelShard,
                hiddenSize: Int, eosTokenIds: Set<Int>) {
        self.plan = plan
        self.group = group
        self.shard = shard
        self.hiddenSize = hiddenSize
        self.eosTokenIds = eosTokenIds
    }

    private var headRank: Int { 0 }
    private var tailRank: Int { plan.worldSize - 1 }

    private func toI32(_ d: Data) -> MLXArray { MLXArray(d.map { Int32($0) }, [d.count]) }
    private func toBytes(_ a: MLXArray) -> Data { Data(a.asArray(Int32.self).map { UInt8(truncatingIfNeeded: $0) }) }
    private func sealedLen(batch B: Int, width: Int) -> Int { 14 + B * width * hiddenSize * 2 + 28 }

    /// Broadcast (head) / receive (peer) the next step's composition over the
    /// ring. The head passes `next`; peers pass nil and read the head's slot.
    public func exchangeComposition(_ next: ClusterBatchComposition?) throws -> ClusterBatchComposition {
        let vec: [Int32]
        if plan.isHead, let next { vec = next.encodeVector() }
        else { vec = [Int32](repeating: 0, count: BATCH_CTRL_WIDTH) }
        let gathered = try group.allGather(MLXArray(vec, [BATCH_CTRL_WIDTH]))
        gathered.eval()
        let flat = gathered.asArray(Int32.self)
        let slot = Array(flat.prefix(BATCH_CTRL_WIDTH))   // head is rank 0
        return ClusterBatchComposition.decode(slot)
    }

    /// Build the AEAD frame context for ring hop frame number `frameSeq`. The
    /// sealing/opening channels enforce `context.seq == internal counter` AND an
    /// exact AAD match, so BOTH sides must derive identical (requestId,
    /// layerRange, seq) per frame. We use a constant requestId + a single
    /// monotonic frameSeq that increments on EVERY hop (admit and decode alike),
    /// and a layerRange tied to the hop edge (rank N -> N+1), which both the
    /// sender (rank N) and receiver (rank N+1) compute identically.
    private func hopContext(frameSeq: UInt64, senderRank: Int) -> ClusterFrameContext {
        ClusterFrameContext(clusterId: plan.clusterId, requestId: "batch",
                            layerRange: "hop-\(senderRank)", seq: frameSeq)
    }

    /// One ring hop for a `[B, width, hidden]` activation. `frameSeq` MUST match
    /// the channel's running counter (one increment per hop on each side).
    private func recvActivation(B: Int, width: Int, frameSeq: UInt64,
                                openCh: ClusterOpeningChannel) throws -> MLXArray {
        let ctx = hopContext(frameSeq: frameSeq, senderRank: plan.rank - 1)
        let template = MLXArray.zeros([sealedLen(batch: B, width: width)], dtype: .int32)
        let cipherArr = try group.recvLike(template, from: plan.rank - 1)
        cipherArr.eval()
        return try ActivationCodec.decode(openCh.open(toBytes(cipherArr), context: ctx))
    }

    private func sendActivation(_ hidden: MLXArray, frameSeq: UInt64,
                                sealCh: ClusterSealingChannel) throws {
        let ctx = hopContext(frameSeq: frameSeq, senderRank: plan.rank)
        let sealed = try sealCh.seal(ActivationCodec.encode(hidden.asType(.bfloat16)), context: ctx)
        let dep = try group.send(toI32(sealed), to: plan.rank + 1)
        dep.eval()
    }

    /// Head-side helpers used by the scheduler (public seams).
    public func sendHead(_ hidden: MLXArray, frameSeq: UInt64, sealCh: ClusterSealingChannel) throws {
        try sendActivation(hidden, frameSeq: frameSeq, sealCh: sealCh)
    }
    public func recvHead(B: Int, width: Int, frameSeq: UInt64, openCh: ClusterOpeningChannel) throws -> MLXArray {
        try recvActivation(B: B, width: width, frameSeq: frameSeq, openCh: openCh)
    }

    public func broadcast(_ hidden: MLXArray?, B: Int) throws -> [Int] {
        try broadcastTokens(hidden, B: B)
    }

    /// Sample the tail's `[B]` next tokens and all_gather them so every rank
    /// learns all rows' next tokens. Non-tail ranks contribute zeros.
    private func broadcastTokens(_ hidden: MLXArray?, B: Int) throws -> [Int] {
        var tokenVec = MLXArray([Int32](repeating: 0, count: B), [B])
        if plan.isTail, let hidden {
            let logits = shard.projectToLogitsBatched(hidden)
            let ids = argMax(logits, axis: logits.ndim - 1)
            ids.eval()
            let flat = ids.asArray(Int32.self)
            if flat.count == B { tokenVec = MLXArray(flat, [B]) }
            else { tokenVec = MLXArray(Array(flat.suffix(B)), [B]) }
        }
        let gathered = try group.allGather(tokenVec)
        gathered.eval()
        let all = gathered.asArray(Int32.self)
        let base = tailRank * B
        return (0..<B).map { Int(all[base + $0]) }
    }

    // MARK: - Peer loop

    /// PEER loop: replay the head's per-step composition until shutdown. Peers
    /// have no scheduler; they apply evict/admit/decode exactly as the head
    /// dictates, keeping their local KV caches row-aligned with the head's.
    public func runBatchedPeerLoop(makeChannels: () -> (ClusterSealingChannel?, ClusterOpeningChannel?)) throws {
        let (sealCh, openCh) = makeChannels()
        // Independent per-direction counters: recvSeq tracks the OPENING channel
        // (frames received from prevRank), sealSeq tracks the SEALING channel
        // (frames sent to nextRank). Each must match its channel's internal
        // counter and the matching side's seq exactly.
        var recvSeq: UInt64 = 0
        var sealSeq: UInt64 = 0
        var liveB = 0
        var started = false

        // Dead-ring backoff — same rationale as ClusterServer.runPeerLoop: a live
        // head blocks the peer in the composition all_gather (no spin), but a dead
        // head makes it throw immediately. Back off on consecutive failures and
        // exit rather than busy-spin a CPU core for the life of the process.
        let maxConsecutiveFailures = 50
        let backoffCapSeconds = 5.0
        var consecutiveFailures = 0

        while true {
            let comp: ClusterBatchComposition
            do {
                comp = try exchangeComposition(nil)
            } catch {
                consecutiveFailures += 1
                if consecutiveFailures >= maxConsecutiveFailures { throw error }
                let delay = min(backoffCapSeconds, 0.01 * pow(2.0, Double(min(consecutiveFailures, 9))))
                Thread.sleep(forTimeInterval: delay)
                continue
            }
            consecutiveFailures = 0
            switch comp.command {
            case .shutdown: return
            case .idle: continue
            case .step: break
            }

            // 1. Evict. Only filter when there's a live batch AND the keep set
            //    actually changes it. When keepIndices is empty (batch fully
            //    drained) we must NOT call filter with [] — BatchKVCache.filter
            //    does leftPadding.min() which traps on a zero-size array. Instead
            //    re-init a fresh empty batch so the next admit starts clean.
            if comp.keepIndices.isEmpty {
                if liveB > 0 || !started { shard.beginBatch(leftPadding: []); started = true }
            } else {
                if !started { shard.beginBatch(leftPadding: []); started = true }
                if comp.keepIndices.count != liveB || comp.keepIndices != Array(0..<liveB) {
                    shard.filterBatch(keepIndices: comp.keepIndices)
                }
            }
            var B = comp.keepIndices.count

            // 2. Admit: prefill admitted rows over the ring + extend caches.
            if !comp.admit.isEmpty {
                let nAdmit = comp.admit.count
                let prefillW = comp.admit.map(\.promptTokens.count).max() ?? 0
                let leftPad = comp.admit.map(\.leftPadding)
                let hidden = try recvActivation(B: nAdmit, width: prefillW, frameSeq: recvSeq, openCh: openCh!)
                recvSeq += 1
                let out = shard.admitPrefill(hidden, leftPadding: leftPad)
                if !plan.isTail {
                    try sendActivation(out, frameSeq: sealSeq, sealCh: sealCh!)
                    sealSeq += 1
                }
                _ = try broadcastTokens(plan.isTail ? out : nil, B: nAdmit)
                B += nAdmit
            }

            // 3. Decode step over the full live batch B.
            liveB = B
            if B == 0 { continue }
            let hidden = try recvActivation(B: B, width: 1, frameSeq: recvSeq, openCh: openCh!)
            recvSeq += 1
            let out = shard.runOwnedLayersBatched(hidden)
            if !plan.isTail {
                try sendActivation(out, frameSeq: sealSeq, sealCh: sealCh!)
                sealSeq += 1
            }
            _ = try broadcastTokens(plan.isTail ? out : nil, B: B)
        }
    }
}
