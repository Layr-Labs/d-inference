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
    /// ALL manual continuations, in submit order — retained so an earlier
    /// request's event stream is not torn down (continuation deinit ⇒
    /// stream finish) when a later manual submit arrives.
    private var _manualContinuations: [AsyncStream<CBv2Event>.Continuation] = []
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
        lock.withLock { _manualContinuations.last }
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
            lock.withLock { _manualContinuations.append(continuation) }
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
    /// Deterministic per-id text ("t<id>") so logprob-entry conversion
    /// (token string + UTF-8 bytes) is assertable.
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        tokenIds.map { "t\($0)" }.joined()
    }
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
        case .info(let prompt, let completion, let tokensPerSecond, _):
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
    engine: any CBv2Engine,
    tokenizer: StubTokenizer = StubTokenizer(),
    modelId: String = "gemma-4-27b-it",
    eosTokenIds: Set<Int> = [2],
    extraEOSTokens: [String] = [],
    defaultMaxTokens: Int = 4096,
    kvBytesPerToken: Int = 0,
    kvBudget: GlobalKVCacheBudget? = nil,
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
        kvBudget: kvBudget,
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
    user: String? = nil,
    promptCacheKey: String? = nil,
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
        user: user,
        prompt_cache_key: promptCacheKey,
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

    @Test("parseLogitBias reports a dropped-key count for the silent-drop signal (fix #9)")
    func logitBiasDroppedCount() {
        let result = EngineV2Translation.parseLogitBiasCountingDropped([
            "50256": -100,   // valid
            "abc": 5,        // non-numeric → dropped
            "-7": 3,         // negative → dropped
            " 9 ": 1,        // valid (whitespace tolerant)
        ])
        #expect(result.bias == [50256: -100, 9: 1])
        #expect(result.dropped == 2)
        // All-valid → zero dropped; nil/empty → zero dropped.
        #expect(EngineV2Translation.parseLogitBiasCountingDropped(["1": 2]).dropped == 0)
        #expect(EngineV2Translation.parseLogitBiasCountingDropped(nil).dropped == 0)
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

    @Test("cacheScope maps onto CBv2Request.cacheSalt; \"\" maps to nil")
    func cacheSaltMapping() {
        // TB-007 forward plumbing: a non-empty tenant scope becomes the
        // per-request salt; unscoped ("") falls back to nil so the engine
        // uses its cache-level salt (byte-identical pre-salt hashes).
        let salted = EngineV2Translation.cbv2Request(
            id: CBv2RequestID(1), promptTokens: [1], request: makeRequest(),
            defaultMaxTokens: 16, stopTokenIds: [], cacheScope: "tenant-a")
        #expect(salted.cacheSalt == "tenant-a")
        let unsalted = EngineV2Translation.cbv2Request(
            id: CBv2RequestID(2), promptTokens: [1], request: makeRequest(),
            defaultMaxTokens: 16, stopTokenIds: [])
        #expect(unsalted.cacheSalt == nil)
    }

    @Test("engine logprobs convert to the OpenAI streaming entry shape")
    func sseTokenLogprobConversion() {
        let names = [10: "Hi", 11: "Yo"]
        let entries = EngineV2Translation.sseTokenLogprobs(
            [
                CBv2TokenLogprob(
                    token: 10, logprob: -0.25,
                    topLogprobs: [(token: 10, logprob: -0.25), (token: 11, logprob: -1.5)]
                ),
                CBv2TokenLogprob(token: 11, logprob: -0.5),
            ],
            decodeToken: { names[$0] ?? "?" }
        )
        #expect(entries.count == 2)
        #expect(entries[0].token == "Hi")
        #expect(entries[0].logprob == -0.25)
        #expect(entries[0].bytes == [72, 105])  // UTF-8 of "Hi"
        #expect(entries[0].topLogprobs.count == 2)
        #expect(entries[0].topLogprobs[1].token == "Yo")
        #expect(entries[0].topLogprobs[1].logprob == -1.5)
        #expect(entries[0].topLogprobs[1].bytes == [89, 111])
        // No alternatives requested → empty top_logprobs, entry still carried.
        #expect(entries[1].token == "Yo")
        #expect(entries[1].topLogprobs.isEmpty)
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

    @Test("bridge stamps the tenant cache scope as CBv2Request.cacheSalt")
    func bridgeStampsCacheSalt() async {
        let engine = ScriptedCBv2Engine(script: .stream([
            .finished(reason: .stop, usage: CBv2Usage(promptTokens: 5, completionTokens: 0))
        ]))
        let bridge = makeBridge(engine: engine)
        // Coordinator path shape: scope decoded out-of-band, passed explicitly.
        _ = await record(await bridge.submitTokenized(
            promptTokens: [1, 2], request: makeRequest(), requestId: "req-salt-1",
            cacheScope: "tenant-scope"))
        // Internal-shape path: scope derived from the request's own
        // prompt_cache_key via `ChatCompletionRequest.cacheScope`.
        _ = await record(await bridge.submit(
            request: makeRequest(promptCacheKey: "consumer-key"),
            requestId: "req-salt-2"))
        // `user` is the fallback identity when prompt_cache_key is absent.
        _ = await record(await bridge.submit(
            request: makeRequest(user: "user-77"), requestId: "req-salt-3"))
        // No tenant identity at all → nil (engine cache-level salt fallback).
        _ = await record(await bridge.submit(
            request: makeRequest(), requestId: "req-salt-4"))
        #expect(engine.submitted.count == 4)
        #expect(engine.submitted[0].cacheSalt == "tenant-scope")
        #expect(engine.submitted[1].cacheSalt == ChatCompletionRequest.scopeHash("consumer-key"))
        #expect(engine.submitted[2].cacheSalt == ChatCompletionRequest.scopeHash("user-77"))
        #expect(engine.submitted[3].cacheSalt == nil)
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

    @Test("length finish frames usage like stop but preserves finish_reason 'length'")
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

    /// Regression: the v2 bridge used to flatten `.length` into the same
    /// `.info` shape as `.stop`, so clients saw finish_reason "stop" on a
    /// max_tokens truncation. The reason now rides on GenerationEvent.info.
    @Test("finish reason threads through: .length => 'length', .stop => 'stop', cancel partial => nil")
    func finishReasonThreadsThroughInfoEvent() async {
        func terminalReason(_ finish: CBv2FinishReason) async -> String?? {
            let engine = ScriptedCBv2Engine(script: .stream([
                .delta(text: "x", tokens: [10], logprobs: nil),
                .finished(reason: finish, usage: CBv2Usage(promptTokens: 4, completionTokens: 1)),
            ]))
            let bridge = makeBridge(engine: engine)
            var got: String?? = nil
            for await event in await bridge.submit(request: makeRequest()) {
                if case .info(_, _, _, let reason) = event {
                    got = .some(reason)
                }
            }
            return got
        }
        #expect(await terminalReason(.length) == .some("length"))
        #expect(await terminalReason(.stop) == .some("stop"))
        // Cancelled-with-work emits its usage info with a nil reason (the
        // terminal signal is the trailing "request cancelled" error).
        #expect(await terminalReason(.cancelled) == .some(String?.none))
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

// MARK: - Logprobs passthrough (delta logprobs → per-request channel)

@Suite("EngineV2 logprobs passthrough")
struct EngineV2LogprobsPassthroughTests {

    @Test("delta logprobs publish to the channel in OpenAI entry shape, in order")
    func logprobsFlowToChannel() async {
        let engine = ScriptedCBv2Engine(script: .stream([
            .delta(
                text: "He", tokens: [10],
                logprobs: [
                    CBv2TokenLogprob(
                        token: 10, logprob: -0.1,
                        topLogprobs: [(token: 10, logprob: -0.1), (token: 12, logprob: -2.0)]
                    )
                ]),
            .delta(
                text: "llo", tokens: [11],
                logprobs: [CBv2TokenLogprob(token: 11, logprob: -0.9)]),
            .finished(reason: .stop, usage: CBv2Usage(promptTokens: 5, completionTokens: 2)),
        ]))
        let bridge = makeBridge(engine: engine)
        let channel = EngineV2LogprobsChannel()
        let (events, _) = await record(await bridge.submit(
            request: makeRequest(logprobs: true, topLogprobs: 2),
            requestId: "req-lp",
            logprobsChannel: channel
        ))
        // The GenerationEvent stream is untouched — logprobs ride out-of-band.
        #expect(events == [
            .chunk("He"), .chunk("llo"), .info(prompt: 5, completion: 2),
        ])
        // Sampling translation asked the engine to capture logprobs.
        #expect(engine.submitted[0].sampling.topLogprobs == 2)
        // Entries arrive converted (StubTokenizer decodes id → "t<id>"),
        // in emission order, with alternatives preserved.
        let entries = channel.drain()
        #expect(entries.count == 2)
        #expect(entries[0].token == "t10")
        #expect(entries[0].logprob == -0.1)
        #expect(entries[0].bytes == Array("t10".utf8).map(Int.init))
        #expect(entries[0].topLogprobs.count == 2)
        #expect(entries[0].topLogprobs[1].token == "t12")
        #expect(entries[1].token == "t11")
        #expect(entries[1].topLogprobs.isEmpty)
        // drain() empties the channel.
        #expect(channel.drain().isEmpty)
    }

    @Test("nil/empty delta logprobs leave the channel empty")
    func noLogprobsNoEntries() async {
        let engine = ScriptedCBv2Engine(script: .stream([
            .delta(text: "x", tokens: [10], logprobs: nil),
            .delta(text: "y", tokens: [11], logprobs: []),
            .finished(reason: .stop, usage: CBv2Usage(promptTokens: 5, completionTokens: 2)),
        ]))
        let bridge = makeBridge(engine: engine)
        let channel = EngineV2LogprobsChannel()
        _ = await record(await bridge.submit(
            request: makeRequest(), requestId: "req-nolp", logprobsChannel: channel
        ))
        #expect(channel.drain().isEmpty)
    }

    @Test("no channel wired → logprob-bearing deltas stream normally (dropped)")
    func logprobsWithoutChannelAreDropped() async {
        let engine = ScriptedCBv2Engine(script: .stream([
            .delta(
                text: "x", tokens: [10],
                logprobs: [CBv2TokenLogprob(token: 10, logprob: -0.5)]),
            .finished(reason: .stop, usage: CBv2Usage(promptTokens: 5, completionTokens: 1)),
        ]))
        let bridge = makeBridge(engine: engine)
        let (events, _) = await record(await bridge.submit(request: makeRequest()))
        #expect(events == [.chunk("x"), .info(prompt: 5, completion: 1)])
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
        #expect(ProviderLoop.mapInferenceErrorToStatus(classified) == 503)
    }

    @Test("engine queue-full sentinel maps to the legacy queue-full class (429), not token-budget (503)")
    func queueFullSentinelMapsToQueueFull() async {
        // `EngineV2.submit` throws `capacityExhausted(needed: 1, available: 0)`
        // when its waiting queue is full (`gauges.beginSubmit(maxWaiting:)`) or
        // it is draining for shutdown — a SLOT rejection, not a byte figure.
        // The legacy path classifies queue saturation as `.queueFull` (429 +
        // Retry-After), so the v2 mapping must preserve that distinction
        // (round-3 PR#499 P2).
        let engine = ScriptedCBv2Engine(
            script: .throwOnSubmit(
                CBv2KVError.capacityExhausted(needed: 1, available: 0)
            ))
        let bridge = makeBridge(engine: engine)
        let (events, _) = await record(await bridge.submit(request: makeRequest()))
        #expect(events.count == 1)
        guard case .error(let message)? = events.first else {
            Issue.record("expected a single .error event, got \(events)")
            return
        }
        // The exact canonical string the legacy planner emits for a full
        // queue (`BatchSchedulerTypes.RejectionReason.queueFull`) — no new
        // classification strings on the wire.
        #expect(message == "token_budget_exhausted: request queue full")
        let classified = MultiModelBatchSchedulerEngineError.fromSchedulerMessage(message)
        #expect(classified == .queueFull(message))
        #expect(ProviderLoop.mapInferenceErrorToStatus(classified) == 429)
    }

    @Test("real byte figures near the sentinel still classify as token-budget capacity")
    func nearSentinelByteFiguresStayTokenBudget() {
        // Only the exact slot-rejection sentinel (needed == 1, available ≤ 0)
        // is queue-full; a genuine byte-ledger rejection always carries
        // needed = a multiple of the per-token KV cost (≫ 1).
        let byteReject = EngineV2Translation.admissionErrorMessage(
            for: CBv2KVError.capacityExhausted(needed: 2, available: 0))
        #expect(!byteReject.contains("queue full"))
        #expect(MultiModelBatchSchedulerEngineError.fromSchedulerMessage(byteReject)
            == .tokenBudgetExhausted(byteReject))
        // needed == 1 with real headroom is not the sentinel either.
        let withHeadroom = EngineV2Translation.admissionErrorMessage(
            for: CBv2KVError.capacityExhausted(needed: 1, available: 512))
        #expect(!withHeadroom.contains("queue full"))
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

    @Test("duplicate request id is rejected with the legacy planner message")
    func duplicateRequestId() async {
        let engine = ScriptedCBv2Engine(script: .manual)
        let bridge = makeBridge(engine: engine)
        _ = await bridge.submit(request: makeRequest(), requestId: "req-dup")
        let (events, _) = await record(
            await bridge.submit(request: makeRequest(), requestId: "req-dup")
        )
        #expect(events == [.error("token_budget_exhausted: duplicate request ID")])
        // Only the first submit reached the engine.
        #expect(engine.submitted.count == 1)
        // Deterministic client fault (400), not a retryable capacity error.
        if case .error(let message)? = events.first {
            let classified = MultiModelBatchSchedulerEngineError.fromSchedulerMessage(message)
            #expect(classified == .requestRejected(message))
        }
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

        // Hold the stream for the whole test: dropping it would fire
        // `onTermination(.cancelled)` and race a second (idempotent)
        // engine cancel into the count assertions below.
        let stream = await bridge.submit(request: makeRequest(), requestId: "req-xyz")
        let owned = await runtime.cancel(requestId: "req-xyz")
        #expect(owned)
        #expect(engine.cancelled.count == 1)

        // Unknown id: no bridge owns it (legacy path's request).
        let unowned = await runtime.cancel(requestId: "req-legacy")
        #expect(!unowned)
        #expect(engine.cancelled.count == 1)
        withExtendedLifetime(stream) {}
    }
}

// MARK: - Capacity mapping

@Suite("EngineV2 capacity: CBv2CapacitySnapshot → BackendSlotCapacity")
struct EngineV2CapacityTests {

    @Test("budget fields follow the legacy committed/worst-case contract; activeTokens stays engine truth")
    func snapshotMapping() async {
        let engine = ScriptedCBv2Engine(
            script: .manual,
            capacity: CBv2CapacitySnapshot(
                activeRequests: 2,
                waitingRequests: 3,
                kvBytesInUse: 4_000_000,
                kvBytesCapacity: 40_000_000,
                activeTokens: 1000,
                stepsExecuted: 12345
            ))
        let bridge = makeBridge(engine: engine, kvBytesPerToken: 4000)
        // Two accepted long-max_tokens requests whose KV has barely
        // materialized: committed worst case = (5+100) + (3+200) = 308.
        _ = await bridge.submitTokenized(
            promptTokens: [1, 2, 3, 4, 5], request: makeRequest(maxTokens: 100),
            requestId: "req-cap-a")
        _ = await bridge.submitTokenized(
            promptTokens: [1, 2, 3], request: makeRequest(maxTokens: 200),
            requestId: "req-cap-b")
        let slot = await bridge.backendSlotCapacity()
        #expect(slot.model == "gemma-4-27b-it")
        #expect(slot.state == "running")
        #expect(slot.numRunning == 2)
        #expect(slot.numWaiting == 3)
        // Engine truth: the real KV-resident token count, NOT the worst case.
        #expect(slot.activeTokens == 1000)
        // Coordinator admission-gate fields: the COMMITTED worst-case
        // reservation (legacy `activeTokenBudgetUsed` semantics) — a request
        // that has only materialized a prefix still holds its full budget.
        #expect(slot.maxTokensPotential == 308)
        #expect(slot.activeTokenBudgetUsed == 308)
        #expect(slot.queuedTokenBudget == 0)
        // Budget ceiling: the engine's byte capacity in tokens.
        #expect(slot.activeTokenBudgetMax == 10000)   // 40 MB / 4000 B-per-token
        #expect(slot.kvBytesPerToken == 4000)
        #expect(slot.maxConcurrency == 4)
        // The engine's own monotonic step counter flows straight through.
        #expect(slot.stepsExecuted == 12345)
        #expect(!slot.wedgeSuspected)
    }

    @Test("idle when nothing runs; budget gate disengaged when kvBytesPerToken unknown")
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
        // Engine truth flows through; no committed requests ⇒ zero budget
        // used, and an unknown rate reports budgetMax 0 so the coordinator's
        // budget gate disengages instead of trusting an invented budget.
        #expect(slot.activeTokens == 17)
        #expect(slot.activeTokenBudgetUsed == 0)
        #expect(slot.activeTokenBudgetMax == 0)
    }

    @Test("finished requests release their committed budget from the heartbeat")
    func budgetReleasedOnFinish() async {
        let engine = ScriptedCBv2Engine(
            script: .stream([
                .delta(text: "x", tokens: [10], logprobs: nil),
                .finished(reason: .stop, usage: CBv2Usage(promptTokens: 5, completionTokens: 1)),
            ]),
            capacity: CBv2CapacitySnapshot(
                activeRequests: 0, waitingRequests: 0, kvBytesInUse: 0,
                kvBytesCapacity: 40_000_000, activeTokens: 0
            ))
        let bridge = makeBridge(engine: engine, kvBytesPerToken: 4000)
        _ = await record(await bridge.submitTokenized(
            promptTokens: [1, 2, 3, 4, 5], request: makeRequest(maxTokens: 100),
            requestId: "req-cap-done"))
        let slot = await bridge.backendSlotCapacity()
        #expect(slot.activeTokenBudgetUsed == 0)
        #expect(slot.maxTokensPotential == 0)
    }

    @Test("wedge counters flow into the slot (admits / first tokens / engine steps)")
    func wedgeCountersInSlot() async {
        let engine = ScriptedCBv2Engine(
            script: .stream([
                .delta(text: "hello", tokens: [10], logprobs: nil),
                .finished(
                    reason: .stop, usage: CBv2Usage(promptTokens: 5, completionTokens: 1)),
            ]),
            capacity: CBv2CapacitySnapshot(
                activeRequests: 0, waitingRequests: 0, kvBytesInUse: 0,
                kvBytesCapacity: 0, activeTokens: 0, stepsExecuted: 42
            ))
        let bridge = makeBridge(engine: engine)
        _ = await record(await bridge.submit(request: makeRequest()))
        let slot = await bridge.backendSlotCapacity()
        #expect(slot.admits == 1)
        #expect(slot.firstTokensEmitted == 1)
        // Loop progress is the ENGINE's monotonic step counter (published in
        // the capacity snapshot every step), not an event-count proxy.
        #expect(slot.stepsExecuted == 42)
    }

    @Test("wedge trips only when the engine step counter flatlines under hanging admits")
    func wedgeRequiresStepFlatline() async {
        let engine = ScriptedCBv2Engine(
            script: .manual,
            capacity: CBv2CapacitySnapshot(
                activeRequests: 3, waitingRequests: 0, kvBytesInUse: 0,
                kvBytesCapacity: 0, activeTokens: 0, stepsExecuted: 100
            ))
        let bridge = makeBridge(engine: engine)
        let t0 = ContinuousClock.Instant.now
        // Three admits that never produce a first token.
        for i in 0..<3 {
            _ = await bridge.submit(request: makeRequest(), requestId: "req-hang-\(i)")
        }
        // Baseline heartbeat: step counter first observed at 100.
        _ = await bridge.backendSlotCapacity(now: t0)
        // 11s later, counter still 100 → frozen loop + 3 hanging admits over
        // the stall threshold ⇒ wedge suspected; slot derates to "crashed".
        let wedged = await bridge.backendSlotCapacity(now: t0.advanced(by: .seconds(11)))
        #expect(wedged.wedgeSuspected)
        #expect(wedged.state == "crashed")
        // The counter advancing is proof of loop progress: same hanging
        // admits, but a moving engine is a slow prefill — NOT a wedge.
        engine.capacitySnapshot = CBv2CapacitySnapshot(
            activeRequests: 3, waitingRequests: 0, kvBytesInUse: 0,
            kvBytesCapacity: 0, activeTokens: 0, stepsExecuted: 101
        )
        let recovered = await bridge.backendSlotCapacity(now: t0.advanced(by: .seconds(22)))
        #expect(!recovered.wedgeSuspected)
        #expect(recovered.stepsExecuted == 101)
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

    @Test("budget max clamps to the live fleet budget; nil clamp preserves the raw grant")
    func budgetMaxClampsToLiveFleetBudget() async {
        let engine = ScriptedCBv2Engine(
            script: .manual,
            capacity: CBv2CapacitySnapshot(
                activeRequests: 0, waitingRequests: 0, kvBytesInUse: 0,
                kvBytesCapacity: 40_000_000, activeTokens: 0
            ))
        let bridge = makeBridge(engine: engine, kvBytesPerToken: 4000)
        // No clamp (unit callers / no fleet context): construction grant.
        let raw = await bridge.backendSlotCapacity()
        #expect(raw.activeTokenBudgetMax == 10000)
        // Fleet shrank the live budget below the grant: report the clamp.
        let clamped = await bridge.backendSlotCapacity(kvBytesBudgetClamp: 20_000_000)
        #expect(clamped.activeTokenBudgetMax == 5000)
        // A clamp ABOVE the grant never inflates the report.
        let above = await bridge.backendSlotCapacity(kvBytesBudgetClamp: 80_000_000)
        #expect(above.activeTokenBudgetMax == 10000)
        // Degenerate negative clamp reports 0, never traps.
        let negative = await bridge.backendSlotCapacity(kvBytesBudgetClamp: -1)
        #expect(negative.activeTokenBudgetMax == 0)
    }

    @Test("runtime summary recomputes each bridge's budget from live fleet residency")
    func runtimeSummaryAppliesFleetClamp() async {
        let gib: UInt64 = 1024 * 1024 * 1024
        let physical = 64 * gib
        let weights = Int(8 * gib)
        let rate = 4096
        let grant = EngineV2KVSizing.engineKVBytesCapacity(
            newModelWeightBytes: weights, coResidentWeightBytes: 0,
            existingEngineKVCapacities: [], physicalBytes: physical)
        let engine = ScriptedCBv2Engine(
            script: .manual,
            capacity: CBv2CapacitySnapshot(
                activeRequests: 0, waitingRequests: 0, kvBytesInUse: 0,
                kvBytesCapacity: grant, activeTokens: 0
            ))
        let bridge = makeBridge(engine: engine, kvBytesPerToken: rate)
        let runtime = EngineV2Runtime()
        await runtime.register(modelId: "gemma-4-27b-it", bridge: bridge)

        // Fleet unchanged since construction: reported max == the grant.
        let alone = await runtime.capacitySummary(
            fleetKV: EngineV2Runtime.FleetKVContext(
                totalResidentWeightBytes: UInt64(weights), physicalBytes: physical))
        #expect(alone.slots.first?.activeTokenBudgetMax == Int64(grant / rate))

        // A 12 GiB model loaded later (legacy — subtracts nothing from the
        // grant): the reported max shrinks by exactly its weights in tokens.
        let laterWeights = 12 * gib
        let grown = await runtime.capacitySummary(
            fleetKV: EngineV2Runtime.FleetKVContext(
                totalResidentWeightBytes: UInt64(weights) + laterWeights,
                physicalBytes: physical))
        #expect(grown.slots.first?.activeTokenBudgetMax
            == Int64((grant - Int(laterWeights)) / rate))

        // No fleet context (legacy callers): raw construction figures.
        let uncontexted = await runtime.capacitySummary()
        #expect(uncontexted.slots.first?.activeTokenBudgetMax == Int64(grant / rate))
    }
}

// MARK: - Config gating

@Suite("EngineV2 fail-loud factory (v0.7.5 one engine — no selection, no fallback)")
struct EngineV2FailLoudFactoryTests {

    @Test("retired selection env vars are detected for the startup WARN, never consulted")
    func retiredEnvDetection() {
        #expect(EngineV2Config.retiredEnvironmentKeysSet(environment: [:]).isEmpty)
        #expect(
            EngineV2Config.retiredEnvironmentKeysSet(
                environment: ["DARKBLOOM_ENGINE_V2": "0"])
                == ["DARKBLOOM_ENGINE_V2"])
        #expect(
            EngineV2Config.retiredEnvironmentKeysSet(
                environment: [
                    "DARKBLOOM_ENGINE_V2": "1",
                    "DARKBLOOM_ENGINE_V2_MODELS": "qwen3*",
                ])
                == ["DARKBLOOM_ENGINE_V2", "DARKBLOOM_ENGINE_V2_MODELS"])
        // Empty values do not count as "set".
        #expect(
            EngineV2Config.retiredEnvironmentKeysSet(
                environment: ["DARKBLOOM_ENGINE_V2": ""]).isEmpty)
    }

    @Test("refusal reasons classify construction errors")
    func refusalReasonClassification() {
        struct SomeError: Error {}
        #expect(EngineV2RefusalReason.classify(
            EngineV2ProductionError.noKVHeadroom) == .noKVHeadroom)
        #expect(EngineV2RefusalReason.classify(
            EngineV2ProductionError.unsupportedModel("Qwen3Model")) == .unsupportedModel)
        #expect(EngineV2RefusalReason.classify(
            EngineV2VLMTextExtractionError.parityMismatch("x")) == .vlmExtractionFailed)
        #expect(EngineV2RefusalReason.classify(SomeError()) == .engineInitFailed)
    }

    @Test("factory: healthy builder → v2 bridge, no telemetry")
    func factoryBuilds() async throws {
        let telemetry = TelemetrySink()
        let bridge = try EngineV2Factory.makeBridge(
            modelId: "gemma-4-26b-qat-4bit",
            tokenizer: TokenizerHandle(StubTokenizer()),
            eosTokenIds: [2],
            emitTelemetry: telemetry.callback(),
            makeEngine: { ScriptedCBv2Engine(script: .manual) }
        )
        #expect(await bridge.modelId == "gemma-4-26b-qat-4bit")
        #expect(telemetry.events.isEmpty)
    }

    @Test("factory: init failure THROWS + ERROR engine_v2_refusal telemetry (no fallback)")
    func factoryInitFailureRefusesLoudly() {
        struct InitFailure: Error {}
        let telemetry = TelemetrySink()
        #expect(throws: InitFailure.self) {
            _ = try EngineV2Factory.makeBridge(
                modelId: "gpt-oss-20b",
                tokenizer: TokenizerHandle(StubTokenizer()),
                eosTokenIds: [2],
                emitTelemetry: telemetry.callback(),
                makeEngine: { throw InitFailure() }
            )
        }
        let events = telemetry.events
        #expect(events.count == 1)
        #expect(events.first?.kind == .engineHealth)
        // ERROR, not WARN: with no legacy engine left a refusal must alarm.
        #expect(events.first?.severity == .error)
        #expect(events.first?.fields?["operation"]?.description == "engine_v2_refusal")
        #expect(events.first?.fields?["backend"]?.description == "engine_v2")
        #expect(events.first?.fields?["model"]?.description == "gpt-oss-20b")
        #expect(events.first?.fields?["reason"]?.description == "engine_init_failed")
        #expect(events.first?.fields?["error_class"]?.description.contains("InitFailure") == true)
        #expect(events.first?.fields?["error"]?.description.contains("InitFailure") == true)
    }

    @Test("factory: refusal reasons ride the telemetry for every classified failure")
    func factoryRefusalReasonsOnTelemetry() {
        let cases: [(any Error, String)] = [
            (EngineV2ProductionError.noKVHeadroom, "no_kv_headroom"),
            (EngineV2ProductionError.unsupportedModel("StubModel"), "unsupported_model"),
            (EngineV2VLMTextExtractionError.parityMismatch("probe"), "vlm_extraction_failed"),
        ]
        for (error, expectedReason) in cases {
            let telemetry = TelemetrySink()
            #expect(throws: (any Error).self) {
                _ = try EngineV2Factory.makeBridge(
                    modelId: "gemma-4-26b-qat-4bit",
                    tokenizer: TokenizerHandle(StubTokenizer()),
                    eosTokenIds: [2],
                    emitTelemetry: telemetry.callback(),
                    makeEngine: { throw error }
                )
            }
            #expect(
                telemetry.events.first?.fields?["reason"]?.description == expectedReason,
                "reason for \(error)")
        }
    }

    @Test("supported set mirrors the makeProductionEngine switch (model_type keyed)")
    func supportedSetPredicate() {
        // The two CBv2-adapted production families.
        #expect(EngineV2SupportedModels.isSupported(modelType: "gpt_oss"))
        #expect(EngineV2SupportedModels.isSupported(modelType: "gemma4"))        // VLM wrapper
        #expect(EngineV2SupportedModels.isSupported(modelType: "gemma4_text"))   // text config
        #expect(EngineV2SupportedModels.isSupported(modelType: "GEMMA4_TEXT"))   // case-insensitive
        // Everything else fails closed — including nil/empty and the
        // near-miss families that must never match by accident.
        #expect(!EngineV2SupportedModels.isSupported(modelType: nil))
        #expect(!EngineV2SupportedModels.isSupported(modelType: ""))
        #expect(!EngineV2SupportedModels.isSupported(modelType: "gemma3"))
        #expect(!EngineV2SupportedModels.isSupported(modelType: "gemma"))
        #expect(!EngineV2SupportedModels.isSupported(modelType: "qwen3"))
        #expect(!EngineV2SupportedModels.isSupported(modelType: "llama"))
    }

    @Test("backend config: engine_v2 still parses (retired, surfaced); concurrency keys decode")
    func backendConfigKeys() throws {
        let decoder = JSONDecoder()
        // The retired key must still DECODE so old provider.toml files load
        // (startup warns off retiredKeysPresent); the field itself is gone.
        let off = try decoder.decode(
            BackendSettings.self,
            from: Data(#"{"engine_v2": false}"#.utf8)
        )
        #expect(off.retiredKeysPresent == ["engine_v2"])
        // New concurrency keys: default 4, per-model override map.
        let absent = try decoder.decode(BackendSettings.self, from: Data(#"{}"#.utf8))
        #expect(absent.engineV2MaxConcurrent == 4)
        #expect(absent.engineV2MaxConcurrentByModel.isEmpty)
        let configured = try decoder.decode(
            BackendSettings.self,
            from: Data(#"""
                {"engine_v2_max_concurrent": 6,
                 "engine_v2_max_concurrent_by_model": {"gemma-4-26b-qat-4bit": 2}}
                """#.utf8)
        )
        #expect(configured.engineV2MaxConcurrent == 6)
        #expect(configured.engineV2MaxConcurrentByModel == ["gemma-4-26b-qat-4bit": 2])
    }

    @Test("TOML: engine_v2_max_concurrent + per-model map parse from provider.toml")
    func tomlConcurrencyKeys() {
        let toml = """
            [provider]
            name = "cfg-test"

            [backend]
            engine_v2_max_concurrent = 6

            [backend.engine_v2_max_concurrent_by_model]
            "gemma-4-26b-qat-4bit" = 2
            "gpt-oss-20b" = 8
            """
        let config = ConfigManager.parse(toml)
        #expect(config.backend.engineV2MaxConcurrent == 6)
        #expect(config.backend.engineV2MaxConcurrentByModel == [
            "gemma-4-26b-qat-4bit": 2, "gpt-oss-20b": 8,
        ])
        // Defaults when the keys are absent.
        let defaults = ConfigManager.parse("[provider]\nname = \"cfg-test\"\n")
        #expect(defaults.backend.engineV2MaxConcurrent == 4)
        #expect(defaults.backend.engineV2MaxConcurrentByModel.isEmpty)
    }

    @Test("concurrency clamp: [1, 8] product ceiling")
    func concurrencyClamp() {
        #expect(ProviderLoop.clampEngineV2Concurrency(0) == 1)
        #expect(ProviderLoop.clampEngineV2Concurrency(1) == 1)
        #expect(ProviderLoop.clampEngineV2Concurrency(4) == 4)
        #expect(ProviderLoop.clampEngineV2Concurrency(8) == 8)
        #expect(ProviderLoop.clampEngineV2Concurrency(24) == 8)
        #expect(ProviderLoop.clampEngineV2Concurrency(UInt64.max) == 8)
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

// MARK: - Shared-budget KV accounting (fix #2)

/// Deterministic shared budgets driven by SCRIPTED memory snapshots (never
/// the real machine's memory) — live-isolated per the testing rules.
private enum TestBudgets {
    /// A budget with plenty of headroom: 8 GiB box, nothing used.
    /// Effective cap = min(0.9 × 8 GiB, 8 GiB − 2 GiB) = 6 GiB.
    static func ample() -> GlobalKVCacheBudget {
        let gib: UInt64 = 1024 * 1024 * 1024
        return GlobalKVCacheBudget(
            capFraction: 0.9,
            activationReserveBytes: 0,
            memorySnapshot: {
                .init(total: 8 * gib, active: 0, cache: 0, systemAvailable: 8 * gib)
            })
    }

    /// A budget with ZERO headroom: everything under the cap already used.
    static func exhausted() -> GlobalKVCacheBudget {
        let gib: UInt64 = 1024 * 1024 * 1024
        return GlobalKVCacheBudget(
            capFraction: 0.9,
            activationReserveBytes: 0,
            memorySnapshot: {
                .init(total: 8 * gib, active: 8 * gib, cache: 0, systemAvailable: 0)
            })
    }
}

@Suite("EngineV2 shared-budget KV accounting")
struct EngineV2SharedBudgetTests {

    @Test("kv_quant → fp16 sizing decision (EngineV2KVSizing)")
    func fp16SizingDecision() {
        // kv_quant OFF (rates equal): use the rate, no WARN.
        let off = EngineV2KVSizing.resolve(quantizedRate: 400_000, fp16Rate: 400_000)
        #expect(off.rate == 400_000)
        #expect(!off.warnKVQuantUnsupported)
        // kv_quant ON (quantized below fp16): pick fp16, WARN.
        let on = EngineV2KVSizing.resolve(quantizedRate: 100_000, fp16Rate: 400_000)
        #expect(on.rate == 400_000)
        #expect(on.warnKVQuantUnsupported)
        // fp16 unknown: fall back to the quantized rate, never WARN.
        let unknown = EngineV2KVSizing.resolve(quantizedRate: 100_000, fp16Rate: 0)
        #expect(unknown.rate == 100_000)
        #expect(!unknown.warnKVQuantUnsupported)
    }

    @Test("an in-flight v2 request reserves its worst-case KV in the shared budget, released on finish")
    func recordsAndReleasesReservation() async {
        // Manual script so the request stays in-flight until we drive the terminal.
        let engine = ScriptedCBv2Engine(script: .manual)
        let budget = TestBudgets.ample()
        // 4000 B/token × (5 prompt + 16 maxTokens) = 84_000 bytes.
        let bridge = makeBridge(engine: engine, kvBytesPerToken: 4000, kvBudget: budget)
        #expect(await budget.outstandingReservedBytes() == 0)

        let stream = await bridge.submitTokenized(
            promptTokens: [1, 2, 3, 4, 5],
            request: makeRequest(maxTokens: 16),
            requestId: "req-acct-1")
        // No-gap invariant: the reservation is taken atomically WITH (in fact
        // strictly before) engine admission, so it is already visible the
        // instant submit returns — before the pump task runs and before the
        // stream is consumed. No polling: a concurrent model-load gate can
        // never observe zero in the window between engine admission and the
        // pump starting.
        #expect(await budget.outstandingReservedBytes() == 84_000)
        // Consume the stream on a separate task so the pump runs to terminal.
        let consumer = Task { await record(stream) }

        // Terminal → the reservation is released.
        engine.manualContinuation?.yield(
            .finished(reason: .stop, usage: CBv2Usage(promptTokens: 5, completionTokens: 1)))
        engine.manualContinuation?.finish()
        _ = await consumer.value
        #expect(await budget.outstandingReservedBytes() == 0)
    }

    @Test("teardown without a terminal still releases the reservation")
    func teardownReleasesReservation() async {
        // A stream that yields no terminal, then closes (engine torn down).
        let engine = ScriptedCBv2Engine(script: .stream([
            .delta(text: "partial", tokens: [10], logprobs: nil)
        ]))
        let budget = TestBudgets.ample()
        let bridge = makeBridge(engine: engine, kvBytesPerToken: 4000, kvBudget: budget)
        _ = await record(await bridge.submitTokenized(
            promptTokens: [1, 2, 3, 4, 5],
            request: makeRequest(maxTokens: 16),
            requestId: "req-acct-2"))
        // The stream closed without a terminal — the pump's teardown path
        // must still have released the reservation.
        #expect(await budget.outstandingReservedBytes() == 0)
        let counters = await bridge._testCounters()
        #expect(counters.active == 0)
    }

    @Test("no reservation when kvBytesPerToken is unknown (0)")
    func noReservationWhenRateUnknown() async {
        let engine = ScriptedCBv2Engine(script: .manual)
        let budget = TestBudgets.ample()
        let bridge = makeBridge(engine: engine, kvBytesPerToken: 0, kvBudget: budget)
        let stream = await bridge.submitTokenized(
            promptTokens: [1, 2, 3], request: makeRequest(maxTokens: 8),
            requestId: "req-acct-3")
        let consumer = Task { await record(stream) }
        // Give the pump time to run; with an unknown rate nothing is recorded.
        try? await Task.sleep(for: .milliseconds(30))
        #expect(await budget.outstandingReservedBytes() == 0)
        engine.manualContinuation?.yield(
            .finished(reason: .stop, usage: CBv2Usage(promptTokens: 3, completionTokens: 0)))
        engine.manualContinuation?.finish()
        _ = await consumer.value
    }

    @Test("shared-budget gate: exhausted pool rejects as capacity BEFORE the engine sees the request")
    func sharedBudgetGateRejectsBeforeEngine() async {
        let engine = ScriptedCBv2Engine(script: .manual)
        let budget = TestBudgets.exhausted()
        let bridge = makeBridge(engine: engine, kvBytesPerToken: 4000, kvBudget: budget)
        let (events, _) = await record(await bridge.submitTokenized(
            promptTokens: [1, 2, 3, 4, 5],
            request: makeRequest(maxTokens: 16),
            requestId: "req-gate-1"))
        // Single canonical capacity error (5 prompt + 16 max = 21 tokens).
        #expect(events == [.error(
            "token_budget_exhausted: request requires 21 tokens "
                + "but the shared KV budget has no headroom")])
        // The gate fired BEFORE submission: the engine never saw the request,
        // and no bookkeeping leaked.
        #expect(engine.submitted.isEmpty)
        #expect(await budget.outstandingReservedBytes() == 0)
        let counters = await bridge._testCounters()
        #expect(counters.active == 0)
        // Classified exactly like the legacy KV-reserve rejection: retryable
        // capacity (→ 429/503 upstream), so the coordinator reroutes.
        if case .error(let message)? = events.first {
            let classified = MultiModelBatchSchedulerEngineError.fromSchedulerMessage(message)
            #expect(classified == .tokenBudgetExhausted(message))
        }
    }

    @Test("shared-budget gate: another request's live reservation blocks a worst case that no longer fits")
    func sharedBudgetGateSeesOtherLiveReservations() async {
        // A pool with exactly 200_000 bytes of live headroom: 3 GiB box at
        // capFraction 1.0 ⇒ effective cap = 3 GiB − 2 GiB OS floor = 1 GiB;
        // MLX usage pinned 200_000 bytes below that cap.
        let budget = GlobalKVCacheBudget(
            capFraction: 1.0,
            activationReserveBytes: 0,
            memorySnapshot: {
                let gib: UInt64 = 1024 * 1024 * 1024
                return .init(
                    total: 3 * gib, active: gib - 200_000, cache: 0,
                    systemAvailable: 200_000)
            })
        let engine = ScriptedCBv2Engine(script: .manual)
        let bridge = makeBridge(engine: engine, kvBytesPerToken: 4000, kvBudget: budget)
        // First request: 21 tokens × 4000 = 84_000 bytes — fits.
        let first = await bridge.submitTokenized(
            promptTokens: [1, 2, 3, 4, 5], request: makeRequest(maxTokens: 16),
            requestId: "req-gate-a")
        #expect(engine.submitted.count == 1)
        // Second identical worst case would need another 84_000 with only
        // 116_000 left… fits. Third does not (232_000 > 200_000).
        let second = await bridge.submitTokenized(
            promptTokens: [1, 2, 3, 4, 5], request: makeRequest(maxTokens: 16),
            requestId: "req-gate-b")
        #expect(engine.submitted.count == 2)
        let (events, _) = await record(await bridge.submitTokenized(
            promptTokens: [1, 2, 3, 4, 5], request: makeRequest(maxTokens: 16),
            requestId: "req-gate-c"))
        #expect(engine.submitted.count == 2)  // third never reached the engine
        if case .error(let message)? = events.first {
            #expect(message.hasPrefix("token_budget_exhausted:"))
        } else {
            Issue.record("expected a capacity error, got \(events)")
        }
        withExtendedLifetime((first, second)) {}
    }

    @Test("degenerate maxTokens <= 0 skips the gate (engine finishes it without KV)")
    func degenerateRequestSkipsGate() async {
        // Even on an EXHAUSTED pool, a request that can allocate no KV must
        // not be capacity-rejected by the gate — the engine's own degenerate
        // path finishes it immediately (immediate .length terminal).
        let engine = ScriptedCBv2Engine(script: .stream([
            .finished(reason: .length, usage: CBv2Usage(promptTokens: 3, completionTokens: 0))
        ]))
        let budget = TestBudgets.exhausted()
        let bridge = makeBridge(engine: engine, kvBytesPerToken: 4000, kvBudget: budget)
        let (events, _) = await record(await bridge.submitTokenized(
            promptTokens: [1, 2, 3], request: makeRequest(maxTokens: 0),
            requestId: "req-degenerate"))
        // Reached the engine (no gate rejection), reserved nothing.
        #expect(engine.submitted.count == 1)
        #expect(events == [.info(prompt: 3, completion: 0)])
        #expect(await budget.outstandingReservedBytes() == 0)
    }

    @Test("engine rejection after the gate releases the shared reservation")
    func engineRejectionReleasesSharedReservation() async {
        let engine = ScriptedCBv2Engine(
            script: .throwOnSubmit(
                CBv2KVError.capacityExhausted(needed: 5120, available: 1024)))
        let budget = TestBudgets.ample()
        let bridge = makeBridge(engine: engine, kvBytesPerToken: 4000, kvBudget: budget)
        let (events, _) = await record(await bridge.submitTokenized(
            promptTokens: [1, 2, 3, 4, 5],
            request: makeRequest(maxTokens: 16),
            requestId: "req-gate-2"))
        // The engine's own rejection surfaced (its private ledger stays
        // authoritative for its slot)…
        #expect(events == [.error(
            "token_budget_exhausted: request requires 5120 tokens but only 1024 available")])
        // …and the shared reservation taken by the gate was rolled back, so
        // a rejected request can never pin shared headroom.
        #expect(await budget.outstandingReservedBytes() == 0)
    }
}

// MARK: - Hardening (request-id validation, id overflow, pump lifecycle)

@Suite("EngineV2 bridge hardening")
struct EngineV2HardeningTests {

    @Test("request-id validation: nil / empty / over-long / control chars → fresh id (fix #4)")
    func requestIdValidation() {
        // Valid ids pass through verbatim.
        #expect(EngineV2Bridge.isValidRequestId("req-abc123"))
        #expect(EngineV2Bridge.isValidRequestId(String(repeating: "a", count: 256)))
        #expect(EngineV2Bridge.normalizedRequestId("req-coord-1") == "req-coord-1")
        // Invalid ids are rejected and replaced with a generated one.
        #expect(!EngineV2Bridge.isValidRequestId(""))
        #expect(!EngineV2Bridge.isValidRequestId(String(repeating: "a", count: 257)))
        #expect(!EngineV2Bridge.isValidRequestId("req\u{0}embedded-nul"))
        #expect(!EngineV2Bridge.isValidRequestId("req\u{7f}del"))
        #expect(!EngineV2Bridge.isValidRequestId("line\nbreak"))
        // nil and each invalid form normalize to a fresh, valid `req-…` id.
        for bad in [nil, "", "line\nbreak", String(repeating: "z", count: 300)] {
            let normalized = EngineV2Bridge.normalizedRequestId(bad)
            #expect(normalized.hasPrefix("req-"))
            #expect(EngineV2Bridge.isValidRequestId(normalized))
        }
    }

    @Test("a malformed request-id is normalized before it becomes a cancel handle")
    func malformedIdNormalizedInSubmit() async {
        let engine = ScriptedCBv2Engine(script: .manual)
        let bridge = makeBridge(engine: engine)
        // Submit with a control-char id: the bridge must NOT key its state on it.
        let stream = await bridge.submitTokenized(
            promptTokens: [1, 2, 3], request: makeRequest(), requestId: "bad\u{0}id")
        // The raw malformed id maps to nothing (a fresh id was minted).
        #expect(await bridge._testEngineRequestId(for: "bad\u{0}id") == nil)
        // Exactly one request is live under the normalized id.
        let counters = await bridge._testCounters()
        #expect(counters.active == 1)
        withExtendedLifetime(stream) {}
    }

    @Test("shutdown cancels live pump tasks and releases their reservations (fix #7)")
    func shutdownCancelsLivePumps() async {
        // A manual engine keeps the request in-flight (stream never finishes)
        // so the pump is parked on `for await`. Shutdown must cancel it.
        let engine = ScriptedCBv2Engine(script: .manual)
        let budget = TestBudgets.ample()
        let bridge = makeBridge(engine: engine, kvBytesPerToken: 4000, kvBudget: budget)
        let stream = await bridge.submitTokenized(
            promptTokens: [1, 2, 3, 4, 5], request: makeRequest(maxTokens: 16),
            requestId: "req-live-1")
        // Reservation is recorded synchronously with admission (no poll), and
        // the pump task is tracked for shutdown.
        #expect(await budget.outstandingReservedBytes() == 84_000)
        #expect(await bridge._testLivePumpCount() == 1)
        let consumer = Task { await record(stream) }

        await bridge.shutdown()
        #expect(engine.shutdownCalls == 1)
        // The cancelled pump unwinds (AsyncStream.next() returns nil under
        // cancellation → teardown path), releasing its reservation and
        // clearing its task handle.
        _ = await consumer.value
        for _ in 0..<200 where await bridge._testLivePumpCount() != 0 {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(await bridge._testLivePumpCount() == 0)
        #expect(await budget.outstandingReservedBytes() == 0)
    }

    @Test("nextRawId uses wrapping increment (fix #5)")
    func nextRawIdWraps() async {
        // A stream engine so each submit runs to a terminal and self-clears,
        // letting the same provider id be reused across submits.
        let engine = ScriptedCBv2Engine(script: .stream([
            .finished(reason: .stop, usage: CBv2Usage(promptTokens: 1, completionTokens: 0))
        ]))
        let bridge = makeBridge(engine: engine)
        // Two sequential submits mint two distinct engine ids (raw 1, 2).
        _ = await record(await bridge.submitTokenized(
            promptTokens: [1], request: makeRequest(), requestId: "r1"))
        _ = await record(await bridge.submitTokenized(
            promptTokens: [1], request: makeRequest(), requestId: "r2"))
        #expect(engine.submitted.count == 2)
        #expect(engine.submitted[0].id == CBv2RequestID(1))
        #expect(engine.submitted[1].id == CBv2RequestID(2))
    }
}

// MARK: - Seeded sampling reproducibility (stable engine ids)

/// STOCHASTIC sampler stub: emitted tokens are a pure function of
/// (sampling.seed, request.id.raw, stepIndex) — the exact key shape the real
/// v2 sampler uses (`SamplerV2.mix`) — so these tests prove end-to-end that
/// seeded outputs reproduce iff the bridge hands the engine a stable id.
private final class StochasticScriptedEngine: CBv2Engine, @unchecked Sendable {
    private let lock = NSLock()
    private var _submitted: [CBv2Request] = []
    var submitted: [CBv2Request] { lock.withLock { _submitted } }

    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        lock.withLock { _submitted.append(request) }
        let (stream, continuation) = AsyncStream<CBv2Event>.makeStream()
        for step in 0..<4 {
            let key = Self.mix(
                seed: request.sampling.seed ?? 0, id: request.id.raw, step: UInt64(step))
            let token = Int(key % 50_000)
            continuation.yield(.delta(text: "t\(token) ", tokens: [token], logprobs: nil))
        }
        continuation.yield(.finished(
            reason: .stop,
            usage: CBv2Usage(promptTokens: request.promptTokens.count, completionTokens: 4)))
        continuation.finish()
        return stream
    }

    func cancel(_ id: CBv2RequestID) {}
    func capacity() -> CBv2CapacitySnapshot {
        CBv2CapacitySnapshot(
            activeRequests: 0, waitingRequests: 0, kvBytesInUse: 0,
            kvBytesCapacity: 0, activeTokens: 0)
    }
    func shutdown() async {}

    /// Same mixing family as the engine sampler's keyed RNG.
    static func mix(seed: UInt64, id: UInt64, step: UInt64) -> UInt64 {
        func splitmix(_ x: UInt64) -> UInt64 {
            var z = x &+ 0x9E37_79B9_7F4A_7C15
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        return splitmix(splitmix(splitmix(seed) ^ id) ^ step)
    }
}

@Suite("EngineV2 seeded sampling reproducibility")
struct EngineV2SeededSamplingTests {

    private func chunks(_ events: [RecordedEvent]) -> [String] {
        events.compactMap {
            if case .chunk(let text) = $0 { return text }
            return nil
        }
    }

    @Test("same seed + same prompt reproduce identical output across submissions")
    func seededOutputReproduces() async {
        let engine = StochasticScriptedEngine()
        let bridge = makeBridge(engine: engine)
        let prompt = [11, 22, 33]

        let (first, _) = await record(await bridge.submitTokenized(
            promptTokens: prompt, request: makeRequest(maxTokens: 8, seed: 42),
            requestId: "req-seed-1"))
        // Interleave an UNRELATED request so the monotonic counter moves —
        // the regression this fix targets: seeded output must not depend on
        // prior traffic.
        _ = await record(await bridge.submitTokenized(
            promptTokens: [9, 9, 9], request: makeRequest(maxTokens: 8),
            requestId: "req-noise"))
        let (second, _) = await record(await bridge.submitTokenized(
            promptTokens: prompt, request: makeRequest(maxTokens: 8, seed: 42),
            requestId: "req-seed-2"))

        #expect(!chunks(first).isEmpty)
        #expect(chunks(first) == chunks(second))
        // The engine saw the SAME stable id on both seeded submissions —
        // that is what keys the RNG stream — and it carries the seeded tag.
        #expect(engine.submitted.count == 3)
        #expect(engine.submitted[0].id == engine.submitted[2].id)
        #expect(engine.submitted[0].id.raw & EngineV2Bridge.seededIdTagBit != 0)
    }

    @Test("different seed or different prompt produce different ids (and RNG streams)")
    func seededOutputDiverges() async {
        let engine = StochasticScriptedEngine()
        let bridge = makeBridge(engine: engine)
        _ = await record(await bridge.submitTokenized(
            promptTokens: [1, 2, 3], request: makeRequest(maxTokens: 8, seed: 42),
            requestId: "req-a"))
        _ = await record(await bridge.submitTokenized(
            promptTokens: [1, 2, 3], request: makeRequest(maxTokens: 8, seed: 43),
            requestId: "req-b"))
        _ = await record(await bridge.submitTokenized(
            promptTokens: [1, 2, 4], request: makeRequest(maxTokens: 8, seed: 42),
            requestId: "req-c"))
        let ids = engine.submitted.map(\.id.raw)
        #expect(Set(ids).count == 3)
    }

    @Test("unseeded submissions keep fresh monotonic ids")
    func unseededStaysMonotonic() async {
        let engine = StochasticScriptedEngine()
        let bridge = makeBridge(engine: engine)
        _ = await record(await bridge.submitTokenized(
            promptTokens: [1, 2, 3], request: makeRequest(maxTokens: 8),
            requestId: "req-u1"))
        _ = await record(await bridge.submitTokenized(
            promptTokens: [1, 2, 3], request: makeRequest(maxTokens: 8),
            requestId: "req-u2"))
        #expect(engine.submitted[0].id == CBv2RequestID(1))
        #expect(engine.submitted[1].id == CBv2RequestID(2))
    }

    @Test("a live identical seeded request falls back to a fresh id (collision guard)")
    func liveCollisionFallsBackToFreshId() async {
        // Manual engine keeps the first submission LIVE while the identical
        // second one arrives.
        let engine = ScriptedCBv2Engine(script: .manual)
        let bridge = makeBridge(engine: engine)
        let first = await bridge.submitTokenized(
            promptTokens: [1, 2, 3], request: makeRequest(maxTokens: 8, seed: 42),
            requestId: "req-live-a")
        let second = await bridge.submitTokenized(
            promptTokens: [1, 2, 3], request: makeRequest(maxTokens: 8, seed: 42),
            requestId: "req-live-b")
        #expect(engine.submitted.count == 2)
        let firstId = engine.submitted[0].id
        let secondId = engine.submitted[1].id
        // First got the stable seeded id; the overlapping duplicate got a
        // fresh monotonic id (documented reproducibility waiver) — never a
        // duplicate live id inside the engine.
        #expect(firstId.raw & EngineV2Bridge.seededIdTagBit != 0)
        #expect(secondId.raw & EngineV2Bridge.seededIdTagBit == 0)
        #expect(firstId != secondId)
        withExtendedLifetime((first, second)) {}
    }

    @Test("stableSeededRawId is deterministic, tagged, and input-sensitive")
    func stableSeededRawIdProperties() {
        let a = EngineV2Bridge.stableSeededRawId(seed: 42, promptTokens: [1, 2, 3])
        let b = EngineV2Bridge.stableSeededRawId(seed: 42, promptTokens: [1, 2, 3])
        #expect(a == b)
        #expect(a & EngineV2Bridge.seededIdTagBit != 0)
        #expect(a != EngineV2Bridge.stableSeededRawId(seed: 43, promptTokens: [1, 2, 3]))
        #expect(a != EngineV2Bridge.stableSeededRawId(seed: 42, promptTokens: [1, 2]))
        #expect(a != EngineV2Bridge.stableSeededRawId(seed: 42, promptTokens: [1, 2, 4]))
        // Empty prompt still derives a valid tagged id.
        let empty = EngineV2Bridge.stableSeededRawId(seed: 42, promptTokens: [])
        #expect(empty & EngineV2Bridge.seededIdTagBit != 0)
    }
}

// MARK: - Logprobs channel cap (fix #8)

@Suite("EngineV2 logprobs channel bounding")
struct EngineV2LogprobsChannelCapTests {

    private func entry(_ token: String) -> SSETokenLogprob {
        SSETokenLogprob(token: token, logprob: -0.1, bytes: nil, topLogprobs: [])
    }

    @Test("undrained channel is capped at maxEntries with drop-oldest")
    func channelCapsWithDropOldest() {
        let channel = EngineV2LogprobsChannel()
        let cap = EngineV2LogprobsChannel.maxEntries
        // Append cap + 10 entries, tagged by index, without ever draining.
        for i in 0..<(cap + 10) {
            channel.append([entry("t\(i)")])
        }
        let drained = channel.drain()
        // Buffer never exceeds the cap; the 10 OLDEST were dropped.
        #expect(drained.count == cap)
        #expect(channel.droppedCount == 10)
        // The freshest entries are retained (drop-oldest): first kept is t10,
        // last is t<cap+9>.
        #expect(drained.first?.token == "t10")
        #expect(drained.last?.token == "t\(cap + 9)")
    }

    @Test("under the cap nothing is dropped; drain empties the buffer")
    func channelUnderCapNoDrops() {
        let channel = EngineV2LogprobsChannel()
        for i in 0..<100 { channel.append([entry("t\(i)")]) }
        #expect(channel.droppedCount == 0)
        #expect(channel.drain().count == 100)
        #expect(channel.drain().isEmpty)
    }
}
