import Foundation
import MLX
import MLXLMCommon

/// Hybrid generation: the prompt is prefilled on one rank with the unsharded
/// model (the Mac that prefills faster), its request state is cut by heads —
/// attention keys/values by KV head, the linear attention's convolution state
/// by the q/k/v channels of each rank's heads and its recurrent state by value
/// head — the other rank's part is sent to it byte for byte, and decode runs
/// tensor parallel from the first token. The first token is the prefill rank's
/// own choice; it travels with the state.
///
/// The prefill rank holds both the unsharded model and its shard. The
/// pipeline-prefill variant (each rank prefills its own layers, then the state
/// is exchanged by heads) moves the same bytes; it needs the residual-ingress
/// stage path and is not built here.
public enum QwenTensorParallelHybrid {
    /// One rank's part of the state, in transfer order.
    struct Layout {
        var activationCount = 0
        var floatCount = 0
        var pieces: [(layer: Int, shape: [Int], float32: Bool)] = []
    }

    static func layout(_ plan: QwenTensorParallelPlan, tokens: Int, convolutionKernel: Int) -> Layout {
        var layout = Layout()
        let s = plan.size
        for layer in 0..<plan.layerCount {
            if (layer + 1) % plan.fullAttentionInterval != 0 {
                let conv = [1, convolutionKernel - 1, (2 * plan.linearKeyHeads * plan.linearKeyHeadDim
                    + plan.linearValueHeads * plan.linearValueHeadDim) / s]
                let ssm = [1, plan.linearValueHeads / s, plan.linearValueHeadDim, plan.linearKeyHeadDim]
                layout.pieces.append((layer, conv, false)); layout.activationCount += conv.reduce(1, *)
                layout.pieces.append((layer, ssm, true)); layout.floatCount += ssm.reduce(1, *)
            } else {
                let kv = [1, plan.kvHeads / s, tokens, plan.headDim]
                layout.pieces.append((layer, kv, false)); layout.pieces.append((layer, kv, false))
                layout.activationCount += 2 * kv.reduce(1, *)
            }
        }
        return layout
    }

    /// `rank`'s cut of one layer's unsharded state, as exact copies.
    static func cut(_ state: [MLXArray], layer: Int, rank: Int, plan: QwenTensorParallelPlan) throws -> [MLXArray] {
        let s = plan.size
        guard state.count == 2 else { throw ProbeError("Hybrid: layer \(layer) holds \(state.count) state arrays") }
        func heads(_ total: Int) -> MLXArray { MLXArray(((rank * total / s) ..< ((rank + 1) * total / s)).map { Int32($0) }) }
        if (layer + 1) % plan.fullAttentionInterval != 0 {
            let channels = MLXArray(plan.linearQKVRows(rank: rank).flatMap { $0.map { Int32($0) } })
            return [take(state[0], channels, axis: 2), take(state[1], heads(plan.linearValueHeads), axis: 1)]
        }
        let index = heads(plan.kvHeads)
        return [take(state[0], index, axis: 1), take(state[1], index, axis: 1)]
    }

    public static func generate(full: QwenTensorParallelModel?, shard: QwenTensorParallelModel,
                                group: QwenTensorParallelGroup, prefillRank: Int, prompt: [Int],
                                outputCount: Int, chunk: Int, convolutionKernel: Int = 4,
                                activationDType: DType = .bfloat16) throws -> QwenTensorParallelModel.Generation {
        let plan = shard.plan
        guard plan.equalShares else { throw ProbeError("Hybrid: the state cut by heads covers equal shards only") }
        guard case .shard(let rank, let size) = shard.role, rank == group.rank, size == group.size, size == 2,
              (0..<size).contains(prefillRank), (rank == prefillRank) == (full != nil),
              full.map({ $0.role == .full }) ?? true, !prompt.isEmpty, outputCount >= 1 else {
            throw ProbeError("Hybrid: the prefill rank holds the unsharded model and its shard; the other rank its shard")
        }
        let other = 1 - rank
        let layout = layout(plan, tokens: prompt.count, convolutionKernel: convolutionKernel)
        guard try group.agree([Int32(prompt.count), Int32(prefillRank), Int32(layout.activationCount % 1_000_000_007),
                               Int32(layout.floatCount % 1_000_000_007)]) else {
            throw ProbeError("Hybrid: the ranks disagree on the prompt, the prefill rank or the state layout")
        }
        let started = QwenTensorParallelModel.now()
        let cache = shard.newCache()
        var generationPrefill: Double?
        var bytes = 0
        let first: MLXArray
        if let full {
            let fullCache = full.newCache()
            let logits = full.prefill(prompt, chunk: chunk, cache: fullCache)
            let token = full.select(logits)
            eval([token] + fullCache.flatMap { $0.innerState() })
            generationPrefill = QwenTensorParallelModel.now() - started
            var outgoing: [MLXArray] = [], outgoingFloat: [MLXArray] = []
            for layer in 0..<plan.layerCount {
                let state = fullCache[layer].state
                let mine = try cut(state, layer: layer, rank: rank, plan: plan)
                let theirs = try cut(state, layer: layer, rank: other, plan: plan)
                // A key/value cache takes its offset from the keys; the
                // recurrent cache's offset is not read by this model.
                var target = cache[layer]
                target.state = mine
                for array in theirs {
                    if array.dtype == .float32 { outgoingFloat.append(array.flattened()) }
                    else { outgoing.append(array.flattened()) }
                }
            }
            let activations = concatenated(outgoing, axis: 0)
            let floats = concatenated(outgoingFloat + [token.asType(.float32)], axis: 0)
            eval(activations, floats)
            guard try group.agree([activations.dtype == activationDType ? 1 : 0, Int32(activations.size % 1_000_000_007),
                                   Int32(floats.size % 1_000_000_007)]) else {
                throw ProbeError("Hybrid: the cut state differs from the agreed layout")
            }
            try group.send(activations, to: other)
            try group.send(floats, to: other)
            bytes = activations.nbytes + floats.nbytes
            first = token
        } else {
            guard try group.agree([1, Int32(layout.activationCount % 1_000_000_007),
                                   Int32((layout.floatCount + 1) % 1_000_000_007)]) else {
                throw ProbeError("Hybrid: the cut state differs from the agreed layout")
            }
            let activations = try group.receive(count: layout.activationCount, dtype: activationDType, from: prefillRank)
            let floats = try group.receive(count: layout.floatCount + 1, dtype: .float32, from: prefillRank)
            bytes = activations.nbytes + floats.nbytes
            var a = 0, f = 0
            var arrays: [Int: [MLXArray]] = [:]
            for piece in layout.pieces {
                let count = piece.shape.reduce(1, *)
                let value: MLXArray
                if piece.float32 { value = floats[f ..< f + count].reshaped(piece.shape); f += count }
                else { value = activations[a ..< a + count].reshaped(piece.shape); a += count }
                arrays[piece.layer, default: []].append(value)
            }
            for layer in 0..<plan.layerCount {
                var target = cache[layer]
                target.state = arrays[layer]!
            }
            first = floats[f ..< f + 1].asType(.int32)
        }
        eval([first] + cache.flatMap { $0.innerState() })
        let ready = QwenTensorParallelModel.now() - started
        var result = shard.decode(first: first, firstLogits: nil, cache: cache, outputCount: outputCount,
                                  recordTop: 0, started: started)
        result.prefillSeconds = generationPrefill
        result.handoffSeconds = ready - (generationPrefill ?? 0)
        result.handoffBytes = bytes
        return result
    }
}
