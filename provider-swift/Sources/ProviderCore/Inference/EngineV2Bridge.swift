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
#if canImport(os)
import os
#endif

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

    /// The v2 engine. `CBv2Engine` is declared `Sendable` in the contract
    /// (the engine serializes all cross-actor entry points —
    /// submit/cancel/capacity/shutdown — on its own step loop), so the
    /// bridge actor holds and calls it directly. The former
    /// `@unchecked Sendable` box workaround (CONTRACT-ISSUES-H-provider.md
    /// §1) is resolved.
    let engine: any CBv2Engine
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
    /// This is the UNQUANTIZED (fp16) rate: engine_v2 builds fp16 caches even
    /// when the provider's `kv_quant` is on (KV-quant unsupported by v2), so
    /// heartbeat token budgets AND the shared-budget reservation below are
    /// sized to the caches actually built — see `EngineV2KVSizing`.
    let kvBytesPerToken: Int
    /// Process-wide KV reservation ledger shared with the legacy schedulers.
    /// When set (production), each in-flight v2 request records its worst-case
    /// KV footprint here so the model-LOAD gate and the legacy live-KV gate
    /// see v2 slots' committed KV (nil in unit tests ⇒ no shared accounting).
    /// This is bookkeeping ONLY: it never gates v2 admission (the v2 engine's
    /// own byte ledger does that) — see `GlobalKVCacheBudget.recordEngineKV`.
    let kvBudget: GlobalKVCacheBudget?
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
    /// Live per-request pump tasks, so `shutdown()` can cancel any that
    /// outlive the engine drain (defense against a leaked stream). Keyed by
    /// the (normalized) provider request-id; each entry removes itself when
    /// its pump returns (`clearPumpTask`).
    var pumpTasks: [String: Task<Void, Never>] = [:]

    /// Upper bound on a caller-supplied request-id we will use verbatim.
    /// Coordinator/provider ids are short (`req-<uuid-prefix>` or a
    /// coordinator UUID); anything longer is malformed and is replaced with a
    /// fresh generated id rather than used as a dictionary key / cancel
    /// correlation handle.
    static let maxRequestIdLength = 256

    #if canImport(os)
    private static let logger = Logger(subsystem: "com.darkbloom.provider", category: "engine_v2")
    #endif

    // MARK: - Health / telemetry state

    /// Same monitor type + semantics as the legacy engine's first-token
    /// wedge instrumentation (`WedgeMonitor`). Loop progress is sampled
    /// from the engine's own monotonic `CBv2CapacitySnapshot.stepsExecuted`
    /// counter on the heartbeat cadence — the direct analogue of the
    /// legacy `EngineCore.stepsExecuted` signal (the event-count proxy
    /// recorded in CONTRACT-ISSUES-H-provider.md §3 is resolved).
    var wedgeMonitor = WedgeMonitor()
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
        kvBudget: GlobalKVCacheBudget? = nil,
        emitTelemetry: (@Sendable (TelemetryEvent) -> Void)? = nil
    ) {
        self.engine = engine
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
        self.kvBudget = kvBudget
        self.emitTelemetry = emitTelemetry
    }

    // MARK: - Submit

    /// Tokenize + submit an OpenAI-shaped chat request. Mirrors the legacy
    /// `BatchScheduler.submit(request:)` tokenization path (role/content
    /// dict + Harmony channel-tag stripping for assistant turns).
    ///
    /// The per-tenant prefix-cache scope is derived from the request itself
    /// (`prompt_cache_key`/`user` → `ChatCompletionRequest.cacheScope`);
    /// callers that decode the scope out-of-band (the coordinator path)
    /// use `submitTokenized(..., cacheScope:)` directly.
    public func submit(
        request: ChatCompletionRequest,
        requestId: String? = nil,
        logprobsChannel: EngineV2LogprobsChannel? = nil
    ) async -> AsyncStream<GenerationEvent> {
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
        return await submitTokenized(
            promptTokens: promptTokens, request: request, requestId: requestId,
            cacheScope: request.cacheScope, logprobsChannel: logprobsChannel
        )
    }

    /// Submit a pre-tokenized prompt (the `MultiModelBatchSchedulerEngine`
    /// path, which tokenizes the full OpenAI request — tools included —
    /// itself). Sampling/stop/max-token translation still comes from the
    /// request so both entry points share one translation source.
    ///
    /// `cacheScope` is the per-tenant prefix-cache scope
    /// (`SHA256(prompt_cache_key)`/`SHA256(user)`, "" ⇒ unscoped) — the
    /// same value the legacy `BatchScheduler.submitTokenized(cacheScope:)`
    /// receives. It maps onto `CBv2Request.cacheSalt` (TB-007): non-empty
    /// scopes can never share cached KV across tenants; "" maps to nil
    /// (cache-level salt fallback). Inert in production today — the v2
    /// prefix cache is constructed OFF (`prefixCache: nil` in
    /// `EngineV2Factory.makeProductionEngine`).
    ///
    /// `logprobsChannel`, when non-nil, receives OpenAI-shaped logprob
    /// entries for every engine delta that carries them (requires
    /// `request.logprobs == true` so the translated sampling params ask
    /// the engine to capture them).
    public func submitTokenized(
        promptTokens: [Int],
        request: ChatCompletionRequest,
        requestId: String? = nil,
        cacheScope: String = "",
        logprobsChannel: EngineV2LogprobsChannel? = nil
    ) async -> AsyncStream<GenerationEvent> {
        // Validate the caller-supplied id before it becomes a dictionary key /
        // cancel-correlation handle: a nil / empty / over-long / non-printable
        // id is replaced with a fresh generated one (it could never correlate
        // a cancel reliably anyway, and an unbounded/control-char key is a
        // hardening risk). See `normalizedRequestId`.
        let id = Self.normalizedRequestId(requestId)
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
        // Wrapping increment: 2^64 request ids is unreachable in practice
        // (billions of years at any real submit rate), but `&+` makes the
        // theoretical overflow explicitly defined (wrap to 0) instead of a
        // trap. Collisions after a wrap are still impossible in practice —
        // the engine id space is far larger than the live-request window.
        nextRawId &+= 1
        let cbv2Request = EngineV2Translation.cbv2Request(
            id: cbv2Id,
            promptTokens: promptTokens,
            request: request,
            defaultMaxTokens: defaultMaxTokens,
            stopTokenIds: stopTokenIds,
            cacheScope: cacheScope
        )

        let events: AsyncStream<CBv2Event>
        do {
            // `engine.submit` is an O(1) non-blocking ENQUEUE by contract
            // (`CBv2Engine.submit`: "Cancel promptly … row is dropped O(1)";
            // `EngineV2.submit` does a lock-guarded admission check +
            // `loop.register` + `loop.enqueue`, all constant-time, and NO
            // forward pass — that runs on the engine's own step thread).
            // Tokenization already happened off this actor (in `submit`, or in
            // the caller for `submitTokenized`), so calling it synchronously
            // on the bridge actor does not stall other actor work.
            events = try engine.submit(cbv2Request)
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

        // Record the request's worst-case KV footprint in the shared budget
        // SYNCHRONOUSLY with admission — before returning the stream and
        // before the pump task is even scheduled — so a concurrent model-load
        // gate can never observe zero v2 KV in the gap between engine
        // admission and the pump starting. Bookkeeping only (never gates v2
        // admission); released on every terminal/teardown path in the pump.
        // No-op when kvBudget is nil (unit tests) or kvBytesPerToken is 0.
        await kvBudget?.recordEngineKV(
            requestID: id, kvBytesPerToken: kvBytesPerToken,
            tokenCount: promptTokens.count + cbv2Request.maxTokens)

        runPump(
            id: id, events: events, continuation: continuation,
            logprobsChannel: logprobsChannel
        )

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
        engine.cancel(cbv2Id)
    }

    /// Runtime fan-out helper: cancel iff this bridge owns the request-id.
    func cancelIfOwned(requestId: String) -> Bool {
        guard let cbv2Id = idMap[requestId] else { return false }
        engine.cancel(cbv2Id)
        return true
    }

    /// Graceful drain (unload / process shutdown): running requests finish,
    /// new submissions are rejected by the engine.
    ///
    /// The per-request pump tasks are tracked (`pumpTasks`) and cancelled here
    /// so none outlives the bridge. Cancellation makes each pump's
    /// `for await event in events` resume with nil (AsyncStream is
    /// cancellation-aware), so the pump hits its teardown path — yielding the
    /// closed-stream sentinel and releasing per-request state — instead of
    /// leaking. We cancel BEFORE draining the engine so a wedged engine stream
    /// can't keep a pump (and its KV reservation) alive past shutdown, then
    /// await the engine drain.
    public func shutdown() async {
        let live = pumpTasks
        pumpTasks.removeAll()
        for task in live.values { task.cancel() }
        await engine.shutdown()
    }

    // MARK: - Event pump (CBv2Event → GenerationEvent)

    private func runPump(
        id: String,
        events: AsyncStream<CBv2Event>,
        continuation: AsyncStream<GenerationEvent>.Continuation,
        logprobsChannel: EngineV2LogprobsChannel? = nil
    ) {
        let bridge = self
        let task = Task {
            await bridge.pump(
                id: id, events: events, continuation: continuation,
                logprobsChannel: logprobsChannel
            )
            await bridge.clearPumpTask(id: id)
        }
        pumpTasks[id] = task
    }

    /// Remove a completed pump's task handle (called from the pump task after
    /// `pump` returns, on every exit path).
    func clearPumpTask(id: String) {
        pumpTasks.removeValue(forKey: id)
    }

    private func pump(
        id: String,
        events: AsyncStream<CBv2Event>,
        continuation: AsyncStream<GenerationEvent>.Continuation,
        logprobsChannel: EngineV2LogprobsChannel? = nil
    ) async {
        // NOTE: the shared-budget KV reservation is recorded in
        // `submitTokenized` (synchronously with admission), NOT here — the
        // pump only RELEASES it on the terminal/teardown paths below.
        var sawFirstToken = false
        var sawTerminal = false
        for await event in events {
            switch event {
            case .delta(let text, let tokens, let logprobs):
                // Key first-token on TOKEN count, not text: some tokens
                // (BPE intermediates, specials) detokenize to "" and would
                // otherwise leave the first-token bookkeeping unset.
                if !sawFirstToken, !tokens.isEmpty {
                    sawFirstToken = true
                    recordFirstToken(id: id)
                }
                recordProgress(id: id, newTokens: tokens.count)
                // Logprobs passthrough: convert to the OpenAI streaming
                // entry shape and publish to the per-request channel BEFORE
                // yielding the chunk, so by the time the SSE frame carrying
                // this delta's text reaches the frame decorator its entries
                // are already drainable (happens-before via the yield).
                if let logprobsChannel, let logprobs, !logprobs.isEmpty {
                    logprobsChannel.append(
                        EngineV2Translation.sseTokenLogprobs(
                            logprobs,
                            decodeToken: { [inner = tokenizer.inner] id in
                                inner.decode(tokenIds: [id], skipSpecialTokens: false)
                            }
                        )
                    )
                }
                if !text.isEmpty {
                    continuation.yield(.chunk(text))
                }
            case .finished(let reason, let usage):
                sawTerminal = true
                finishAndEmit(
                    id: id, reason: reason, usage: usage,
                    sawFirstToken: sawFirstToken, continuation: continuation
                )
                // Release the shared-budget KV reservation on the terminal
                // (idempotent; no-op when none was recorded).
                await kvBudget?.release(requestID: id)
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
            await kvBudget?.release(requestID: id)
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

    // MARK: - Request-id validation

    /// Return a request-id safe to use as a dictionary key and cancel
    /// correlation handle. A caller-supplied id is accepted verbatim only
    /// when it is non-empty, at most `maxRequestIdLength`, and printable
    /// (no ASCII control chars); otherwise — and when nil — a fresh
    /// `req-<uuid-prefix>` is generated. Pure/static so it is unit-testable.
    static func normalizedRequestId(_ requestId: String?) -> String {
        if let requestId, isValidRequestId(requestId) { return requestId }
        return "req-\(UUID().uuidString.prefix(12))"
    }

    /// A request-id is valid when non-empty, within the length cap, and free
    /// of ASCII control characters (`< 0x20` or DEL `0x7f`).
    static func isValidRequestId(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= maxRequestIdLength else { return false }
        return !id.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
    }

    // MARK: - Test seams (internal; reachable via @testable only)

    /// Number of live pump tasks (shutdown-tracking assertions).
    func _testLivePumpCount() -> Int { pumpTasks.count }

    /// Snapshot of internal counters for unit assertions.
    func _testCounters() -> (active: Int, admits: Int, firstTokens: Int) {
        (active.count, wedgeMonitor.admits, wedgeMonitor.firstTokens)
    }

    /// The engine request-id minted for a provider request-id, if active.
    func _testEngineRequestId(for requestId: String) -> CBv2RequestID? {
        idMap[requestId]
    }
}
