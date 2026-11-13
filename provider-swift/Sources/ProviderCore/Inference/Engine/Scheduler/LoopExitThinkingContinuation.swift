// Copyright © 2026 Eigen Labs.

import Foundation
import Logging

/// Continues an answer whose thought the loop guard ended.
///
/// The bridge stops a row whose thought repeats verbatim exactly as it stops
/// any repeating row: the engine cancels it and its stream ends with a
/// `length` terminal. When the guard asked to end the thought instead
/// (`GenerationLoopExitRecord.requested`), this holds that terminal back, waits
/// for the row's stream to finish, and submits one continuation (its `submit`
/// first waits for the row to release its serving slot:
/// `EngineV2Bridge.waitForRowRelease`): the same prompt, every token the row
/// produced, then the family's end of thinking (`GenerationLoopExitThinking.exitTokens`),
/// with the output budget the row left (at most
/// `GenerationLoopExitThinking.answerTokenLimit`). The client sees one answer:
/// the thought, the exit text, then the continuation's text, and one terminal
/// whose usage is the original prompt and every token produced (the row's, the
/// exit's, the continuation's).
///
/// Anything that keeps the continuation from starting (under
/// `minimumAnswerBudget` tokens of budget left, a row that closed its thought
/// itself, a row that did not release its slot in time, a refused submission,
/// a continuation that fails before its first token, a cancel) ends the answer
/// exactly as before: the held `length` terminal. A continuation that fails
/// after its first token ends the answer there, as `length`; only the client's
/// cancel keeps its error.
enum LoopExitThinkingContinuation {
    /// `cancelled` is the splice's own cancel (its `cancel`, which an owner's
    /// disconnect hook can call while the splice's task keeps running): an
    /// owner checks it after its release wait and submits nothing once it is
    /// set, as it does for the task's cancellation.
    typealias Submit = @Sendable (
        _ promptTokens: [Int], _ maxTokens: Int, _ cancelled: @Sendable () -> Bool
    ) async throws -> AsyncStream<GenerationEvent>

    /// What happened to one request whose loop guard ended its thought.
    enum Outcome: Sendable, Equatable, CustomStringConvertible {
        /// The continuation produced the answer's end (its own terminal).
        case continued(continuationTokens: Int, finishReason: String?)
        /// It did not start: the request ended as `length`, as before.
        case endedAsLength(reason: String)
        /// It started and then was cancelled.
        case failedAfterStart
        /// It started and then failed: the answer ends there, as `length`.
        case cutAfterStart(reason: String)

        var description: String {
            switch self {
            case .continued(let tokens, let reason): "continued: \(tokens) answer tokens, \(reason ?? "no reason")"
            case .endedAsLength(let reason): "ended as length: \(reason)"
            case .failedAfterStart: "cancelled after the answer started"
            case .cutAfterStart(let reason): "cut after the answer started: \(reason)"
            }
        }
    }

    static let logger = Logger(label: "darkbloom.loop-guard.exit-thinking")

    /// The stopped row did not release its serving slot in time
    /// (`EngineV2Bridge.waitForRowRelease`).
    struct RowNotReleased: Error {}

    /// Below this answer budget the re-prefill of the whole thought is not
    /// worth it: the request ends as `length`, as before.
    static let minimumAnswerBudget = 256

    /// The spliced stream; its cancel, which stops whichever row is running;
    /// and `finished`, which returns once the splice is over: a continuation
    /// that a cancel overtook during the hand-off has been cancelled by then.
    /// An owner that returns its admission when the request ends joins it.
    static func splice(
        first: AsyncStream<GenerationEvent>,
        cancelFirst: @escaping @Sendable () async -> Void,
        exit: GenerationLoopExitThinking,
        promptTokens: [Int],
        outputBudget: Int,
        submit: @escaping Submit,
        cancelContinuation: @escaping @Sendable () async -> Void,
        onOutcome: (@Sendable (Outcome) -> Void)? = nil
    ) -> (events: AsyncStream<GenerationEvent>, cancel: @Sendable () async -> Void,
          finished: @Sendable () async -> Void) {
        let (events, out) = AsyncStream<GenerationEvent>.makeStream()
        let control = Control()
        let task = Task {
            await run(
                first: first, out: out, control: control, exit: exit, promptTokens: promptTokens,
                outputBudget: outputBudget, submit: submit, cancelContinuation: cancelContinuation,
                onOutcome: onOutcome)
        }
        let cancel: @Sendable () async -> Void = {
            let continuationStarted = control.cancel()
            await cancelFirst()
            if continuationStarted { await cancelContinuation() }
        }
        out.onTermination = { termination in
            guard case .cancelled = termination else { return }
            task.cancel()
            Task { await cancel() }
        }
        return (events, cancel, { await task.value })
    }

    private static func run(
        first: AsyncStream<GenerationEvent>,
        out: AsyncStream<GenerationEvent>.Continuation,
        control: Control,
        exit: GenerationLoopExitThinking,
        promptTokens: [Int],
        outputBudget: Int,
        submit: Submit,
        cancelContinuation: @Sendable () async -> Void,
        onOutcome: (@Sendable (Outcome) -> Void)?
    ) async {
        // The row's own events; only the guard's `length` terminal is held.
        var held: (prompt: Int, completion: Int, tokensPerSecond: Double)?
        for await event in first {
            if case .info(let prompt, let completion, let tps, let reason) = event,
               reason == "length", exit.record.requested != nil {
                held = (prompt, completion, tps)
                continue
            }
            out.yield(event)
        }
        guard let held else {
            out.finish()
            return
        }
        func endAsLength(_ reason: String) {
            out.yield(.info(
                promptTokens: held.prompt, completionTokens: held.completion,
                tokensPerSecond: held.tokensPerSecond, finishReason: "length"))
            out.finish()
            onOutcome?(.endedAsLength(reason: reason))
        }
        let generated = exit.record.generatedTokens
        // A row that closed its thought itself after the stop has no thought
        // left to end: the marker's own token says so (not the text around
        // it: Qwen's newlines are any text), or the text the guard followed.
        if let detection = exit.record.requested, exit.record.closedAfterStop
            || generated.dropFirst(detection.generatedTokens).contains(exit.closeToken) {
            return endAsLength("the row closed its thought itself")
        }
        let budget = min(outputBudget - held.completion - exit.exitTokens.count, exit.answerTokenLimit)
        guard budget >= minimumAnswerBudget else { return endAsLength("output budget left \(max(0, budget))") }
        guard !control.isCancelled, !Task.isCancelled else { return endAsLength("cancelled") }
        let continuation: AsyncStream<GenerationEvent>
        do {
            continuation = try await submit(promptTokens + generated + exit.exitTokens, budget, { control.isCancelled })
        } catch {
            return endAsLength(control.isCancelled || error is CancellationError
                ? "cancelled" : "continuation refused: \(error)")
        }
        guard control.markStarted() else {
            await cancelContinuation()
            return endAsLength("cancelled")
        }
        // Tokens the client is billed for before the continuation's own.
        let carried = held.completion + exit.exitTokens.count
        var started = false
        // The continuation's last reported completion, for a failure after it started.
        var answerTokens = 0
        // A failure after the answer started ends it as a cut `length`, as the
        // guard's own stop would have; only a cancel keeps its error framing.
        func endCut(_ reason: String, completion: Int) {
            out.yield(.info(
                promptTokens: held.prompt, completionTokens: carried + completion,
                tokensPerSecond: held.tokensPerSecond, finishReason: "length"))
            out.finish()
            onOutcome?(.cutAfterStart(reason: reason))
        }
        func start() {
            guard !started else { return }
            started = true
            out.yield(.chunk(exit.exitText))
        }
        for await event in continuation {
            switch event {
            case .chunk(let text):
                start()
                out.yield(.chunk(text))
            case .logprobs(let entries):
                start()
                out.yield(.logprobs(entries))
            case .info(_, let completion, let tps, let reason):
                // A cancelled continuation reports its usage with no reason,
                // then its error: before its first token that is a failure.
                guard reason != nil || started else { continue }
                start()
                answerTokens = completion
                if reason == nil, !control.isCancelled {
                    // Usage ahead of an error that is not the client's cancel:
                    // held for the cut `length` below.
                    continue
                }
                out.yield(.info(
                    promptTokens: held.prompt, completionTokens: carried + completion,
                    tokensPerSecond: tps, finishReason: reason))
                if reason != nil {
                    onOutcome?(.continued(continuationTokens: completion, finishReason: reason))
                }
            case .error(let message):
                guard started else { return endAsLength("continuation failed: \(message)") }
                guard control.isCancelled else { return endCut(message, completion: answerTokens) }
                out.yield(.error(message))
                onOutcome?(.failedAfterStart)
            case .terminal(let cause, _, _, let completion):
                guard started else { return endAsLength("continuation ended: \(cause.rawValue)") }
                return endCut(cause.rawValue, completion: completion)
            }
        }
        if !started {
            return endAsLength(control.isCancelled ? "cancelled" : "continuation ended before its first token")
        }
        out.finish()
    }

    /// Orders a cancel against the continuation's start: a cancel that wins
    /// keeps it from starting; one that loses also stops the continuation.
    final class Control: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var started = false

        var isCancelled: Bool { lock.withLock { cancelled } }

        /// Returns whether the continuation already started.
        func cancel() -> Bool {
            lock.withLock {
                cancelled = true
                return started
            }
        }

        /// Returns false when a cancel came first.
        func markStarted() -> Bool {
            lock.withLock {
                guard !cancelled else { return false }
                started = true
                return true
            }
        }
    }
}
