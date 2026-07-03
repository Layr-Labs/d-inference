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
    /// When set (production), each v2 submission must RESERVE its worst-case
    /// KV footprint here BEFORE it is handed to the engine — the reservation
    /// both GATES v2 admission against the process-wide unified-memory cap
    /// (the engine's private byte ledger only knows its own slot; with
    /// another slot's live KV already reserved, this shared pool is the only
    /// gate that sees the whole process) and is the accounting entry the
    /// model-LOAD gate and the legacy live-KV gate subtract. nil in unit
    /// tests ⇒ no shared gating/accounting.
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
    /// Monotonic engine-id counter for UNSEEDED requests. Lives in the low
    /// half of the id space (seeded requests derive TAGGED ids with bit 63
    /// set — see `stableSeededRawId`), so the two families cannot collide:
    /// reaching 2^63 monotonic ids is unattainable at any real submit rate.
    var nextRawId: UInt64 = 1
    /// Live per-request pump tasks, so `shutdown()` can cancel any that
    /// outlive the engine drain (defense against a leaked stream). Keyed by
    /// the (normalized) provider request-id; each entry removes itself when
    /// its pump returns (`clearPumpTask`).
    ///
    /// BOUNDED WITHOUT A LOCAL LIMIT: a pump task exists only for an
    /// engine-ACCEPTED request (created strictly after `engine.submit`
    /// returned) and self-clears on its terminal, and the engine's own
    /// admission bounds accepted-but-unfinished requests — `EngineV2.submit`
    /// throws `capacityExhausted` once the waiting queue is full
    /// (`gauges.beginSubmit(maxWaiting:)`, `CBv2SchedulerConfig.maxWaiting`,
    /// default 64) on top of the running-row cap (`maxConcurrentRequests`,
    /// production 4). So `pumpTasks.count ≤ maxConcurrent + maxWaiting`
    /// (≈ 68 in production) by construction; the shared KV-budget gate in
    /// `submitTokenized` bounds it further under memory pressure. A separate
    /// bridge-side limit would just shadow the engine's admission with a
    /// second constant to keep in sync.
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

        // Translate with a PLACEHOLDER engine id — the real id is minted
        // below, AFTER the shared-budget await, in the same synchronous
        // stretch as `engine.submit` and the `idMap` registration. Minting
        // before the suspension would let two concurrent IDENTICAL seeded
        // submissions both pass the collision check and hand the engine
        // duplicate live ids.
        var cbv2Request = EngineV2Translation.cbv2Request(
            id: CBv2RequestID(0),
            promptTokens: promptTokens,
            request: request,
            defaultMaxTokens: defaultMaxTokens,
            stopTokenIds: stopTokenIds,
            cacheScope: cacheScope
        )

        // SHARED-BUDGET ADMISSION GATE: reserve this request's worst-case KV
        // footprint (prompt + maxTokens at the fp16 rate — the caches v2
        // actually builds) in the process-wide ledger BEFORE handing the
        // request to the engine. The engine's private byte ledger
        // (`AdmissionV2`, sized to its own `kvBytesCapacity`) only knows its
        // own slot; when another slot (legacy or v2) already has live KV
        // reserved, this shared pool is the only gate that sees the WHOLE
        // process — without it, concurrent requests across co-resident models
        // could overcommit unified memory (default `max_model_slots` allows
        // several). `reserve` is atomic on the budget actor (check + record in
        // one hop — no TOCTOU window between a probe and a later record), so
        // once it returns true the reservation is already visible to the
        // model-LOAD gate and the legacy live-KV gate; it is released on every
        // terminal/teardown path in the pump, and below when the engine
        // rejects the submission. A gate failure maps to the canonical
        // retryable capacity error (429/503), exactly like the legacy
        // scheduler's KV-reserve rejection. Skipped when kvBudget is nil
        // (unit tests / standalone), the per-token rate is unknown (0), or
        // maxTokens ≤ 0 (degenerate request — the engine finishes it
        // immediately without allocating any KV).
        let worstCaseTokens = promptTokens.count + cbv2Request.maxTokens
        var sharedKVReserved = false
        if let kvBudget, kvBytesPerToken > 0, cbv2Request.maxTokens > 0 {
            sharedKVReserved = await kvBudget.reserve(
                requestID: id, kvBytesPerToken: kvBytesPerToken, tokenCount: worstCaseTokens)
            guard sharedKVReserved else {
                continuation.yield(.error(
                    "token_budget_exhausted: request requires \(worstCaseTokens) tokens "
                        + "but the shared KV budget has no headroom"))
                continuation.finish()
                return stream
            }
            // Re-check the duplicate guard: `reserve` suspended this actor,
            // so a concurrent submit under the SAME id that skipped the gate
            // (degenerate maxTokens / unknown rate ⇒ no suspension) could
            // have been admitted in the gap. Reject THIS submission and roll
            // back its reservation — never overwrite live bookkeeping. (A
            // gate-taking duplicate can't get here: its own `reserve` fails
            // on this id's existing entry.)
            guard active[id] == nil else {
                await kvBudget.release(requestID: id)
                continuation.yield(.error("token_budget_exhausted: duplicate request ID"))
                continuation.finish()
                return stream
            }
        }

        // Mint the engine request id: monotonic by default, STABLE
        // (seed, prompt)-derived when the caller supplied an explicit seed —
        // the engine keys its sampler RNG on (seed, requestID, stepIndex)
        // (`CBv2SamplingParams.seed`), so a fresh id on every submission
        // would make identical seeded requests sample differently depending
        // on prior traffic. See `mintEngineRequestId` for the collision
        // guarantees and the documented reproducibility limits.
        let cbv2Id = mintEngineRequestId(
            seed: cbv2Request.sampling.seed, promptTokens: promptTokens)
        cbv2Request.id = cbv2Id

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
            // Engine rejected AFTER the shared reservation was taken — release
            // it before surfacing the error (no pump will ever finish it).
            if sharedKVReserved { await kvBudget?.release(requestID: id) }
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

        runPump(
            id: id, events: events, continuation: continuation,
            holdsSharedReservation: sharedKVReserved,
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
        holdsSharedReservation: Bool,
        logprobsChannel: EngineV2LogprobsChannel? = nil
    ) {
        let bridge = self
        let task = Task {
            await bridge.pump(
                id: id, events: events, continuation: continuation,
                holdsSharedReservation: holdsSharedReservation,
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
        holdsSharedReservation: Bool,
        logprobsChannel: EngineV2LogprobsChannel? = nil
    ) async {
        // NOTE: the shared-budget KV reservation is taken in `submitTokenized`
        // (the pre-engine admission gate), NOT here — the pump only RELEASES
        // it on the terminal/teardown paths below, and ONLY when THIS request
        // took one (`holdsSharedReservation`): an unconditional release could
        // drop a same-keyed reservation owned by a different submission in
        // the pathological duplicate-id corner.
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
                // (only when this request took one; release is idempotent).
                if holdsSharedReservation {
                    await kvBudget?.release(requestID: id)
                }
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
            if holdsSharedReservation {
                await kvBudget?.release(requestID: id)
            }
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
            // Preserve the v2 engine's truncation signal: `.length` must
            // reach the client as finish_reason "length", not be flattened
            // to "stop" (max_tokens truncation was invisible on v2).
            continuation.yield(.info(
                promptTokens: final.prompt,
                completionTokens: final.completion,
                tokensPerSecond: final.tps,
                finishReason: reason == .length ? "length" : "stop"
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
                    tokensPerSecond: final.tps,
                    finishReason: nil
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

    // MARK: - Engine request-id minting

    /// Tag bit for (seed, prompt)-derived engine ids. Keeps the seeded id
    /// family disjoint from the monotonic counter (which starts at 1 and can
    /// never reach 2^63 at any real submit rate), so a derived id can only
    /// ever collide with another SEEDED id — and then only for an identical
    /// (seed, prompt) pair, which `mintEngineRequestId` guards against.
    static let seededIdTagBit: UInt64 = 1 << 63

    /// Deterministic engine-id for a seeded submission: a SplitMix64 chain
    /// over (seed, promptTokens…), tagged into the seeded id family.
    ///
    /// WHY (round-2 PR#499 P2): the v2 sampler's RNG key is
    /// (seed, requestID.raw, stepIndex) — `SamplerV2.mix` — so `seed` only
    /// reproduces output if the request id is itself a pure function of the
    /// request. Deriving it from (seed, prompt) makes same-seed + same-prompt
    /// submissions sample identically at B=1 regardless of prior traffic,
    /// while different prompts/seeds still get distinct RNG streams.
    ///
    /// Deterministic across processes (no `Hasher` seed), mirroring the
    /// engine sampler's own SplitMix64 keying family.
    static func stableSeededRawId(seed: UInt64, promptTokens: [Int]) -> UInt64 {
        var hash = splitmix64(seed)
        for token in promptTokens {
            hash = splitmix64(hash ^ UInt64(bitPattern: Int64(token)))
        }
        return hash | seededIdTagBit
    }

    /// SplitMix64 finalizer (public-domain constants).
    static func splitmix64(_ x: UInt64) -> UInt64 {
        var z = x &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Mint the engine id for a submission. Seeded requests get the stable
    /// (seed, prompt)-derived id; everything else gets the monotonic counter
    /// (`&+` wrap: 2^63 ids is unreachable, but the overflow is defined).
    ///
    /// Collision guard: an IDENTICAL seeded request that is still LIVE would
    /// collide inside the engine's per-request maps, so the derived id falls
    /// back to a fresh monotonic id. DOCUMENTED LIMITS of seeded
    /// reproducibility: (a) submissions that overlap their own duplicate
    /// in-flight lose the stable id (this fallback); (b) under batching the
    /// contract is best-effort — the RNG key itself is batch-invariant, but
    /// non-deterministic kernel scheduling can still perturb floating-point
    /// reductions across different batch compositions.
    ///
    /// MUST be called in the same synchronous (no-await) stretch as
    /// `engine.submit` + the `idMap` registration, so the liveness check
    /// cannot race a concurrent identical submission across a suspension.
    private func mintEngineRequestId(seed: UInt64?, promptTokens: [Int]) -> CBv2RequestID {
        if let seed {
            let stable = CBv2RequestID(
                Self.stableSeededRawId(seed: seed, promptTokens: promptTokens))
            // O(live requests) scan (≤ engine concurrency + waiting cap);
            // only taken on seeded submissions.
            if !idMap.values.contains(stable) { return stable }
        }
        let fresh = CBv2RequestID(nextRawId)
        nextRawId &+= 1
        return fresh
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
