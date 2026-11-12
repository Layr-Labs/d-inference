// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore

/// A Gemma 4 row that repeats one clause verbatim, inside its thought or in
/// its answer, one token per delta; the guard's cancel ends it `.cancelled`
/// (a row nobody cancels ends `.length` after a short wait). Any later
/// submission is the continuation: it answers "Answer: B" and stops.
private final class ThoughtLoopCBv2Engine: CBv2Engine, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [AsyncStream<CBv2Event>.Continuation] = []
    private var submitted: [CBv2Request] = []
    private var produced: [[Int]] = []
    private var cancels = 0
    let loopInsideThought: Bool
    let loopTokens: Int

    init(loopInsideThought: Bool, loopTokens: Int = 4_200) {
        self.loopInsideThought = loopInsideThought
        self.loopTokens = loopTokens
    }

    var requests: [CBv2Request] { lock.withLock { submitted } }
    var outputs: [[Int]] { lock.withLock { produced } }
    var cancelCount: Int { lock.withLock { cancels } }

    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        let (stream, continuation) = AsyncStream<CBv2Event>.makeStream()
        let index = lock.withLock {
            submitted.append(request)
            continuations.append(continuation)
            produced.append([])
            return submitted.count - 1
        }
        func emit(_ text: String) {
            let tokens = GemmaThoughtTestTokenizer.tokens(text)
            lock.withLock { produced[index] += tokens }
            continuation.yield(.delta(text: text, tokens: tokens, logprobs: nil))
        }
        if index == 0 {
            emit("<|channel>")
            emit("thought\n")
            if !loopInsideThought {
                emit("ok")
                emit("<channel|>")
            }
            let clause = Array("Wait, the carbon count is 19. ")
            for position in 0..<loopTokens {
                emit(String(clause[position % clause.count]))
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                self?.finish(index, .length)
            }
        } else {
            for character in "Answer: B" { emit(String(character)) }
            finish(index, .stop)
        }
        return stream
    }

    private func finish(_ index: Int, _ reason: CBv2FinishReason) {
        let (continuation, prompt, completion) = lock.withLock {
            defer { continuations[index] = AsyncStream<CBv2Event>.makeStream().continuation }
            return (continuations[index], submitted[index].promptTokens.count, produced[index].count)
        }
        continuation.yield(.finished(
            reason: reason, usage: CBv2Usage(promptTokens: prompt, completionTokens: completion)))
        continuation.finish()
    }

    func cancel(_ id: CBv2RequestID) {
        let index = lock.withLock {
            cancels += 1
            return submitted.lastIndex { $0.id == id }
        }
        if let index { finish(index, .cancelled) }
    }

    func capacity() -> CBv2CapacitySnapshot {
        .init(activeRequests: 0, waitingRequests: 0, kvBytesInUse: 0, kvBytesCapacity: 0, activeTokens: 0)
    }

    func shutdown() async {}
}

@Suite("Loop guard: a repeating thought ends in an answer (scheduler text path)")
struct GenerationLoopExitThinkingServingTests {
    private let modelID = "mlx-community/gemma-4-26B-A4B-it-qat-4bit"
    private static let tokenizer = TokenizerHandle(GemmaThoughtTestTokenizer())

    private struct Outcome {
        var content = ""
        var reasoning = ""
        var info: ServerGenerationInfo?
        var error: (any Error)?
        /// The `ends_thought` field of each loop-guard telemetry event.
        var loopGuardStops: [Bool] = []
    }

    private final class TelemetrySink: @unchecked Sendable {
        private let lock = NSLock()
        private var received: [TelemetryEvent] = []
        func add(_ event: TelemetryEvent) { lock.withLock { received.append(event) } }
        var loopGuardStops: [Bool] {
            lock.withLock {
                received.filter { $0.fields?["operation"]?.description == "engine_v2_loop_guard" }
                    .map { $0.fields?["ends_thought"]?.value as? Bool ?? false }
            }
        }
    }

    private func serve(
        _ engine: ThoughtLoopCBv2Engine, modelType: String = "gemma4", maxTokens: Int = 8_192
    ) async throws -> Outcome {
        let telemetry = TelemetrySink()
        let bridge = EngineV2Bridge(engine: engine, modelId: modelID, tokenizer: Self.tokenizer,
            eosTokenIds: [GemmaThoughtTestTokenizer.turnClose, GemmaThoughtTestTokenizer.eos], defaultMaxTokens: 64,
            maxConcurrentRequests: 1, emitTelemetry: { telemetry.add($0) })
        let id = modelID
        let tokenizer = Self.tokenizer
        let scheduler = MultiModelBatchSchedulerEngine(registryProvider: {
            [id: .init(tokenizer: tokenizer, modelType: modelType, engineV2Bridge: bridge)]
        })
        let request = try JSONDecoder().decode(OpenAIChatCompletionRequest.self, from: Data("""
        {"model":"\(modelID)","messages":[{"role":"user","content":"hi"}],"reasoning_parser":"gemma4",\
        "max_tokens":\(maxTokens)}
        """.utf8))
        var outcome = Outcome()
        var parser = StreamingReasoningParser(format: .gemma4)
        func apply(_ parsed: ParsedReasoning) {
            outcome.content += parsed.content
            outcome.reasoning += parsed.reasoningContent ?? ""
        }
        do {
            for try await event in try await scheduler.streamChatCompletion(request: request) {
                switch event {
                case .content(let text): parser.parse(text).forEach(apply)
                case .parsed(let parsed): apply(parsed)
                case .info(let info): outcome.info = info
                case .toolCall, .toolCallDelta, .logprobs: break
                }
            }
        } catch { outcome.error = error }
        parser.finish().forEach(apply)
        await bridge.shutdown()
        outcome.loopGuardStops = telemetry.loopGuardStops
        return outcome
    }

    @Test("a loop inside the thought ends the thought; the answer continues and the usage counts every token")
    func thoughtLoopEndsInAnAnswer() async throws {
        let engine = ThoughtLoopCBv2Engine(loopInsideThought: true)
        let outcome = try await serve(engine)
        #expect(outcome.error == nil)
        #expect(engine.cancelCount == 1)
        let requests = engine.requests
        #expect(requests.count == 2)
        let first = try #require(requests.first)
        let continuation = try #require(requests.last)
        let firstOutput = try #require(engine.outputs.first)
        // The same prompt, every token the row produced (the in-flight ones
        // after the stop included), then the end of thinking.
        #expect(continuation.promptTokens
            == first.promptTokens + firstOutput + [GemmaThoughtTestTokenizer.channelClose])
        #expect(continuation.maxTokens == first.maxTokens - firstOutput.count - 1)
        #expect(outcome.reasoning.hasPrefix("Wait, the carbon count is 19."))
        #expect(outcome.content == "Answer: B")
        #expect(outcome.info?.stopReason == "stop")
        #expect(outcome.info?.promptTokens == first.promptTokens.count)
        #expect(outcome.info?.completionTokens == firstOutput.count + 1 + 9)
        #expect(outcome.loopGuardStops == [true])
    }

    @Test("a loop in the answer, after the thought, still ends as length with nothing more submitted")
    func answerLoopEndsAsLength() async throws {
        let engine = ThoughtLoopCBv2Engine(loopInsideThought: false)
        let outcome = try await serve(engine)
        #expect(outcome.error == nil)
        #expect(engine.cancelCount == 1)
        #expect(engine.requests.count == 1)
        #expect(outcome.info?.stopReason == "length")
        #expect(outcome.content.hasPrefix("Wait, the carbon count is 19."))
        #expect(outcome.loopGuardStops == [false])
    }

    @Test("a thought loop that used the whole budget ends as length, with nothing more submitted")
    func noBudgetLeft() async throws {
        let engine = ThoughtLoopCBv2Engine(loopInsideThought: true)
        // The row produces 1 + 8 + 4,200 tokens; the marker would be the 4,210th.
        let outcome = try await serve(engine, maxTokens: 4_210)
        let firstOutput = try #require(engine.outputs.first)
        #expect(firstOutput.count == 4_209)
        #expect(engine.requests.count == 1)
        #expect(outcome.error == nil)
        #expect(outcome.info?.stopReason == "length")
        #expect(outcome.info?.completionTokens == 4_209)
        #expect(outcome.content.isEmpty)
        #expect(outcome.loopGuardStops == [true])
    }

    @Test("a family without the exit keeps today's length")
    func otherFamilyKeepsLength() async throws {
        let engine = ThoughtLoopCBv2Engine(loopInsideThought: true)
        let outcome = try await serve(engine, modelType: "qwen3_5")
        #expect(engine.requests.count == 1)
        #expect(outcome.info?.stopReason == "length")
        #expect(outcome.loopGuardStops == [false])
    }
}
