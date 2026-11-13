// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore

/// A row that repeats one clause verbatim, inside its thought or in its
/// answer, one token per delta; the guard's cancel ends it `.cancelled` (a row
/// nobody cancels ends `.length` after a short wait). Any later submission is
/// the continuation: it answers "Answer: B" and stops.
private final class ThoughtLoopCBv2Engine: CBv2Engine, @unchecked Sendable {
    /// How one family's row spells its text, opens its thought (when the
    /// prompt has not) and closes it.
    struct Family: Sendable {
        let tokens: @Sendable (String) -> [Int]
        let opening: [String]
        let closing: [String]

        static let gemma = Family(
            tokens: { GemmaThoughtTestTokenizer.tokens($0) }, opening: ["<|channel>", "thought\n"],
            closing: ["ok", "<channel|>"])
        /// The served Qwen 3.5/3.6 template opens the thought in the prompt.
        static let qwen = Family(
            tokens: { QwenByteTestTokenizer.tokens($0) }, opening: [], closing: ["ok\n", "</think>", "\n\n"])
    }

    private let lock = NSLock()
    private var continuations: [AsyncStream<CBv2Event>.Continuation] = []
    private var submitted: [CBv2Request] = []
    private var produced: [[Int]] = []
    private var cancels = 0
    let loopInsideThought: Bool
    let loopTokens: Int
    let family: Family

    init(loopInsideThought: Bool, loopTokens: Int = 4_200, family: Family = .gemma) {
        self.loopInsideThought = loopInsideThought
        self.loopTokens = loopTokens
        self.family = family
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
            let tokens = family.tokens(text)
            lock.withLock { produced[index] += tokens }
            continuation.yield(.delta(text: text, tokens: tokens, logprobs: nil))
        }
        if index == 0 {
            family.opening.forEach(emit)
            if !loopInsideThought { family.closing.forEach(emit) }
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

/// A retirement the engine holds until it releases it.
private final class RetirementGate: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var retirement: CBv2RequestRetirement { CBv2RequestRetirement { await self.wait() } }

    func wait() async {
        await withCheckedContinuation { continuation in
            let now = lock.withLock { () -> Bool in
                if released { return true }
                waiters.append(continuation)
                return false
            }
            if now { continuation.resume() }
        }
    }

    func release() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            released = true
            defer { waiters.removeAll() }
            return waiters
        }
        pending.forEach { $0.resume() }
    }
}

/// The coordinator's path: the row is admitted atomically against its
/// first-content deadline, so its stream ends before its retirement, which this
/// engine holds 50 ms past the stop. The continuation (no deadline) is an
/// ordinary submission: it answers "Answer: B" and stops.
private final class AdmittedThoughtLoopEngine: CBv2Engine, @unchecked Sendable {
    private let lock = NSLock()
    private var submitted: [CBv2Request] = []
    private var continuations: [CBv2RequestID: AsyncStream<CBv2Event>.Continuation] = [:]
    private var produced: [CBv2RequestID: Int] = [:]
    private var gates: [CBv2RequestID: RetirementGate] = [:]

    var requests: [CBv2Request] { lock.withLock { submitted } }

    func submit(
        _ request: CBv2Request, firstTokenDeadline: CBv2FirstTokenDeadlineAdmission
    ) async throws -> CBv2FirstTokenDeadlineResult {
        let gate = RetirementGate()
        lock.withLock { gates[request.id] = gate }
        return .admitted(
            stream: start(request),
            projectedWork: .bounded(
                work: .init(prefillTokens: request.promptTokens.count, decodeTokens: 0, scheduledSteps: 1, mixedSteps: 0),
                serviceDuration: .milliseconds(1)),
            admittedAt: .now, retirement: gate.retirement)
    }

    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> { start(request) }

    private func start(_ request: CBv2Request) -> AsyncStream<CBv2Event> {
        let (stream, continuation) = AsyncStream<CBv2Event>.makeStream()
        let first = lock.withLock {
            submitted.append(request)
            continuations[request.id] = continuation
            return submitted.count == 1
        }
        func emit(_ text: String) {
            let tokens = GemmaThoughtTestTokenizer.tokens(text)
            lock.withLock { produced[request.id, default: 0] += tokens.count }
            continuation.yield(.delta(text: text, tokens: tokens, logprobs: nil))
        }
        if first {
            emit("<|channel>")
            emit("thought\n")
            let clause = Array("Wait, the carbon count is 19. ")
            for position in 0..<4_200 { emit(String(clause[position % clause.count])) }
        } else {
            for character in "Answer: B" { emit(String(character)) }
            finish(request.id, .stop)
        }
        return stream
    }

    private func finish(_ id: CBv2RequestID, _ reason: CBv2FinishReason) {
        let (continuation, prompt, completion, gate) = lock.withLock {
            defer { continuations[id] = nil }
            return (continuations[id], submitted.first { $0.id == id }?.promptTokens.count ?? 0, produced[id] ?? 0,
                    gates[id])
        }
        continuation?.yield(.finished(
            reason: reason, usage: CBv2Usage(promptTokens: prompt, completionTokens: completion)))
        continuation?.finish()
        // The row's engine resources retire a little after its terminal.
        Task {
            try? await Task.sleep(for: .milliseconds(50))
            gate?.release()
        }
    }

    func cancel(_ id: CBv2RequestID) { finish(id, .cancelled) }

    func capacity() -> CBv2CapacitySnapshot {
        .init(activeRequests: 0, waitingRequests: 0, kvBytesInUse: 0, kvBytesCapacity: 0, activeTokens: 0)
    }

    func shutdown() async {}
}

@Suite("Loop guard: a repeating thought ends in an answer (scheduler text path)")
struct GenerationLoopExitThinkingServingTests {
    private let modelID = "mlx-community/gemma-4-26B-A4B-it-qat-4bit"
    private static let tokenizer = TokenizerHandle(GemmaThoughtTestTokenizer())

    /// One family as the scheduler serves it: Gemma 4 unless a test says otherwise.
    private struct Served: Sendable {
        var modelID = "mlx-community/gemma-4-26B-A4B-it-qat-4bit"
        var modelType = "gemma4"
        var tokenizer = GenerationLoopExitThinkingServingTests.tokenizer
        var eosTokenIds: Set<Int> = [GemmaThoughtTestTokenizer.turnClose, GemmaThoughtTestTokenizer.eos]
        var parser = ReasoningParserFormat.gemma4
    }

    /// Qwen 3.6 35B with thinking on: the prompt ends `<think>\n`.
    private static let qwen = Served(
        modelID: "qwen3.6-35b-a3b-vl-mtp-mxfp8", modelType: "qwen3_5_moe",
        tokenizer: TokenizerHandle(QwenByteTestTokenizer()), eosTokenIds: [248_046, 248_044], parser: .qwen3)

    private struct Outcome {
        var content = ""
        var reasoning = ""
        var info: ServerGenerationInfo?
        var error: (any Error)?
        /// The `ends_thought` field of each loop-guard telemetry event (nil: the field is missing).
        var loopGuardStops: [Bool?] = []
    }

    private final class TelemetrySink: @unchecked Sendable {
        private let lock = NSLock()
        private var received: [TelemetryEvent] = []
        func add(_ event: TelemetryEvent) { lock.withLock { received.append(event) } }
        var loopGuardStops: [Bool?] {
            lock.withLock {
                received.filter { $0.fields?["operation"]?.description == "engine_v2_loop_guard" }
                    .map { $0.fields?["ends_thought"]?.value as? Bool }
            }
        }
    }

    private func serve(
        _ engine: ThoughtLoopCBv2Engine, served: Served = Served(), maxTokens: Int = 8_192, extra: String = "",
        usage: EngineV2RequestUsageSignal? = nil
    ) async throws -> Outcome {
        let telemetry = TelemetrySink()
        let bridge = EngineV2Bridge(engine: engine, modelId: served.modelID, tokenizer: served.tokenizer,
            eosTokenIds: served.eosTokenIds, defaultMaxTokens: 64,
            maxConcurrentRequests: 1, emitTelemetry: { telemetry.add($0) })
        let scheduler = MultiModelBatchSchedulerEngine(registryProvider: {
            [served.modelID: .init(tokenizer: served.tokenizer, modelType: served.modelType, engineV2Bridge: bridge)]
        }, engineV2Usage: usage)
        var outcome = try await consume(scheduler, served: served, maxTokens: maxTokens, extra: extra)
        await bridge.shutdown()
        outcome.loopGuardStops = telemetry.loopGuardStops
        return outcome
    }

    /// `extra`: more top-level request fields, each with its leading comma.
    private func consume(
        _ scheduler: MultiModelBatchSchedulerEngine, served: Served = Served(), maxTokens: Int, extra: String = ""
    ) async throws -> Outcome {
        let request = try JSONDecoder().decode(OpenAIChatCompletionRequest.self, from: Data("""
        {"model":"\(served.modelID)","messages":[{"role":"user","content":"hi"}],\
        "reasoning_parser":"\(served.parser.rawValue)","max_tokens":\(maxTokens)\(extra)}
        """.utf8))
        var outcome = Outcome()
        var parser = StreamingReasoningParser(format: served.parser)
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

    @Test("the bridge reports a row's serving slot released only after its pump's cleanup")
    func waitForRowRelease() async throws {
        let engine = ThoughtLoopCBv2Engine(loopInsideThought: true, loopTokens: 64)
        let bridge = EngineV2Bridge(engine: engine, modelId: modelID, tokenizer: Self.tokenizer,
            eosTokenIds: [GemmaThoughtTestTokenizer.turnClose, GemmaThoughtTestTokenizer.eos], defaultMaxTokens: 64,
            maxConcurrentRequests: 1)
        let request = MultiModelBatchSchedulerEngine.translate(
            openAIRequest: try JSONDecoder().decode(OpenAIChatCompletionRequest.self, from: Data("""
            {"model":"\(modelID)","messages":[{"role":"user","content":"hi"}],"max_tokens":256}
            """.utf8)), defaultMaxTokens: 64)
        let stream = await bridge.submitTokenized(
            promptTokens: GemmaThoughtTestTokenizer.tokens("<|turn>user\nhi<turn|>\n<|turn>model\n"),
            request: request, requestId: "row-1")
        // The row still runs: its slot is still held.
        #expect(await bridge.waitForRowRelease(requestId: "row-1", within: .milliseconds(50)) == false)
        await bridge.cancel(requestId: "row-1")
        for await _ in stream {}
        #expect(await bridge.waitForRowRelease(requestId: "row-1", within: .seconds(5)))
        await bridge.shutdown()
    }

    @Test("on a full Mac, a row admitted against its deadline still gets its continuation once it retires")
    func fullMacAtomicAdmission() async throws {
        let engine = AdmittedThoughtLoopEngine()
        let budget = GlobalKVCacheBudget(capFraction: 0.9, activationReserveBytes: 0) {
            .init(total: 8 << 30, active: 0, cache: 0, systemAvailable: 8 << 30)
        }
        // Every whole-Mac slot is busy but the one this request takes.
        let width = ServingPerformanceProfiles.legacyWholeMacConcurrency
        for slot in 0..<(width - 1) {
            #expect(budget.serviceBudget.acquire(ownerID: "busy-\(slot)", concurrency: width))
        }
        let bridge = EngineV2Bridge(engine: engine, modelId: modelID, tokenizer: Self.tokenizer,
            eosTokenIds: [GemmaThoughtTestTokenizer.turnClose, GemmaThoughtTestTokenizer.eos], defaultMaxTokens: 64,
            maxConcurrentRequests: 1, prefillDeadlineMode: .enforce, kvBytesPerToken: 4_000, kvBudget: budget)
        await bridge.setMeasurementActivity(EngineMeasurementActivity())
        await bridge.updatePrefillTpsEwma(2_000, isolated: true)
        let id = modelID
        let tokenizer = Self.tokenizer
        let scheduler = MultiModelBatchSchedulerEngine(
            registryProvider: { [id: .init(tokenizer: tokenizer, modelType: "gemma4", engineV2Bridge: bridge)] },
            firstContentDeadline: FirstContentDeadline(relativeBudgetMilliseconds: 60_000))
        let outcome = try await consume(scheduler, maxTokens: 8_192)
        await bridge.shutdown()
        #expect(outcome.error == nil)
        #expect(engine.requests.count == 2)
        #expect(outcome.info?.stopReason == "stop")
        #expect(outcome.content == "Answer: B")
    }

    @Test("Qwen 3.6: a loop inside the thought ends it with `\\n</think>\\n\\n`, and stops apply to the answer")
    func qwenThoughtLoopEndsInAnAnswer() async throws {
        let engine = ThoughtLoopCBv2Engine(loopInsideThought: true, family: .qwen)
        let outcome = try await serve(engine, served: Self.qwen)
        #expect(outcome.error == nil)
        #expect(engine.cancelCount == 1)
        let requests = engine.requests
        #expect(requests.count == 2)
        let first = try #require(requests.first)
        let continuation = try #require(requests.last)
        let firstOutput = try #require(engine.outputs.first)
        // The row's tokens, then the close as Qwen's template writes it: the
        // marker is its own special token.
        #expect(continuation.promptTokens == first.promptTokens + firstOutput + [10, 248_069, 10, 10])
        #expect(continuation.maxTokens == first.maxTokens - firstOutput.count - 4)
        // The row's output starts inside the thought the prompt opened; the
        // continuation's starts after `</think>`, so stop strings apply to it.
        #expect(first.stopStringScope
            == CBv2StopStringScope(excluding: [ReasoningStopScope.think], startingInside: true))
        #expect(continuation.stopStringScope
            == CBv2StopStringScope(excluding: [ReasoningStopScope.think], startingInside: false))
        #expect(outcome.reasoning.hasPrefix("Wait, the carbon count is 19."))
        // As after a thought the model closes itself: the answer follows `</think>\n\n`.
        #expect(outcome.content == "\n\nAnswer: B")
        #expect(outcome.info?.stopReason == "stop")
        #expect(outcome.info?.completionTokens == firstOutput.count + 4 + 9)
        #expect(outcome.loopGuardStops == [true])
    }

    @Test("Qwen 3.6: a loop in the answer, after `</think>`, still ends as length")
    func qwenAnswerLoopEndsAsLength() async throws {
        let engine = ThoughtLoopCBv2Engine(loopInsideThought: false, family: .qwen)
        let outcome = try await serve(engine, served: Self.qwen)
        #expect(outcome.error == nil)
        #expect(engine.requests.count == 1)
        #expect(outcome.info?.stopReason == "length")
        #expect(outcome.loopGuardStops == [false])
    }

    @Test("a stop string that ends the answer is the request's matched stop sequence")
    func qwenStopInTheAnswer() async throws {
        let engine = ThoughtLoopCBv2Engine(loopInsideThought: true, family: .qwen)
        let usage = EngineV2RequestUsageSignal()
        let outcome = try await serve(engine, served: Self.qwen, extra: #","stop":["B"]"#, usage: usage)
        #expect(outcome.error == nil)
        #expect(engine.requests.count == 2)
        #expect(engine.requests.last?.stopStrings == ["B"])
        #expect(outcome.info?.stopReason == "stop")
        // The row ended `length`; the stop that ended the answer is the continuation's.
        #expect(usage.matchedStopSequence == "B")
    }

    @Test("Qwen 3.8 27B shares `qwen3_5` with the 9B and keeps today's length by default")
    func qwen38KeepsLength() async throws {
        let engine = ThoughtLoopCBv2Engine(loopInsideThought: true, family: .qwen)
        var served = Self.qwen
        served.modelID = "EigenLabs/Qwen3.8-27B-4bit-mtp"
        served.modelType = "qwen3_5"
        let outcome = try await serve(engine, served: served)
        #expect(engine.requests.count == 1)
        #expect(outcome.info?.stopReason == "length")
        #expect(outcome.loopGuardStops == [false])
    }

    @Test("a family without the exit keeps today's length")
    func otherFamilyKeepsLength() async throws {
        let engine = ThoughtLoopCBv2Engine(loopInsideThought: true)
        // Gemma's test tokenizer has no `<|end|>`, so GPT-OSS's Harmony exit cannot resolve here.
        let outcome = try await serve(engine, served: Served(modelType: "gpt_oss"))
        #expect(engine.requests.count == 1)
        #expect(outcome.info?.stopReason == "length")
        #expect(outcome.loopGuardStops == [false])
    }
}
