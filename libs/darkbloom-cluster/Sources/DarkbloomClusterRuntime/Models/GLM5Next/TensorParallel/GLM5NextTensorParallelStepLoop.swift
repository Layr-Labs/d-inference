import DarkbloomClusterProtocol

/// One GLM tensor-parallel request's decode on one rank, one token a step:
/// the path without a NextN layer (`GLM5NextTensorParallelResidentRuntime.mtpDepth`
/// 0); with one, every request decodes in MTP rounds. Greedy steps are built
/// one ahead: step k+1 is submitted before step k's choice is read. A sampled
/// step is built after its token is known (the sampler draws at the output
/// index with the history up to it). Each step's agreement carries both
/// ranks' tokens and stop flags (`GLM5NextTensorParallelResidentRuntime.choose`),
/// and a flag on either rank ends both after that step. The runtime supplies
/// the steps and its request's state, so two ranks can run it without a model.
struct GLM5NextTensorParallelStepLoop<Selection> {
    let outputCount: Int
    let promptCount: Int
    let stopTokenIDs: Set<Int>
    /// Greedy: each step is submitted before the previous step's choice is read.
    let pipelined: Bool
    /// Builds and submits the step after `selection`'s token, carrying this rank's stop flag.
    let step: (_ selection: Selection, _ stop: Float) throws -> Selection
    /// A step's evaluated agreement: [token rank 0, token rank 1, stop rank 0, stop rank 1].
    let agreement: (Selection) throws -> [Float]
    /// Evaluates a step both ranks submitted that the loop did not read.
    let evaluate: (Selection) throws -> Void
    /// The request's pages, before a step that brings it to `needed` context tokens is built.
    let growPages: (_ needed: Int) -> Void
    let pagesRefused: () -> Bool
    /// This rank's stop slot (0 while it goes on), and setting it.
    let stopKeep: () -> Float
    let setStopKeep: (Float) -> Void
    /// Rank 0: reads the owner's answer to the last published token.
    let readAnswer: () throws -> Void
    /// Tokens committed on this rank, and keeping only the first `count`.
    let committed: () -> Int
    let keep: (_ count: Int) -> Void
    /// Commits one agreed token on this rank; the request's own end at it, else nil.
    let commit: (Int) throws -> ClusterWorkerFinishReason?
    /// This rank stopped on its own (cancel, deadline, memory).
    let localStop: () -> Bool

    /// The steps from the first token's agreement; the finish the loop
    /// decided, or nil when it ran out of steps.
    func run(first: Selection) throws -> ClusterWorkerFinishReason? {
        var current = first, finish: ClusterWorkerFinishReason?
        var pending: Selection?
        steps: for index in 0 ..< outputCount {
            pending = nil
            if pipelined, index + 1 < outputCount {
                growPages(promptCount + index + 2)
                pending = try step(current, stopKeep())
            }
            // The answer to the last token arrived while this step was encoded.
            if stopKeep() == 0 { try readAnswer() }
            let agreed = try agreement(current)
            let value = try GLM5NextTensorParallelResidentRuntime.agreedToken(agreed, sampled: !pipelined)
            let flags = [agreed[2], agreed[3]].filter { $0 > 0 }
            if let slot = flags.min() {
                let stop = QwenTensorParallelStopRule.stop(slot: slot)
                keep(stop.keep)
                finish = stop.finish == .length ? .length : .clientStop; break
            }
            if stopKeep() == 0 {
                if let end = try commit(value) { finish = end; break steps }
                if localStop() {
                    setStopKeep(Float(committed()))
                } else if pagesRefused() {
                    setStopKeep(QwenTensorParallelStopRule.lengthStop(keep: committed()))
                }
            }
            if !pipelined, index + 1 < outputCount {
                growPages(promptCount + index + 2)
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
