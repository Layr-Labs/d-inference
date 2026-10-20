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
    public let publish: (Int, Int, Int) throws -> Void
    public let answer: () throws -> Bool

    public init(publish: @escaping (Int, Int, Int) throws -> Void, answer: @escaping () throws -> Bool) {
        self.publish = publish; self.answer = answer
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
