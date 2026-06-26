/// ClusterBatchPipeline -- the BATCHED ring decode loop (continuous-batching
/// Phase 1: static, equal-length batch).
///
/// Mirrors `ClusterPipeline` collective-for-collective — the same lockstep
/// discipline that prevents deadlock — but carries a batch of B rows:
///   - the head embeds a `[B, width, hidden]` activation (one row per request),
///   - the ring hop ships `[B, width, hidden]` (sealed as ONE AEAD blob/step),
///   - the tail samples `[B, vocab] -> [B]` next tokens and `all_gather`s the
///     whole `[B]` vector so every rank advances all rows together.
///
/// Decode is memory-bandwidth-bound: the per-step weight streaming is the same
/// whether B=1 or B=8, so B rows produce ~B tokens in ~one step's wall-clock —
/// the throughput win. Phase 1 keeps B fixed for the whole generation (no
/// mid-flight admit/evict) and assumes equal-length rows (leftPadding all 0), so
/// the plain causal mask in the shard is correct. Ragged positions (Phase 2) and
/// continuous admit/evict (Phase 3) build on this.
///
/// IMPORTANT: every rank must call `beginBatch` (to allocate the batched KV
/// caches) with the SAME row count before `generateBatch`, and call the same
/// collectives in the same order — identical to ClusterPipeline's invariant.

import Foundation
import MLX

public struct ClusterBatchPipeline {
    let plan: ClusterPlan
    let group: MLXDistributedGroup
    let shard: any PipelineModelShard
    let hiddenSize: Int
    let sealCh: ClusterSealingChannel?   // toward nextRank (nil on tail)
    let openCh: ClusterOpeningChannel?   // from prevRank (nil on head)

    public init(
        plan: ClusterPlan, group: MLXDistributedGroup, shard: any PipelineModelShard,
        hiddenSize: Int, sealCh: ClusterSealingChannel?, openCh: ClusterOpeningChannel?
    ) {
        self.plan = plan
        self.group = group
        self.shard = shard
        self.hiddenSize = hiddenSize
        self.sealCh = sealCh
        self.openCh = openCh
    }

    private var headRank: Int { 0 }
    private var tailRank: Int { plan.worldSize - 1 }

    private func toI32(_ d: Data) -> MLXArray { MLXArray(d.map { Int32($0) }, [d.count]) }
    private func toBytes(_ a: MLXArray) -> Data { Data(a.asArray(Int32.self).map { UInt8(truncatingIfNeeded: $0) }) }

    /// Ciphertext length for a `[B, width, hidden]` bf16 activation:
    /// header (2 + ndim*4, ndim=3 -> 14) + payload (B*width*hidden*2) + AEAD (28).
    private func sealedLen(batch B: Int, width: Int) -> Int { 14 + B * width * hiddenSize * 2 + 28 }

    /// Run ONE greedy batched generation for `prompts` (B rows of EQUAL length),
    /// up to `maxTokens`. `onToken(row, tokenId)` fires on the head per produced
    /// token per row. EVERY rank runs this in lockstep. Returns the per-row
    /// generated token id arrays (head; peers get empty rows).
    ///
    /// Phase 1 contract: all rows have the same prompt length; the generation
    /// runs until every row has hit an EOS or `maxTokens` is reached. A row that
    /// hits EOS early keeps stepping (its later tokens are caller-trimmed) — no
    /// mid-flight eviction yet.
    public func generateBatch(
        prompts: [[Int]], maxTokens: Int, requestId: String,
        eosTokenIds: Set<Int>, onToken: (Int, Int) -> Void
    ) throws -> [[Int]] {
        let B = prompts.count
        precondition(B > 0, "empty batch")
        let promptLen = prompts[0].count
        precondition(prompts.allSatisfy { $0.count == promptLen },
                     "Phase 1 requires equal-length rows; got \(prompts.map(\.count))")

        // Allocate batched KV caches for B rows (equal length -> no left padding).
        let zeroPad = Array(repeating: 0, count: B)
        shard.beginBatch(leftPadding: zeroPad)

        var generated = Array(repeating: [Int](), count: B)
        var lastTokens = [Int]()         // length B, the previous step's tokens
        var rowDone = Array(repeating: false, count: B)

        for step in 0..<maxTokens {
            let width = step == 0 ? promptLen : 1

            let inCtx = ClusterFrameContext(
                clusterId: plan.clusterId, requestId: requestId,
                layerRange: "hop-\(plan.rank == headRank ? headRank : plan.rank - 1)", seq: UInt64(step))

            var hidden: MLXArray
            if plan.isHead {
                let rows: [[Int]] = step == 0 ? prompts : lastTokens.map { [$0] }
                hidden = shard.embedBatch(rows: rows, leftPadding: zeroPad)
            } else {
                let template = MLXArray.zeros([sealedLen(batch: B, width: width)], dtype: .int32)
                let cipherArr = try group.recvLike(template, from: plan.rank - 1)
                cipherArr.eval()
                let plain = try openCh!.open(toBytes(cipherArr), context: inCtx)
                hidden = try ActivationCodec.decode(plain)
            }
            hidden = shard.runOwnedLayersBatched(hidden)

            if !plan.isTail {
                let outCtx = ClusterFrameContext(
                    clusterId: plan.clusterId, requestId: requestId,
                    layerRange: "hop-\(plan.rank)", seq: UInt64(step))
                let sealed = try sealCh!.seal(ActivationCodec.encode(hidden.asType(.bfloat16)), context: outCtx)
                let dep = try group.send(toI32(sealed), to: plan.rank + 1)
                dep.eval()
            }

            // Token broadcast — every rank all_gathers a [B] vector. The tail
            // fills its [B] with sampled tokens; peers contribute zeros. After
            // gather, the tail's slot holds the B next tokens for every rank.
            var tokenVec = MLXArray([Int32](repeating: 0, count: B), [B])
            if plan.isTail {
                // projectToLogitsBatched is lastPositionOnly -> [B, 1, vocab].
                // argMax over the vocab axis -> [B, 1]; flattening gives exactly
                // B values, one next-token per row, in row order.
                let logits = shard.projectToLogitsBatched(hidden)
                let ids = argMax(logits, axis: logits.ndim - 1)
                ids.eval()
                let flat = ids.asArray(Int32.self)
                precondition(flat.count == B,
                             "tail sampled \(flat.count) tokens, expected B=\(B) (lastPositionOnly?)")
                tokenVec = MLXArray(flat, [B])
            }
            let gathered = try group.allGather(tokenVec)            // [worldSize*B]
            gathered.eval()
            let all = gathered.asArray(Int32.self)
            let base = tailRank * B
            let nextTokens = (0..<B).map { Int(all[base + $0]) }

            lastTokens = nextTokens
            for b in 0..<B where !rowDone[b] {
                let tok = nextTokens[b]
                generated[b].append(tok)
                if plan.isHead { onToken(b, tok) }
                if eosTokenIds.contains(tok) { rowDone[b] = true }
            }
            if rowDone.allSatisfy({ $0 }) { break }
        }
        return generated
    }
}
