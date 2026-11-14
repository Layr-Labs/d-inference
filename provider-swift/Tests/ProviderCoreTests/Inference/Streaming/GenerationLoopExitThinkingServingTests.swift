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

/// A busy Mac: `slots` engine slots and a queue, admitted as `SchedulerV2`
/// admits (the waiting requests by priority, higher first, then in arrival
/// order). The continuation, if still waiting after `lease`, ends
/// `admission_timeout`, as `EngineLoopV2`'s admission lease ends it (120 s in
/// production); the other requests have no lease here. The first
/// request is a Gemma row whose thought repeats verbatim once the test opens
/// its gate (the guard's stop cancels it); a request whose prompt ends with
/// Gemma's exit (`<channel|>`) is the continuation: it answers "Answer: B".
/// The second request writes one token and ends 50 ms after the continuation
/// has queued (a slot that frees while it waits); every later one writes one
/// token and holds its slot for `longHold`.
private final class QueueingThoughtLoopEngine: CBv2Engine, @unchecked Sendable {
    private struct Row {
        let index: Int
        let request: CBv2Request
        let continuation: AsyncStream<CBv2Event>.Continuation
    }

    private let lock = NSLock()
    private let slots: Int
    private let lease: Duration
    private let longHold: Duration
    private var submitted: [CBv2Request] = []
    private var produced: [Int] = []
    private var running: [CBv2RequestID: Row] = [:]
    private var waiting: [Row] = []
    private var admissions: [Int] = []
    private var expired: [Int] = []
    private var loopGate: CheckedContinuation<Void, Never>?
    private var loopOpen = false
    private var continuationArrived = false
    private var continuationWaiters: [CheckedContinuation<Void, Never>] = []

    init(slots: Int, lease: Duration, longHold: Duration) {
        self.slots = slots
        self.lease = lease
        self.longHold = longHold
    }

    var requests: [CBv2Request] { lock.withLock { submitted } }
    /// Submission indexes, in the order the engine admitted them.
    var admitted: [Int] { lock.withLock { admissions } }
    /// Submission indexes that ended `admission_timeout`.
    var timedOut: [Int] { lock.withLock { expired } }

    /// Lets the first row write its looping thought.
    func openLoop() {
        let gate = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            loopOpen = true
            defer { loopGate = nil }
            return loopGate
        }
        gate?.resume()
    }

    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        let (stream, continuation) = AsyncStream<CBv2Event>.makeStream()
        let (row, admitNow) = lock.withLock { () -> (Row, Bool) in
            submitted.append(request)
            produced.append(0)
            let row = Row(index: submitted.count - 1, request: request, continuation: continuation)
            guard running.count < slots, waiting.isEmpty else {
                let at = waiting.firstIndex { $0.request.priority < request.priority } ?? waiting.count
                waiting.insert(row, at: at)
                return (row, false)
            }
            running[request.id] = row
            admissions.append(row.index)
            return (row, true)
        }
        if request.promptTokens.last == GemmaThoughtTestTokenizer.channelClose {
            let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                continuationArrived = true
                defer { continuationWaiters.removeAll() }
                return continuationWaiters
            }
            waiters.forEach { $0.resume() }
        }
        if admitNow {
            start(row)
        } else if request.promptTokens.last == GemmaThoughtTestTokenizer.channelClose {
            Task { [weak self, lease] in
                try? await Task.sleep(for: lease)
                self?.expire(row.request.id)
            }
        }
        return stream
    }

    private func start(_ row: Row) {
        func emit(_ text: String) {
            let tokens = GemmaThoughtTestTokenizer.tokens(text)
            lock.withLock { produced[row.index] += tokens.count }
            row.continuation.yield(.delta(text: text, tokens: tokens, logprobs: nil))
        }
        if row.index == 0 {
            Task { [weak self] in
                guard let self else { return }
                await withCheckedContinuation { (gate: CheckedContinuation<Void, Never>) in
                    let open = self.lock.withLock { () -> Bool in
                        if self.loopOpen { return true }
                        self.loopGate = gate
                        return false
                    }
                    if open { gate.resume() }
                }
                emit("<|channel>")
                emit("thought\n")
                let clause = Array("Wait, the carbon count is 19. ")
                for position in 0..<4_200 { emit(String(clause[position % clause.count])) }
            }
        } else if row.request.promptTokens.last == GemmaThoughtTestTokenizer.channelClose {
            for character in "Answer: B" { emit(String(character)) }
            finish(row.request.id, .stop)
        } else if row.index == 1 {
            emit("x")
            Task { [weak self] in
                guard let self else { return }
                await withCheckedContinuation { (arrived: CheckedContinuation<Void, Never>) in
                    let now = self.lock.withLock { () -> Bool in
                        if self.continuationArrived { return true }
                        self.continuationWaiters.append(arrived)
                        return false
                    }
                    if now { arrived.resume() }
                }
                try? await Task.sleep(for: .milliseconds(50))
                self.finish(row.request.id, .stop)
            }
        } else {
            emit("x")
            Task { [weak self, longHold] in
                try? await Task.sleep(for: longHold)
                self?.finish(row.request.id, .stop)
            }
        }
    }

    private func finish(_ id: CBv2RequestID, _ reason: CBv2FinishReason) {
        let (row, next) = lock.withLock { () -> (Row?, [Row]) in
            guard let row = running.removeValue(forKey: id) else { return (nil, []) }
            var next: [Row] = []
            while running.count < slots, !waiting.isEmpty {
                let admitted = waiting.removeFirst()
                running[admitted.request.id] = admitted
                admissions.append(admitted.index)
                next.append(admitted)
            }
            return (row, next)
        }
        if let row {
            let completion = lock.withLock { produced[row.index] }
            row.continuation.yield(.finished(
                reason: reason,
                usage: CBv2Usage(promptTokens: row.request.promptTokens.count, completionTokens: completion)))
            row.continuation.finish()
        }
        next.forEach(start)
    }

    private func expire(_ id: CBv2RequestID) {
        let row = lock.withLock { () -> Row? in
            guard let at = waiting.firstIndex(where: { $0.request.id == id }) else { return nil }
            let row = waiting.remove(at: at)
            expired.append(row.index)
            return row
        }
        guard let row else { return }
        row.continuation.yield(.finished(
            reason: .terminal(cause: .admissionTimeout, message: "admission lease expired before engine admission"),
            usage: CBv2Usage(promptTokens: row.request.promptTokens.count, completionTokens: 0)))
        row.continuation.finish()
    }

    func cancel(_ id: CBv2RequestID) {
        let queued = lock.withLock { () -> Row? in
            guard let at = waiting.firstIndex(where: { $0.request.id == id }) else { return nil }
            return waiting.remove(at: at)
        }
        if let queued {
            queued.continuation.yield(.finished(
                reason: .cancelled, usage: CBv2Usage(promptTokens: queued.request.promptTokens.count, completionTokens: 0)))
            queued.continuation.finish()
            return
        }
        finish(id, .cancelled)
    }

    func capacity() -> CBv2CapacitySnapshot {
        lock.withLock {
            .init(activeRequests: running.count, waitingRequests: waiting.count, kvBytesInUse: 0, kvBytesCapacity: 0,
                  activeTokens: 0)
        }
    }

    func shutdown() async {}
}

/// Holds every request (no token, no end until it is cancelled) and reports
/// the waiting count the test sets, as the engine publishes it.
private final class HeldQueueEngine: CBv2Engine, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CBv2RequestID: AsyncStream<CBv2Event>.Continuation] = [:]
    private var priorities: [Int] = []
    private var waitingCount = 0

    var submittedPriorities: [Int] { lock.withLock { priorities } }
    func setWaiting(_ count: Int) { lock.withLock { waitingCount = count } }

    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        let (stream, continuation) = AsyncStream<CBv2Event>.makeStream()
        lock.withLock {
            continuations[request.id] = continuation
            priorities.append(request.priority)
        }
        return stream
    }

    func cancel(_ id: CBv2RequestID) {
        let continuation = lock.withLock { continuations.removeValue(forKey: id) }
        continuation?.yield(.finished(reason: .cancelled, usage: CBv2Usage(promptTokens: 1, completionTokens: 0)))
        continuation?.finish()
    }

    func capacity() -> CBv2CapacitySnapshot {
        lock.withLock {
            .init(activeRequests: 0, waitingRequests: waitingCount, kvBytesInUse: 0, kvBytesCapacity: 0,
                  activeTokens: 0)
        }
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

    /// The Qwen 3.6 tests turn its exit on with a list set on the Mac that names the build: Qwen's families take only
    /// the Qwen 3.5 builds the A/B proved unless a list names another.
    private static let qwenOn = GenerationLoopExitThinkingPolicy.Setting.modelTypes(["qwen3_5_moe", "qwen3.6"])

    /// A clean process's setting. The scheduler's default reads the process's environment; these tests take this
    /// one unless they pass their own, so a runner with DARKBLOOM_LOOP_EXIT_THINKING set (an A/B box) gets the same
    /// results.
    private static let cleanProcess = GenerationLoopExitThinkingPolicy.setting(environment: [:])

    private func serve(
        _ engine: ThoughtLoopCBv2Engine, served: Served = Served(), maxTokens: Int = 8_192, extra: String = "",
        usage: EngineV2RequestUsageSignal? = nil, exitThinking: GenerationLoopExitThinkingPolicy.Setting? = nil
    ) async throws -> Outcome {
        let telemetry = TelemetrySink()
        let bridge = EngineV2Bridge(engine: engine, modelId: served.modelID, tokenizer: served.tokenizer,
            eosTokenIds: served.eosTokenIds, defaultMaxTokens: 64,
            maxConcurrentRequests: 1, emitTelemetry: { telemetry.add($0) })
        var scheduler = MultiModelBatchSchedulerEngine(registryProvider: {
            [served.modelID: .init(tokenizer: served.tokenizer, modelType: served.modelType, engineV2Bridge: bridge)]
        }, engineV2Usage: usage)
        scheduler.exitThinkingSetting = exitThinking ?? Self.cleanProcess
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
        var scheduler = MultiModelBatchSchedulerEngine(
            registryProvider: { [id: .init(tokenizer: tokenizer, modelType: "gemma4", engineV2Bridge: bridge)] },
            firstContentDeadline: FirstContentDeadline(relativeBudgetMilliseconds: 60_000))
        scheduler.exitThinkingSetting = Self.cleanProcess
        let outcome = try await consume(scheduler, maxTokens: 8_192)
        await bridge.shutdown()
        #expect(outcome.error == nil)
        #expect(engine.requests.count == 2)
        #expect(outcome.info?.stopReason == "stop")
        #expect(outcome.content == "Answer: B")
    }

    @Test("on a busy Mac the continuation takes its stopped row's place, ahead of the queue, before its admission lease ends",
          .timeLimit(.minutes(1)))
    func continuationAheadOfTheQueue() async throws {
        // Two slots. The looping row and a short request run; two long ones
        // wait. The guard's stop frees a slot, which the first waiting request
        // takes; the continuation arrives after it. When the short request
        // ends, the continuation must be admitted, not the waiting long one,
        // or it waits behind both long ones past its lease.
        let engine = QueueingThoughtLoopEngine(slots: 2, lease: .seconds(1), longHold: .seconds(20))
        let bridge = EngineV2Bridge(engine: engine, modelId: modelID, tokenizer: Self.tokenizer,
            eosTokenIds: [GemmaThoughtTestTokenizer.turnClose, GemmaThoughtTestTokenizer.eos], defaultMaxTokens: 64,
            maxConcurrentRequests: 8)
        let id = modelID
        let tokenizer = Self.tokenizer
        var scheduler = MultiModelBatchSchedulerEngine(registryProvider: {
            [id: .init(tokenizer: tokenizer, modelType: "gemma4", engineV2Bridge: bridge)]
        })
        scheduler.exitThinkingSetting = Self.cleanProcess
        let served = scheduler
        let looping = Task { () -> (stop: String?, content: String) in
            let outcome = try? await self.consume(served, maxTokens: 8_192)
            return (outcome?.info?.stopReason, outcome?.content ?? "")
        }
        while engine.requests.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        // A short request in the second slot, then two long ones that wait.
        let other = MultiModelBatchSchedulerEngine.translate(
            openAIRequest: try JSONDecoder().decode(OpenAIChatCompletionRequest.self, from: Data("""
            {"model":"\(modelID)","messages":[{"role":"user","content":"hi"}],"max_tokens":256}
            """.utf8)), defaultMaxTokens: 64)
        var others: [AsyncStream<GenerationEvent>] = []
        for name in ["short", "long-1", "long-2"] {
            others.append(await bridge.submitTokenized(
                promptTokens: GemmaThoughtTestTokenizer.tokens("<|turn>user\n\(name)<turn|>\n<|turn>model\n"),
                request: other, requestId: name))
        }
        #expect(engine.admitted == [0, 1])
        engine.openLoop()
        let outcome = await looping.value
        for name in ["long-1", "long-2"] { await bridge.cancel(requestId: name) }
        for stream in others { for await _ in stream {} }
        await bridge.shutdown()
        // Submissions: 0 the looping row, 1 short, 2 and 3 long, 4 the continuation.
        #expect(engine.requests.count == 5)
        #expect(engine.timedOut.isEmpty)
        #expect(engine.admitted.prefix(4) == [0, 1, 2, 4])
        #expect(outcome.stop == "stop")
        #expect(outcome.content == "Answer: B")
    }

    @Test("a continuation goes to the engine with priority 1, and the bridge reads the queue in the engine's order",
          .timeLimit(.minutes(1)))
    func queueStateFollowsPriority() async throws {
        let engine = HeldQueueEngine()
        let bridge = EngineV2Bridge(engine: engine, modelId: modelID, tokenizer: Self.tokenizer,
            eosTokenIds: [GemmaThoughtTestTokenizer.turnClose, GemmaThoughtTestTokenizer.eos], defaultMaxTokens: 64,
            maxConcurrentRequests: 8)
        let request = MultiModelBatchSchedulerEngine.translate(
            openAIRequest: try JSONDecoder().decode(OpenAIChatCompletionRequest.self, from: Data("""
            {"model":"\(modelID)","messages":[{"role":"user","content":"hi"}],"max_tokens":256}
            """.utf8)), defaultMaxTokens: 64)
        let prompt = GemmaThoughtTestTokenizer.tokens("<|turn>user\nhi<turn|>\n<|turn>model\n")
        var streams: [AsyncStream<GenerationEvent>] = []
        for id in ["older", "newer"] {
            streams.append(await MeFirstDarkbloomRequest.$id.withValue("req-\(id)") {
                await bridge.submitTokenized(promptTokens: prompt, request: request, requestId: id)
            })
        }
        streams.append(await MeFirstDarkbloomRequest.$id.withValue("req-continuation") {
            await EngineAdmissionPriority.$current.withValue(LoopExitThinkingContinuation.admissionPriority) {
                await bridge.submitTokenized(promptTokens: prompt, request: request, requestId: "continuation")
            }
        })
        #expect(engine.submittedPriorities == [0, 0, 1])
        // One request waits. If all three arrived while the engine was full,
        // it admits the continuation first, then the older request, so the
        // newer one waits; otherwise the continuation waits and the newer one
        // misreads as waiting (an error toward waiting). The bridge counts
        // only the requests that can't overtake a request, so it reads the
        // newer one as waiting and the older one as admitted; the
        // continuation reads as waiting too, but me first treats it as
        // admitted: it never gives way.
        engine.setWaiting(1)
        #expect(await bridge.queueState(of: "newer")?.waiting == true)
        #expect(await bridge.queueState(of: "older")?.waiting == false)
        #expect(await bridge.queueState(of: "continuation")?.waiting == true)
        #expect(await bridge.hasAdmitted(darkbloomRequest: "req-newer") == false)
        #expect(await bridge.hasAdmitted(darkbloomRequest: "req-older"))
        #expect(await bridge.hasAdmitted(darkbloomRequest: "req-continuation"))
        // Nothing waits: all read as admitted.
        engine.setWaiting(0)
        #expect(await bridge.queueState(of: "continuation")?.waiting == false)
        #expect(await bridge.hasAdmitted(darkbloomRequest: "req-newer"))
        for id in ["older", "newer", "continuation"] { await bridge.cancel(requestId: id) }
        for stream in streams { for await _ in stream {} }
        await bridge.shutdown()
    }

    @Test("on a full Mac a continuation takes its stopped row's place in the whole-Mac allowance; other work is refused",
          .timeLimit(.minutes(1)))
    func continuationTakesItsRowsAllowance() async throws {
        // Every whole-Mac slot is held: the stopped row's slot went to work
        // that was waiting for it before the continuation could ask.
        let budget = GlobalKVCacheBudget(capFraction: 0.9, activationReserveBytes: 0) {
            .init(total: 8 << 30, active: 0, cache: 0, systemAvailable: 8 << 30)
        }
        let width = ServingPerformanceProfiles.legacyWholeMacConcurrency
        for slot in 0..<width {
            #expect(budget.serviceBudget.acquire(ownerID: "busy-\(slot)", concurrency: width))
        }
        let engine = HeldQueueEngine()
        let bridge = EngineV2Bridge(engine: engine, modelId: modelID, tokenizer: Self.tokenizer,
            eosTokenIds: [GemmaThoughtTestTokenizer.turnClose, GemmaThoughtTestTokenizer.eos], defaultMaxTokens: 64,
            maxConcurrentRequests: 8, kvBytesPerToken: 4_000, kvBudget: budget)
        let request = MultiModelBatchSchedulerEngine.translate(
            openAIRequest: try JSONDecoder().decode(OpenAIChatCompletionRequest.self, from: Data("""
            {"model":"\(modelID)","messages":[{"role":"user","content":"hi"}],"max_tokens":256}
            """.utf8)), defaultMaxTokens: 64)
        let prompt = GemmaThoughtTestTokenizer.tokens("<|turn>user\nhi<turn|>\n<|turn>model\n")
        // Ordinary work is refused as capacity (503 locally; the coordinator re-routes it).
        var refused: [String] = []
        for await event in await bridge.submitTokenized(promptTokens: prompt, request: request, requestId: "ordinary") {
            if case .error(let message) = event { refused.append(message) }
        }
        #expect(refused == [EngineV2Bridge.serviceAllowanceExhausted])
        // The continuation is not: it reaches the engine, one row past the width.
        let continuation = await EngineAdmissionPriority.$current.withValue(LoopExitThinkingContinuation.admissionPriority) {
            await bridge.submitTokenized(promptTokens: prompt, request: request, requestId: "continuation")
        }
        #expect(engine.submittedPriorities == [1])
        #expect(budget.serviceBudget.count == width + 1)
        // What the budget reports stays capped at the whole Mac.
        #expect(budget.serviceBudget.snapshot().usedFraction == 1)
        // Other work still waits while it runs.
        var refusedAgain: [String] = []
        for await event in await bridge.submitTokenized(promptTokens: prompt, request: request, requestId: "ordinary-2") {
            if case .error(let message) = event { refusedAgain.append(message) }
        }
        #expect(refusedAgain == [EngineV2Bridge.serviceAllowanceExhausted])
        await bridge.cancel(requestId: "continuation")
        for await _ in continuation {}
        await bridge.shutdown()
        // Its share is released when it ends.
        #expect(budget.serviceBudget.count == width)
    }

    @Test("width 1: a continuation takes its row's place beside the request that took the slot, not beside the recovery")
    func continuationOnAWidthOneMac() {
        let service = GlobalKVCacheBudget(capFraction: 0.9, activationReserveBytes: 0) {
            .init(total: 8 << 30, active: 0, cache: 0, systemAvailable: 8 << 30)
        }.serviceBudget
        // On a width-1 profile each row is a whole Mac: the request that took
        // the stopped row's slot holds all of it.
        #expect(service.acquire(ownerID: "took-the-slot", concurrency: 1))
        #expect(!service.acquire(ownerID: "ordinary", concurrency: 1))
        #expect(service.acquire(ownerID: "continuation", concurrency: 1, overcommit: true))
        service.release(ownerID: "continuation")
        service.release(ownerID: "took-the-slot")
        // The idle prefill-evidence recovery (`requiresIdle`) has the Mac to
        // itself until its prompt completes, at any width.
        #expect(service.acquire(ownerID: "recovery", concurrency: 1, requiresIdle: true))
        #expect(!service.acquire(ownerID: "continuation", concurrency: 8, overcommit: true))
        service.reduceExclusiveAllowance(ownerID: "recovery", concurrency: 1)
        #expect(service.acquire(ownerID: "continuation", concurrency: 8, overcommit: true))
        service.release(ownerID: "continuation")
        service.release(ownerID: "recovery")
        #expect(service.count == 0)
    }

    @Test("Qwen 3.6: a loop inside the thought ends it with `\\n</think>\\n\\n`, and stops apply to the answer")
    func qwenThoughtLoopEndsInAnAnswer() async throws {
        let engine = ThoughtLoopCBv2Engine(loopInsideThought: true, family: .qwen)
        let outcome = try await serve(engine, served: Self.qwen, exitThinking: Self.qwenOn)
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
        let outcome = try await serve(engine, served: Self.qwen, exitThinking: Self.qwenOn)
        #expect(outcome.error == nil)
        #expect(engine.requests.count == 1)
        #expect(outcome.info?.stopReason == "length")
        #expect(outcome.loopGuardStops == [false])
    }

    @Test("a stop string that ends the answer is the request's matched stop sequence")
    func qwenStopInTheAnswer() async throws {
        let engine = ThoughtLoopCBv2Engine(loopInsideThought: true, family: .qwen)
        let usage = EngineV2RequestUsageSignal()
        let outcome = try await serve(engine, served: Self.qwen, extra: #","stop":["B"]"#, usage: usage,
                                      exitThinking: Self.qwenOn)
        #expect(outcome.error == nil)
        #expect(engine.requests.count == 2)
        #expect(engine.requests.last?.stopStrings == ["B"])
        #expect(outcome.info?.stopReason == "stop")
        // The row ended `length`; the stop that ended the answer is the continuation's.
        #expect(usage.matchedStopSequence == "B")
    }

    /// `Self.qwen` as another Qwen 3.5-family build.
    private static func qwenBuild(_ modelID: String, _ modelType: String) -> Served {
        var served = qwen
        served.modelID = modelID
        served.modelType = modelType
        return served
    }

    @Test("by default the Qwen 3.5 builds the A/B proved, the 9B and the 35B, end a looping thought in an answer")
    func qwen35BuildsTakeTheExitByDefault() async throws {
        for (id, type) in [("Qwen3.5-9B", "qwen3_5"), ("qwen3.5-35b-a3b", "qwen3_5_moe")] {
            let engine = ThoughtLoopCBv2Engine(loopInsideThought: true, family: .qwen)
            let outcome = try await serve(engine, served: Self.qwenBuild(id, type))
            #expect(outcome.error == nil, "\(id)")
            #expect(engine.requests.count == 2, "\(id)")
            #expect(outcome.content == "\n\nAnswer: B", "\(id)")
            #expect(outcome.info?.stopReason == "stop", "\(id)")
            #expect(outcome.loopGuardStops == [true], "\(id)")
        }
    }

    @Test("by default Qwen 3.6 and the Qwen 3.8 27B builds keep today's length: their families, not the A/B's builds")
    func otherQwenBuildsKeepLengthByDefault() async throws {
        let builds = [("qwen3.6-35b-a3b-vl-mtp-mxfp8", "qwen3_5_moe"),
                      ("EigenLabs/Qwen3.5-9B-MLX-4bit-mtp", "qwen3_5")]
            + ModelRuntimeRequirements.qwen38ConcreteModelIDs.sorted().map { ($0, "qwen3_5") }
        for (id, type) in builds {
            let engine = ThoughtLoopCBv2Engine(loopInsideThought: true, family: .qwen)
            let outcome = try await serve(engine, served: Self.qwenBuild(id, type))
            #expect(outcome.error == nil, "\(id)")
            #expect(engine.requests.count == 1, "\(id)")
            #expect(outcome.info?.stopReason == "length", "\(id)")
            #expect(outcome.loopGuardStops == [false], "\(id)")
        }
    }

    @Test("a list set on the Mac keeps Qwen to its proven builds; another build takes the exit only when named")
    func aListNamesOtherQwenBuilds() async throws {
        let key = GenerationLoopExitThinkingPolicy.environmentKey
        // The default list plus Nemotron 3.5 Super, as the docs' `…,nemotron_h_omni` reads.
        let plusSuper = GenerationLoopExitThinkingPolicy.setting(
            environment: [key: "gemma4,gemma4_text,gpt_oss,qwen3_5,qwen3_5_moe,nemotron_h_omni"])
        let named = GenerationLoopExitThinkingPolicy.setting(
            environment: [key: "qwen3_5_moe,qwen3_5,Qwen3.6,qwen3.8-27b"])
        let cases: [(id: String, type: String, setting: GenerationLoopExitThinkingPolicy.Setting, answers: Bool)] = [
            ("qwen3.5-35b-a3b", "qwen3_5_moe", plusSuper, true),
            ("qwen3.6-35b-a3b-vl-mtp-mxfp8", "qwen3_5_moe", plusSuper, false),
            ("EigenLabs/Qwen3.8-27B-4bit-mtp", "qwen3_5", plusSuper, false),
            ("qwen3.6-35b-a3b-vl-mtp-mxfp8", "qwen3_5_moe", named, true),
            ("EigenLabs/Qwen3.8-27B-4bit-mtp", "qwen3_5", named, true),
        ]
        for build in cases {
            let engine = ThoughtLoopCBv2Engine(loopInsideThought: true, family: .qwen)
            let outcome = try await serve(
                engine, served: Self.qwenBuild(build.id, build.type), exitThinking: build.setting)
            let label = "\(build.id), \(build.setting)"
            #expect(outcome.error == nil, "\(label)")
            #expect(engine.requests.count == (build.answers ? 2 : 1), "\(label)")
            #expect(outcome.info?.stopReason == (build.answers ? "stop" : "length"), "\(label)")
            #expect(outcome.loopGuardStops == [build.answers], "\(label)")
            if build.answers { #expect(outcome.content == "\n\nAnswer: B", "\(label)") }
        }
    }

    @Test("a family without the exit keeps today's length")
    func otherFamilyKeepsLength() async throws {
        let engine = ThoughtLoopCBv2Engine(loopInsideThought: true)
        // Nemotron 3.5 Lightning: guarded, with no thought marker listed.
        let outcome = try await serve(engine, served: Served(modelType: "nemotron_h"))
        #expect(engine.requests.count == 1)
        #expect(outcome.info?.stopReason == "length")
        #expect(outcome.loopGuardStops == [false])
    }
}
