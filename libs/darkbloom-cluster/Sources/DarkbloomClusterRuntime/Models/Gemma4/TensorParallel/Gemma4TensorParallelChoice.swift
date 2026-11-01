import DarkbloomClusterProtocol
import MLX

/// How each step's token is chosen on every rank, built into the step's own
/// evaluation (the `select` of `Gemma4TensorParallelPagedSession.prefill`
/// and `decode`). The result is `[1 + ranks]` FP32: the agreed token, then
/// each rank's stop flag.
///
/// - Greedy (no sampler, or one that neither draws nor depends on history:
///   a greedy request asking for logprobs): the vocabulary-split argmax, with
///   both ranks' stop flags carried in its one collective (ties to the lowest
///   ID, as a whole row's argmax).
/// - Sampled: the whole row gathered to every rank (every bit kept), rank 0
///   draws with the product's sampler (`QwenStageTokenSampler`: bias,
///   penalties, temperature, top-k/p, min-p, the keyed draw), and one small
///   collective carries its token and both ranks' flags. Rank 1 puts its
///   row's argmax in its token slot, which nobody reads: the slot must depend
///   on the row, so the collective is never scheduled before the step's sums.
struct Gemma4TensorParallelChoice {
    let selection: Gemma4TensorParallelSelection
    let sampler: QwenStageTokenSampler?
    let rank: Int

    var ranks: Int { selection.reduction?.size ?? 1 }

    /// Greedy requests take the vocabulary-split argmax; their logprobs, when
    /// asked, come from the vocabulary-split top-k gather (`logprobs`).
    var gathersRow: Bool {
        guard let sampler else { return false }
        return sampler.wire.isStochastic || sampler.wire.dependsOnHistory
    }

    func build(_ logits: MLXArray, stop: Float) -> MLXArray {
        let flag = MLXArray([stop])
        guard gathersRow, let sampler else {
            let chosen = selection.greedy(logits, carrying: flag)
            return concatenated([chosen.token.asType(.float32), chosen.flags], axis: 0)
        }
        let row = selection.gather(logits)
        let local = rank == 0 ? sampler.sample(row) : argMax(row, axis: -1)
        let slots = selection.exchange(concatenated([local.asType(.float32).reshaped(1), flag], axis: 0))
        return concatenated([slots[0 ..< 1]] + (0 ..< ranks).map { slots[(2 * $0 + 1) ..< (2 * $0 + 2)] }, axis: 0)
    }

    /// The agreed token and every rank's flag of an evaluated `build`.
    func read(_ agreed: MLXArray) throws -> (token: Int, flags: [Float]) {
        let values = agreed.asArray(Float.self)
        guard values.count == 1 + ranks, let token = values.first, token >= 0, token == token.rounded(),
              Int(token) < selection.vocabularySize else {
            throw ProbeError("Gemma tensor-parallel selection has a wrong shape or token")
        }
        return (Int(token), Array(values.dropFirst()))
    }

    /// A greedy step's logprobs (`count` alternatives) from the vocabulary-
    /// split top-k gather: one collective on every rank, evaluated now. The
    /// chosen token is the top candidate (both break ties by the lowest ID).
    func logprobs(_ logits: MLXArray, token: Int, count: Int) throws -> ClusterWorkerTokenLogprobs {
        let top = try selection.topK(logits, count: count)
        guard top.tokenIDs.first == token else {
            throw ProbeError("Gemma tensor-parallel greedy token is not its row's top candidate")
        }
        return .init(logprob: top.logprobs[0],
            top: zip(top.tokenIDs, top.logprobs).map { ClusterWorkerTokenLogprobs.Alternative(tokenID: $0, logprob: $1) })
    }
}
