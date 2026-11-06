import DarkbloomClusterProtocol
import Foundation
import MLX
import MLXLMCommon

/// Speculative rounds of one Gemma 4 request on a tensor-parallel rank (or on
/// the whole model, with no reduction).
///
/// A round proposes up to `depth` tokens with the assistant
/// (`Gemma4TensorParallelAssistant`; every rank drafts from its own mirror,
/// no collective), runs the window `[last, d1 … dk]` through every layer's
/// sums at once (`Gemma4VerifyWindow`: each row is the plain step's bits), and
/// agrees in one collective on each column's target, every rank's stop flag,
/// every rank's proposals and every rank's new key and value rows of the
/// assistant's two source layers. The drafts, the window and the agreement
/// are one evaluation: one host synchronization a round.
///
/// Targets: greedy requests take each column's vocabulary-split argmax (the
/// strictly greater maximum wins, ties to the lower rank: the plain step's
/// rule); sampled ones gather each column's whole row and rank 0 draws the
/// product's keyed target sample at its own output index
/// (`QwenStageTokenSampler.verifyRound`, the proposals recorded first for a
/// request whose transforms depend on its history); a round of no proposal
/// draws as the plain step does (`sample`).
///
/// Kept tokens: proposals while each equals the target before it, then the
/// target, cut at a stop token and the output allowance. A proposal counts
/// only while every rank proposed the same token: ranks on different chips
/// may round the drafter differently, and a window row after a differing
/// proposal is not computed from one token sequence on both ranks. Row 0 is
/// the last committed token on every rank, so a round always keeps at least
/// the plain step's token. Proposals never choose a committed token: greedy
/// output is the plain tensor-parallel path's, token for token.
final class Gemma4TensorParallelRounds {
    struct Round {
        /// The tokens this round keeps, in order (at least one).
        let tokens: [Int]
        /// Every column's target (`tokens` is a prefix of it).
        let targets: [Int]
        /// Greedy: each column's maximum logit (the target's).
        let maxima: [Float]
        /// Every rank's stop flag, in rank order.
        let flags: [Float]
        let proposed: Int
        let accepted: Int
        /// The window's logits `[T, head rows]`, evaluated.
        let logits: MLXArray
    }

    struct Statistics: Equatable {
        var rounds = 0, plainRounds = 0, proposed = 0, accepted = 0
        var acceptedByPosition = [Int](repeating: 0, count: Gemma4TensorParallelAssistant.maximumDepth)
        var proposedByPosition = [Int](repeating: 0, count: Gemma4TensorParallelAssistant.maximumDepth)
    }

    let session: Gemma4TensorParallelPagedSession
    let assistant: Gemma4TensorParallelAssistant
    let sampler: QwenStageTokenSampler?
    let gathersRow: Bool
    let rank: Int
    private let reduction: QwenTensorParallelReduction?
    private let mirror: Gemma4TensorParallelDraftMirror
    private let slidingLayer: Int, fullLayer: Int
    /// The target's pre-norm hidden row of the last committed token's
    /// position minus one: what produced the last token (nil before the
    /// first round, which proposes nothing).
    private var hidden: MLXArray?
    private(set) var statistics = Statistics()
    /// Tests only: proposals from a script instead of the assistant, given the
    /// output index of the first proposal and the count (the window and the
    /// agreement are the product's).
    var scriptedProposals: ((_ outputIndex: Int, _ count: Int) -> [Int])?

    init(session: Gemma4TensorParallelPagedSession, assistant: Gemma4TensorParallelAssistant,
         choice: Gemma4TensorParallelChoice) throws {
        let model = session.model
        let rank: Int
        switch model.role {
        case .shard(let r): rank = r
        case .full: rank = 0
        case .splitSum: throw ProbeError("Gemma speculative rounds need a whole model or a shard")
        }
        guard choice.rank == rank, (model.reduction?.size ?? 1) == choice.ranks, choice.ranks <= 2 else {
            throw ProbeError("Gemma speculative rounds differ from their rank's choice")
        }
        (slidingLayer, fullLayer) = try Gemma4VerifyWindow.sourceLayers(model.textModel.configuration)
        self.session = session; self.assistant = assistant; self.rank = rank
        sampler = choice.sampler; gathersRow = choice.gathersRow
        reduction = model.reduction
        mirror = Gemma4TensorParallelDraftMirror(slidingWindow: model.fullTextConfiguration.slidingWindow)
    }

    private var ranks: Int { reduction?.size ?? 1 }

    /// The drafter's capture at the committed frontier (inspection).
    func currentCapture() throws -> CBv2MTPRowCapture {
        let retained = session.state.rows[slidingLayer]?.retainedCount ?? 0
        return try mirror.capture(retained: min(retained, mirror.count))
    }

    /// This rank's own rows of the two source layers at the committed frontier (inspection).
    func ownRows() -> (full: (keys: MLXArray, values: MLXArray), sliding: (keys: MLXArray, values: MLXArray))? {
        guard let full = session.state.rows[fullLayer]?.snapshot(),
              let sliding = session.state.rows[slidingLayer]?.snapshot() else { return nil }
        return ((full.keys, full.values), (sliding.keys, sliding.values))
    }

    /// Every rank's `[n]` FP32 slot, in rank order, each rank's at its place
    /// and -0 elsewhere (x + -0 is x, every bit kept). Not evaluated.
    private func exchange(_ mine: MLXArray) -> MLXArray {
        guard let reduction else { return mine }
        let empty = MLXArray.full([mine.dim(0)], values: MLXArray(Float(-0.0)))
        return reduction.allSum(concatenated((0 ..< ranks).map { $0 == rank ? mine : empty }, axis: 0))
    }

    private static func flat(_ parts: [MLXArray]) -> MLXArray {
        concatenated(parts.map { $0.asType(.float32).reshaped(-1) }, axis: 0)
    }

    /// The rank-order whole heads of one layer from every rank's rows: this
    /// rank's `own` and the others' as flat FP32 in `all` at `offsets`.
    private func wholeHeads(own: MLXArray, all: MLXArray, offsets: [Int]) -> MLXArray {
        let parts = (0 ..< ranks).map { r -> MLXArray in
            r == rank ? own : all[offsets[r] ..< offsets[r] + own.size].reshaped(own.shape).asType(own.dtype)
        }
        return parts.count == 1 ? parts[0] : concatenated(parts, axis: 1)
    }

    /// After the prompt (cold or restored): every rank's heads of the two
    /// source layers at the committed frontier, exchanged in pieces of at most
    /// `Gemma4TensorParallelRequestBudget.mirrorExchangePositions` positions
    /// (the sliding window rides the first), each evaluated before the next.
    func start(check: () throws -> Void) throws {
        let state = session.state
        guard let fullRow = state.rows[fullLayer], let slidingRow = state.rows[slidingLayer],
              state.committedTokens >= session.promptCount else {
            throw ProbeError("Gemma speculative rounds start before the prompt")
        }
        let full = fullRow.snapshot(), sliding = slidingRow.snapshot()
        let frontier = state.committedTokens
        guard full.offset == frontier, sliding.offset == frontier, full.keys.dim(2) == frontier else {
            throw ProbeError("Gemma draft mirror rows differ from the committed frontier")
        }
        let piece = Gemma4TensorParallelRequestBudget.mirrorExchangePositions
        var keys: [MLXArray] = [], values: [MLXArray] = []
        var slidingWhole: [MLXArray] = []
        for from in stride(from: 0, to: frontier, by: piece) {
            let to = min(frontier, from + piece)
            var own = [full.keys[0..., 0..., from ..< to], full.values[0..., 0..., from ..< to]]
            if from == 0 { own += [sliding.keys, sliding.values] }
            let width = own.reduce(0) { $0 + $1.size }
            let all = exchange(Self.flat(own))
            var offsets = [[Int]](repeating: [], count: own.count)
            for r in 0 ..< ranks {
                var at = r * width
                for (index, part) in own.enumerated() { offsets[index].append(at); at += part.size }
            }
            let whole = own.indices.map { wholeHeads(own: own[$0], all: all, offsets: offsets[$0]) }
            try MLX.withError { error in eval(whole); try error.check() }
            try check()
            keys.append(whole[0]); values.append(whole[1])
            if from == 0 { slidingWhole = [whole[2], whole[3]] }
        }
        let fullKeys = keys.count == 1 ? keys[0] : concatenated(keys, axis: 2)
        let fullValues = values.count == 1 ? values[0] : concatenated(values, axis: 2)
        mirror.start(full: (fullKeys, fullValues), sliding: (slidingWhole[0], slidingWhole[1]), frontier: frontier)
        eval(mirror.evaluationTargets); try check()
    }

    /// One round after `lastToken` (committed, not yet fed), proposing up to
    /// `proposals` tokens, carrying this rank's `stop` flag. Keeps at most
    /// `remaining` tokens. Every rank calls it with the same arguments except
    /// `stop`. A flagged round keeps its first row and returns its flags; the
    /// caller ends the request.
    func round(lastToken: Int, proposals: Int, stop: Float, remaining: Int, stopTokens: Set<Int>,
               check: () throws -> Void) throws -> Round {
        guard remaining >= 1, proposals >= 0, proposals <= assistant.depth else {
            throw ProbeError("Gemma speculative round outside its allowance")
        }
        let count = hidden == nil ? 0 : min(proposals, remaining - 1)
        var drafts: MLXArray?
        if count > 0, let script = scriptedProposals {
            let outputIndex = session.state.committedTokens - session.promptCount + 1
            drafts = MLXArray(script(outputIndex, count).map(Int32.init))
        } else if count > 0, let hidden {
            let retained = session.state.rows[slidingLayer]?.retainedCount ?? 0
            drafts = assistant.propose(token: lastToken, hidden: hidden,
                capture: try mirror.capture(retained: min(retained, mirror.count)), count: count)
        }
        let seed = MLXArray([Int32(lastToken)]).reshaped([1, 1])
        let input = drafts.map { concatenated([seed, $0.reshaped([1, count])], axis: 1) } ?? seed
        let columns = count + 1
        let built = try session.beginWindow(input)
        let output = built.output
        let model = session.model
        let selection = model.selection
        // This rank's slot: [targets' maxima (T), targets (T), stop, proposals (k), new KV rows].
        let own = [output.full.keys, output.full.values, output.sliding.keys, output.sliding.values]
        var gathered: MLXArray?
        var head: [MLXArray]
        if gathersRow, let sampler {
            let rows = selection.gather(output.logits)
            gathered = rows
            let draws: MLXArray
            if rank == 0 {
                if columns == 1 {
                    draws = sampler.sample(rows)
                } else {
                    for step in 0 ..< count { sampler.proposeChosen(drafts![step ..< step + 1], step: step) }
                    draws = sampler.verifyRound(rows.reshaped([1, columns, -1])).reshaped(-1)
                }
            } else {
                draws = argMax(rows, axis: -1)
            }
            head = [MLXArray.zeros([columns], dtype: .float32), draws.asType(.float32)]
        } else {
            let values = output.logits.asType(.float32)
            head = [values.max(axis: -1),
                    argMax(values, axis: -1).asType(.float32) + MLXArray(Float(selection.vocabularyRange.lowerBound))]
        }
        head.append(MLXArray([stop]))
        if let drafts { head.append(drafts.asType(.float32)) }
        let fixed = 2 * columns + 1 + count
        let ownWidth = own.reduce(0) { $0 + $1.size }
        let all = exchange(Self.flat(head + own))
        let width = fixed + ownWidth
        try MLX.withError { error in
            eval(built.roots + [all] + (gathered.map { [$0] } ?? []))
            try error.check()
        }
        try check()
        try session.confirmWindow(check: check)
        let agreed = all.asArray(Float.self)
        guard agreed.count == width * ranks else { throw ProbeError("Gemma speculative round agreement has a wrong shape") }
        func slot(_ r: Int, _ field: Int) -> Float { agreed[width * r + field] }
        var targets: [Int] = [], maxima: [Float] = []
        for column in 0 ..< columns {
            var best = slot(0, column), token = slot(0, columns + column)
            if !gathersRow {
                for other in 1 ..< ranks where slot(other, column) > best {
                    best = slot(other, column); token = slot(other, columns + column)
                }
            }
            guard token >= 0, token == token.rounded(), Int(token) < model.plan.vocabularySize else {
                throw ProbeError("Gemma speculative round chose no token of the vocabulary")
            }
            targets.append(Int(token)); maxima.append(best)
        }
        let flags = (0 ..< ranks).map { slot($0, 2 * columns) }
        // Proposals count while every rank proposed the same token.
        var common = 0
        while common < count, (0 ..< ranks).allSatisfy({ slot($0, fixed - count + common) == slot(0, fixed - count + common) }) {
            common += 1
        }
        var accepted = 0
        while accepted < common, Int(slot(0, fixed - count + accepted)) == targets[accepted] { accepted += 1 }
        var kept = min(accepted + 1, remaining)
        if let stopAt = targets[..<kept].firstIndex(where: stopTokens.contains) { kept = stopAt + 1 }
        if flags.contains(where: { $0 > 0 }) { kept = 1 }
        let roots = try session.settleWindow(keeping: kept)
        // The kept rows of every rank's heads join the mirror.
        var offsets: [[Int]] = [[], [], [], []]
        for r in 0 ..< ranks {
            var at = r * width + fixed
            for (index, part) in own.enumerated() { offsets[index].append(at); at += part.size }
        }
        let whole = own.indices.map {
            wholeHeads(own: own[$0], all: all, offsets: offsets[$0])[0..., 0..., ..<kept, 0...]
        }
        mirror.append(full: (whole[0], whole[1]), sliding: (whole[2], whole[3]), positions: kept)
        hidden = output.hidden[0..., (kept - 1) ..< kept, 0...]
        try MLX.withError { error in
            eval(roots + mirror.evaluationTargets + [hidden!])
            try error.check()
        }
        try session.confirmSettled(check: check)
        statistics.rounds += 1
        if count == 0 { statistics.plainRounds += 1 }
        statistics.proposed += count; statistics.accepted += accepted
        for position in 0 ..< count { statistics.proposedByPosition[position] += 1 }
        for position in 0 ..< accepted { statistics.acceptedByPosition[position] += 1 }
        return Round(tokens: Array(targets[..<kept]), targets: targets, maxima: maxima, flags: flags,
                     proposed: count, accepted: accepted, logits: output.logits)
    }
}
