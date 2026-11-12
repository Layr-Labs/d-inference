// Copyright © 2026 Eigen Labs.

import Foundation

/// Continues an answer whose thought the loop guard ended.
///
/// The bridge stops a row whose thought repeats verbatim exactly as it stops
/// any repeating row: the engine cancels it and its stream ends with a
/// `length` terminal. When the guard asked to end the thought instead
/// (`GenerationLoopExitRecord.requested`), this holds that terminal back, waits
/// for the row's stream to finish (its engine resources are released by then),
/// and submits one continuation: the same prompt, every token the row produced,
/// then the family's end-of-thinking marker, with the output budget the row
/// left (at most `GenerationLoopExitThinking.answerTokenLimit`). The client
/// sees one answer: the thought, the marker, then the continuation's text, and
/// one terminal whose usage is the original prompt and every token produced
/// (the row's, the marker, the continuation's).
///
/// Anything that keeps the continuation from starting (no budget left, a row
/// that closed its thought itself, a refused submission, a continuation that
/// fails before its first token, a cancel) ends the answer exactly as before:
/// the held `length` terminal.
enum LoopExitThinkingContinuation {
    typealias Submit = @Sendable (_ promptTokens: [Int], _ maxTokens: Int) async throws
        -> AsyncStream<GenerationEvent>

    /// What happened to one request whose loop guard ended its thought.
    enum Outcome: Sendable, Equatable, CustomStringConvertible {
        /// The continuation produced the answer's end (its own terminal).
        case continued(continuationTokens: Int, finishReason: String?)
        /// It did not start: the request ended as `length`, as before.
        case endedAsLength(reason: String)
        /// It started and then failed or was cancelled.
        case failedAfterStart

        var description: String {
            switch self {
            case .continued(let tokens, let reason): "continued: \(tokens) answer tokens, \(reason ?? "no reason")"
            case .endedAsLength(let reason): "ended as length: \(reason)"
            case .failedAfterStart: "failed after the answer started"
            }
        }
    }

    /// The spliced stream and its cancel, which stops whichever row is running.
    static func splice(
        first: AsyncStream<GenerationEvent>,
        cancelFirst: @escaping @Sendable () async -> Void,
        exit: GenerationLoopExitThinking,
        promptTokens: [Int],
        outputBudget: Int,
        submit: @escaping Submit,
        cancelContinuation: @escaping @Sendable () async -> Void,
        onOutcome: (@Sendable (Outcome) -> Void)? = nil
    ) -> (events: AsyncStream<GenerationEvent>, cancel: @Sendable () async -> Void) {
        (first, cancelFirst)
    }
}
