// Copyright © 2026 Eigen Labs.
//
// EngineV2Bridge — adapts the ContinuousBatchingV2 engine (`CBv2Engine`,
// frozen contract in libs/mlx-swift-lm `Libraries/MLXLMCommon/
// ContinuousBatchingV2/CBv2Contracts.swift`) to the provider's existing
// engine surface: the same `AsyncStream<GenerationEvent>` shape
// (`.chunk` / `.info` / `.error`) that `BatchScheduler` produces and that
// `MultiModelBatchSchedulerEngine` / `ProviderLoop` / `StandaloneServer`
// consume. Downstream SSE framing, error→status mapping
// (`MultiModelBatchSchedulerEngineError.fromSchedulerMessage` → 429/503),
// billing extraction, and cancellation therefore work unchanged.
//
// Strictly additive: nothing constructs this type unless
// `EngineV2Factory.makeBridgeIfSelected` picked the v2 engine (env
// `DARKBLOOM_ENGINE_V2=1` / config `engine_v2` + per-model allowlist —
// see `EngineV2Config.swift`). Flag off ⇒ this file is dead code and the
// legacy path is byte-identical.
//
// Companion files:
//   * `EngineV2Bridge+Translation.swift` — pure ChatRequest → CBv2Request
//     translation (sampling params, logit_bias parsing, stop resolution
//     with `buildStopTokenIds` semantics, error-message mapping).
//   * `EngineV2Bridge+Capacity.swift`    — CBv2CapacitySnapshot → heartbeat
//     `BackendSlotCapacity` mapping + the `engine_v2.step_wedge` signal.
//   * `EngineV2Runtime.swift`            — process-wide bridge registry the
//     ProviderLoop capacity/cancellation hooks fan out through.
//   * `EngineV2Config.swift`             — flag/allowlist selection + the
//     safe-fallback factory.

import Foundation
import MLXLMCommon
import ProviderCoreFoundation

/// `CBv2Engine` is not declared `Sendable` in the frozen contract, but its
/// whole API surface (submit/cancel/capacity/shutdown) is the engine's
/// cross-actor entry point (the engine serializes internally on its own
/// step loop). Box it — and funnel ALL engine access through the box's
/// wrappers — so the bridge actor can hold and use it under Swift 6 strict
/// concurrency. Recorded in docs/engine-v2/CONTRACT-ISSUES-H-provider.md.
struct EngineV2EngineBox: @unchecked Sendable {
    let engine: any CBv2Engine

    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        try engine.submit(request)
    }

    func cancel(_ id: CBv2RequestID) {
        engine.cancel(id)
    }

    func capacity() -> CBv2CapacitySnapshot {
        engine.capacity()
    }

    func shutdown() async {
        await engine.shutdown()
    }
}

/// Bridges one `CBv2Engine` (one loaded model) to the provider's
/// `GenerationEvent` streaming surface.
///
/// Event framing intentionally mirrors `BatchScheduler+EngineBridge`
/// exactly (fixture-pinned in `EngineV2BridgeTests`):
///   * text deltas       → `.chunk(text)` (empty deltas suppressed)
///   * finish stop/length→ `.info(prompt, completion, tps)` then finish
///   * cancelled         → `.info(usage)` if any tokens were produced,
///                         then `.error("request cancelled")`
///   * engine error      → `.error(message)` (no `.info` — matches legacy)
///   * admission failure → single `.error("token_budget_exhausted: …")`
///   * stream torn down  → `.error("request stream closed by engine teardown")`
public actor EngineV2Bridge {

    // MARK: - Immutable configuration

    let engineBox: EngineV2EngineBox
    public let modelId: String
    let tokenizer: TokenizerHandle
    /// Resolved stop-token set (model EOS ∪ tokenizer EOS ∪ extra EOS
    /// tokens) — `buildStopTokenIds` semantics, computed ONCE at bridge
    /// construction so B=1 and batched behavior stay identical.
    let stopTokenIds: Set<Int>
    let defaultMaxTokens: Int
    let maxConcurrentRequests: Int
    /// Per-token KV byte cost for bytes→tokens capacity derivation
    /// (0 = unknown; capacity then falls back to the engine's token counts).
    let kvBytesPerToken: Int
    /// Injectable telemetry sink (tests); nil ⇒ `TelemetryClient.shared`.
    let emitTelemetry: (@Sendable (TelemetryEvent) -> Void)?

    // MARK: - Per-request bookkeeping

    struct ActiveRequestState {
        let promptTokens: Int
        let maxTokens: Int
        var completionTokens: Int = 0
        let submittedAt: ContinuousClock.Instant
        var firstTokenAt: ContinuousClock.Instant?
    }

    var active: [String: ActiveRequestState] = [:]
    /// Provider request-id → engine request-id, for `cancel`.
    var idMap: [String: CBv2RequestID] = [:]
    var nextRawId: UInt64 = 1

    // MARK: - Health / telemetry state

    /// Same monitor type + semantics as the legacy engine's first-token
    /// wedge instrumentation (`WedgeMonitor`). The v2 contract exposes no
    /// engine step counter, so loop progress is proxied by
    /// `eventsObserved` — any event from any request proves the engine
    /// loop advanced (see CONTRACT-ISSUES-H-provider.md).
    var wedgeMonitor = WedgeMonitor()
    /// Monotonic count of CBv2 events observed across all requests — the
    /// v2 stand-in for `EngineCore.stepsExecuted`.
    var eventsObserved: Int = 0
    var observedDecodeTpsEwma: Double = 0
    var ewmaInitialized = false
    /// Last wedge verdict emitted, for transition-edge telemetry.
    var lastWedgeSuspectedEmitted = false

    public init(
        engine: any CBv2Engine,
        modelId: String,
        tokenizer: TokenizerHandle,
        eosTokenIds: Set<Int>,
        extraEOSTokens: [String] = [],
        defaultMaxTokens: Int = 4096,
        maxConcurrentRequests: Int = 4,
        kvBytesPerToken: Int = 0,
        emitTelemetry: (@Sendable (TelemetryEvent) -> Void)? = nil
    ) {
        self.engineBox = EngineV2EngineBox(engine: engine)
        self.modelId = modelId
        self.tokenizer = tokenizer
        self.stopTokenIds = EngineV2Translation.stopTokenIds(
            eosTokenIds: eosTokenIds,
            tokenizerEOSTokenId: tokenizer.inner.eosTokenId,
            extraEOSTokens: extraEOSTokens,
            convertTokenToId: { [inner = tokenizer.inner] in inner.convertTokenToId($0) }
        )
        self.defaultMaxTokens = defaultMaxTokens
        self.maxConcurrentRequests = maxConcurrentRequests
        self.kvBytesPerToken = kvBytesPerToken
        self.emitTelemetry = emitTelemetry
    }

    // MARK: - Submit

    /// Tokenize + submit an OpenAI-shaped chat request. Mirrors the legacy
    /// `BatchScheduler.submit(request:)` tokenization path (role/content
    /// dict + Harmony channel-tag stripping for assistant turns).
    public func submit(
        request: ChatCompletionRequest,
        requestId: String? = nil
    ) -> AsyncStream<GenerationEvent> {
        let messages: [[String: any Sendable]] = request.messages.map { msg in
            [
                "role": msg.role,
                "content": msg.role == "assistant"
                    ? stripHarmonyChannelFraming(fromAssistantContent: msg.content)
                    : msg.content,
            ]
        }
        let promptTokens: [Int]
        do {
            promptTokens = try tokenizer.inner.applyChatTemplate(
                messages: messages, tools: nil, additionalContext: nil
            )
        } catch {
            let (stream, continuation) = AsyncStream<GenerationEvent>.makeStream()
            continuation.yield(.error("Failed to tokenize: \(error.localizedDescription)"))
            continuation.finish()
            return stream
        }
        return submitTokenized(
            promptTokens: promptTokens, request: request, requestId: requestId
        )
    }

    /// Submit a pre-tokenized prompt (the `MultiModelBatchSchedulerEngine`
    /// path, which tokenizes the full OpenAI request — tools included —
    /// itself). Sampling/stop/max-token translation still comes from the
    /// request so both entry points share one translation source.
    public func submitTokenized(
        promptTokens: [Int],
        request: ChatCompletionRequest,
        requestId: String? = nil
    ) -> AsyncStream<GenerationEvent> {
        let id = requestId ?? "req-\(UUID().uuidString.prefix(12))"
        let (stream, continuation) = AsyncStream<GenerationEvent>.makeStream()

        // Duplicate request-id guard (legacy: the planner's
        // `duplicateRequestID` rejection). Without it a second submit under
        // the same id would overwrite the first request's bookkeeping and
        // the two pumps would corrupt each other's teardown. Same canonical
        // message → `.requestRejected` (a deterministic client fault).
        guard active[id] == nil else {
            continuation.yield(.error("token_budget_exhausted: duplicate request ID"))
            continuation.finish()
            return stream
        }

        let cbv2Id = CBv2RequestID(nextRawId)
        nextRawId += 1
        let cbv2Request = EngineV2Translation.cbv2Request(
            id: cbv2Id,
            promptTokens: promptTokens,
            request: request,
            defaultMaxTokens: defaultMaxTokens,
            stopTokenIds: stopTokenIds
        )

        let events: AsyncStream<CBv2Event>
        do {
            events = try engineBox.submit(cbv2Request)
        } catch {
            // Admission failure. The message keeps the canonical
            // `token_budget_exhausted:` prefix contract so
            // `fromSchedulerMessage` classifies it as a retryable capacity
            // error (429/503) exactly as the legacy engine's rejections.
            continuation.yield(.error(EngineV2Translation.admissionErrorMessage(for: error)))
            continuation.finish()
            return stream
        }

        active[id] = ActiveRequestState(
            promptTokens: promptTokens.count,
            maxTokens: cbv2Request.maxTokens,
            submittedAt: .now
        )
        idMap[id] = cbv2Id
        // Wedge instrumentation: the request is now in the engine's hands.
        wedgeMonitor.recordAdmit(now: .now)

        runPump(id: id, events: events, continuation: continuation)

        let bridge = self
        continuation.onTermination = { @Sendable termination in
            if case .cancelled = termination {
                Task { await bridge.cancel(requestId: id) }
            }
        }
        return stream
    }

    // MARK: - Cancel / shutdown

    /// Cancel by provider request-id. Prompt per the v2 contract: the
    /// in-flight step completes and the row is dropped O(1); the engine
    /// then delivers `.finished(.cancelled)` on the request's stream,
    /// which drives the normal bookkeeping/teardown in the pump.
    public func cancel(requestId: String) {
        guard let cbv2Id = idMap[requestId] else { return }
        engineBox.cancel(cbv2Id)
    }

    /// Runtime fan-out helper: cancel iff this bridge owns the request-id.
    func cancelIfOwned(requestId: String) -> Bool {
        guard let cbv2Id = idMap[requestId] else { return false }
        engineBox.cancel(cbv2Id)
        return true
    }

    /// Graceful drain (unload / process shutdown): running requests finish,
    /// new submissions are rejected by the engine.
    public func shutdown() async {
        await engineBox.shutdown()
    }

    // MARK: - Event pump (CBv2Event → GenerationEvent)

    private func runPump(
        id: String,
        events: AsyncStream<CBv2Event>,
        continuation: AsyncStream<GenerationEvent>.Continuation
    ) {
        let bridge = self
        Task {
            await bridge.pump(id: id, events: events, continuation: continuation)
        }
    }

    private func pump(
        id: String,
        events: AsyncStream<CBv2Event>,
        continuation: AsyncStream<GenerationEvent>.Continuation
    ) async {
        var sawFirstToken = false
        var sawTerminal = false
        for await event in events {
            noteEngineProgress()
            switch event {
            case .delta(let text, let tokens, _):
                // Key first-token on TOKEN count, not text: some tokens
                // (BPE intermediates, specials) detokenize to "" and would
                // otherwise leave the first-token bookkeeping unset.
                if !sawFirstToken, !tokens.isEmpty {
                    sawFirstToken = true
                    recordFirstToken(id: id)
                }
                recordProgress(id: id, newTokens: tokens.count)
                if !text.isEmpty {
                    continuation.yield(.chunk(text))
                }
            case .finished(let reason, let usage):
                sawTerminal = true
                finishAndEmit(
                    id: id, reason: reason, usage: usage,
                    sawFirstToken: sawFirstToken, continuation: continuation
                )
                continuation.finish()
                return
            }
        }
        // Stream closed without a terminal event (engine torn down
        // mid-request). Same distinct error string as the legacy bridge so
        // callers never see a 200-OK with truncated content.
        if !sawTerminal {
            continuation.yield(.error("request stream closed by engine teardown"))
            if !sawFirstToken {
                wedgeMonitor.recordTerminalWithoutFirstToken()
            }
            dropRequest(id: id)
            continuation.finish()
        }
    }

    /// Terminal framing — mirrors `BatchScheduler+EngineBridge` exactly.
    private func finishAndEmit(
        id: String,
        reason: CBv2FinishReason,
        usage: CBv2Usage,
        sawFirstToken: Bool,
        continuation: AsyncStream<GenerationEvent>.Continuation
    ) {
        switch reason {
        case .stop, .length:
            let final = recordFinish(id: id, usage: usage, success: true)
            continuation.yield(.info(
                promptTokens: final.prompt,
                completionTokens: final.completion,
                tokensPerSecond: final.tps
            ))
        case .cancelled:
            let final = recordFinish(id: id, usage: usage, success: false)
            // A cancel that did real work emits its usage BEFORE the error
            // so a listener can still bill delivered tokens (legacy abort
            // framing).
            if final.prompt > 0 || final.completion > 0 {
                continuation.yield(.info(
                    promptTokens: final.prompt,
                    completionTokens: final.completion,
                    tokensPerSecond: final.tps
                ))
            }
            continuation.yield(.error("request cancelled"))
        case .error(let message):
            _ = recordFinish(id: id, usage: usage, success: false)
            emitInferenceErrorTelemetry(requestId: id)
            continuation.yield(.error(message))
        }
        if !sawFirstToken {
            wedgeMonitor.recordTerminalWithoutFirstToken()
        }
    }

    // MARK: - Bookkeeping

    private func recordFirstToken(id: String) {
        let now = ContinuousClock.Instant.now
        wedgeMonitor.recordFirstToken(now: now)
        guard var state = active[id] else { return }
        if state.firstTokenAt == nil {
            state.firstTokenAt = now
            active[id] = state
        }
    }

    private func recordProgress(id: String, newTokens: Int) {
        guard newTokens > 0, var state = active[id] else { return }
        state.completionTokens += newTokens
        active[id] = state
    }

    /// Progress proxy for the wedge monitor's step sampling: every event
    /// received from the engine proves its loop advanced.
    private func noteEngineProgress() {
        eventsObserved += 1
    }

    /// Finish bookkeeping with the legacy billing-zero defense: the
    /// terminal usage can only ever RAISE observed counts, never zero them.
    /// TPS methodology matches `BatchScheduler.recordFinish` (decode rate
    /// measured first-token→finish over `completion - 1` tokens).
    private func recordFinish(
        id: String,
        usage: CBv2Usage,
        success: Bool
    ) -> (prompt: Int, completion: Int, tps: Double) {
        idMap.removeValue(forKey: id)
        let now = ContinuousClock.Instant.now
        guard var state = active.removeValue(forKey: id) else {
            return (max(0, usage.promptTokens), max(0, usage.completionTokens), 0)
        }
        state.completionTokens = max(state.completionTokens, usage.completionTokens)
        let prompt = max(state.promptTokens, usage.promptTokens)
        let completion = state.completionTokens

        let tps: Double
        if let firstTokenAt = state.firstTokenAt, completion > 1 {
            let seconds = WedgeMonitor.seconds(now - firstTokenAt)
            tps = seconds > 0 ? Double(completion - 1) / seconds : 0
        } else {
            let seconds = WedgeMonitor.seconds(now - state.submittedAt)
            tps = seconds > 0 ? Double(completion) / seconds : 0
        }
        if success, tps > 0 {
            updateDecodeTpsEwma(tps)
        }
        return (prompt, completion, tps)
    }

    /// Stream torn down without a terminal event — drop local state.
    private func dropRequest(id: String) {
        active.removeValue(forKey: id)
        idMap.removeValue(forKey: id)
    }

    /// Same EWMA (α = 0.3) as the legacy scheduler's decode-TPS heartbeat
    /// signal so routing sees comparable numbers across engines.
    private func updateDecodeTpsEwma(_ tps: Double) {
        let alpha = 0.3
        if ewmaInitialized {
            observedDecodeTpsEwma = alpha * tps + (1 - alpha) * observedDecodeTpsEwma
        } else {
            observedDecodeTpsEwma = tps
            ewmaInitialized = true
        }
    }

    /// PRIVACY: engine-error telemetry carries only allowlisted operational
    /// fields — never the error message (defense in depth against any
    /// engine string that could embed request-adjacent detail).
    private func emitInferenceErrorTelemetry(requestId: String) {
        var event = TelemetryEvent(
            source: .provider,
            severity: .error,
            kind: .inferenceError,
            message: "engine_v2: generation failed"
        ).withFields([
            "component": .string("engine"),
            "operation": .string("engine_v2_error"),
            "backend": .string("engine_v2"),
            "model": .string(modelId),
            "error_class": .string("cbv2_engine_error"),
        ])
        event.requestId = requestId
        emit(event)
    }

    /// Route telemetry through the injectable sink (tests) or the shared
    /// client (production).
    func emit(_ event: TelemetryEvent) {
        if let emitTelemetry {
            emitTelemetry(event)
        } else {
            TelemetryClient.shared.emit(event)
        }
    }

    // MARK: - Test seams (internal; reachable via @testable only)

    /// Snapshot of internal counters for unit assertions.
    func _testCounters() -> (active: Int, eventsObserved: Int, admits: Int, firstTokens: Int) {
        (active.count, eventsObserved, wedgeMonitor.admits, wedgeMonitor.firstTokens)
    }

    /// The engine request-id minted for a provider request-id, if active.
    func _testEngineRequestId(for requestId: String) -> CBv2RequestID? {
        idMap[requestId]
    }
}
