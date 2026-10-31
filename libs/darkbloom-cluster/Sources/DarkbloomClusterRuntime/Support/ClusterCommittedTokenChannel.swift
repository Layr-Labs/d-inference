import DarkbloomClusterProtocol
import Foundation

/// Rank 0's committed tokens to its owner, in two halves, so a runtime can
/// let the owner's answer cross the pipes while it encodes and runs its next
/// step instead of between steps. `publish` hands over one committed token
/// (ordinal, token, committed frontier) and returns without waiting;
/// `answer` waits for the owner's answer to it (true: go on). The protocol's
/// token credit holds as before: exactly one `answer` follows every
/// `publish` before the next `publish`, and nothing is published after an
/// answer that stops (`ClusterWorkerSession` refuses either). A runtime
/// that reads answers late may compute a step or round past a stop, which
/// it never publishes.
public struct ClusterCommittedTokenChannel {
    /// One committed token with the decoding rank's logprobs for it, when the
    /// request asks for them (`ClusterWorkerSampling.topLogprobs`).
    public let publishToken: (Int, Int, Int, ClusterWorkerTokenLogprobs?) throws -> Void
    public let answer: () throws -> Bool

    public init(publish: @escaping (Int, Int, Int) throws -> Void, answer: @escaping () throws -> Bool) {
        self.publishToken = { ordinal, token, frontier, _ in try publish(ordinal, token, frontier) }
        self.answer = answer
    }

    public init(publishToken: @escaping (Int, Int, Int, ClusterWorkerTokenLogprobs?) throws -> Void,
                answer: @escaping () throws -> Bool) {
        self.publishToken = publishToken; self.answer = answer
    }

    /// A committed token without logprobs.
    public func publish(_ ordinal: Int, _ token: Int, _ frontier: Int) throws {
        try publishToken(ordinal, token, frontier, nil)
    }

    /// The one-call form (publish, then wait for the answer) as a channel,
    /// for `body`'s duration.
    public static func answering<T>(_ callback: (Int, Int, Int) throws -> Bool,
                                    _ body: (ClusterCommittedTokenChannel) throws -> T) throws -> T {
        try withoutActuallyEscaping(callback) { callback in
            let pending = PendingAnswer()
            return try body(.init(publish: { pending.answer = try callback($0, $1, $2) }, answer: {
                guard let value = pending.answer else { throw ProbeError("Token answer read before its token was published") }
                pending.answer = nil
                return value
            }))
        }
    }
}

/// The answer the one-call form got with its token, until it is read.
private final class PendingAnswer { var answer: Bool? }
