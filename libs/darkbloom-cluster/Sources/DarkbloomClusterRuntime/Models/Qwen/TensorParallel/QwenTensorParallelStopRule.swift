/// How a tensor-parallel request ends, decided without MLX (model-free checks).
///
/// The product's engine answers "not wanted" for the token that ends a request
/// (a stop token, or the output limit), as it does for a client stop. A stop
/// token and the output limit end the request at that token whatever the
/// answer, in that order, exactly as the pipeline's decision packet decides
/// (`QwenLayerStageGenerationDecisionPacket`) and as the owner and rank 0's
/// worker session check: only a "not wanted" before either is a client stop.
/// (Before this rule, a stop token answered "not wanted" finished rank 0 as a
/// client stop; its session refused the finish, the worker ended, and the
/// installed path stopped serving after its first request.)
///
/// Both ranks then end on rank 0's outcome: rank 0 alone hears the answers,
/// and a client stop it made when no later step could carry its flag (the
/// step after it was already the last one built) leaves rank 1 at the output
/// limit with one token more. Rank 0's count and finish cross in one small
/// sealed agreement at the end of every request; rank 1 adopts them unless it
/// stopped on its own (cancelled, deadline, memory), which fails the request
/// on both ranks as before.
enum QwenTensorParallelStopRule {
    enum Outcome: Equatable { case proceed, eos, length, clientStop }

    enum Finish: Equatable {
        case eos, length, clientStop
        /// The integer that crosses in the end-of-request agreement (never 0).
        var code: Int32 {
            switch self {
            case .eos: 1
            case .length: 2
            case .clientStop: 3
            }
        }
        init?(code: Int32) {
            switch code {
            case 1: self = .eos
            case 2: self = .length
            case 3: self = .clientStop
            default: return nil
            }
        }
    }

    /// The outcome of the token just committed: `committed` tokens are held
    /// now, of `outputCount`; `wanted` is the owner's answer (always true on a
    /// rank that does not ask).
    static func outcome(isStopToken: Bool, committed: Int, outputCount: Int, wanted: Bool) -> Outcome {
        if isStopToken { return .eos }
        if committed >= outputCount { return .length }
        return wanted ? .proceed : .clientStop
    }

    /// The finish and token count this rank reports, given rank 0's.
    static func reconcile(rank: Int, localFinish: Finish, localCount: Int, localStopped: Bool,
                          rank0Finish: Finish, rank0Count: Int) -> (finish: Finish, count: Int) {
        guard rank != 0, !localStopped, localFinish != rank0Finish || localCount != rank0Count,
              rank0Count >= 0, rank0Count <= localCount else { return (localFinish, localCount) }
        return (rank0Finish, rank0Count)
    }
}
