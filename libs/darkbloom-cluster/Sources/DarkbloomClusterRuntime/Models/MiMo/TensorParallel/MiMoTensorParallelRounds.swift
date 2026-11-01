import Cmlx
import DarkbloomClusterProtocol
import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// Speculative rounds of one request on a MiMo V2.6 tensor-parallel rank
/// (`pipeline_mtp_v1`'s rules through the tensor-parallel sums).
///
/// After the prompt and the first token (a plain step's agreement), each
/// round drafts up to `depth` proposals from the replicated heads (each one
/// small sum), runs the window `[last, d1 … dk]` through every layer's two
/// sums at once (`MiMoV26TextModel.forwardVerifyWindow`: each row is the
/// one-token step's bits, so greedy is lossless against the one-token path),
/// and agrees in one sum on every column's target (the vocabulary-split
/// argmax, or rank 0's keyed target sample over the gathered rows), both
/// ranks' stop slots and positions. Both ranks then keep the same tokens
/// (`MiMoMTPAcceptance.kept`: drafts while each equals the target before it,
/// then the target; cut at a stop token and the output limit), roll the rest
/// of the window back exactly, and commit. A round of no proposal is the
/// one-token step itself; a sampler that cannot verify drafts never gets here
/// (`run` decodes it one token a step).
///
/// Stops: a round's stop slots are read before either rank commits any of its
/// tokens. Rank 0 hears the owner's answer to each token at once; a client
/// stop inside a round stops rank 0's commits there and rides the next
/// round's agreement, unless the round already ends the request (a stop token
/// or the limit, which both ranks see in the agreed tokens): both ranks then
/// end after it, and rank 1 adopts rank 0's count and finish in the end
/// agreement (`QwenTensorParallelStopRule.reconcile`), so no rank waits in a
/// collective its peer never joins.
extension MiMoTensorParallelDecoding {
    struct Round {
        let targets: [Int]
        let maxima: [Float]
        let stop: Float?
        /// The gathered rows `[n, V]` (FP32) of a gathered-row request.
        let rows: MLXArray?
    }

    func runRounds(_ request: Request, speculation: MiMoTensorParallelSpeculation, localStop: () -> Bool,
                   publish: (Int, Int, ClusterWorkerTokenLogprobs?) throws -> Bool,
                   observe: ((Step) throws -> Void)?) throws -> (outcome: Outcome, statistics: MiMoMTPStatistics) {
        let prompt = request.prompt
        let started = MiMoTensorParallelModel.now()
        let caches = try model.model.makeIndependentHistoryCaches()
        var outcome = Outcome(caches: caches)
        let drafter = try MiMoTensorParallelDrafter(speculation, vocabularySize: model.plan.vocabularySize,
            maximumTokens: prompt.count + request.outputCount)
        defer { drafter.release() }
        let firstLogits = try prefill(prompt, chunk: request.chunk, caches: caches, drafter: drafter)
        var previousOperations: Int32 = 0, previousMegabytes: Int32 = 0
        mlx_metal_set_thread_command_buffer_limits(Int32(Self.decodeCommandBuffers.operations),
            Int32(Self.decodeCommandBuffers.megabytes), &previousOperations, &previousMegabytes)
        defer { mlx_metal_set_thread_command_buffer_limits(previousOperations, previousMegabytes, nil, nil) }

        var stopKeep: Float = 0
        var agreed = 0
        var last = 0
        /// Commits agreed tokens (rank 0 publishes each and hears its answer); true when they end the request.
        func commit(_ tokens: [Int], logprobs: [ClusterWorkerTokenLogprobs?]) throws -> Bool {
            for (index, token) in tokens.enumerated() where stopKeep == 0 {
                outcome.tokens.append(token)
                var wanted = true
                if rank == 0 { wanted = try publish(outcome.tokens.count - 1, token, logprobs[index]) }
                switch QwenTensorParallelStopRule.outcome(isStopToken: request.stopTokenIDs.contains(token),
                                                          committed: outcome.tokens.count,
                                                          outputCount: request.outputCount, wanted: wanted) {
                case .eos: outcome.finish = .eos
                case .length: outcome.finish = .length
                case .clientStop:
                    outcome.finish = .clientStop
                    outcome.ownerStopped = true
                    stopKeep = Float(outcome.tokens.count)
                case .proceed: break
                }
            }
            agreed += tokens.count
            last = tokens[tokens.count - 1]
            return request.stopTokenIDs.contains(last) || agreed >= request.outputCount
        }

        // The first token: the one-token step's agreement (no stop can be set yet).
        let first = try select(firstLogits, request: request, stop: 0, position: caches[0].offset)
        routes?.flush()
        outcome.firstTokenSeconds = MiMoTensorParallelModel.now() - started
        try observe?(first.step(0))
        request.sampler?.commit(first.token)
        var ended = try commit([first.token], logprobs: [first.logprobs])
        if !ended {
            try drafter.begin(firstToken: first.token)
            if stopKeep == 0, localStop() { stopKeep = Float(outcome.tokens.count); outcome.stoppedHere = true }
        }
        while !ended {
            let remaining = request.outputCount - agreed
            let count = min(drafter.depth, remaining - 1)
            let drafts = count >= 1 ? try drafter.draft(lastToken: last, nextIndex: agreed, count: count) : []
            if drafts.isEmpty {
                // A plain step: the one-token path's forward and selection.
                let logits = try forward([last], caches: caches)
                let choice = try select(logits, request: request, stop: stopKeep, position: caches[0].offset)
                routes?.flush()
                if let slot = choice.stop { endAtStop(slot, &outcome); break }
                try drafter.plainStep()
                try observe?(choice.step(agreed))
                request.sampler?.commit(choice.token)
                ended = try commit([choice.token], logprobs: [choice.logprobs])
            } else {
                let window = try model.model.forwardVerifyWindow(
                    inputIDs: MLXArray(([last] + drafts).map(Int32.init)).reshaped(1, drafts.count + 1), caches: caches)
                let round = try selectRound(window.logits, request: request, stop: stopKeep,
                                            position: caches[0].offset)
                if let slot = round.stop { endAtStop(slot, &outcome); break }
                let kept = try MiMoMTPAcceptance.kept(drafts: drafts, targets: round.targets, remaining: remaining,
                                                      stopTokens: request.stopTokenIDs)
                try MLX.withError { error in
                    try window.settle(keeping: kept.tokens.count)
                    eval(caches.flatMap { $0.innerState() })
                    try error.check()
                }
                try drafter.finalize(drafts: drafts, tokens: kept.tokens, acceptedDrafts: kept.acceptedDrafts,
                                     hidden: window.normalizedHiddenStates)
                let logprobs = try roundLogprobs(round, logits: window.logits, kept: kept.tokens, request: request)
                if let observe {
                    for (index, token) in kept.tokens.enumerated() {
                        try observe(.init(index: agreed + index, token: token, logits: window.logits[0..., index, 0...],
                            row: round.rows.map { $0[index ..< (index + 1)] }, top: nil, sampledLogprobs: nil))
                    }
                }
                request.sampler?.commitRound(kept.tokens)
                ended = try commit(kept.tokens, logprobs: logprobs)
            }
            if !ended, stopKeep == 0, localStop() { stopKeep = Float(outcome.tokens.count); outcome.stoppedHere = true }
        }
        try agreeRoundsEnd(&outcome)
        outcome.decodeSeconds = MiMoTensorParallelModel.now() - started - outcome.firstTokenSeconds
        return (outcome, drafter.statistics)
    }

    /// One round's agreement over a window's logits `[1, n, V or V/2]`: per
    /// rank `[maxima (n), tokens (n), stop, position]`, evaluated. Greedy rows
    /// put each column's FP32 maximum and its global ID (the strictly greater
    /// maximum wins, ties to the lower rank: each column's whole-row argmax);
    /// gathered rows put rank 0's keyed target sample at each column
    /// (`QwenStageTokenSampler.verifyRound`) and rank 1 an ignored argmax.
    func selectRound(_ logits: MLXArray, request: Request, stop: Float, position: Int) throws -> Round {
        let columns = logits.dim(1)
        let values = logits[0].asType(.float32)
        let selection = model.selection
        var rows: MLXArray?
        let mine: MLXArray
        switch request.rule {
        case .greedy, .greedyLogprobs:
            let ids = argMax(values, axis: -1).asType(.float32) + MLXArray(Float(selection.vocabularyRange.lowerBound))
            mine = concatenated([values.max(axis: -1), ids, MLXArray([stop, Float(position)])], axis: 0)
        case .gatheredRow:
            let whole = selection.gather(values)
            rows = whole
            let drawn = rank == 0
                ? request.sampler!.verifyRound(whole.reshaped(1, columns, -1)).reshaped(-1)
                : argMax(whole, axis: -1)
            mine = concatenated([MLXArray.zeros([columns], dtype: .float32), drawn.asType(.float32),
                                 MLXArray([stop, Float(position)])], axis: 0)
        }
        let width = 2 * columns + 2
        let ranks = reduction?.size ?? 1
        let all: MLXArray
        if let reduction {
            let empty = MLXArray.zeros([width], dtype: .float32)
            all = reduction.allSum(concatenated((0 ..< ranks).map { $0 == reduction.rank ? mine : empty }, axis: 0))
        } else {
            all = mine
        }
        try MLX.withError { error in
            eval([all] + (rows.map { [$0] } ?? []))
            try error.check()
        }
        let agreed = all.asArray(Float.self)
        guard agreed.count == width * ranks else { throw ProbeError("MiMo tensor parallel round agreement has a wrong shape") }
        func slot(_ rank: Int, _ field: Int) -> Float { agreed[width * rank + field] }
        guard (0 ..< ranks).allSatisfy({ slot($0, width - 1) == Float(position) }) else {
            throw ProbeError("MiMo tensor-parallel ranks are at different positions")
        }
        var targets: [Int] = [], maxima: [Float] = []
        for column in 0 ..< columns {
            var best = slot(0, column), token = Int(slot(0, columns + column))
            if request.rule != .gatheredRow {
                for other in 1 ..< ranks where slot(other, column) > best {
                    best = slot(other, column); token = Int(slot(other, columns + column))
                }
            }
            guard (0 ..< model.plan.vocabularySize).contains(token) else {
                throw ProbeError("MiMo tensor parallel round chose no token of the vocabulary")
            }
            targets.append(token); maxima.append(best)
        }
        let stops = (0 ..< ranks).map { slot($0, width - 2) }.filter { $0 > 0 }
        return Round(targets: targets, maxima: maxima, stop: stops.min(), rows: rows)
    }

    /// The kept columns' logprobs, when the request asks for them: one
    /// vocabulary-split top-k gather per kept column (both ranks know how many
    /// were kept), led by the column's agreed maximum even when an exactly tied
    /// token leads the gather; or the product sampler's own over the gathered rows.
    func roundLogprobs(_ round: Round, logits: MLXArray, kept: [Int], request: Request) throws
        -> [ClusterWorkerTokenLogprobs?] {
        switch request.rule {
        case .greedy:
            return Array(repeating: nil, count: kept.count)
        case .greedyLogprobs(let count):
            return try kept.indices.map { column in
                let gathered = try model.selection.topK(logits[0..., column, 0...], count: count)
                guard let first = gathered.logprobs.first, gathered.logits.first == round.maxima[column] else {
                    throw ProbeError("MiMo tensor parallel logprobs do not lead with the greedy token's logit")
                }
                return .init(logprob: first, top: zip(gathered.tokenIDs, gathered.logprobs).map {
                    .init(tokenID: $0, logprob: $1)
                })
            }
        case .gatheredRow:
            guard rank == 0, let sampler = request.sampler, sampler.wire.capturedLogprobs != nil else {
                return Array(repeating: nil, count: kept.count)
            }
            let gathered = sampler.takeRoundLogprobs(tokens: kept)
            guard gathered.count == kept.count else { throw ProbeError("MiMo tensor parallel round has no logprobs") }
            return gathered
        }
    }

    /// Every rank's count, finish and own-stop flag in one sum. Rank 1 adopts
    /// rank 0's count and finish when rank 0 stopped for its owner inside the
    /// last round (`QwenTensorParallelStopRule.reconcile`); any other difference
    /// means the ranks diverged.
    func agreeRoundsEnd(_ outcome: inout Outcome) throws {
        guard let reduction else { return }
        var slots = [Float](repeating: 0, count: 3 * reduction.size)
        slots[3 * reduction.rank] = Float(outcome.tokens.count)
        slots[3 * reduction.rank + 1] = Float(outcome.finish.code)
        slots[3 * reduction.rank + 2] = outcome.stoppedHere ? 1 : 0
        let summed = reduction.allSum(MLXArray(slots))
        try MLX.withError { error in eval(summed); try error.check() }
        let values = summed.asArray(Float.self)
        guard let rank0Finish = QwenTensorParallelStopRule.Finish(code: Int32(values[1])) else {
            throw ProbeError("MiMo tensor-parallel rank 0 ended with no finish")
        }
        let rank0Count = Int(values[0])
        for other in 0 ..< reduction.size {
            guard let finish = QwenTensorParallelStopRule.Finish(code: Int32(values[3 * other + 1])) else {
                throw ProbeError("MiMo tensor-parallel rank ended with no finish")
            }
            let reconciled = QwenTensorParallelStopRule.reconcile(rank: other, localFinish: finish,
                localCount: Int(values[3 * other]), localStopped: values[3 * other + 2] > 0,
                rank0Finish: rank0Finish, rank0Count: rank0Count)
            guard reconciled.finish == rank0Finish, reconciled.count == rank0Count else {
                throw ProbeError("MiMo tensor-parallel ranks ended the request differently")
            }
        }
        outcome.tokens = Array(outcome.tokens.prefix(rank0Count))
        outcome.finish = rank0Finish
    }
}
