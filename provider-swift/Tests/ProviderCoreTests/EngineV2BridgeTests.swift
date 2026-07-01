// Copyright © 2026 Eigen Labs.
//
// WS-H (provider bridge) unit tests — live-isolated style: a scripted
// in-process `CBv2Engine` stub emitting canned streams; no network, no
// models, no prod anything.
//
//   * Translation: OpenAI-style request → CBv2Request field-by-field
//     (params, stops, maxTokens defaulting, logit_bias id parsing).
//   * Event → stream framing: fixture-compare against the recorded legacy
//     `BatchScheduler+EngineBridge` shape (chunks → single info → finish;
//     abort usage-before-error; teardown sentinel).
//   * Error mapping: capacityExhausted → the retryable capacity error
//     class (`.tokenBudgetExhausted` → 429/503), backendIneligible →
//     non-retryable.
//   * Config gating: flag off → legacy; flag on + non-allowlisted model →
//     legacy; init failure → fallback + telemetry event.
//   * Cancellation: provider request-id → `CBv2Engine.cancel` with the
//     minted engine id, incl. the `EngineV2Runtime` fan-out the
//     ProviderLoop hook uses.
//   * Capacity: CBv2CapacitySnapshot → BackendSlotCapacity field mapping
//     (truthful bytes-derived budgets, wedge counters).

import Foundation
import MLXLMCommon
import Testing

@testable import ProviderCore

// MARK: - Scripted CBv2Engine stub

/// In-process scripted engine. Thread-safe via NSLock so the bridge actor
/// and the test can both touch it.
private final class ScriptedCBv2Engine: CBv2Engine, @unchecked Sendable {
    enum Script {
        /// Throw from `submit` (admission failure).
        case throwOnSubmit(any Error)
        /// Yield these events, then finish the stream. Include a
        /// `.finished` event for a normal terminal; omit it to simulate an
        /// engine teardown mid-request.
        case stream([CBv2Event])
        /// The test drives the event continuation by hand.
        case manual
    }

    private let lock = NSLock()
    private var script: Script
    private var _submitted: [CBv2Request] = []
    private var _cancelled: [CBv2RequestID] = []
    private var _shutdownCalls = 0
    private var _manualContinuation: AsyncStream<CBv2Event>.Continuation?
    var capacitySnapshot: CBv2CapacitySnapshot

    init(
        script: Script,
        capacity: CBv2CapacitySnapshot = CBv2CapacitySnapshot(
            activeRequests: 0, waitingRequests: 0, kvBytesInUse: 0,
            kvBytesCapacity: 0, activeTokens: 0
        )
    ) {
        self.script = script
        self.capacitySnapshot = capacity
    }

    var submitted: [CBv2Request] { lock.withLock { _submitted } }
    var cancelled: [CBv2RequestID] { lock.withLock { _cancelled } }
    var shutdownCalls: Int { lock.withLock { _shutdownCalls } }
    var manualContinuation: AsyncStream<CBv2Event>.Continuation? {
        lock.withLock { _manualContinuation }
    }

    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        let script = lock.withLock { () -> Script in
            _submitted.append(request)
            return self.script
        }
        switch script {
        case .throwOnSubmit(let error):
            throw error
        case .stream(let events):
            let (stream, continuation) = AsyncStream<CBv2Event>.makeStream()
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
            return stream
        case .manual:
            let (stream, continuation) = AsyncStream<CBv2Event>.makeStream()
            lock.withLock { _manualContinuation = continuation }
            return stream
        }
    }

    func cancel(_ id: CBv2RequestID) {
        lock.withLock { _cancelled.append(id) }
    }

    func capacity() -> CBv2CapacitySnapshot {
        lock.withLock { capacitySnapshot }
    }

    func shutdown() async {
        lock.withLock { _shutdownCalls += 1 }
    }
}

// MARK: - Stub tokenizer

/// Fixed-output tokenizer: `applyChatTemplate` always yields
/// `templateTokens`; EOS resolves via the token table.
private struct StubTokenizer: MLXLMCommon.Tokenizer {
    var templateTokens: [Int] = [1, 2, 3, 4, 5]
    var tokenTable: [String: Int] = ["</s>": 2, "<|eot|>": 7]
    var eosTokenString: String? = "</s>"
    var failTemplate = false

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        Array(repeating: 0, count: text.count)
    }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { "" }
    func convertTokenToId(_ token: String) -> Int? { tokenTable[token] }
    func convertIdToToken(_ id: Int) -> String? { nil }
    var bosToken: String? { nil }
    var eosToken: String? { eosTokenString }
    var unknownToken: String? { nil }

    struct TemplateError: Error {}

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        if failTemplate { throw TemplateError() }
        return templateTokens
    }
}

// MARK: - Telemetry capture

private final class TelemetrySink: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [TelemetryEvent] = []
    var events: [TelemetryEvent] { lock.withLock { _events } }
    func callback() -> @Sendable (TelemetryEvent) -> Void {
        { [weak self] event in
            guard let self else { return }
            self.lock.withLock { self._events.append(event) }
        }
    }
}

// MARK: - Stream recording (fixture comparison shape)

/// Normalized event shape for fixture comparison. TPS is wall-clock
/// dependent so it is recorded separately, not part of the fixture.
private enum RecordedEvent: Equatable, CustomStringConvertible {
    case chunk(String)
    case info(prompt: Int, completion: Int)
    case error(String)

    var description: String {
        switch self {
        case .chunk(let s): return "chunk(\(s))"
        case .info(let p, let c): return "info(\(p),\(c))"
        case .error(let m): return "error(\(m))"
        }
    }
}

private func record(
    _ stream: AsyncStream<GenerationEvent>
) async -> (events: [RecordedEvent], tps: [Double]) {
    var events: [RecordedEvent] = []
    var tps: [Double] = []
    for await event in stream {
        switch event {
        case .chunk(let text):
            events.append(.chunk(text))
        case .info(let prompt, let completion, let tokensPerSecond):
            events.append(.info(prompt: prompt, completion: completion))
            tps.append(tokensPerSecond)
        case .error(let message):
            events.append(.error(message))
        }
    }
    return (events, tps)
}

// MARK: - Shared builders

private func makeBridge(
    engine: ScriptedCBv2Engine,
    tokenizer: StubTokenizer = StubTokenizer(),
    modelId: String = "gemma-4-27b-it",
    eosTokenIds: Set<Int> = [2],
    extraEOSTokens: [String] = [],
    defaultMaxTokens: Int = 4096,
    kvBytesPerToken: Int = 0,
    telemetry: TelemetrySink? = nil
) -> EngineV2Bridge {
    EngineV2Bridge(
        engine: engine,
        modelId: modelId,
        tokenizer: TokenizerHandle(tokenizer),
        eosTokenIds: eosTokenIds,
        extraEOSTokens: extraEOSTokens,
        defaultMaxTokens: defaultMaxTokens,
        maxConcurrentRequests: 4,
        kvBytesPerToken: kvBytesPerToken,
        emitTelemetry: telemetry?.callback()
    )
}

private func makeRequest(
    temperature: Float? = nil,
    topP: Float? = nil,
    topK: Int? = nil,
    maxTokens: Int? = nil,
    repetitionPenalty: Float? = nil,
    presencePenalty: Float? = nil,
    frequencyPenalty: Float? = nil,
    stop: StopSequences? = nil,
    seed: UInt64? = nil,
    logitBias: [String: Float]? = nil,
    logprobs: Bool? = nil,
    topLogprobs: Int? = nil
) -> ChatCompletionRequest {
    ChatCompletionRequest(
        model: "gemma-4-27b-it",
        messages: [ChatMessage(role: "user", content: "hi")],
        temperature: temperature,
        top_p: topP,
        top_k: topK,
        max_tokens: maxTokens,
        repetition_penalty: repetitionPenalty,
        presence_penalty: presencePenalty,
        frequency_penalty: frequencyPenalty,
        stop: stop,
        seed: seed,
        logit_bias: logitBias,
        logprobs: logprobs,
        top_logprobs: topLogprobs
    )
}

// MARK: - Translation

@Suite("EngineV2 translation: ChatCompletionRequest → CBv2Request")
struct EngineV2TranslationTests {

    @Test("full request translates field-by-field")
    func fullFieldTranslation() {
        let request = makeRequest(
            temperature: 0.7, topP: 0.9, topK: 40, maxTokens: 128,
            repetitionPenalty: 1.1, presencePenalty: 0.5, frequencyPenalty: 0.25,
            stop: .multiple(["a", "b"]), seed: 42,
            logitBias: ["50256": -100], logprobs: true, topLogprobs: 5
        )
        let cbv2 = EngineV2Translation.cbv2Request(
            id: CBv2RequestID(9),
            promptTokens: [1, 2, 3],
            request: request,
            defaultMaxTokens: 4096,
            stopTokenIds: [2, 7]
        )
        #expect(cbv2.id == CBv2RequestID(9))
        #expect(cbv2.promptTokens == [1, 2, 3])
        #expect(cbv2.maxTokens == 128)
        #expect(cbv2.stopTokens == [2, 7])
        #expect(cbv2.stopStrings == ["a", "b"])
        #expect(cbv2.priority == 0)
        #expect(cbv2.sampling.temperature == 0.7)
        #expect(cbv2.sampling.topP == 0.9)
        #expect(cbv2.sampling.topK == 40)
        #expect(cbv2.sampling.repetitionPenalty == 1.1)
        #expect(cbv2.sampling.presencePenalty == 0.5)
        #expect(cbv2.sampling.frequencyPenalty == 0.25)
        #expect(cbv2.sampling.seed == 42)
        #expect(cbv2.sampling.logitBias == [50256: -100])
        #expect(cbv2.sampling.topLogprobs == 5)
    }

    @Test("unset knobs collapse to legacy defaults (greedy temperature 0)")
    func defaultTranslation() {
        let cbv2 = EngineV2Translation.cbv2Request(
            id: CBv2RequestID(1),
            promptTokens: [1],
            request: makeRequest(),
            defaultMaxTokens: 2048,
            stopTokenIds: []
        )
        // Legacy engine path uses `request.temperature ?? 0.0` — pinned here
        // so v2 can't drift to the contract's 1.0 default.
        #expect(cbv2.sampling.temperature == 0.0)
        #expect(cbv2.sampling.topP == 1.0)
        #expect(cbv2.sampling.topK == 0)
        #expect(cbv2.sampling.repetitionPenalty == 1.0)
        #expect(cbv2.sampling.frequencyPenalty == 0)
        #expect(cbv2.sampling.presencePenalty == 0)
        #expect(cbv2.sampling.seed == nil)
        #expect(cbv2.sampling.logitBias.isEmpty)
        #expect(cbv2.sampling.topLogprobs == 0)
        // maxTokens defaulting matches BatchScheduler.resolvedMaxTokens.
        #expect(cbv2.maxTokens == 2048)
        #expect(cbv2.stopStrings.isEmpty)
    }

    @Test("logit_bias string keys parse to token ids; junk keys are dropped")
    func logitBiasParsing() {
        let parsed = EngineV2Translation.parseLogitBias([
            "50256": -100,
            " 42 ": 1.5,      // whitespace-tolerant
            "abc": 5,         // non-numeric → dropped
            "-7": 3,          // negative id → dropped
        ])
        #expect(parsed == [50256: -100, 42: 1.5])
        #expect(EngineV2Translation.parseLogitBias(nil).isEmpty)
        #expect(EngineV2Translation.parseLogitBias([:]).isEmpty)
    }

    @Test("logprobs/top_logprobs mapping (0 = none; chosen-token → 1; clamp 20)")
    func topLogprobsMapping() {
        #expect(EngineV2Translation.topLogprobs(logprobs: nil, topLogprobs: nil) == 0)
        #expect(EngineV2Translation.topLogprobs(logprobs: false, topLogprobs: 3) == 0)
        // Contract can't express "chosen token only" — maps to 1 (see
        // CONTRACT-ISSUES-H-provider.md §2).
        #expect(EngineV2Translation.topLogprobs(logprobs: true, topLogprobs: nil) == 1)
        #expect(EngineV2Translation.topLogprobs(logprobs: true, topLogprobs: 0) == 1)
        #expect(EngineV2Translation.topLogprobs(logprobs: true, topLogprobs: 5) == 5)
        #expect(EngineV2Translation.topLogprobs(logprobs: true, topLogprobs: 50) == 20)
    }

    @Test("stop resolution follows buildStopTokenIds semantics")
    func stopResolution() {
        // model EOS ∪ tokenizer EOS ∪ resolvable extra EOS tokens.
        let resolved = EngineV2Translation.stopTokenIds(
            eosTokenIds: [1, 2],
            tokenizerEOSTokenId: 2,
            extraEOSTokens: ["<|eot|>", "<|unknown|>"],
            convertTokenToId: { ["<|eot|>": 7][$0] }
        )
        #expect(resolved == [1, 2, 7])
    }

    @Test("bridge resolves the stop set once at construction and stamps every request")
    func bridgeStampsStopTokens() async {
        let engine = ScriptedCBv2Engine(script: .stream([
            .finished(reason: .stop, usage: CBv2Usage(promptTokens: 5, completionTokens: 0))
        ]))
        let bridge = makeBridge(
            engine: engine,
            tokenizer: StubTokenizer(),   // eos "</s>" → 2
            eosTokenIds: [1],
            extraEOSTokens: ["<|eot|>"]   // → 7
        )
        let stream = await bridge.submit(request: makeRequest())
        _ = await record(stream)
        #expect(engine.submitted.count == 1)
        #expect(engine.submitted[0].stopTokens == [1, 2, 7])
        // Tokenization went through the tokenizer's chat-template path.
        #expect(engine.submitted[0].promptTokens == [1, 2, 3, 4, 5])
    }
}

// MARK: - Event framing (fixture-compare against the legacy stream shape)

@Suite("EngineV2 event framing matches the legacy GenerationEvent shape")
struct EngineV2EventFramingTests {

    @Test("happy path: chunks then a single usage info, then finish")
    func happyPath() async {
        let engine = ScriptedCBv2Engine(script: .stream([
            .delta(text: "Hello", tokens: [10], logprobs: nil),
            .delta(text: " world", tokens: [11], logprobs: nil),
            // Empty-text delta (BPE intermediate): counted, never yielded.
            .delta(text: "", tokens: [12], logprobs: nil),
            .finished(reason: .stop, usage: CBv2Usage(promptTokens: 5, completionTokens: 3)),
        ]))
        let bridge = makeBridge(engine: engine)
        let (events, tps) = await record(
            await bridge.submit(request: makeRequest())
        )
        // Recorded legacy shape (BatchScheduler+EngineBridge): every
        // non-empty text delta is one `.chunk`, a successful terminal is
        // exactly one `.info(prompt, completion, tps)`, then finish.
        let legacyShape: [RecordedEvent] = [
            .chunk("Hello"),
            .chunk(" world"),
            .info(prompt: 5, completion: 3),
        ]
        #expect(events == legacyShape)
        #expect(tps.count == 1)
        #expect(tps[0] >= 0)
    }

    @Test("length finish frames identically to stop")
    func lengthFramesLikeStop() async {
        let engine = ScriptedCBv2Engine(script: .stream([
            .delta(text: "x", tokens: [10], logprobs: nil),
            // Terminal under-reports the prompt (4 < the 5 tokens the bridge
            // tokenized) — the bridge-known count wins (legacy max() rule).
            .finished(reason: .length, usage: CBv2Usage(promptTokens: 4, completionTokens: 1)),
        ]))
        let bridge = makeBridge(engine: engine)
        let (events, _) = await record(await bridge.submit(request: makeRequest()))
        #expect(events == [.chunk("x"), .info(prompt: 5, completion: 1)])
    }

    @Test("terminal usage can only raise observed counts (billing-zero defense)")
    func usageMaxDefense() async {
        let engine = ScriptedCBv2Engine(script: .stream([
            .delta(text: "a", tokens: [10], logprobs: nil),
            .delta(text: "b", tokens: [11, 12], logprobs: nil),
            // Terminal under-reports (0 completion) — must not zero billing.
            .finished(reason: .stop, usage: CBv2Usage(promptTokens: 5, completionTokens: 0)),
        ]))
        let bridge = makeBridge(engine: engine)
        let (events, _) = await record(await bridge.submit(request: makeRequest()))
        #expect(events == [.chunk("a"), .chunk("b"), .info(prompt: 5, completion: 3)])
    }

    @Test("cancel that did work: usage info BEFORE the cancel error (legacy abort framing)")
    func cancelledWithWork() async {
        let engine = ScriptedCBv2Engine(script: .stream([
            .delta(text: "Hi", tokens: [10], logprobs: nil),
            .finished(reason: .cancelled, usage: CBv2Usage(promptTokens: 5, completionTokens: 1)),
        ]))
        let bridge = makeBridge(engine: engine)
        let (events, _) = await record(await bridge.submit(request: makeRequest()))
        #expect(events == [
            .chunk("Hi"),
            .info(prompt: 5, completion: 1),
            .error("request cancelled"),
        ])
    }

    @Test("cancel before any decode: prompt-only usage info, then cancel error")
    func cancelledWithoutWork() async {
        let engine = ScriptedCBv2Engine(script: .stream([
            .finished(reason: .cancelled, usage: CBv2Usage(promptTokens: 0, completionTokens: 0)),
        ]))
        let bridge = makeBridge(engine: engine)
        let (events, _) = await record(await bridge.submit(request: makeRequest()))
        // The bridge tokenized a 5-token prompt, so even a did-nothing
        // cancel reports prompt usage before the error — exactly the legacy
        // abort framing (`recordFinish` max()es the bridge-known prompt).
        #expect(events == [
            .info(prompt: 5, completion: 0),
            .error("request cancelled"),
        ])
    }

    @Test("engine error: error only — no info (legacy failure framing)")
    func engineError() async {
        let telemetry = TelemetrySink()
        let engine = ScriptedCBv2Engine(script: .stream([
            .delta(text: "x", tokens: [10], logprobs: nil),
            .finished(
                reason: .error("metal command buffer failed"),
                usage: CBv2Usage(promptTokens: 4, completionTokens: 1)
            ),
        ]))
        let bridge = makeBridge(engine: engine, telemetry: telemetry)
        let (events, _) = await record(await bridge.submit(request: makeRequest()))
        #expect(events == [.chunk("x"), .error("metal command buffer failed")])
        // engine_v2-tagged inference_error telemetry (allowlisted fields
        // only — never the raw engine message).
        let errorEvents = telemetry.events.filter { $0.kind == .inferenceError }
        #expect(errorEvents.count == 1)
        #expect(errorEvents.first?.fields?["backend"]?.description == "engine_v2")
        #expect(errorEvents.first?.fields?["operation"]?.description == "engine_v2_error")
    }

    @Test("stream closed without terminal → teardown sentinel error")
    func teardownSentinel() async {
        let engine = ScriptedCBv2Engine(script: .stream([
            .delta(text: "partial", tokens: [10], logprobs: nil)
            // no .finished — engine torn down mid-request
        ]))
        let bridge = makeBridge(engine: engine)
        let (events, _) = await record(await bridge.submit(request: makeRequest()))
        #expect(events == [
            .chunk("partial"),
            .error("request stream closed by engine teardown"),
        ])
        // Local bookkeeping must be dropped.
        let counters = await bridge._testCounters()
        #expect(counters.active == 0)
    }

    @Test("tokenize failure surfaces as a tokenize error without touching the engine")
    func tokenizeFailure() async {
        let engine = ScriptedCBv2Engine(script: .stream([]))
        var tokenizer = StubTokenizer()
        tokenizer.failTemplate = true
        let bridge = makeBridge(engine: engine, tokenizer: tokenizer)
        let (events, _) = await record(await bridge.submit(request: makeRequest()))
        #expect(events.count == 1)
        if case .error(let message)? = events.first {
            #expect(message.hasPrefix("Failed to tokenize:"))
        }
        #expect(engine.submitted.isEmpty)
    }
}

// MARK: - Error mapping (capacity → retryable class)

@Suite("EngineV2 admission-error mapping")
struct EngineV2ErrorMappingTests {

    @Test("capacityExhausted → canonical token_budget_exhausted string → retryable class")
    func capacityExhaustedIsRetryable() async {
        let engine = ScriptedCBv2Engine(
            script: .throwOnSubmit(
                CBv2KVError.capacityExhausted(needed: 5120, available: 1024)
            ))
        let bridge = makeBridge(engine: engine)
        let (events, _) = await record(await bridge.submit(request: makeRequest()))
        #expect(events.count == 1)
        guard case .error(let message)? = events.first else {
            Issue.record("expected a single .error event, got \(events)")
            return
        }
        #expect(message == "token_budget_exhausted: request requires 5120 tokens but only 1024 available")
        // The exact classification the legacy engine's rejections get:
        // retryable capacity (→ 503 with backoff upstream).
        let classified = MultiModelBatchSchedulerEngineError.fromSchedulerMessage(message)
        #expect(classified == .tokenBudgetExhausted(message))
    }

    @Test("backendIneligible → non-retryable generation failure")
    func backendIneligibleIsNotRetryable() async {
        let engine = ScriptedCBv2Engine(
            script: .throwOnSubmit(
                CBv2KVError.backendIneligible(reason: "sinks unsupported")
            ))
        let bridge = makeBridge(engine: engine)
        let (events, _) = await record(await bridge.submit(request: makeRequest()))
        guard case .error(let message)? = events.first else {
            Issue.record("expected a single .error event, got \(events)")
            return
        }
        let classified = MultiModelBatchSchedulerEngineError.fromSchedulerMessage(message)
        #expect(classified == .generationFailed(message))
    }

    @Test("unknown submit error → generic failure, never claims capacity")
    func unknownErrorIsGeneric() {
        struct Boom: Error {}
        let message = EngineV2Translation.admissionErrorMessage(for: Boom())
        #expect(!message.contains("token_budget_exhausted"))
        let classified = MultiModelBatchSchedulerEngineError.fromSchedulerMessage(message)
        #expect(classified == .generationFailed(message))
    }
}

// MARK: - Cancellation

@Suite("EngineV2 cancellation wiring")
struct EngineV2CancellationTests {

    @Test("bridge cancel maps the provider request-id to the minted engine id")
    func bridgeCancelMapsId() async {
        let engine = ScriptedCBv2Engine(script: .manual)
        let bridge = makeBridge(engine: engine)
        let stream = await bridge.submit(request: makeRequest(), requestId: "req-abc")
        let engineId = await bridge._testEngineRequestId(for: "req-abc")
        #expect(engineId != nil)

        await bridge.cancel(requestId: "req-abc")
        #expect(engine.cancelled == [engineId!])

        // Engine delivers the cancelled terminal; the stream tears down
        // with the legacy abort framing.
        engine.manualContinuation?.yield(
            .finished(reason: .cancelled, usage: CBv2Usage(promptTokens: 5, completionTokens: 0)))
        engine.manualContinuation?.finish()
        let (events, _) = await record(stream)
        #expect(events.last == .error("request cancelled"))
        #expect(await bridge._testEngineRequestId(for: "req-abc") == nil)
    }

    @Test("cancel for an unknown id is a no-op")
    func cancelUnknownId() async {
        let engine = ScriptedCBv2Engine(script: .manual)
        let bridge = makeBridge(engine: engine)
        await bridge.cancel(requestId: "req-never-submitted")
        #expect(engine.cancelled.isEmpty)
    }

    @Test("runtime fan-out (the ProviderLoop handleCancellation hook path)")
    func runtimeFanOut() async {
        let engine = ScriptedCBv2Engine(script: .manual)
        let bridge = makeBridge(engine: engine)
        let runtime = EngineV2Runtime()
        await runtime.register(modelId: "gemma-4-27b-it", bridge: bridge)

        _ = await bridge.submit(request: makeRequest(), requestId: "req-xyz")
        let owned = await runtime.cancel(requestId: "req-xyz")
        #expect(owned)
        #expect(engine.cancelled.count == 1)

        // Unknown id: no bridge owns it (legacy path's request).
        let unowned = await runtime.cancel(requestId: "req-legacy")
        #expect(!unowned)
        #expect(engine.cancelled.count == 1)
    }
}

// MARK: - Capacity mapping

@Suite("EngineV2 capacity: CBv2CapacitySnapshot → BackendSlotCapacity")
struct EngineV2CapacityTests {

    @Test("bytes-derived truthful budget mapping onto the existing protocol fields")
    func snapshotMapping() async {
        let engine = ScriptedCBv2Engine(
            script: .manual,
            capacity: CBv2CapacitySnapshot(
                activeRequests: 2,
                waitingRequests: 3,
                kvBytesInUse: 4_000_000,
                kvBytesCapacity: 40_000_000,
                activeTokens: 1000
            ))
        let bridge = makeBridge(engine: engine, kvBytesPerToken: 4000)
        let slot = await bridge.backendSlotCapacity()
        #expect(slot.model == "gemma-4-27b-it")
        #expect(slot.state == "running")
        #expect(slot.numRunning == 2)
        #expect(slot.numWaiting == 3)
        #expect(slot.activeTokens == 1000)
        #expect(slot.activeTokenBudgetUsed == 1000)   // 4 MB / 4000 B-per-token
        #expect(slot.activeTokenBudgetMax == 10000)   // 40 MB / 4000 B-per-token
        #expect(slot.kvBytesPerToken == 4000)
        #expect(slot.maxConcurrency == 4)
        #expect(!slot.wedgeSuspected)
    }

    @Test("idle when nothing runs; token fallback when kvBytesPerToken unknown")
    func idleAndFallback() async {
        let engine = ScriptedCBv2Engine(
            script: .manual,
            capacity: CBv2CapacitySnapshot(
                activeRequests: 0,
                waitingRequests: 0,
                kvBytesInUse: 123,
                kvBytesCapacity: 456,
                activeTokens: 17
            ))
        let bridge = makeBridge(engine: engine, kvBytesPerToken: 0)
        let slot = await bridge.backendSlotCapacity()
        #expect(slot.state == "idle")
        #expect(slot.activeTokenBudgetUsed == 17)
        #expect(slot.activeTokenBudgetMax == 0)
    }

    @Test("wedge counters flow into the slot (admits / first tokens / steps)")
    func wedgeCountersInSlot() async {
        let engine = ScriptedCBv2Engine(script: .stream([
            .delta(text: "hello", tokens: [10], logprobs: nil),
            .finished(reason: .stop, usage: CBv2Usage(promptTokens: 5, completionTokens: 1)),
        ]))
        let bridge = makeBridge(engine: engine)
        _ = await record(await bridge.submit(request: makeRequest()))
        let slot = await bridge.backendSlotCapacity()
        #expect(slot.admits == 1)
        #expect(slot.firstTokensEmitted == 1)
        // Loop-progress proxy: 2 events were observed.
        #expect(slot.stepsExecuted == 2)
    }

    @Test("runtime capacity summary aggregates registered bridges")
    func runtimeCapacitySummary() async {
        let engine = ScriptedCBv2Engine(
            script: .manual,
            capacity: CBv2CapacitySnapshot(
                activeRequests: 1, waitingRequests: 0, kvBytesInUse: 0,
                kvBytesCapacity: 0, activeTokens: 10
            ))
        let bridge = makeBridge(engine: engine)
        let runtime = EngineV2Runtime()

        // Empty registry (v2 off) → empty summary, legacy heartbeat unchanged.
        let empty = await runtime.capacitySummary()
        #expect(empty.slots.isEmpty)
        #expect(empty.activeRequests == 0)

        await runtime.register(modelId: "gemma-4-27b-it", bridge: bridge)
        _ = await bridge.submit(request: makeRequest(), requestId: "req-1")
        let summary = await runtime.capacitySummary()
        #expect(summary.slots.count == 1)
        #expect(summary.slots.first?.model == "gemma-4-27b-it")
        #expect(summary.activeRequests == 1)

        await runtime.unregister(modelId: "gemma-4-27b-it")
        let after = await runtime.capacitySummary()
        #expect(after.slots.isEmpty)
    }
}

// MARK: - Config gating

@Suite("EngineV2 config gating (flag, allowlist, fallback)")
struct EngineV2ConfigGatingTests {

    @Test("flag resolution: env overrides config; garbage fails safe")
    func flagResolution() {
        #expect(EngineV2Config.flagEnabled(environment: ["DARKBLOOM_ENGINE_V2": "1"], configEnabled: false))
        #expect(EngineV2Config.flagEnabled(environment: ["DARKBLOOM_ENGINE_V2": "true"], configEnabled: false))
        // Env kill switch beats config.
        #expect(!EngineV2Config.flagEnabled(environment: ["DARKBLOOM_ENGINE_V2": "0"], configEnabled: true))
        #expect(!EngineV2Config.flagEnabled(environment: ["DARKBLOOM_ENGINE_V2": "off"], configEnabled: true))
        // Absent env defers to the `engine_v2` provider-config key.
        #expect(EngineV2Config.flagEnabled(environment: [:], configEnabled: true))
        #expect(!EngineV2Config.flagEnabled(environment: [:], configEnabled: false))
        // Unrecognized value fails safe (legacy).
        #expect(!EngineV2Config.flagEnabled(environment: ["DARKBLOOM_ENGINE_V2": "maybe"], configEnabled: true))
    }

    @Test("default allowlist: gemma-4* and gpt-oss*, incl. org-prefixed ids")
    func defaultAllowlist() {
        #expect(EngineV2Config.modelAllowlisted("gemma-4-27b-it"))
        #expect(EngineV2Config.modelAllowlisted("Gemma-4-9B"))
        #expect(EngineV2Config.modelAllowlisted("gpt-oss-20b-4bit"))
        #expect(EngineV2Config.modelAllowlisted("mlx-community/gpt-oss-20b-4bit"))
        #expect(EngineV2Config.modelAllowlisted("mlx-community/gemma-4-27b-it-4bit"))
        #expect(!EngineV2Config.modelAllowlisted("qwen3-8b"))
        #expect(!EngineV2Config.modelAllowlisted("llama-3.3-70b"))
        #expect(!EngineV2Config.modelAllowlisted(""))
    }

    @Test("allowlist env override")
    func allowlistOverride() {
        let env = ["DARKBLOOM_ENGINE_V2_MODELS": "qwen3*, exact-model"]
        let patterns = EngineV2Config.allowlistPatterns(environment: env)
        #expect(EngineV2Config.modelAllowlisted("qwen3-8b", patterns: patterns))
        #expect(EngineV2Config.modelAllowlisted("exact-model", patterns: patterns))
        #expect(!EngineV2Config.modelAllowlisted("exact-model-2", patterns: patterns))
        #expect(!EngineV2Config.modelAllowlisted("gemma-4-27b-it", patterns: patterns))
    }

    @Test("selection matrix")
    func selectionMatrix() {
        // Flag off → legacy even for allowlisted models.
        #expect(EngineV2Config.selection(
            modelId: "gemma-4-27b-it", environment: [:], configEnabled: false
        ) == .legacy)
        // Flag on + allowlisted → v2.
        #expect(EngineV2Config.selection(
            modelId: "gemma-4-27b-it",
            environment: ["DARKBLOOM_ENGINE_V2": "1"], configEnabled: false
        ) == .v2)
        // Flag on + non-allowlisted → legacy.
        #expect(EngineV2Config.selection(
            modelId: "qwen3-8b",
            environment: ["DARKBLOOM_ENGINE_V2": "1"], configEnabled: false
        ) == .legacy)
    }

    @Test("factory: flag off → legacy, builder never invoked")
    func factoryFlagOff() {
        let telemetry = TelemetrySink()
        var builderCalls = 0
        let bridge = EngineV2Factory.makeBridgeIfSelected(
            modelId: "gemma-4-27b-it",
            configEnabled: false,
            environment: [:],
            tokenizer: TokenizerHandle(StubTokenizer()),
            eosTokenIds: [2],
            emitTelemetry: telemetry.callback(),
            makeEngine: {
                builderCalls += 1
                return ScriptedCBv2Engine(script: .manual)
            }
        )
        #expect(bridge == nil)
        #expect(builderCalls == 0)
        #expect(telemetry.events.isEmpty)
    }

    @Test("factory: flag on + non-allowlisted model → legacy, builder never invoked")
    func factoryNonAllowlisted() {
        var builderCalls = 0
        let bridge = EngineV2Factory.makeBridgeIfSelected(
            modelId: "qwen3-8b",
            configEnabled: true,
            environment: [:],
            tokenizer: TokenizerHandle(StubTokenizer()),
            eosTokenIds: [2],
            makeEngine: {
                builderCalls += 1
                return ScriptedCBv2Engine(script: .manual)
            }
        )
        #expect(bridge == nil)
        #expect(builderCalls == 0)
    }

    @Test("factory: init failure → legacy fallback + engine_v2_fallback telemetry")
    func factoryInitFailureFallsBack() {
        struct InitFailure: Error {}
        let telemetry = TelemetrySink()
        let bridge = EngineV2Factory.makeBridgeIfSelected(
            modelId: "gpt-oss-20b",
            configEnabled: true,
            environment: [:],
            tokenizer: TokenizerHandle(StubTokenizer()),
            eosTokenIds: [2],
            emitTelemetry: telemetry.callback(),
            makeEngine: { throw InitFailure() }
        )
        #expect(bridge == nil)
        let events = telemetry.events
        #expect(events.count == 1)
        #expect(events.first?.kind == .engineHealth)
        #expect(events.first?.severity == .warn)
        #expect(events.first?.fields?["operation"]?.description == "engine_v2_fallback")
        #expect(events.first?.fields?["backend"]?.description == "engine_v2")
        #expect(events.first?.fields?["model"]?.description == "gpt-oss-20b")
        #expect(events.first?.fields?["error_class"]?.description.contains("InitFailure") == true)
    }

    @Test("factory: selected + healthy builder → v2 bridge")
    func factorySelectedBuilds() {
        let bridge = EngineV2Factory.makeBridgeIfSelected(
            modelId: "gemma-4-27b-it",
            configEnabled: true,
            environment: [:],
            tokenizer: TokenizerHandle(StubTokenizer()),
            eosTokenIds: [2],
            makeEngine: { ScriptedCBv2Engine(script: .manual) }
        )
        #expect(bridge != nil)
    }

    @Test("backend config decodes engine_v2 key (default false)")
    func backendConfigKey() throws {
        let decoder = JSONDecoder()
        let on = try decoder.decode(
            BackendSettings.self,
            from: Data(#"{"engine_v2": true}"#.utf8)
        )
        #expect(on.engineV2)
        let absent = try decoder.decode(
            BackendSettings.self,
            from: Data(#"{}"#.utf8)
        )
        #expect(!absent.engineV2)
    }
}

// MARK: - Shutdown

@Suite("EngineV2 bridge shutdown")
struct EngineV2ShutdownTests {
    @Test("shutdown drains through the engine")
    func shutdownForwards() async {
        let engine = ScriptedCBv2Engine(script: .manual)
        let bridge = makeBridge(engine: engine)
        await bridge.shutdown()
        #expect(engine.shutdownCalls == 1)
    }
}
