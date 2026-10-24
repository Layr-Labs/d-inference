import Foundation

/// What one tensor-parallel rank holds of a request ledger's divided parts:
/// its own KV heads (with the query heads that read them), its own linear
/// attention key and value heads, and its own rows or input columns of every
/// divided projection, exactly as `QwenTensorParallelPlan` cuts them at LOAD.
/// Replicated parts (hidden-width boundaries, logits gathered to the whole
/// vocabulary, the replicated assistant) stay whole. A nil rank keeps the
/// earlier whole-model charge on either rank.
extension QwenLongPrefillBudgetGeometry {
    func tensorParallelShard(plan: QwenTensorParallelPlan, rank: Int?) throws -> Self {
        guard let rank else { return self }
        guard (0..<plan.size).contains(rank), stateLayers == nil, layers == plan.layerCount,
              fullAttentionInterval == plan.fullAttentionInterval, hiddenSize == plan.hiddenSize,
              queryHeads == plan.attentionHeads, kvHeads == plan.kvHeads, headDimension == plan.headDim,
              linearKeyHeads == plan.linearKeyHeads, linearValueHeads == plan.linearValueHeads,
              linearKeyDimension == plan.linearKeyHeadDim, linearValueDimension == plan.linearValueHeadDim else {
            throw ProbeError("Tensor-parallel rank ledger geometry differs from its plan")
        }
        return try .init(layers: layers, fullAttentionInterval: fullAttentionInterval, hiddenSize: hiddenSize,
            queryHeads: plan.attentionHeadsPerRank[rank], kvHeads: plan.kvHeadsPerRank[rank],
            headDimension: headDimension, linearKeyHeads: plan.linearKeyHeadsPerRank[rank],
            linearValueHeads: plan.linearValueHeadsPerRank[rank], linearKeyDimension: linearKeyDimension,
            linearValueDimension: linearValueDimension, convolutionKernel: convolutionKernel)
    }
}

extension QwenTensorParallelPlan {
    /// `tensor`'s elements on `rank`: all of them when replicated, else the
    /// rows or logical input columns its cut keeps (packed words and
    /// per-group scales and biases cut with them).
    func rankElements(of tensor: QwenDenseCanonicalTensor, rank: Int) throws -> Int {
        let product = QwenLongPrefillCheckedBytes.product
        guard !tensor.shape.isEmpty, tensor.shape.allSatisfy({ $0 > 0 }) else {
            throw ProbeError("Tensor-parallel rank ledger tensor \(tensor.name) has no shape")
        }
        switch try disposition(key: tensor.name, rank: rank) {
        case .load(.replicate):
            return try product(tensor.shape)
        case .load(.rows(let ranges)):
            guard ranges.allSatisfy({ $0.lowerBound >= 0 && $0.upperBound <= tensor.shape[0] }) else {
                throw ProbeError("Tensor-parallel rank ledger rows exceed \(tensor.name)")
            }
            return try product([ranges.reduce(0) { $0 + $1.count }] + tensor.shape.dropFirst())
        case .load(.inputColumns(let columns)):
            guard tensor.shape.count == 2, let dot = tensor.name.lastIndex(of: ".") else {
                throw ProbeError("Tensor-parallel rank ledger input columns need a 2-D quantized leaf")
            }
            let (groupSize, bits) = affineQuantization(forModule: String(tensor.name[..<dot]))
            let packed = tensor.name.hasSuffix(".weight")
            let stored = packed ? columns.count * bits / 32 : columns.count / groupSize
            let end = packed ? columns.upperBound * bits / 32 : columns.upperBound / groupSize
            guard columns.count % groupSize == 0, (columns.count * bits) % 32 == 0, end <= tensor.shape[1] else {
                throw ProbeError("Tensor-parallel rank ledger columns of \(tensor.name) leave a group or word")
            }
            return try product([tensor.shape[0], stored])
        default:
            throw ProbeError("Tensor-parallel rank ledger does not price \(tensor.name)")
        }
    }
}
