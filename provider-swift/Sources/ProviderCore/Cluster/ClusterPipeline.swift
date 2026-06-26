/// ClusterPipeline -- the SINGLE, proven ring decode loop, shared by both the
/// one-shot harness (cluster-run) and the coordinator-connected provider
/// (cluster-provider).
///
/// This is a faithful extraction of the loop that has been verified on hardware
/// (correct GPT-OSS + Mistral generations). Its collective discipline is the
/// reason it does NOT deadlock and MUST be preserved:
///   - EVERY rank calls `all_gather` once per step, unconditionally, in the same
///     order. Per-rank branching happens only AROUND the collective (head
///     embeds; tail samples), never INSIDE the collective call sequence.
///   - The ring hop is `send` (non-tail) / `recvLike` (non-head), sealed with
///     ClusterLinkCrypto; activations cross the wire only as AEAD ciphertext.
///
/// `ClusterShard` is the minimal surface the loop needs (PipelineModelShard
/// already provides it). The server path adds a control round — the head
/// broadcasts the next request's (promptTokens, maxTokens) to peers via
/// `all_gather` before each generation, so peers loop request-to-request in
/// lockstep without their own coordinator connection.

import Foundation
import MLX

public struct ClusterPipeline {
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

    /// Deterministic ciphertext length for a [1, width, hidden] bf16 activation:
    /// header (2 + ndim*4) + payload (width*hidden*2) + AEAD overhead (28).
    private func sealedLen(width: Int) -> Int { 14 + width * hiddenSize * 2 + 28 }

    /// Run ONE greedy generation for `promptTokens`, up to `maxTokens`. Calls
    /// `onToken` on the head for each produced token. EVERY rank runs this in
    /// lockstep (peers ignore `onToken`). Returns the generated token ids (head).
    ///
    /// `requestId` scopes the AEAD frames; `seqBase` lets multiple requests reuse
    /// distinct nonce ranges if the same channels persist (the caller passes
    /// fresh channels per request, so seqBase can stay 0).
    public func generate(
        promptTokens: [Int], maxTokens: Int, requestId: String,
        eosTokenIds: Set<Int>, onToken: (Int) -> Void
    ) throws -> [Int] {
        var seq = promptTokens
        var generated = [Int]()

        // ── Fine-grained tracing (DARKBLOOM_TRACE=1) ────────────────────────
        // Every primitive is timed, and each GPU op is force-eval'd IMMEDIATELY
        // before its timer closes so the measured time is that op's real cost
        // (not deferred into a later barrier). This is the key to honest numbers:
        // without per-op eval, MLX's laziness would smear all compute into
        // whichever later .eval() happens to materialize it.
        //
        // Phases captured per step (rank-dependent):
        //   embed            head: token embedding
        //   recv_wait        non-head: time blocked in recvLike (transit + peer-idle)
        //   to_bytes         non-head: cipher MLXArray -> [UInt8]
        //   aead_open        non-head: ChaCha20-Poly1305 open
        //   codec_decode     non-head: bytes -> hidden MLXArray
        //   layers_compute   GPU: runOwnedLayers (eval'd)
        //   codec_encode     non-tail: hidden -> bytes (bf16) (eval'd)
        //   aead_seal        non-tail: ChaCha20-Poly1305 seal
        //   to_i32           non-tail: sealed bytes -> MLXArray
        //   send_hop         non-tail: group.send + eval (transit)
        //   logits_compute   tail: projectToLogits + argMax (eval'd)
        //   allgather        all: token broadcast + eval (round-trip)
        //   readback         all: gathered.asArray (host copy)
        let trace = ProcessInfo.processInfo.environment["DARKBLOOM_TRACE"] == "1"
            || ProcessInfo.processInfo.environment["DARKBLOOM_PROFILE"] == "1"
        var acc = [String: UInt64]()
        var profSteps = 0
        func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
        @inline(__always) func tick(_ k: String, _ t0: UInt64) { if trace { acc[k, default: 0] += now() - t0 } }

        for step in 0..<maxTokens {
            let inputTokens: [Int] = step == 0 ? seq : [seq[seq.count - 1]]
            let width = inputTokens.count
            let prof = trace && step > 0    // skip prefill (step 0) — steady-state only
            if prof { profSteps += 1 }
            let stepStart = now()

            let inCtx = ClusterFrameContext(
                clusterId: plan.clusterId, requestId: requestId,
                layerRange: "hop-\(plan.rank == headRank ? headRank : plan.rank - 1)", seq: UInt64(step))

            var hidden: MLXArray
            if plan.isHead {
                var t = now()
                hidden = shard.embed(tokens: inputTokens)
                if prof { hidden.eval(); tick("embed", t); _ = t }
            } else {
                // recv_wait: blocked here until the prev rank's send arrives.
                var t = now()
                let template = MLXArray.zeros([sealedLen(width: width)], dtype: .int32)
                let cipherArr = try group.recvLike(template, from: plan.rank - 1)
                cipherArr.eval()
                if prof { tick("recv_wait", t) }
                t = now()
                let cipherBytes = toBytes(cipherArr)
                if prof { tick("to_bytes", t) }
                t = now()
                let plain = try openCh!.open(cipherBytes, context: inCtx)
                if prof { tick("aead_open", t) }
                t = now()
                hidden = try ActivationCodec.decode(plain)
                if prof { hidden.eval(); tick("codec_decode", t) }
            }

            var t = now()
            hidden = shard.runOwnedLayers(hidden)
            if prof { hidden.eval(); tick("layers_compute", t) }

            if !plan.isTail {
                t = now()
                let bf16 = hidden.asType(.bfloat16)
                let encoded = try ActivationCodec.encode(bf16)
                if prof { tick("codec_encode", t) }
                let outCtx = ClusterFrameContext(
                    clusterId: plan.clusterId, requestId: requestId,
                    layerRange: "hop-\(plan.rank)", seq: UInt64(step))
                t = now()
                let sealed = try sealCh!.seal(encoded, context: outCtx)
                if prof { tick("aead_seal", t) }
                t = now()
                let sealedArr = toI32(sealed)
                if prof { tick("to_i32", t) }
                t = now()
                let dep = try group.send(sealedArr, to: plan.rank + 1)
                dep.eval()
                if prof { tick("send_hop", t) }
            }

            var tokenScalar = MLXArray([Int32(0)])
            if plan.isTail {
                t = now()
                let logits = shard.projectToLogits(hidden)
                let ids = argMax(logits, axis: logits.ndim - 1)
                ids.eval()
                tokenScalar = MLXArray([Int32(Int(ids.asArray(Int32.self).last ?? 0))])
                if prof { tick("logits_compute", t) }
            }
            t = now()
            let gathered = try group.allGather(tokenScalar)
            gathered.eval()
            if prof { tick("allgather", t) }
            t = now()
            let nextToken = Int(gathered.asArray(Int32.self)[tailRank])
            if prof { tick("readback", t) }

            if prof { tick("STEP_TOTAL", stepStart) }
            seq.append(nextToken)
            generated.append(nextToken)
            if plan.isHead { onToken(nextToken) }
            if eosTokenIds.contains(nextToken) { break }
        }

        if trace && profSteps > 0 {
            // Print every phase this rank recorded, sorted by cost, with % of step.
            let total = Double(acc["STEP_TOTAL"] ?? 1)
            let role = plan.isHead ? "HEAD" : (plan.isTail ? "TAIL" : "MID")
            var line = "\n[trace rank \(plan.rank)/\(role) · \(profSteps) decode steps · per-step avg ms]\n"
            for (k, v) in acc.sorted(by: { $0.value > $1.value }) {
                let ms = Double(v) / 1_000_000 / Double(profSteps)
                let pct = total > 0 ? Double(v) / total * 100 : 0
                line += String(format: "   %-16@ %7.2f ms  %5.1f%%\n", k, ms, pct)
            }
            FileHandle.standardError.write(Data(line.utf8))
        }
        return generated
    }
}
