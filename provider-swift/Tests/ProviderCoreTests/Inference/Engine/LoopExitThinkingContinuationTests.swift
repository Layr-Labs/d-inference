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
    ) -> (events: AsyncStream<GenerationEvent>, cancel: @Sendable () async -> Void) {
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

    @Test("a failure after the answer started keeps its usage and its error")
    func failureAfterStart() async {
        let calls = Calls()
        let first = stream([.info(promptTokens: 5, completionTokens: 4_200, tokensPerSecond: 10, finishReason: "length")])
        let out = await drain(splice(first: first, exit: exit(requested: true, tokens: thought), calls: calls) {
            self.stream([.chunk("A"), .info(promptTokens: 4_206, completionTokens: 3, tokensPerSecond: 0, finishReason: nil),
                         .error("request cancelled")])
        }.events)
        #expect(out == ["chunk:<channel|>", "chunk:A", "info:5/4204/nil", "error:request cancelled"])

        let terminal = await drain(splice(first: stream([.info(promptTokens: 5, completionTokens: 4_200,
                tokensPerSecond: 10, finishReason: "length")]), exit: exit(requested: true, tokens: thought), calls: Calls()) {
            self.stream([.chunk("A"), .terminal(cause: .decodeStall, message: "stalled", promptTokens: 4_206,
                                                completionTokens: 2)])
        }.events)
        #expect(terminal == ["chunk:<channel|>", "chunk:A", "terminal:\(InferenceTerminalCause.decodeStall.rawValue)/5/4203"])
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
