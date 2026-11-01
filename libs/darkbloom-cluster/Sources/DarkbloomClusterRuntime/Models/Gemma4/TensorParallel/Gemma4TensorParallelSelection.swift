import Foundation
import MLX

/// Choices from a tied head whose vocabulary rows are split across ranks.
/// Each rank holds its rows' FP32 (softcapped) logits `[1, V/2]`; one small
/// collective per choice makes the same choice on every rank, and no rank
/// holds the whole row. Without a reduction the rows are the whole
/// vocabulary and the same functions are the plain choices of a whole model.
public struct Gemma4TensorParallelSelection {
    public let vocabularyRange: Range<Int>
    public let vocabularySize: Int
    let reduction: QwenTensorParallelReduction?
    /// A whole row normalized as two ranks normalize it (each half's top
    /// `count` and log-sum-exp, merged): the split-sum oracle's head.
    let splitsWholeRow: Bool

    public init(vocabularyRange: Range<Int>, vocabularySize: Int, reduction: QwenTensorParallelReduction?,
                splitsWholeRow: Bool = false) {
        self.vocabularyRange = vocabularyRange
        self.vocabularySize = vocabularySize
        self.reduction = reduction
        self.splitsWholeRow = splitsWholeRow && reduction == nil
    }

    /// Greedy: the argmax over every rank's rows, ties to the lowest token ID
    /// as a whole row's argmax breaks them. One collective of two values per
    /// rank. An `[1]` int32 token, not evaluated.
    public func greedy(_ logits: MLXArray) -> MLXArray {
        argmaxAcrossRanks(logits.asType(.float32), carrying: nil).token
    }

    /// `greedy`, with every rank's `flags` (`[n]` FP32, the same `n` on every
    /// rank) carried in the same collective: the token and all ranks' flags in
    /// rank order (`[size n]`). Not evaluated.
    public func greedy(_ logits: MLXArray, carrying flags: MLXArray) -> (token: MLXArray, flags: MLXArray) {
        let chosen = argmaxAcrossRanks(logits.asType(.float32), carrying: flags.asType(.float32).reshaped(-1))
        return (chosen.token, chosen.carried!)
    }

    /// `greedy` of every row of `logits` (`[B, rows]`, one row a batch lane):
    /// `[B]` int32 tokens from one collective of two values a row and rank,
    /// with `greedy`'s tie rule. Not evaluated.
    public func greedyRows(_ logits: MLXArray) -> MLXArray {
        let values = logits.asType(.float32)
        guard let reduction else { return argMax(values, axis: -1).asType(.int32) }
        let width = values.dim(0)
        let local = stacked([values.max(axis: -1),
            argMax(values, axis: -1).asType(.float32) + MLXArray(Float(vocabularyRange.lowerBound))], axis: 1)
        let zeros = MLXArray.zeros([width, 2], dtype: .float32)
        let all = reduction.allSum(concatenated((0 ..< reduction.size).map { $0 == reduction.rank ? local : zeros }, axis: 1))
        var best = all[0..., 0], token = all[0..., 1]
        for other in 1 ..< reduction.size {
            let better = all[0..., 2 * other] .> best
            best = which(better, all[0..., 2 * other], best)
            token = which(better, all[0..., 2 * other + 1], token)
        }
        return token.asType(.int32)
    }

    /// Every rank's `slots` (`[n]` FP32) in rank order (`[size n]`), each rank
    /// adding its own at its place and -0 elsewhere. Not evaluated.
    public func exchange(_ slots: MLXArray) -> MLXArray {
        let mine = slots.asType(.float32).reshaped(-1)
        guard let reduction else { return mine }
        let empty = MLXArray.full([mine.dim(0)], values: MLXArray(Float(-0.0)))
        return reduction.allSum(concatenated((0 ..< reduction.size).map { $0 == reduction.rank ? mine : empty }, axis: 0))
    }

    /// Sampling with keyed noise (Gumbel-max): exactly the token
    /// `argMax(MLXRandom.gumbel([1, V], key: key) + whole * (1 / temperature))`
    /// of the whole row. Every rank generates the whole vocabulary's noise
    /// from the shared `key`, adds its rows' part, and the argmax collective
    /// of `greedy` chooses. An `[1]` int32 token, not evaluated. The pinned
    /// MLX samples a single row by its inverse CDF instead
    /// (`categorical_inverse_cdf`), so token-for-token parity with the
    /// product's sampler takes the whole row (`gather`) and that sampler.
    public func sample(_ logits: MLXArray, temperature: Float, key: MLXArray) -> MLXArray {
        let scaled = logits.asType(.float32) * (1 / temperature)
        let noise = MLXRandom.gumbel([1, vocabularySize], key: key)[0..., vocabularyRange]
        return argmaxAcrossRanks(noise + scaled, carrying: nil).token
    }

    /// One choice's candidates: the top `count` tokens of the whole row with
    /// their logits and log probabilities (each logit minus the whole row's
    /// log-sum-exp), highest first, equal logits by token ID. Each rank
    /// contributes its own top `count` and its rows' log-sum-exp in one
    /// collective of `2 count + 1` values per rank. Evaluated.
    public func topK(_ logits: MLXArray, count: Int) throws -> (tokenIDs: [Int], logits: [Float], logprobs: [Float]) {
        let values = logits.asType(.float32).reshaped(-1)
        guard values.dim(0) == vocabularyRange.count, count >= 1,
              count <= values.dim(0) / (splitsWholeRow ? 2 : 1) else {
            throw ProbeError("Gemma vocabulary-split top-k: \(count) of a \(values.dim(0))-row slice")
        }
        func candidates(_ slice: MLXArray, offset: Int) -> MLXArray {
            let order = argPartition(-slice, kth: count - 1)[..<count]
            return concatenated([slice[order], order.asType(.float32) + Float(offset),
                                 logSumExp(slice, axis: 0).reshaped(1)], axis: 0)
        }
        let width = 2 * count + 1
        let all: MLXArray
        let ranks: Int
        if let reduction {
            ranks = reduction.size
            // -0 in the other ranks' slots: x + -0 is x, every bit kept.
            let empty = MLXArray.full([width], values: MLXArray(Float(-0.0)))
            let mine = candidates(values, offset: vocabularyRange.lowerBound)
            all = reduction.allSum(concatenated((0 ..< ranks).map { $0 == reduction.rank ? mine : empty }, axis: 0))
        } else if splitsWholeRow {
            ranks = 2
            let half = values.dim(0) / 2
            all = concatenated([candidates(values[..<half], offset: vocabularyRange.lowerBound),
                                candidates(values[half...], offset: vocabularyRange.lowerBound + half)], axis: 0)
        } else {
            ranks = 1
            all = candidates(values, offset: vocabularyRange.lowerBound)
        }
        try MLX.withError { error in
            eval(all)
            try error.check()
        }
        let gathered = all.asArray(Float.self)
        var merged: [(id: Int, logit: Float)] = []
        var sums: [Double] = []
        for rank in 0 ..< ranks {
            let base = rank * width
            for index in 0 ..< count {
                merged.append((Int(gathered[base + count + index]), gathered[base + index]))
            }
            sums.append(Double(gathered[base + 2 * count]))
        }
        let peak = sums.max()!
        let total = Float(peak + log(sums.reduce(0) { $0 + exp($1 - peak) }))
        let chosen = merged.sorted { $0.logit != $1.logit ? $0.logit > $1.logit : $0.id < $1.id }.prefix(count)
        return (chosen.map(\.id), chosen.map(\.logit), chosen.map { $0.logit - total })
    }

    /// The whole row on every rank, every bit kept: each rank's rows at their
    /// place and -0 elsewhere (x + -0 is x), in one collective of V values.
    /// Not evaluated.
    public func gather(_ logits: MLXArray) -> MLXArray {
        let values = logits.asType(.float32)
        guard let reduction else { return values }
        func negativeZeros(_ count: Int) -> MLXArray {
            MLXArray.full([values.dim(0), count], values: MLXArray(Float(-0.0)))
        }
        var parts: [MLXArray] = []
        if vocabularyRange.lowerBound > 0 { parts.append(negativeZeros(vocabularyRange.lowerBound)) }
        parts.append(values)
        if vocabularyRange.upperBound < vocabularySize { parts.append(negativeZeros(vocabularySize - vocabularyRange.upperBound)) }
        return reduction.allSum(concatenated(parts, axis: -1))
    }

    /// Each rank's local maximum, its token ID and `extra` in slots of a
    /// `(2 + extra) size` collective; the strictly greater value wins, so ties
    /// go to the lower rank, which holds the lower IDs.
    private func argmaxAcrossRanks(_ values: MLXArray, carrying extra: MLXArray?) -> (token: MLXArray, carried: MLXArray?) {
        guard let reduction else { return (argMax(values, axis: -1).asType(.int32), extra) }
        let width = 2 + (extra?.dim(0) ?? 0)
        let localIndex = argMax(values, axis: -1).asType(.float32) + MLXArray(Float(vocabularyRange.lowerBound))
        let mine = concatenated([values.max(axis: -1), localIndex] + (extra.map { [$0] } ?? []), axis: 0)
        let zeros = MLXArray.zeros([width], dtype: .float32)
        let all = reduction.allSum(concatenated((0 ..< reduction.size).map { $0 == reduction.rank ? mine : zeros }, axis: 0))
        var best = all[0], token = all[1]
        for other in 1 ..< reduction.size {
            let better = all[width * other] .> best
            best = which(better, all[width * other], best)
            token = which(better, all[width * other + 1], token)
        }
        let carried = extra.map { _ in
            concatenated((0 ..< reduction.size).map { all[(width * $0 + 2) ..< (width * ($0 + 1))] }, axis: 0)
        }
        return (token.asType(.int32).reshaped(1), carried)
    }
}
