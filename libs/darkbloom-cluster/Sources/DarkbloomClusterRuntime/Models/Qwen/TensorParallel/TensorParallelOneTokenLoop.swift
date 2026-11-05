/// One tensor-parallel request's decode on one rank, one token a step,
/// without MLX (model-free checks): GLM tensor parallel's step order
/// (`GLM5NextTensorParallelStepLoop`) for runtimes whose steps are their
/// own. Greedy steps are built one ahead: step k+1 is submitted before step
/// k's choice is read, so the GPU and the collectives run step k+1 while the
/// host reads step k, answers the owner and commits (on two M5 Ultras, GLM's
/// pipelined step took 12.0 ms against 13.4 ms read-then-build). A sampled
/// step is built after its token is known (the sampler draws at the output
/// index with the history up to it).
///
/// Each step's agreement carries the agreed token and every rank's stop flag,
/// and a flag on either rank ends both after that step. A rank that stopped
/// after a step was built (rank 0 reads the owner's answer late) commits
/// nothing more, but still ends at a stop token its peer commits, so both
/// leave after the same step; the end-of-request agreement then settles each
/// rank's count and finish (`QwenTensorParallelStopRule.reconcile`). A step
/// both ranks built that the loop did not read is evaluated before it
/// returns, so its collectives meet on both ranks.
struct TensorParallelOneTokenLoop<Selection> {
    typealias Finish = QwenTensorParallelStopRule.Finish
    let outputCount: Int
    let stopTokenIDs: Set<Int>
    /// Greedy: each step is submitted before the previous step's choice is read.
    let pipelined: Bool
    /// Builds and submits the step after `selection`'s token, carrying this rank's stop flag.
    let step: (_ selection: Selection, _ stop: Float) throws -> Selection
    /// A step's evaluated agreement: the agreed token and every rank's stop flag.
    let read: (Selection) throws -> (token: Int, flags: [Float])
    /// Evaluates a step both ranks submitted that the loop did not read.
    let evaluate: (Selection) throws -> Void
    /// Grows the request's pages before the step after `committed` tokens is built.
    let growPages: () -> Void
    let pagesRefused: () -> Bool
    /// This rank's stop slot (0 while it goes on), and setting it.
    let stopKeep: () -> Float
    let setStopKeep: (Float) -> Void
    /// Rank 0: reads the owner's answer to the last published token.
    let readAnswer: () throws -> Void
    /// Tokens committed on this rank, and keeping only the first `count`.
    let committed: () -> Int
    let keep: (_ count: Int) -> Void
    /// Runs on every rank at each step whose agreement carried no stop flag,
    /// before this rank commits its token or skips it: a step's own
    /// collective every rank must take (a greedy step's logprobs gather).
    let agreedStep: (_ selection: Selection, _ token: Int) throws -> Void
    /// Commits one agreed token of `selection`'s step on this rank; the
    /// request's own end at it, else nil.
    let commit: (_ selection: Selection, _ token: Int) throws -> Finish?
    /// This rank stopped on its own (cancel, deadline, memory).
    let localStop: () -> Bool

    /// The steps from the first token's agreement; the finish the loop
    /// decided, or nil when it ran out of steps.
    func run(first: Selection) throws -> Finish? {
        var current = first, finish: Finish?
        var pending: Selection?
        steps: for index in 0 ..< outputCount {
            pending = nil
            if pipelined, index + 1 < outputCount {
                growPages()
                pending = try step(current, stopKeep())
            }
            // The answer to the last token arrived while this step ran.
            if stopKeep() == 0 { try readAnswer() }
            let agreed = try read(current)
            if let slot = agreed.flags.filter({ $0 > 0 }).min() {
                // A rank asked both to stop: both keep the tokens it named and
                // end here (at the request's length when its pages could not grow).
                let stop = QwenTensorParallelStopRule.stop(slot: slot)
                keep(stop.keep)
                finish = stop.finish == .length ? .length : .clientStop
                break
            }
            try agreedStep(current, agreed.token)
            if stopKeep() == 0 {
                if let end = try commit(current, agreed.token) { finish = end; break steps }
                if localStop() {
                    setStopKeep(Float(committed()))
                } else if pagesRefused() {
                    setStopKeep(QwenTensorParallelStopRule.lengthStop(keep: committed()))
                }
            } else if stopTokenIDs.contains(agreed.token) {
                // This rank's flag rides only a later step, which the peer,
                // ending at this stop token, would never join.
                break steps
            }
            if !pipelined, index + 1 < outputCount {
                growPages()
                if pagesRefused(), stopKeep() == 0 { setStopKeep(QwenTensorParallelStopRule.lengthStop(keep: committed())) }
                pending = try step(current, stopKeep())
            }
            guard let next = pending else { break }
            current = next; pending = nil
        }
        // A step both ranks submitted is evaluated by both, so its reductions meet.
        if let pending { try evaluate(pending) }
        return finish
    }
}
