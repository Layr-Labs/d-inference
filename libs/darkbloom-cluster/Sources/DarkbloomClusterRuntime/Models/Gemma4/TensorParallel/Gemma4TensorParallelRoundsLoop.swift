import DarkbloomClusterProtocol
import Foundation
import MLX

extension Gemma4TensorParallelRequestLoop {
    /// The request's decode in speculative rounds (`Gemma4TensorParallelRounds`)
    /// instead of one step a token: the prompt and its token as `run` takes
    /// them, then rounds until the request ends.
    ///
    /// Stops follow `run`'s rules with a round in place of a step: rank 0
    /// publishes each kept token and hears the owner's answer to it at once
    /// (a stop answer stops rank 0's commits there); a stop on either rank
    /// (`localStop`, the owner's answer, pages that could not grow) rides in
    /// the next round's agreement, and both ranks keep the tokens it names and
    /// end after that round. A round that ends the request by itself (a stop
    /// token or the length, which every rank sees in the agreed tokens) ends
    /// both after it. At the end rank 0's count and finish cross in one small
    /// agreement and rank 1 adopts them, as `run` does.
    func runRounds(_ rounds: Gemma4TensorParallelRounds, channel: ClusterCommittedTokenChannel,
                   check: () throws -> Void) throws -> Outcome {
        let rank = choice.rank, prompt = request.promptTokenIDs
        let sampler = choice.sampler
        var offset = session.committedTokens
        var current: (logits: MLXArray, selected: MLXArray)?
        while offset < prompt.count {
            let end = min(prompt.count, offset + request.chunkSize)
            current = try session.prefill(prompt, range: offset ..< end, check: check) { choice.build($0, stop: 0) } ?? current
            offset = end
        }
        guard let step = current else { throw ProbeError("Gemma tensor-parallel prompt produced no logits") }
        var tokens: [Int] = []
        var finish: ClusterWorkerFinishReason = .length
        var clientStopped = false
        var stopKeep: Float = 0
        var pagesRefused = false
        let stops = Set(request.stopTokenIDs)
        let logprobCount = sampler?.wire.capturedLogprobs
        /// Commits one agreed token on this rank (rank 0 publishes it and hears
        /// the owner's answer): the request's own end at it, else nil.
        func commit(_ value: Int, logprobs: ClusterWorkerTokenLogprobs?) throws -> ClusterWorkerFinishReason? {
            tokens.append(value)
            if rank == 0 {
                try channel.publishToken(tokens.count - 1, value, prompt.count + tokens.count - 1, logprobs)
                if try !channel.answer(), stopKeep == 0 { clientStopped = true; stopKeep = Float(tokens.count) }
            }
            switch QwenTensorParallelStopRule.outcome(isStopToken: stops.contains(value),
                                                      committed: tokens.count, outputCount: request.outputCount, wanted: true) {
            case .eos: return .eos
            case .length: return .length
            case .clientStop, .proceed: return nil
            }
        }
        try GPU.withCommandBufferLimits(Gemma4TensorParallelModel.decodeCommandBuffers) {
            // The prompt's token: the plain step's choice (no stop can be set yet).
            let first = try choice.read(step.selected)
            var logprobs: ClusterWorkerTokenLogprobs?
            if let count = logprobCount {
                if choice.gathersRow {
                    if rank == 0 { logprobs = sampler?.takePendingLogprobs() }
                } else {
                    let gathered = try choice.logprobs(step.logits, token: first.token, maximum: first.maximum, count: count)
                    logprobs = rank == 0 ? gathered : nil
                }
            }
            sampler?.commit(first.token)
            if let end = try commit(first.token, logprobs: logprobs) { finish = end; return }
            if stopKeep == 0, localStop() { stopKeep = Float(tokens.count) }
            try rounds.start(check: check)
            var last = first.token, agreed = 1
            rounds: while agreed < request.outputCount {
                let remaining = request.outputCount - agreed
                var proposals = min(rounds.assistant.depth, remaining - 1)
                // Pages grow ahead of the window; a refused growth leaves a
                // one-row round its page and carries the length stop.
                if !pagesRefused, !session.pagesCover(writing: proposals + 1),
                   !session.reservePages(writing: proposals + 1) {
                    pagesRefused = true
                    if stopKeep == 0 { stopKeep = QwenTensorParallelStopRule.lengthStop(keep: tokens.count) }
                }
                if pagesRefused { proposals = 0 }
                let round = try rounds.round(lastToken: last, proposals: proposals, stop: stopKeep,
                    remaining: remaining, stopTokens: stops, check: check)
                if let slot = round.flags.filter({ $0 > 0 }).min() {
                    // A rank asked both to stop: both keep the tokens it named and end here.
                    let stop = QwenTensorParallelStopRule.stop(slot: slot)
                    tokens = Array(tokens.prefix(stop.keep))
                    finish = stop.finish == .length ? .length : .clientStop
                    break rounds
                }
                var logprobs = [ClusterWorkerTokenLogprobs?](repeating: nil, count: round.tokens.count)
                if let count = logprobCount {
                    if choice.gathersRow {
                        if rank == 0, let sampler {
                            let taken = round.proposed == 0 ? sampler.takePendingLogprobs().map { [$0] } ?? []
                                : sampler.takeRoundLogprobs(tokens: round.tokens)
                            guard taken.count == round.tokens.count else {
                                throw ProbeError("Gemma speculative round has no logprobs for its tokens")
                            }
                            logprobs = taken
                        }
                    } else {
                        for (index, token) in round.tokens.enumerated() {
                            let gathered = try choice.logprobs(round.logits[index ..< index + 1], token: token,
                                maximum: round.maxima[index], count: count)
                            logprobs[index] = rank == 0 ? gathered : nil
                        }
                    }
                }
                if round.proposed == 0 { sampler?.commit(round.tokens[0]) } else { sampler?.commitRound(round.tokens) }
                agreed += round.tokens.count
                last = round.tokens[round.tokens.count - 1]
                for (index, token) in round.tokens.enumerated() {
                    if stopKeep == 0 {
                        if let end = try commit(token, logprobs: logprobs[index]) { finish = end; break rounds }
                    } else if stops.contains(token) {
                        // The stop rides only the next round; the peer ends at this token.
                        break rounds
                    }
                }
                if stopKeep == 0, localStop() { stopKeep = Float(tokens.count) }
            }
        }
        if clientStopped || (stopKeep > 0 && stopKeep < QwenTensorParallelStopRule.lengthStopBase) { finish = .clientStop }
        let localFinish: QwenTensorParallelStopRule.Finish = finish == .eos ? .eos : finish == .length ? .length : .clientStop
        let agreedEnd = try exchange(rank == 0 ? [Int32(tokens.count), localFinish.code] : [0, 0])
        guard agreedEnd.count == 2, let rank0Finish = QwenTensorParallelStopRule.Finish(code: agreedEnd[1]) else {
            throw ProbeError("Gemma tensor-parallel ranks did not agree how the request ended")
        }
        let ended = QwenTensorParallelStopRule.reconcile(rank: rank, localFinish: localFinish, localCount: tokens.count,
            localStopped: stopKeep > 0 && !clientStopped, rank0Finish: rank0Finish, rank0Count: Int(agreedEnd[0]))
        tokens = Array(tokens.prefix(ended.count))
        switch ended.finish {
        case .eos: finish = .eos
        case .length: finish = .length
        case .clientStop: finish = .clientStop
        }
        return .init(tokens: tokens, finish: finish, clientStopped: clientStopped, pagesRefused: pagesRefused)
    }
}
