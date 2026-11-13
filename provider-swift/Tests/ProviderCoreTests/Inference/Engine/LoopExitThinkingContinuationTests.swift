// Copyright © 2026 Eigen Labs.

import Foundation
import Testing

@testable import ProviderCore

@Suite("Continuing an answer after the loop guard ended its thought")
struct LoopExitThinkingContinuationTests {
    private static let prompt = [1, 2, 3, 4, 5]
    private static let close = GemmaThoughtTestTokenizer.channelClose

    /// What the continuation was asked for, and what was cancelled.
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var submitted: [(prompt: [Int], maxTokens: Int)] = []
        private var firstCancels = 0
        private var continuationCancels = 0

        func submit(_ prompt: [Int], _ maxTokens: Int) { lock.withLock { submitted.append((prompt, maxTokens)) } }
        func cancelFirst() { lock.withLock { firstCancels += 1 } }
        func cancelContinuation() { lock.withLock { continuationCancels += 1 } }
        var submits: [(prompt: [Int], maxTokens: Int)] { lock.withLock { submitted } }
        var cancels: (first: Int, continuation: Int) { lock.withLock { (firstCancels, continuationCancels) } }
    }

    private struct Refused: Error {}

    /// Holds a submission until released.
    private final class HandOffGate: @unchecked Sendable {
        private let lock = NSLock()
        private var entered = false
        private var released = false
        private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func enterAndWait() async {
            let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                entered = true
                defer { enteredWaiters.removeAll() }
                return enteredWaiters
            }
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                let now = lock.withLock { () -> Bool in
                    if released { return true }
                    releaseWaiters.append(continuation)
                    return false
                }
                if now { continuation.resume() }
            }
        }

        func waitUntilEntered() async {
            await withCheckedContinuation { continuation in
                let now = lock.withLock { () -> Bool in
                    if entered { return true }
                    enteredWaiters.append(continuation)
                    return false
                }
                if now { continuation.resume() }
            }
        }

        func release() {
            let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                released = true
                defer { releaseWaiters.removeAll() }
                return releaseWaiters
            }
            waiters.forEach { $0.resume() }
        }
    }

    private final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var events = 0
        func add() { lock.withLock { events += 1 } }
        var count: Int { lock.withLock { events } }
    }

    private func stream(_ events: [GenerationEvent], finish: Bool = true) -> AsyncStream<GenerationEvent> {
        let (stream, continuation) = AsyncStream<GenerationEvent>.makeStream()
        events.forEach { continuation.yield($0) }
        if finish { continuation.finish() }
        return stream
    }

    private func exit(requested: Bool, tokens: [Int]) -> GenerationLoopExitThinking {
        let record = GenerationLoopExitRecord()
        record.append(tokens)
        if requested { record.requestExit(.init(period: 19, span: 2_048, generatedTokens: 4_096)) }
        return GenerationLoopExitThinking(
            openMarker: "<|channel>", closeMarker: "<channel|>", exitTokens: [Self.close],
            exitText: "<channel|>", startsInside: false, record: record)
    }

    private static func describe(_ event: GenerationEvent) -> String {
        switch event {
        case .chunk(let text): "chunk:\(text)"
        case .logprobs: "logprobs"
        case .info(let prompt, let completion, _, let reason): "info:\(prompt)/\(completion)/\(reason ?? "nil")"
        case .error(let message): "error:\(message)"
        case .terminal(let cause, _, let prompt, let completion): "terminal:\(cause.rawValue)/\(prompt)/\(completion)"
        }
    }

    private func drain(_ events: AsyncStream<GenerationEvent>) async -> [String] {
        var out: [String] = []
        for await event in events { out.append(Self.describe(event)) }
        return out
    }

    private func splice(
        first: AsyncStream<GenerationEvent>, exit: GenerationLoopExitThinking, outputBudget: Int = 8_192,
        calls: Calls, continuation: @escaping @Sendable () throws -> AsyncStream<GenerationEvent>
    ) -> (events: AsyncStream<GenerationEvent>, cancel: @Sendable () async -> Void,
          finished: @Sendable () async -> Void) {
        LoopExitThinkingContinuation.splice(
            first: first, cancelFirst: { calls.cancelFirst() }, exit: exit, promptTokens: Self.prompt,
            outputBudget: outputBudget,
            submit: { prompt, maxTokens in
                calls.submit(prompt, maxTokens)
                return try continuation()
            },
            cancelContinuation: { calls.cancelContinuation() })
    }

    private let thought = Array(repeating: 900, count: 4_200)

    @Test("no exit asked: the row's events pass through and nothing more is submitted")
    func passThrough() async {
        let calls = Calls()
        let first = stream([.chunk("a"), .info(promptTokens: 5, completionTokens: 4_200, tokensPerSecond: 10,
                                                finishReason: "length")])
        let out = await drain(splice(first: first, exit: exit(requested: false, tokens: thought), calls: calls) {
            self.stream([.chunk("never")])
        }.events)
        #expect(out == ["chunk:a", "info:5/4200/length"])
        #expect(calls.submits.isEmpty)
    }

    @Test("an ended thought continues: the marker, the answer, and one terminal with every token")
    func continues() async throws {
        let calls = Calls()
        let first = stream([.chunk("think"), .info(promptTokens: 5, completionTokens: 4_200, tokensPerSecond: 10,
                                                    finishReason: "length")])
        let out = await drain(splice(first: first, exit: exit(requested: true, tokens: thought), calls: calls) {
            self.stream([.chunk("Answer: B"), .info(promptTokens: 4_206, completionTokens: 9, tokensPerSecond: 20,
                                                    finishReason: "stop")])
        }.events)
        #expect(out == ["chunk:think", "chunk:<channel|>", "chunk:Answer: B", "info:5/4210/stop"])
        let submit = try #require(calls.submits.first)
        #expect(calls.submits.count == 1)
        #expect(submit.prompt == Self.prompt + thought + [Self.close])
        #expect(submit.maxTokens == 8_192 - 4_200 - 1)
    }

    @Test("a refused continuation ends the answer as length, as before")
    func refused() async {
        let calls = Calls()
        let first = stream([.chunk("think"), .info(promptTokens: 5, completionTokens: 4_200, tokensPerSecond: 10,
                                                    finishReason: "length")])
        let out = await drain(splice(first: first, exit: exit(requested: true, tokens: thought), calls: calls) {
            throw Refused()
        }.events)
        #expect(out == ["chunk:think", "info:5/4200/length"])
    }

    @Test("a continuation that fails before its first token ends the answer as length")
    func failsBeforeFirstToken() async {
        let calls = Calls()
        let first = stream([.chunk("think"), .info(promptTokens: 5, completionTokens: 4_200, tokensPerSecond: 10,
                                                    finishReason: "length")])
        let out = await drain(splice(first: first, exit: exit(requested: true, tokens: thought), calls: calls) {
            self.stream([.info(promptTokens: 4_206, completionTokens: 0, tokensPerSecond: 0, finishReason: nil),
                         .error("request cancelled")])
        }.events)
        #expect(out == ["chunk:think", "info:5/4200/length"])
    }

    @Test("the answer's budget is the request's remainder, at most the answer cap")
    func answerCap() async throws {
        let calls = Calls()
        let first = stream([.info(promptTokens: 5, completionTokens: 4_200, tokensPerSecond: 10, finishReason: "length")])
        let out = await drain(splice(
            first: first, exit: exit(requested: true, tokens: thought), outputBudget: 131_072, calls: calls
        ) {
            self.stream([.chunk("B"), .info(promptTokens: 4_206, completionTokens: 1, tokensPerSecond: 20,
                                            finishReason: "stop")])
        }.events)
        #expect(out == ["chunk:<channel|>", "chunk:B", "info:5/4202/stop"])
        let submit = try #require(calls.submits.first)
        #expect(submit.maxTokens == GenerationLoopExitThinkingPolicy.answerTokenLimit)
    }

    @Test("a row that closed its thought itself after the stop is not continued")
    func closedInFlight() async {
        let calls = Calls()
        let tokens = Array(repeating: 900, count: 4_096) + [Self.close, 65, 66]
        let first = stream([.chunk("think<channel|>AB"),
                            .info(promptTokens: 5, completionTokens: 4_099, tokensPerSecond: 10, finishReason: "length")])
        let out = await drain(splice(first: first, exit: exit(requested: true, tokens: tokens), calls: calls) {
            self.stream([.chunk("never")])
        }.events)
        #expect(out == ["chunk:think<channel|>AB", "info:5/4099/length"])
        #expect(calls.submits.isEmpty)
    }

    @Test("a multi-token exit (Qwen's `\\n</think>\\n\\n`): only the close marker in flight means the row closed its thought")
    func multiTokenExit() async throws {
        let exitTokens = [10, 248_069, 10, 10]
        func qwenExit(_ tokens: [Int]) -> GenerationLoopExitThinking {
            let record = GenerationLoopExitRecord()
            record.append(tokens)
            record.requestExit(.init(period: 19, span: 2_048, generatedTokens: 4_096))
            return GenerationLoopExitThinking(
                openMarker: "<think>", closeMarker: "</think>", exitTokens: exitTokens, exitText: "\n</think>\n\n",
                closeToken: 248_069, startsInside: true, record: record)
        }
        // Newlines in flight after the stop are still the thought.
        let calls = Calls()
        let tokens = Array(repeating: 900, count: 4_096) + [10, 10, 900]
        let out = await drain(splice(
            first: stream([.info(promptTokens: 5, completionTokens: 4_099, tokensPerSecond: 10, finishReason: "length")]),
            exit: qwenExit(tokens), calls: calls
        ) {
            self.stream([.chunk("B"), .info(promptTokens: 4_108, completionTokens: 1, tokensPerSecond: 20,
                                            finishReason: "stop")])
        }.events)
        #expect(out == ["chunk:\n</think>\n\n", "chunk:B", "info:5/4104/stop"])
        let submit = try #require(calls.submits.first)
        #expect(submit.prompt == Self.prompt + tokens + exitTokens)
        #expect(submit.maxTokens == 8_192 - 4_099 - 4)

        // `</think>` in flight: the row closed its thought itself.
        let closed = Calls()
        let closing = Array(repeating: 900, count: 4_096) + [10, 248_069, 10, 10, 65]
        let kept = await drain(splice(
            first: stream([.info(promptTokens: 5, completionTokens: 4_101, tokensPerSecond: 10, finishReason: "length")]),
            exit: qwenExit(closing), calls: closed
        ) { self.stream([.chunk("never")]) }.events)
        #expect(kept == ["info:5/4101/length"])
        #expect(closed.submits.isEmpty)
    }

    @Test("a row whose in-flight text closed its thought, without the close token, is not continued")
    func closedInFlightText() async {
        let calls = Calls()
        let exit = exit(requested: true, tokens: thought)
        exit.record.noteClosedAfterStop()
        let first = stream([.chunk("think</think>A"),
                            .info(promptTokens: 5, completionTokens: 4_200, tokensPerSecond: 10, finishReason: "length")])
        let out = await drain(splice(first: first, exit: exit, calls: calls) { self.stream([.chunk("never")]) }.events)
        #expect(out == ["chunk:think</think>A", "info:5/4200/length"])
        #expect(calls.submits.isEmpty)
    }

    @Test("no output budget left: nothing is submitted")
    func noBudget() async {
        let calls = Calls()
        let first = stream([.chunk("think"), .info(promptTokens: 5, completionTokens: 4_200, tokensPerSecond: 10,
                                                    finishReason: "length")])
        let out = await drain(splice(
            first: first, exit: exit(requested: true, tokens: thought), outputBudget: 4_201, calls: calls
        ) { self.stream([.chunk("never")]) }.events)
        #expect(out == ["chunk:think", "info:5/4200/length"])
        #expect(calls.submits.isEmpty)
    }

    @Test("under 256 tokens of budget left, the thought is not prefilled again for an answer")
    func smallBudget() async {
        let calls = Calls()
        let first = stream([.info(promptTokens: 5, completionTokens: 4_200, tokensPerSecond: 10, finishReason: "length")])
        let out = await drain(splice(
            first: first, exit: exit(requested: true, tokens: thought), outputBudget: 4_200 + 1 + 255, calls: calls
        ) { self.stream([.chunk("never")]) }.events)
        #expect(out == ["info:5/4200/length"])
        #expect(calls.submits.isEmpty)
    }

    @Test("a client that leaves during the answer cancels the continuation")
    func consumerLeaves() async throws {
        let calls = Calls()
        let (answer, answerContinuation) = AsyncStream<GenerationEvent>.makeStream()
        let first = stream([.info(promptTokens: 5, completionTokens: 4_200, tokensPerSecond: 10, finishReason: "length")])
        let spliced = splice(first: first, exit: exit(requested: true, tokens: thought), calls: calls) { answer }
        answerContinuation.yield(.chunk("A"))
        let seen = Seen()
        // The client's task is cancelled while it waits for more of the answer.
        let consumer = Task { for await _ in spliced.events { seen.add() } }
        let limit = ContinuousClock.now + .seconds(2)
        while seen.count < 2, ContinuousClock.now < limit { try await Task.sleep(for: .milliseconds(5)) }
        #expect(seen.count == 2)
        consumer.cancel()
        while calls.cancels.continuation == 0, ContinuousClock.now < limit {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(calls.cancels.continuation == 1)
        answerContinuation.finish()
    }

    @Test("a row that ended any other way is not continued")
    func otherEndings() async {
        for ending: GenerationEvent in [
            .info(promptTokens: 5, completionTokens: 100, tokensPerSecond: 1, finishReason: "stop"),
            .error("request cancelled"),
        ] {
            let calls = Calls()
            let first = stream([.chunk("think"), ending])
            let out = await drain(splice(first: first, exit: exit(requested: true, tokens: thought), calls: calls) {
                self.stream([.chunk("never")])
            }.events)
            #expect(out == ["chunk:think", Self.describe(ending)])
            #expect(calls.submits.isEmpty)
        }
    }

    @Test("an empty answer still closes the thought")
    func emptyAnswer() async {
        let calls = Calls()
        let first = stream([.info(promptTokens: 5, completionTokens: 4_200, tokensPerSecond: 10, finishReason: "length")])
        let out = await drain(splice(first: first, exit: exit(requested: true, tokens: thought), calls: calls) {
            self.stream([.info(promptTokens: 4_206, completionTokens: 0, tokensPerSecond: 0, finishReason: "stop")])
        }.events)
        #expect(out == ["chunk:<channel|>", "info:5/4201/stop"])
    }

    @Test("a failure after the answer started ends it as a paid length, as the guard's stop would")
    func failureAfterStart() async {
        let calls = Calls()
        let first = stream([.info(promptTokens: 5, completionTokens: 4_200, tokensPerSecond: 10, finishReason: "length")])
        // Not the client's cancel (a teardown, a capacity error): the usage before the error is kept.
        let out = await drain(splice(first: first, exit: exit(requested: true, tokens: thought), calls: calls) {
            self.stream([.chunk("A"), .info(promptTokens: 4_206, completionTokens: 3, tokensPerSecond: 0, finishReason: nil),
                         .error("request cancelled")])
        }.events)
        #expect(out == ["chunk:<channel|>", "chunk:A", "info:5/4204/length"])

        let capacity = await drain(splice(first: stream([.info(promptTokens: 5, completionTokens: 4_200,
                tokensPerSecond: 10, finishReason: "length")]), exit: exit(requested: true, tokens: thought), calls: Calls()) {
            self.stream([.chunk("A"), .error("token_budget_exhausted: KV capacity exhausted")])
        }.events)
        #expect(capacity == ["chunk:<channel|>", "chunk:A", "info:5/4201/length"])

        let terminal = await drain(splice(first: stream([.info(promptTokens: 5, completionTokens: 4_200,
                tokensPerSecond: 10, finishReason: "length")]), exit: exit(requested: true, tokens: thought), calls: Calls()) {
            self.stream([.chunk("A"), .terminal(cause: .decodeStall, message: "stalled", promptTokens: 4_206,
                                                completionTokens: 2)])
        }.events)
        #expect(terminal == ["chunk:<channel|>", "chunk:A", "info:5/4203/length"])
    }

    @Test("a cancel during the hand-off starts no continuation, and the splice's end waits for the submission")
    func cancelDuringHandOff() async throws {
        let calls = Calls()
        let gate = HandOffGate()
        let first = stream([.info(promptTokens: 5, completionTokens: 4_200, tokensPerSecond: 10, finishReason: "length")])
        let spliced = LoopExitThinkingContinuation.splice(
            first: first, cancelFirst: { calls.cancelFirst() }, exit: exit(requested: true, tokens: thought),
            promptTokens: Self.prompt, outputBudget: 8_192,
            submit: { prompt, maxTokens in
                // The owner's hand-off (the row's release, the submission) is still running.
                await gate.enterAndWait()
                calls.submit(prompt, maxTokens)
                return self.stream([.chunk("never")], finish: false)
            },
            cancelContinuation: { calls.cancelContinuation() })
        await gate.waitUntilEntered()
        await spliced.cancel()
        gate.release()
        await spliced.finished()
        // The submission returned after the cancel: it was cancelled before the splice ended.
        #expect(calls.submits.count == 1)
        #expect(calls.cancels.continuation == 1)
        #expect(await drain(spliced.events) == ["info:5/4200/length"])
    }

    @Test("a cancel before the continuation starts keeps it from starting")
    func cancelBeforeStart() async {
        let calls = Calls()
        let (first, firstContinuation) = AsyncStream<GenerationEvent>.makeStream()
        let spliced = splice(first: first, exit: exit(requested: true, tokens: thought), calls: calls) {
            self.stream([.chunk("never")])
        }
        firstContinuation.yield(.info(promptTokens: 5, completionTokens: 4_200, tokensPerSecond: 10,
                                      finishReason: "length"))
        await spliced.cancel()
        firstContinuation.finish()
        let out = await drain(spliced.events)
        #expect(out == ["info:5/4200/length"])
        #expect(calls.submits.isEmpty)
        #expect(calls.cancels.first == 1)
        #expect(calls.cancels.continuation == 0)
    }

    @Test("a cancel during the continuation stops it")
    func cancelDuringContinuation() async {
        let calls = Calls()
        let (answer, answerContinuation) = AsyncStream<GenerationEvent>.makeStream()
        let first = stream([.info(promptTokens: 5, completionTokens: 4_200, tokensPerSecond: 10, finishReason: "length")])
        let spliced = splice(first: first, exit: exit(requested: true, tokens: thought), calls: calls) { answer }
        answerContinuation.yield(.chunk("A"))
        var iterator = spliced.events.makeAsyncIterator()
        #expect(await iterator.next().map(Self.describe) == "chunk:<channel|>")
        #expect(await iterator.next().map(Self.describe) == "chunk:A")
        await spliced.cancel()
        #expect(calls.cancels.continuation == 1)
        answerContinuation.yield(.info(promptTokens: 4_206, completionTokens: 1, tokensPerSecond: 0, finishReason: nil))
        answerContinuation.yield(.error("request cancelled"))
        answerContinuation.finish()
        #expect(await iterator.next().map(Self.describe) == "info:5/4202/nil")
        #expect(await iterator.next().map(Self.describe) == "error:request cancelled")
        #expect(await iterator.next() == nil)
    }
}
