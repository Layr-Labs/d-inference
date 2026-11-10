import DarkbloomClusterProtocol
import Foundation
import MLX
import MLXLMCommon

/// One request on one rank of a Gemma 4 tensor-parallel pair, as the resident
/// runtime serves it alone: the prompt in chunks of the request's own size
/// (from a restored prefix's boundary, when both ranks restored one), then
/// one decode step a token (`TensorParallelOneTokenLoop`, GLM tensor
/// parallel's step order). Each step's token and both ranks' stop flags
/// are agreed in the step's own evaluation (`Gemma4TensorParallelChoice`);
/// both ranks submit the same collectives in the same order whatever either
/// decides, and end after the same step. Each step is built one ahead, on
/// the previous step's lazy agreed token
/// (`Gemma4TensorParallelPagedSession.submitDecode`), so the GPU and the
/// collectives run it while the host reads the previous one: greedy and
/// sampled requests (rank 0's keyed draw is the one made at its output index
/// with the history up to it), but not a greedy request asking for logprobs
/// (`pipelines`). A step built after the request ended is evaluated; its
/// token is never committed or published.
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
    /// Its stop was its live memory check's refusal (D6): the end agreement
    /// then makes the request a memory abort on both ranks.
    var stoppedForMemory: () -> Bool = { false }

    struct Outcome {
        var tokens: [Int]
        var finish: ClusterWorkerFinishReason
        /// The owner answered a token with stop.
        var clientStopped: Bool
        var pagesRefused: Bool
        /// Both ranks ended the request alone for a rank's memory (D6).
        var abort: ClusterWorkerAbort? = nil
    }

    /// One built step: its logits, its agreement (`Gemma4TensorParallelChoice.build`)
    /// and, on rank 0 of a sampled request asking for them, its draw's
    /// logprobs as graph nodes (kept with the step, as the next step's draw
    /// may be built before this one is read).
    struct Step {
        let logits: MLXArray
        let selected: MLXArray
        let logprobs: CBv2StepLogprobs?
    }

    /// Whether `choice`'s steps are built one ahead: greedy and sampled
    /// requests alike (each draw is keyed on its output index and its
    /// history on the device, `QwenStageTokenSampler.sample`). A greedy
    /// request asking for logprobs reads each step before building the next:
    /// its logprobs come from a vocabulary-split top-k gather, a collective
    /// evaluated on the host after the step's token is agreed, which would
    /// wait for the step built ahead and gain nothing.
    static func pipelines(_ choice: Gemma4TensorParallelChoice) -> Bool {
        if let buildsAhead { return buildsAhead }
        return choice.gathersRow || choice.sampler?.wire.capturedLogprobs == nil
    }
    /// Tests only: a test's own order (nil: `pipelines`'s). The product never sets it.
    @TaskLocal static var buildsAhead: Bool?

    func run(channel: ClusterCommittedTokenChannel, check: () throws -> Void) throws -> Outcome {
        let rank = choice.rank, prompt = request.promptTokenIDs
        let sampler = choice.sampler
        // A restored prefix ends on the chunk grid: the rest runs the chunks a cold request runs there.
        var offset = session.committedTokens
        /// A built step, with rank 0's sampled draw's logprobs taken now.
        func built(_ step: (logits: MLXArray, selected: MLXArray)) -> Step {
            let logprobs = rank == 0 && choice.gathersRow ? sampler?.takePendingStepLogprobs() : nil
            return Step(logits: step.logits, selected: step.selected, logprobs: logprobs)
        }
        var current: Step?
        while offset < prompt.count {
            let end = min(prompt.count, offset + request.chunkSize)
            current = try session.prefill(prompt, range: offset ..< end, check: check) { choice.build($0, stop: 0) }
                .map(built) ?? current
            offset = end
        }
        guard let step = current else { throw ProbeError("Gemma tensor-parallel prompt produced no logits") }
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
        var stepLogprobs: ClusterWorkerTokenLogprobs?
        /// Commits one agreed token on this rank (and publishes it on rank 0):
        /// the request's own end at it (EOS or length), else nil.
        func commit(_ value: Int, logprobs: ClusterWorkerTokenLogprobs?) throws -> QwenTensorParallelStopRule.Finish? {
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
        try withoutActuallyEscaping(check) { check in
            // Steps are built one ahead (`TensorParallelOneTokenLoop`, GLM's step order): the next step is submitted
            // on this step's lazy agreed token before the host reads it (`pipelines`).
            let pipelined = Self.pipelines(choice)
            let steps = TensorParallelOneTokenLoop<Step>(
                outputCount: request.outputCount, stopTokenIDs: request.stopTokenIDs, pipelined: pipelined,
                step: { current, stop in
                    let select: (MLXArray) -> MLXArray = { choice.build($0, stop: stop) }
                    return try built(pipelined ? session.submitDecode(after: current.selected, check: check, select: select)
                        : session.decode(choice.read(current.selected).token, check: check, select: select))
                },
                read: { current in
                    let agreed = try choice.read(current.selected)
                    return (agreed.token, agreed.flags)
                },
                evaluate: { eval($0.selected); try check() },
                // Pages grow a granule ahead, at least a margin before they are
                // needed: a growth the pool refuses still leaves the next step its
                // row, and a later step carries the length stop (rank-local; the
                // collectives are the same either way).
                growPages: { if !pagesRefused { pagesRefused = !session.reservePages(writing: 1) } },
                pagesRefused: { pagesRefused },
                stopKeep: { stopKeep }, setStopKeep: { stopKeep = $0 }, readAnswer: readAnswer,
                committed: { tokens.count }, keep: { tokens = Array(tokens.prefix($0)) },
                agreedStep: { current, token in
                    // A greedy step's logprobs come from the split top-k gather, a
                    // collective every rank takes, a stopped rank too; a sampled
                    // one's from rank 0's draw.
                    stepLogprobs = nil
                    guard let count = logprobCount else { return }
                    if choice.gathersRow {
                        if rank == 0, stopKeep == 0 {
                            guard let drawn = current.logprobs else {
                                throw ProbeError("Gemma tensor-parallel token has no logprobs")
                            }
                            stepLogprobs = QwenStageTokenSampler.tokenLogprobs(drawn)
                        }
                    } else {
                        let maximum = try choice.read(current.selected).maximum
                        let gathered = try choice.logprobs(current.logits, token: token, maximum: maximum, count: count)
                        stepLogprobs = rank == 0 ? gathered : nil
                    }
                },
                commit: { _, token in
                    sampler?.commit(token)
                    return try commit(token, logprobs: stepLogprobs)
                },
                localStop: localStop)
            try GPU.withCommandBufferLimits(Gemma4TensorParallelModel.decodeCommandBuffers) {
                if let ended = try steps.run(first: step) {
                    finish = ended == .eos ? .eos : ended == .length ? .length : .clientStop
                }
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
        let localStopped = stopKeep > 0 && stopKeep < QwenTensorParallelStopRule.lengthStopBase && !clientStopped
        let agreedEnd = try QwenTensorParallelStopRule.readEnd(exchange(QwenTensorParallelStopRule.endWords(rank: rank,
            count: tokens.count, finish: localFinish, clientStopped: clientStopped,
            stoppedForMemory: localStopped && stoppedForMemory())))
        if let abort = agreedEnd.abort {
            return .init(tokens: tokens, finish: .clientStop, clientStopped: false, pagesRefused: pagesRefused, abort: abort)
        }
        let ended = QwenTensorParallelStopRule.reconcile(rank: rank, localFinish: localFinish, localCount: tokens.count,
            localStopped: stopKeep > 0 && !clientStopped, rank0Finish: agreedEnd.rank0Finish, rank0Count: agreedEnd.rank0Count)
        tokens = Array(tokens.prefix(ended.count))
        switch ended.finish {
        case .eos: finish = .eos
        case .length: finish = .length
        case .clientStop: finish = .clientStop
        }
        return .init(tokens: tokens, finish: finish, clientStopped: clientStopped, pagesRefused: pagesRefused)
    }
}
