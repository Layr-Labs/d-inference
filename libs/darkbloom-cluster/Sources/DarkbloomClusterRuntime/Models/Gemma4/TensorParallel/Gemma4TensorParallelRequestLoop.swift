import DarkbloomClusterProtocol
import Foundation
import MLX

/// One request on one rank of a Gemma 4 tensor-parallel pair, as the resident
/// runtime serves it alone: the prompt in chunks of the request's own size,
/// then one decode step a token. Each step's token and both ranks' stop flags
/// are agreed in the step's own evaluation (`Gemma4TensorParallelChoice`);
/// both ranks submit the same collectives in the same order whatever either
/// decides, and end after the same step.
///
/// Rank 0 publishes each token at once and reads the owner's answer to it
/// after the next step ran; a stop answer is acted on one step later (the
/// extra step is computed and never published). A stop on either rank
/// (`localStop`: cancel, deadline, memory; or pages that could not grow)
/// rides in the next step's flags. A rank that stopped commits nothing more
/// but still ends at a stop token its peer commits, so both leave after the
/// same step. At the end rank 0's count and finish cross in one small
/// agreement (`exchange`) and rank 1 adopts them
/// (`QwenTensorParallelStopRule.reconcile`), as GLM's tensor parallel does.
struct Gemma4TensorParallelRequestLoop {
    let session: Gemma4TensorParallelPagedSession
    let request: QwenLayerStageGenerationRequest
    let choice: Gemma4TensorParallelChoice
    /// Every rank's integers summed, evaluated now (each rank fills its own
    /// slots, the others zero): `QwenTensorParallelGroup.exchangeIntegers`.
    let exchange: ([Int32]) throws -> [Int32]
    /// This rank wants to stop now (checked after each committed token).
    let localStop: () -> Bool

    struct Outcome {
        var tokens: [Int]
        var finish: ClusterWorkerFinishReason
        /// The owner answered a token with stop.
        var clientStopped: Bool
        var pagesRefused: Bool
    }

    func run(channel: ClusterCommittedTokenChannel, check: () throws -> Void) throws -> Outcome {
        let rank = choice.rank, prompt = request.promptTokenIDs
        let sampler = choice.sampler
        var offset = 0
        var current: (logits: MLXArray, selected: MLXArray)?
        while offset < prompt.count {
            let end = min(prompt.count, offset + request.chunkSize)
            current = try session.prefill(prompt, range: offset ..< end, check: check) { choice.build($0, stop: 0) } ?? current
            offset = end
        }
        guard var step = current else { throw ProbeError("Gemma tensor-parallel prompt produced no logits") }
        var tokens: [Int] = []
        var finish: ClusterWorkerFinishReason = .length
        var clientStopped = false
        var stopKeep: Float = 0
        var pagesRefused = false
        var unanswered = false
        func readAnswer() throws {
            guard unanswered else { return }
            unanswered = false
            if try !channel.answer(), stopKeep == 0 { clientStopped = true; stopKeep = Float(tokens.count) }
        }
        let logprobCount = sampler?.wire.capturedLogprobs
        /// Commits one agreed token on this rank (and publishes it on rank 0):
        /// the request's own end at it (EOS or length), else nil.
        func commit(_ value: Int, logprobs: ClusterWorkerTokenLogprobs?) throws -> ClusterWorkerFinishReason? {
            tokens.append(value)
            if rank == 0 {
                try channel.publishToken(tokens.count - 1, value, prompt.count + tokens.count - 1, logprobs)
                unanswered = true
            }
            switch QwenTensorParallelStopRule.outcome(isStopToken: request.stopTokenIDs.contains(value),
                                                      committed: tokens.count, outputCount: request.outputCount, wanted: true) {
            case .eos: return .eos
            case .length: return .length
            case .clientStop, .proceed: return nil
            }
        }
        try GPU.withCommandBufferLimits(Gemma4TensorParallelModel.decodeCommandBuffers) {
            steps: for index in 0 ..< request.outputCount {
                // The answer to the last token arrived while this step ran.
                if stopKeep == 0 { try readAnswer() }
                let agreed = try choice.read(step.selected)
                if let slot = agreed.flags.filter({ $0 > 0 }).min() {
                    // A rank asked both to stop: both keep the tokens it named
                    // and end here (at the request's length when its pages could not grow).
                    let stop = QwenTensorParallelStopRule.stop(slot: slot)
                    tokens = Array(tokens.prefix(stop.keep))
                    finish = stop.finish == .length ? .length : .clientStop
                    break steps
                }
                // A greedy step's logprobs come from the split top-k gather, a
                // collective every rank takes; a sampled one's from rank 0's draw.
                var logprobs: ClusterWorkerTokenLogprobs?
                if let count = logprobCount {
                    if choice.gathersRow {
                        if rank == 0, stopKeep == 0 {
                            guard let drawn = sampler?.takePendingLogprobs() else {
                                throw ProbeError("Gemma tensor-parallel token has no logprobs")
                            }
                            logprobs = drawn
                        }
                    } else {
                        let gathered = try choice.logprobs(step.logits, token: agreed.token, maximum: agreed.maximum,
                                                           count: count)
                        logprobs = rank == 0 ? gathered : nil
                    }
                }
                if stopKeep == 0 {
                    sampler?.commit(agreed.token)
                    if let end = try commit(agreed.token, logprobs: logprobs) { finish = end; break steps }
                    if localStop() {
                        stopKeep = Float(tokens.count)
                    } else if pagesRefused {
                        stopKeep = QwenTensorParallelStopRule.lengthStop(keep: tokens.count)
                    }
                } else if request.stopTokenIDs.contains(agreed.token) {
                    // The owner's stop was read after this step ran, so only the
                    // next step could carry it; the peer ends at this token.
                    break steps
                }
                guard index + 1 < request.outputCount else { break steps }
                // Pages grow a granule ahead, at least a margin before they are
                // needed: a growth the pool refuses still leaves this step its
                // row, and the step carries the length stop (rank-local; the
                // collectives are the same either way).
                if !pagesRefused {
                    pagesRefused = !session.reservePages(writing: 1)
                    if pagesRefused, stopKeep == 0 { stopKeep = QwenTensorParallelStopRule.lengthStop(keep: tokens.count) }
                }
                step = try session.decode(agreed.token, check: check) { choice.build($0, stop: stopKeep) }
            }
        }
        // The owner answers every published token, the last one too. A stop
        // answer to a token the request ended at changes nothing.
        if unanswered {
            unanswered = false
            if try !channel.answer(), finish == .clientStop { clientStopped = true }
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
