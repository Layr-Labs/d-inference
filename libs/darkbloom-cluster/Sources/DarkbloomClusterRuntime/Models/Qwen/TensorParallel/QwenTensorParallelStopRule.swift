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
/// stopped on its own (cancelled, deadline, memory, pages): a memory stop
/// rank 0 ended on is an abort on both ranks (`readEnd`), and a cancel or the
/// deadline fails the request as before. A stop of rank 1's own that came too
/// late for any step to carry it, while rank 0 ended the request itself at
/// its stop token or its length, changes nothing the client gets: rank 1
/// reports rank 0's finish then, with the tokens it committed (two finishes
/// that differ fail the request on the owner, and with it the pair).
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

    /// A rank's stop slot when its KV pages could not grow
    /// (`GLM5NextTensorParallelPagedKV`): keep `keep` tokens and end at the
    /// request's length, not as a client stop. The offset tells the peer which
    /// it is (exact in float32: counts stay far below 2^22); a client stop's
    /// smaller slot wins when both ranks stop after the same step.
    static let lengthStopBase: Float = 4_194_304
    static func lengthStop(keep: Int) -> Float { Float(keep) + lengthStopBase }
    /// The tokens to keep and the finish a step's smallest nonzero stop slot names.
    static func stop(slot: Float) -> (keep: Int, finish: Finish) {
        slot >= lengthStopBase ? (Int(slot - lengthStopBase), .length) : (Int(slot), .clientStop)
    }

    /// The end-of-request agreement (D6): rank 0's count, finish and whether
    /// its owner asked to stop, then each rank's memory stop, each rank in
    /// words of its own (`QwenTensorParallelGroup.exchangeIntegers` sums them).
    static func endWords(rank: Int, count: Int, finish: Finish, clientStopped: Bool, stoppedForMemory: Bool) -> [Int32] {
        rank == 0 ? [Int32(count), finish.code, clientStopped ? 1 : 0, stoppedForMemory ? 1 : 0, 0]
            : [0, 0, 0, 0, stoppedForMemory ? 1 : 0]
    }

    struct End: Equatable {
        let rank0Count: Int
        let rank0Finish: Finish
        /// Set when a rank's live memory check stopped the request and nothing
        /// else ended it (its stop token, its length, its owner's stop): both
        /// ranks end it alone, naming that rank (rank 0 when both stopped).
        /// `abort` is its worker abort. (This file builds without the protocol
        /// module too, for TensorParallelPlanChecks.)
        let memoryStopRank: Int?
    }

    static func readEnd(_ words: [Int32]) throws -> End {
        guard words.count == 5, words[0] >= 0, let finish = Finish(code: words[1]),
              words[2...].allSatisfy({ $0 == 0 || $0 == 1 }) else {
            throw ProbeError("Tensor-parallel ranks did not agree how the request ended")
        }
        let memoryRank: Int? = words[3] == 1 ? 0 : words[4] == 1 ? 1 : nil
        let localStop = finish == .clientStop && words[2] == 0
        return .init(rank0Count: Int(words[0]), rank0Finish: finish, memoryStopRank: localStop ? memoryRank : nil)
    }

    /// The finish and token count this rank reports, given rank 0's. Rank 1
    /// takes rank 0's when it went on to the end; when it stopped on its own,
    /// only rank 0's stop token or length, which ended a request that is
    /// whole (rank 0 never holds fewer tokens than a rank that stopped).
    static func reconcile(rank: Int, localFinish: Finish, localCount: Int, localStopped: Bool,
                          rank0Finish: Finish, rank0Count: Int) -> (finish: Finish, count: Int) {
        guard rank != 0, rank0Count >= 0 else { return (localFinish, localCount) }
        if localStopped {
            guard rank0Finish != .clientStop, rank0Count >= localCount else { return (localFinish, localCount) }
            return (rank0Finish, localCount)
        }
        guard localFinish != rank0Finish || localCount != rank0Count, rank0Count <= localCount else {
            return (localFinish, localCount)
        }
        return (rank0Finish, rank0Count)
    }
}
