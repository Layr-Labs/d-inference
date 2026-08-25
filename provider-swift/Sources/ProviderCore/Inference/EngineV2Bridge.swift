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
// v0.7.5 ONE ENGINE: every model slot serves through this bridge —
// `EngineV2Factory.makeBridge` (fail-loud, no selection gate; see
// `EngineV2Config.swift`) constructs it at model load, and a load whose
// bridge cannot be built fails with a 503 instead of falling back.
//
// Companion files:
//   * `EngineV2Bridge+Translation.swift` — pure ChatRequest → CBv2Request
//     translation (sampling params, logit_bias parsing, stop resolution
//     with `buildStopTokenIds` semantics, error-message mapping).
//   * `EngineV2Bridge+Capacity.swift`    — CBv2CapacitySnapshot → heartbeat
//     `BackendSlotCapacity` mapping + the `engine_v2.step_wedge` signal.
//   * `EngineV2Runtime.swift`            — process-wide bridge registry the
//     ProviderLoop capacity/cancellation hooks fan out through.
//   * `EngineV2Config.swift`             — the fail-loud factory + the
//     engine_v2_refusal telemetry.

import Foundation
import MLXLMCommon
import ProviderCoreFoundation
#if canImport(os)
import os
#endif

/// What a paged slot's construction-fixed pool could NOT do when the fleet
/// re-slicer moved its grant.
///
/// A contiguous slot resizes its admission ledger and its physical capacity
/// together, so every re-slice is exact. A paged slot's pool is sized ONCE at
/// engine construction and `PagedKVPool` has no resize primitive — `pageCount`
/// is fixed at init and the slabs are immutable `let` arrays written in place.
/// (Since D1 the slabs are WIRED lazily, at the pool's first admission rather
/// than at construction; that moves when the bytes appear, not how many there
/// are. The figure below is the construction-fixed budget either way.) So a
/// non-exact re-slice leaves one of two residues:
///
///   * GROW past the pool ⇒ `deferredGrowthBytes` of awarded fair share the
///     slot cannot serve. The fleet re-slicer believes this slot holds them.
///   * SHRINK below the pool ⇒ `strandedBytes` of physical KV the slot still
///     owns after its fair share was cut. Nobody can use them: the re-slicer
///     has already promised those bytes to a co-resident slot's logical
///     grant while Metal still holds them here, so `Σ(logical grants) ≤
///     fleet budget` stops implying `Σ(physical KV) ≤ fleet budget`.
///
/// Both are ZERO on a contiguous slot and on an exact paged re-slice. They
/// are precisely the two inputs a real pool resize consumes — and, with no
/// canary fleet, the only signal that a box's paged slots are partitioned by
/// model ARRIVAL ORDER rather than by fair share.
public struct PagedPoolResizeShortfall: Sendable, Equatable {
    /// Committed physical pool bytes (`CBv2CapacitySnapshot
    /// .kvBytesBackendCapacity`); always > 0 — an UNKNOWN pool yields no
    /// shortfall at all rather than a fabricated one.
    public let poolBytes: Int
    /// The logical fair share the re-slicer last asked this slot to hold,
    /// recorded BEFORE the physical clamp.
    public let requestedBytes: Int

    /// Awarded grant the construction-fixed pool cannot serve.
    public var deferredGrowthBytes: Int { max(0, requestedBytes - poolBytes) }
    /// Physical KV held past the current fair share; unreclaimable without
    /// an unload/rebuild of the slot's engine.
    public var strandedBytes: Int { max(0, poolBytes - requestedBytes) }
    /// The pool and the fair share agree — nothing to resize.
    public var isExact: Bool { poolBytes == requestedBytes }
}

/// Bridges one `CBv2Engine` (one loaded model) to the provider's
/// `GenerationEvent` streaming surface.
///
/// Event framing intentionally mirrors `BatchScheduler+EngineBridge`
/// exactly (fixture-pinned in `EngineV2BridgeTests`):
///   * text deltas       → `.chunk(text)` (empty deltas suppressed)
///   * finish stop/length→ `.info(prompt, completion, tps, reason)` then
///                         finish (reason "stop"/"length" preserved)
///   * cancelled         → `.info(usage, reason: nil)` if any tokens were
///                         produced, then `.error("request cancelled")`
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
    /// Mutable ownership is intentional: `shutdown()` nils the engine after
    /// drain so its target and MTP drafter references are released before the
    /// slot owner purges MLX cache and regrows survivor grants.
    var ownedEngine: (any CBv2Engine)?
    var engine: any CBv2Engine {
        guard let ownedEngine else {
            preconditionFailure("EngineV2Bridge engine accessed after shutdown")
        }
        return ownedEngine
    }
    func capacitySnapshot() -> CBv2CapacitySnapshot {
        ownedEngine?.capacity()
            ?? CBv2CapacitySnapshot(
                activeRequests: 0,
                waitingRequests: 0,
                kvBytesInUse: 0,
                kvBytesCapacity: 0,
                kvBytesBackendCapacity: 0,
                kvBytesReserved: 0,
                activeTokens: 0,
                stepsExecuted: wedgeMonitor.lastStepsSample)
    }
    public let modelId: String
    /// Which KV backend the engine was built with. Keys the bridge's
    /// shared-gate accounting (paged pools are construction-committed —
    /// no per-request `GlobalKVCacheBudget` reserve), the heartbeat
    /// capacity clamp, and the provider's re-slice policy (paged slots
    /// rebuild instead of resizing; `updateBytesCapacity` is a no-op on
    /// a physically preallocated pool).
    public let kvBackendKind: EngineV2KVBackendKind
    /// Why the engine ended up on `kvBackendKind` instead of the backend
    /// it was asked for — `ProductionBuild.kvBackendFallbackReason`, nil
    /// when nothing degraded. Held for the whole life of the slot (the
    /// decision is made once, at construction) because the heartbeat
    /// reports it on EVERY tick alongside the kind: a degrade that is only
    /// announced in the once-per-load `engine_v2_kv_backend` event rides a
    /// droppable best-effort sink, so a fleet that missed the event books
    /// a degraded slot as a deliberately-contiguous one forever.
    ///
    /// Read ONLY for reporting. Nothing in the bridge's accounting,
    /// clamping or re-slice policy may branch on it — those key off
    /// `kvBackendKind`, which is the backend that actually exists.
    public let kvBackendFallbackReason: String?
    /// `kvBackendFallbackReason` already clamped to the heartbeat budget.
    /// Stored rather than recomputed because the reason is fixed at
    /// construction while the heartbeat rebuilds every slot's capacity every
    /// few seconds, and the clamp costs two O(n) grapheme walks
    /// (`String.count`, then `prefix`) that would otherwise run per slot per
    /// tick for a value that cannot have changed.
    let clampedKVBackendFallbackReason: String?
    let tokenizer: TokenizerHandle
    /// Resolved stop-token set (model EOS ∪ tokenizer EOS ∪ extra EOS
    /// tokens) — `buildStopTokenIds` semantics, computed ONCE at bridge
    /// construction so B=1 and batched behavior stay identical.
    let stopTokenIds: Set<Int>
    let defaultMaxTokens: Int
    let maxConcurrentRequests: Int
    /// Per-token KV byte cost for bytes→tokens capacity derivation
    /// (0 = unknown; capacity then falls back to the engine's token counts).
    /// This is the resolved native serving rate. Contiguous GPT-OSS adds the
    /// fp32 owning-full-row delta to the nominal fp16 sizing rate; Gemma and
    /// paged slots remain fp16. Heartbeats and process-wide reservations use
    /// the same value so neither can overstate capacity.
    let kvBytesPerToken: Int
    /// Peak request-owned residency outside attention KV (Qwen recurrent
    /// committed + transactional conv/SSM generations). Zero preserves the
    /// historical attention-only charge.
    let fixedRequestBytes: Int
    /// Assistant-cache allocation geometry. The per-token rate includes target
    /// KV and assistant logical rows; these fields account for the assistant's
    /// block-rounded physical allocation and staged proposal high-water mark.
    let auxiliaryBytesPerToken: Int
    let auxiliaryTokenGranularity: Int
    let auxiliaryTokenAllocationPadding: Int
    /// Process-wide KV reservation ledger shared by every EngineV2 slot.
    /// When set (production), each v2 submission must RESERVE its worst-case
    /// KV footprint here BEFORE it is handed to the engine — the reservation
    /// both GATES v2 admission against the process-wide unified-memory cap
    /// (the engine's private byte ledger only knows its own slot; with
    /// another slot's live KV already reserved, this shared pool is the only
    /// gate that sees the whole process) and is the accounting entry the
    /// model-load gate subtracts. nil in unit
    /// tests ⇒ no shared gating/accounting.
    let kvBudget: GlobalKVCacheBudget?
    /// Encrypted SSD offload tier (v0.7.5, default for CBv2-supported models
    /// when Secure Enclave KEK construction succeeds):
    /// the SAME instance handed to the engine as its `CBv2PrefixCache`.
    /// The bridge holds it for the pre-submit staging hook (read-through
    /// adoption: probe index → reserve staging bytes → read+decrypt off
    /// the engine threads → seed the staging map so the engine's
    /// synchronous `lookup()` hits), the per-request release backstop
    /// (`completeStaging`), and shutdown. nil means caching is disabled or
    /// SSD initialization was unavailable.
    nonisolated let ssdPrefixCache: SSDPrefixCache?
    nonisolated let prefixCacheBaseStatus: PrefixCacheModelStatus
    nonisolated let prefixCacheEvidenceSequencer: PrefixCacheEvidenceSequencer?
    /// Periodic prefix-cache stats logger (v2 analog of the legacy
    /// checkpoint-tier logger). Started by the slot factory when an active
    /// cache exists; cancelled in `shutdown()`.
    var prefixCacheStatsTask: Task<Void, Never>?
    /// Periodic content-free per-slot POSTURE sampler: the MTP metrics log
    /// plus the `engine_v2_slot_posture` telemetry event that produces the
    /// v0.8.0 MTP and paged-pool fields. Runs for every slot, MTP or not —
    /// see `configureMTPStatus`. Cancelled by `shutdown()`.
    var slotPostureTask: Task<Void, Never>?
    var mtpActivationStatus = MTPActivationStatus.disabled(
        .configDisabled, configured: false)
    /// Injectable telemetry sink (tests); nil ⇒ `TelemetryClient.shared`.
    let emitTelemetry: (@Sendable (TelemetryEvent) -> Void)?

    // MARK: - Per-request bookkeeping

    struct ActiveRequestState {
        let promptTokens: Int
        let maxTokens: Int
        var completionTokens: Int = 0
        var submittedAt: ContinuousClock.Instant
        var firstTokenAt: ContinuousClock.Instant?
        /// No other row was still prefilling when this one was admitted, so
        /// its submit→first-token window is its OWN prefill work rather than
        /// time spent queued behind someone else. Only such rows may
        /// calibrate `isolatedPrefillTpsEwma`.
        let uncontendedAtSubmit: Bool
    }

    var active: [String: ActiveRequestState] = [:]
    /// Provider request-id → engine request-id, for `cancel`.
    var idMap: [String: CBv2RequestID] = [:]
    /// Monotonic engine-id counter for UNSEEDED requests. Lives in the low
    /// half of the id space (seeded requests derive TAGGED ids with bit 63
    /// set — see `stableSeededRawId`), so the two families cannot collide:
    /// reaching 2^63 monotonic ids is unattainable at any real submit rate.
    var nextRawId: UInt64 = 1
    /// Receipt correlation is submission-unique even when the seeded sampler
    /// identity is intentionally stable across sequential identical requests.
    /// This counter is a separate namespace: advancing it must never perturb
    /// engine idMap/cancellation or sampler reproducibility.
    var nextPrefixCacheReceiptRawId: UInt64 = 1
    var prefixCacheHitTelemetrySeen: UInt64 = 0
    var prefixCacheFallbackTelemetrySeen: UInt64 = 0
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
    /// Cold-prefill EWMA (`observed_prefill_tps` heartbeat field), fed only by
    /// successful requests whose terminal usage confirms that no prefix KV was
    /// adopted. The bridge's timing window is first-token time − submit and
    /// the rate is prompt tokens / window. Absorbs
    /// PR #454's measurement approach for the v2 engine (that PR added an
    /// engine prefill-start marker for the LEGACY engine; the v2 bridge
    /// already owns both timestamps, so no engine change is needed) with
    /// the same plausibility bounds — see `recordPrefillSample`.
    var observedPrefillTpsEwma: Double = 0
    var prefillEwmaInitialized = false
    /// Prefill rate measured with the queue wait EXCLUDED — fed only by rows
    /// that found no other prefill in flight at submit, so the window is the
    /// row's own service time.
    ///
    /// `observedPrefillTpsEwma` above is deliberately load-INCLUSIVE (its
    /// window starts at admission, and the wire contract at
    /// `protocol/messages.go:277` documents it that way), which makes it the
    /// wrong denominator for a projection that adds an explicit queue term:
    /// contention would be counted twice, inflating the estimate by ~(K+1)/2
    /// at queue depth K and refusing rows that comfortably fit.
    ///
    /// This one is LOCAL ONLY. It is never reported on the wire, so no
    /// coordinator or mixed-version-fleet compatibility surface is involved.
    ///
    /// Caveat: rows already in DECODE still share engine steps, so this is a
    /// conservative approximation of a truly isolated rate, not a guarantee.
    var isolatedPrefillTpsEwma: Double = 0
    var isolatedPrefillEwmaInitialized = false
    /// Cold-start model load time (ms) for this slot, recorded by
    /// `ProviderLoop.ensureModelLoaded` once the load completes (the
    /// bridge exists before the load finishes, so this arrives post-init).
    /// Reported per-slot as `model_load_time_ms`.
    var modelLoadTimeMs: Int64 = 0
    /// Last wedge verdict emitted, for transition-edge telemetry.
    var lastWedgeSuspectedEmitted = false
    /// True while a wedge-recovery rebuild is in flight for this slot
    /// (`ProviderLoop+EngineV2Liveness`). The heartbeat then reports
    /// slot state "reloading" — the legacy `isReloadingForRecovery`
    /// semantic — so the coordinator deroutes the model for the whole
    /// window instead of seeing "crashed" flap or a healthy-looking slot.
    /// Set on the OLD bridge being drained; the recovered slot's fresh
    /// bridge starts clean.
    var recoveryReloading = false
    /// The logical fair share the fleet re-slicer last asked this slot to
    /// hold, recorded BEFORE the paged physical clamp so the part a
    /// construction-fixed pool cannot honour stays measurable
    /// (`pagedPoolResizeShortfall()`). nil until the first re-slice: a
    /// freshly-built slot's admission ceiling IS its pool, by construction.
    var lastRequestedKVBytesCapacity: Int?
    /// Last shortfall shape published to telemetry, so the clamp signal is
    /// emitted on CHANGE only — the re-slicer fires on every load and unload
    /// of every co-resident model, and an unchanged residue is not news.
    var lastPagedShortfallEmitted: PagedPoolResizeShortfall?

    public init(
        engine: any CBv2Engine,
        modelId: String,
        tokenizer: TokenizerHandle,
        eosTokenIds: Set<Int>,
        extraEOSTokens: [String] = [],
        defaultMaxTokens: Int = 4096,
        maxConcurrentRequests: Int = 4,
        kvBytesPerToken: Int = 0,
        fixedRequestBytes: Int = 0,
        auxiliaryBytesPerToken: Int = 0,
        auxiliaryTokenGranularity: Int = 1,
        auxiliaryTokenAllocationPadding: Int = 0,
        kvBudget: GlobalKVCacheBudget? = nil,
        ssdPrefixCache: SSDPrefixCache? = nil,
        prefixCacheStatus: PrefixCacheModelStatus? = nil,
        kvBackendKind: EngineV2KVBackendKind = .contiguous,
        kvBackendFallbackReason: String? = nil,
        emitTelemetry: (@Sendable (TelemetryEvent) -> Void)? = nil
    ) {
        self.ownedEngine = engine
        self.modelId = modelId
        self.tokenizer = tokenizer
        self.kvBackendKind = kvBackendKind
        self.kvBackendFallbackReason = kvBackendFallbackReason
        self.clampedKVBackendFallbackReason =
            Self.heartbeatFallbackReason(kvBackendFallbackReason)
        self.stopTokenIds = EngineV2Translation.stopTokenIds(
            eosTokenIds: eosTokenIds,
            tokenizerEOSTokenId: tokenizer.inner.eosTokenId,
            extraEOSTokens: extraEOSTokens,
            convertTokenToId: { [inner = tokenizer.inner] in inner.convertTokenToId($0) }
        )
        self.defaultMaxTokens = defaultMaxTokens
        self.maxConcurrentRequests = maxConcurrentRequests
        self.kvBytesPerToken = kvBytesPerToken
        self.fixedRequestBytes = max(0, fixedRequestBytes)
        self.auxiliaryBytesPerToken = max(0, auxiliaryBytesPerToken)
        self.auxiliaryTokenGranularity = max(1, auxiliaryTokenGranularity)
        self.auxiliaryTokenAllocationPadding = max(
            0, auxiliaryTokenAllocationPadding)
        self.kvBudget = kvBudget
        self.ssdPrefixCache = ssdPrefixCache
        self.prefixCacheBaseStatus = prefixCacheStatus ?? PrefixCacheModelStatus(
            modelId: modelId,
            backend: PrefixCacheStatusBackend(kvBackendKind),
            replayStrategy: .unknown,
            state: ssdPrefixCache == nil ? .disabled : .pending,
            reason: ssdPrefixCache == nil ? .unsupportedBackend : .scanPending)
        self.prefixCacheEvidenceSequencer = ssdPrefixCache.map {
            PrefixCacheEvidenceSequencer(cache: $0)
        }
        self.emitTelemetry = emitTelemetry
    }

    // MARK: - Submit

    /// Tokenize + submit an OpenAI-shaped chat request. Mirrors the legacy
    /// `BatchScheduler.submit(request:)` tokenization path (role/content
    /// dict + Harmony channel-tag stripping for assistant turns).
    ///
    /// Local callers are intentionally unscoped. Remote callers pass the
    /// authenticated coordinator-authored scope through `submitTokenized`.
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
            cacheScope: "", logprobsChannel: logprobsChannel
        )
    }

    /// Submit a pre-tokenized prompt (the `MultiModelBatchSchedulerEngine`
    /// path, which tokenizes the full OpenAI request — tools included —
    /// itself). Sampling/stop/max-token translation still comes from the
    /// request so both entry points share one translation source.
    ///
    /// `cacheScope` is authenticated and coordinator-authored for remote
    /// requests; standalone callers remain unscoped. It maps onto
    /// `CBv2Request.cacheSalt`: non-empty scopes cannot share encrypted SSD
    /// blocks across tenants, and `cacheEnabled=false` fails cold.
    ///
    /// `usageSignal`, when non-nil, receives the engine's terminal usage
    /// detail (matched and actually-saved prefix tokens) so the frames loop can
    /// splice `prompt_tokens_details.cached_tokens` into the trailing SSE
    /// usage chunk (same out-of-band pattern as `logprobsChannel`).
    ///
    /// `logprobsChannel`, when non-nil, receives OpenAI-shaped logprob
    /// entries for every engine delta that carries them (requires
    /// `request.logprobs == true` so the translated sampling params ask
    /// the engine to capture them).
    ///
    /// `multimodal` (v0.7.5, image + video) is the precomputed
    /// media-prefill input for an image/video request
    /// (`EngineV2VisionPrefill.PreparedSubmission.multimodalInput()` —
    /// spans over `promptTokens`' placeholder runs, embeddings already
    /// evaluated). nil ⇒ text request, byte-identical to the pre-multimodal
    /// path. Submit-time `CBv2MultimodalError` rejections surface as
    /// `multimodal_rejected: …` stream errors (→ 400). `mediaKind`
    /// (image/video/mixed) tags the engagement telemetry only — it never
    /// affects submission behavior.
    public func submitTokenized(
        promptTokens: [Int],
        request: ChatCompletionRequest,
        requestId: String? = nil,
        cacheScope: String = "",
        cacheEnabled: Bool = true,
        logprobsChannel: EngineV2LogprobsChannel? = nil,
        usageSignal: EngineV2RequestUsageSignal? = nil,
        multimodal: CBv2MultimodalInput? = nil,
        positionState: CBv2PositionState? = nil,
        mediaKind: EngineV2MediaKind? = nil,
        tokenConstraint: (any CBv2TokenConstraint)? = nil
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
            usageSignal?.finalizeLookup(
                failure: .policy,
                fallbackTier: ssdPrefixCache == nil ? .memory : .ssd)
            continuation.yield(.error("token_budget_exhausted: duplicate request ID"))
            continuation.finish()
            return stream
        }

        // Prefill deadline admission. Under FCFS prefill serialization every
        // row ahead of this one finishes before it starts, so this request's
        // time-to-first-token is the whole prefill queue, not its own prompt.
        // Admitting a row that cannot make the consumer's TTFT budget converts
        // a servable request into a timeout; refusing it yields the canonical
        // queue-full string, which the coordinator classifies as retryable and
        // re-dispatches to a different provider. Fails OPEN whenever the rate
        // is unmeasured, so a fresh process never refuses on a guess.
        if let refusal = prefillDeadlineRefusal(promptTokens: promptTokens.count) {
            usageSignal?.finalizeLookup(
                failure: .policy,
                fallbackTier: ssdPrefixCache == nil ? .memory : .ssd)
            continuation.yield(.error(refusal))
            continuation.finish()
            return stream
        }

        // Translate with a PLACEHOLDER engine id — the real id is minted
        // below, AFTER the shared-budget await, in the same synchronous
        // stretch as `engine.submit` and the `idMap` registration. Validate
        // total token arithmetic before minting cache tickets or staging.
        var cbv2Request = EngineV2Translation.cbv2Request(
            id: CBv2RequestID(0),
            promptTokens: promptTokens,
            request: request,
            defaultMaxTokens: defaultMaxTokens,
            stopTokenIds: stopTokenIds,
            cacheScope: cacheScope,
            cacheEnabled: cacheEnabled,
            multimodal: multimodal,
            tokenConstraint: tokenConstraint
        )
        cbv2Request.positionState = positionState ?? multimodal?.positionState
        let (worstCaseTokens, tokenCountOverflow) = promptTokens.count.addingReportingOverflow(
            cbv2Request.maxTokens)
        guard !tokenCountOverflow else {
            usageSignal?.finalizeLookup(
                failure: .capacity,
                fallbackTier: ssdPrefixCache == nil ? .memory : .ssd)
            continuation.yield(.error(
                "token_budget_exhausted: request token count overflow"))
            continuation.finish()
            return stream
        }

        // The SSD staging ticket must be submission-unique even when seeded
        // sampling intentionally reuses a deterministic engine request id.
        // Mint it before staging and pass the same identity through
        // CBv2Request.prefixCacheReceiptID so the engine's request-aware
        // lookup/endAdoption calls balance this exact ticket.
        let prefixCacheReceiptID: CBv2RequestID?
        var readyReceiptRegistered = false
        if cacheEnabled, multimodal == nil, let ssd = ssdPrefixCache {
            let receiptID = mintPrefixCacheReceiptID()
            prefixCacheReceiptID = receiptID
            if let callback = usageSignal?.onCacheReady {
                ssd.registerReadyReceipt(requestID: receiptID, callback: callback)
                readyReceiptRegistered = true
            }
        } else {
            prefixCacheReceiptID = nil
        }

        // PRE-SUBMIT SSD STAGING (v0.7.5 read-through adoption): probe the
        // SSD tier's index for this prompt's chain prefix and, on a hit
        // that clears the benefit gate, reserve the staged bytes in the
        // shared KV budget and rehydrate the blocks OFF the engine/submit
        // threads — so the engine's synchronous `lookup()` (inside
        // `engine.submit` below) finds them in the RAM staging map. A
        // false return is indistinguishable from a cache miss (silent
        // recompute). Every staged=true is balanced by the engine's own
        // `endAdoption` (fires on every adoption outcome, incl. abandon)
        // with `completeStaging` as the idempotent backstop on the paths
        // where lookup never ran (rejections below, pump terminals).
        // Vision requests never stage (engine policy symmetry).
        var ssdStaged = false
        var ssdReuseAttempted = false
        if !cacheEnabled {
            usageSignal?.recordCacheDisabled(tier: ssdPrefixCache == nil ? .memory : .ssd)
        } else if multimodal != nil {
            usageSignal?.finalizeLookup(
                failure: .policy,
                fallbackTier: ssdPrefixCache == nil ? .memory : .ssd)
        } else if let ssd = ssdPrefixCache, let prefixCacheReceiptID {
            let stageResult = await ssd.stage(
                requestID: prefixCacheReceiptID,
                promptTokens: promptTokens,
                cacheScope: cacheScope)
            usageSignal?.record(stageResult: stageResult)
            if case .skippedCapacity = stageResult.disposition {
                emitPrefixCacheColdFallback(
                    requestId: id,
                    reason: "stage_capacity",
                    capacityRefusal: true)
            }
            ssdStaged = stageResult.staged
            ssdReuseAttempted = stageResult.staged
            // `stage` suspended this actor — re-check the duplicate guard
            // (same discipline as the shared-budget gate below).
            guard active[id] == nil else {
                if ssdStaged { await ssd.abandonStaging(requestID: prefixCacheReceiptID) }
                if readyReceiptRegistered {
                    ssd.discardReadyReceipt(requestID: prefixCacheReceiptID)
                }
                usageSignal?.finalizeLookup(failure: .policy, fallbackTier: .ssd)
                continuation.yield(.error("token_budget_exhausted: duplicate request ID"))
                continuation.finish()
                return stream
            }
        }
        cbv2Request.prefixCacheReceiptID = prefixCacheReceiptID

        // SHARED-BUDGET ADMISSION GATE: reserve this request's worst-case KV
        // footprint (target KV plus fixed recurrent and block-rounded assistant
        // state for prompt + maxTokens)
        // in the process-wide ledger BEFORE handing the
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
        var sharedKVReserved = false
        // PAGED slots skip the per-request shared-KV reserve: the pool is
        // committed WHOLE at the slot's first admission (D1 —
        // `PagedKVSlabCommitment.atFirstAdmission`, wired inside
        // `PagedKVBackend.reserve`/`makeSequenceState`, which run downstream
        // of this gate), so from the first paged request onward it is
        // counted once — in MLX active memory (which the shared gate's
        // headroom probe reads) and in the model-load gates. A per-request
        // reservation on top would DOUBLE-count every paged request against
        // headroom the pool has already claimed and collapse the gate to
        // zero. Admission for paged requests is the engine's own ledger
        // (`AdmissionV2`) + the pool's atomic worst-case page charge, with
        // the capacity-requeue backstop.
        //
        // Residual window, deliberately accepted: between a paged slot's
        // build and its first admission the pool is a logical grant with no
        // residency, so a CONCURRENT contiguous request on a co-resident
        // slot can see up to `capacityBytes` more live headroom than the box
        // will have once this slot goes hot. That is exactly the posture a
        // loaded-but-idle CONTIGUOUS slot has always had — its grant is
        // equally invisible to this probe — and the gate re-probes live
        // headroom on every reserve, so the window closes the moment the
        // paged slot serves anything. Before D1 paged was stricter here and
        // paid for it by making the second model unloadable.
        if kvBackendKind == .contiguous, let kvBudget,
            (kvBytesPerToken > 0 || fixedRequestBytes > 0), cbv2Request.maxTokens > 0
        {
            sharedKVReserved = await reserveSharedRequestBytes(
                budget: kvBudget, requestID: id, tokenCount: worstCaseTokens)
            if !sharedKVReserved, ssdStaged, let prefixCacheReceiptID {
                // Optional adoption may be the only reason R no longer fits:
                // retire S synchronously, then retry the full cold request R.
                await ssdPrefixCache?.abandonStaging(requestID: prefixCacheReceiptID)
                ssdStaged = false
                sharedKVReserved = await reserveSharedRequestBytes(
                    budget: kvBudget, requestID: id, tokenCount: worstCaseTokens)
                if sharedKVReserved {
                    emitPrefixCacheColdFallback(
                        requestId: id,
                        reason: "shared_kv_capacity",
                        capacityRefusal: true)
                }
            }
            guard sharedKVReserved else {
                if ssdReuseAttempted {
                    emitPrefixCacheColdFallback(
                        requestId: id,
                        reason: "shared_kv_capacity",
                        capacityRefusal: true)
                }
                if let prefixCacheReceiptID {
                    if ssdStaged {
                        await ssdPrefixCache?.abandonStaging(requestID: prefixCacheReceiptID)
                    }
                    if readyReceiptRegistered {
                        ssdPrefixCache?.discardReadyReceipt(requestID: prefixCacheReceiptID)
                    }
                }
                usageSignal?.finalizeLookup(
                    failure: .capacity,
                    fallbackTier: ssdPrefixCache == nil ? .memory : .ssd)
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
                if let prefixCacheReceiptID {
                    if ssdStaged {
                        await ssdPrefixCache?.abandonStaging(requestID: prefixCacheReceiptID)
                    }
                    if readyReceiptRegistered {
                        ssdPrefixCache?.discardReadyReceipt(requestID: prefixCacheReceiptID)
                    }
                }
                usageSignal?.finalizeLookup(
                    failure: .policy,
                    fallbackTier: ssdPrefixCache == nil ? .memory : .ssd)
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
        guard let engine = ownedEngine else {
            if sharedKVReserved { await kvBudget?.release(requestID: id) }
            if let prefixCacheReceiptID {
                if ssdStaged {
                    await ssdPrefixCache?.abandonStaging(requestID: prefixCacheReceiptID)
                }
                if readyReceiptRegistered {
                    ssdPrefixCache?.discardReadyReceipt(requestID: prefixCacheReceiptID)
                }
            }
            usageSignal?.finalizeLookup(
                failure: .policy,
                fallbackTier: ssdPrefixCache == nil ? .memory : .ssd)
            continuation.yield(.error("request queue full: engine is shutting down"))
            continuation.finish()
            return stream
        }
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
            // A rejected submit also never ran the prefix-cache lookup, so
            // the engine can never balance the staging ticket — backstop it.
            if sharedKVReserved { await kvBudget?.release(requestID: id) }
            if let prefixCacheReceiptID {
                if ssdStaged {
                    await ssdPrefixCache?.abandonStaging(requestID: prefixCacheReceiptID)
                }
                if readyReceiptRegistered {
                    ssdPrefixCache?.discardReadyReceipt(requestID: prefixCacheReceiptID)
                }
            }
            usageSignal?.finalizeLookup(
                failure: Self.prefixCacheFailureClass(for: error),
                fallbackTier: ssdPrefixCache == nil ? .memory : .ssd)
            // Admission failure. The message keeps the canonical
            // `token_budget_exhausted:` prefix contract so
            // `fromSchedulerMessage` classifies it as a retryable capacity
            // error (429/503) exactly as the legacy engine's rejections.
            continuation.yield(.error(EngineV2Translation.admissionErrorMessage(for: error)))
            continuation.finish()
            return stream
        }

        // Evaluated BEFORE this row joins `active`, so it describes the
        // engine this row is entering, not one that already contains it.
        let uncontendedAtSubmit = !active.values.contains { $0.firstTokenAt == nil }
        active[id] = ActiveRequestState(
            promptTokens: promptTokens.count,
            maxTokens: cbv2Request.maxTokens,
            submittedAt: .now,
            uncontendedAtSubmit: uncontendedAtSubmit
        )
        idMap[id] = cbv2Id
        // Wedge instrumentation: the request is now in the engine's hands.
        wedgeMonitor.recordAdmit(now: .now)

        // Media-through-v2 engagement signal (v0.7.5; media-kind tagged
        // since v0.7.5): one INFO per media request the engine ACCEPTED,
        // tagged `multimodal=true` + `media_kind` on the existing engine_v2
        // fields so prod adoption per media shape is observable next to the
        // `engine_v2_vision_refusal` ERRORs. Allowlisted fields only.
        if multimodal != nil {
            emitVisionSubmitTelemetry(requestId: id, mediaKind: mediaKind)
        }

        runPump(
            id: id, events: events, continuation: continuation,
            holdsSharedReservation: sharedKVReserved,
            stopSequences: cbv2Request.stopStrings,
            logprobsChannel: logprobsChannel,
            usageSignal: usageSignal,
            prefixCacheReceiptID: prefixCacheReceiptID,
            readyReceiptRegistered: readyReceiptRegistered
        )

        let bridge = self
        continuation.onTermination = { @Sendable termination in
            if case .cancelled = termination {
                Task { await bridge.cancel(requestId: id) }
            }
        }
        return stream
    }

    private func reserveSharedRequestBytes(
        budget: GlobalKVCacheBudget, requestID: String, tokenCount: Int
    ) async -> Bool {
        guard let total = requestReservationBytes(tokenCount: tokenCount), total > 0 else {
            return false
        }
        return await budget.reserveBytes(requestID: requestID, bytes: UInt64(total))
    }

    func requestReservationBytes(tokenCount: Int) -> Int? {
        guard tokenCount >= 0 else { return nil }
        let targetRate = max(0, kvBytesPerToken - auxiliaryBytesPerToken)
        let (targetBytes, targetOverflow) = targetRate.multipliedReportingOverflow(
            by: tokenCount)
        let (paddedTokens, paddingOverflow) = tokenCount.addingReportingOverflow(
            auxiliaryTokenAllocationPadding)
        guard !targetOverflow, !paddingOverflow else { return nil }
        let auxiliaryTokens: Int
        if auxiliaryBytesPerToken == 0 || paddedTokens == 0 {
            auxiliaryTokens = 0
        } else {
            let (bumped, bumpOverflow) = paddedTokens.addingReportingOverflow(
                auxiliaryTokenGranularity - 1)
            guard !bumpOverflow else { return nil }
            auxiliaryTokens = (bumped / auxiliaryTokenGranularity)
                * auxiliaryTokenGranularity
        }
        let (auxiliaryBytes, auxiliaryOverflow) = auxiliaryBytesPerToken
            .multipliedReportingOverflow(by: auxiliaryTokens)
        guard !auxiliaryOverflow else { return nil }
        let (variableBytes, variableOverflow) = targetBytes.addingReportingOverflow(
            auxiliaryBytes)
        let (total, totalOverflow) = variableBytes.addingReportingOverflow(fixedRequestBytes)
        return variableOverflow || totalOverflow ? nil : total
    }

    func maximumRequestOverheadBytes() -> Int? {
        let (extraAuxiliaryTokens, tokenOverflow) = (auxiliaryTokenGranularity - 1)
            .addingReportingOverflow(auxiliaryTokenAllocationPadding)
        guard !tokenOverflow else { return nil }
        let (auxiliaryOverhead, auxiliaryOverflow) = auxiliaryBytesPerToken
            .multipliedReportingOverflow(by: max(0, extraAuxiliaryTokens))
        let (total, totalOverflow) = fixedRequestBytes.addingReportingOverflow(
            auxiliaryOverhead)
        return auxiliaryOverflow || totalOverflow ? nil : total
    }

    // MARK: - Cancel / shutdown

    /// Cancel by provider request-id. Prompt per the v2 contract: the
    /// in-flight step completes and the row is dropped O(1); the engine
    /// then delivers `.finished(.cancelled)` on the request's stream,
    /// which drives the normal bookkeeping/teardown in the pump.
    public func cancel(requestId: String) {
        guard let cbv2Id = idMap[requestId] else { return }
        ownedEngine?.cancel(cbv2Id)
    }

    // MARK: - Runtime KV re-slicing / slot bookkeeping

    /// Update this SLOT's total KV claim (multi-model co-residency
    /// re-slicing). `bytes` is the slot's re-sliced TOTAL grant; the
    /// construction-fixed prefix-cache budget (T-041) is netted out here —
    /// one translation point for every reslice caller — and the ENGINE's
    /// admission ceiling absorbs the whole delta. Fans out to the engine
    /// (`AdmissionV2` + backend + capacity gauges — see
    /// `EngineV2.updateKVBytesCapacity`): shrink leaves in-flight
    /// reservations untouched and fails new admissions until the pool
    /// drains; grow admits immediately. The engine's `capacity()` snapshot
    /// reflects the new ceiling right away, so heartbeats and later
    /// re-slices (which read `slotKVBytesClaim()` — engine + cache budget)
    /// see the CURRENT grant. A zero RAM carve, including the default SSD
    /// mode, makes this the identity mapping.
    ///
    /// Callers never hand a total below the cache budget: load-time
    /// re-slices refuse such targets at the serviceability floor
    /// (`resliceMeetsServiceabilityFloor(_:fixedCarveBytes:)`), so the
    /// `max(0, …)` clamp is defensive only.
    ///
    /// PAGED slots (`kvBackendKind == .paged`): the physically preallocated
    /// page pool neither shrinks nor grows (`updateBytesCapacity` is a no-op
    /// on the backend). The admission ledger is clamped to that immutable
    /// physical capacity on every resize, so logical admission, heartbeat
    /// reporting, and page placement agree. A SHRINK tightens admission but
    /// does NOT reclaim physical memory; callers must never count it as
    /// freed. A later GROW can restore admission only up to the same pool.
    /// Reclaiming or adding physical bytes requires an unload/rebuild.
    ///
    /// Neither residue is silent any more: the pre-clamp target is recorded
    /// and the difference is published as a `PagedPoolResizeShortfall`
    /// (accessor + `paged_pool_resize_clamped` telemetry). Multi-model boxes
    /// need it — a paged slot sized against the box as it looked at ITS load
    /// instant is otherwise indistinguishable from one holding its fair
    /// share.
    public func updateKVBytesCapacity(_ bytes: Int) {
        let requested = max(0, bytes)
        guard let engine = ownedEngine else { return }
        guard kvBackendKind == .paged else {
            engine.updateKVBytesCapacity(requested)
            return
        }
        lastRequestedKVBytesCapacity = requested
        // `kvBytesBackendCapacity == 0` means UNKNOWN, never "no pool" — the
        // `CBv2CapacitySnapshot` contract says so in as many words. Clamping
        // to it would pin this slot's admission ledger at ZERO for the rest
        // of its life: the loaded-but-unserveable black hole the post-load
        // guard exists to prevent, reached through a legal contract state.
        // An unknown pool therefore does not bind, exactly as
        // `backendSlotCapacity` already refuses to bind the heartbeat.
        let physical = engine.capacity().kvBytesBackendCapacity
        guard physical > 0 else {
            engine.updateKVBytesCapacity(requested)
            return
        }
        engine.updateKVBytesCapacity(min(requested, physical))
        publishPagedPoolResizeShortfall(
            PagedPoolResizeShortfall(poolBytes: physical, requestedBytes: requested))
    }

    /// Record the slot's cold-start load time for heartbeat reporting
    /// (`model_load_time_ms`) — slot-level bookkeeping, previously held by
    /// the legacy scheduler.
    public func recordModelLoadTime(ms: Int64) {
        modelLoadTimeMs = max(0, ms)
    }

    /// The slot's PHYSICAL KV capacity (paged: the committed pool;
    /// contiguous: the admission ceiling). Input to the post-build
    /// serveable-KV guard (`KVHeadroomProbe.postBuildServeable`).
    public func kvBackendPoolBytes() -> UInt64 {
        UInt64(max(0, capacitySnapshot().kvBytesBackendCapacity))
    }

    /// What this slot's construction-fixed paged pool could not do for the
    /// re-slicer's most recent grant. nil on a contiguous slot, on a paged
    /// slot whose pool capacity is UNKNOWN, and before the first re-slice
    /// (a freshly-built slot's ceiling IS its pool).
    public func pagedPoolResizeShortfall() -> PagedPoolResizeShortfall? {
        guard kvBackendKind == .paged, let requested = lastRequestedKVBytesCapacity else {
            return nil
        }
        let pool = capacitySnapshot().kvBytesBackendCapacity
        guard pool > 0 else { return nil }
        return PagedPoolResizeShortfall(poolBytes: pool, requestedBytes: requested)
    }

    /// Publish a change in the paged resize residue as `engine_health` /
    /// `operation=paged_pool_resize_clamped`. WARN while a residue exists,
    /// INFO on the edge back to exact. Off the inference hot path (the
    /// re-slicer runs at model load/unload only) and carries aggregate pool
    /// arithmetic exclusively — every key is already in the coordinator's
    /// allowlist, and the filter is applied so a future key cannot leak.
    ///
    /// DELIBERATELY NOT `pool_utilization`. That key is defined fleet-wide as
    /// OCCUPANCY (`bytesInUse / bytesCapacity`, produced by
    /// `engine_v2_slot_posture` in `EngineV2Bridge+MTP.swift`), and this
    /// event's grant-vs-pool ratio is a different quantity on the same
    /// population — both are paged slots tagged `kv_backend=paged`, so
    /// `avg(pool_utilization) by kv_backend` would blend them into noise.
    /// That is the `backend`-overloading defect recurring, so the ratio is
    /// not emitted here at all.
    ///
    /// RULED (Main, wave 2): this event carries RAW BYTES, never a second
    /// ratio. A second `*_utilization` key was rejected — `min(a, b) / b`
    /// clamps to 1.0 exactly when the fair share exceeds the pool, which is
    /// the case co-residency exists to diagnose, so the magnitude vanishes
    /// at the only moment it matters. Bytes compose: a consumer can sum,
    /// diff, threshold, and derive the ratio from them; nothing recovers
    /// bytes from a clamped ratio. The binding condition is that the ratio
    /// stay DERIVABLE, so the denominator ships with the delta:
    /// `pool_bytes` + `pool_deferred_growth_bytes` + `pool_stranded_bytes`.
    ///
    /// All three keys are mirrored (Go `telemetry_handlers.go`, Swift
    /// `TelemetryEvent.swift`, TS `telemetry-types.ts`) and are emitted
    /// TOGETHER. `pool_bytes` is the denominator and must never ship without
    /// the deltas, nor they without it: `TelemetryFieldFilter` drops
    /// unmirrored keys SILENTLY, so a partial set would look healthy at the
    /// producer and arrive uninterpretable.
    ///
    /// `pool_stranded_bytes` is the fleet-visible diagnostic for the
    /// co-residency admission defect — paged commits slabs per slot at
    /// construction, so on a memory-tight box a later slot measures too
    /// little headroom against the load minimum and 503s where an
    /// all-contiguous box would have served. Without this number that
    /// reaches the fleet as a mystery 503.
    private func publishPagedPoolResizeShortfall(_ shortfall: PagedPoolResizeShortfall) {
        guard shortfall != lastPagedShortfallEmitted else { return }
        // Nothing to report when a slot has been exact all along.
        if shortfall.isExact, lastPagedShortfallEmitted == nil { return }
        lastPagedShortfallEmitted = shortfall
        let reason: String
        if shortfall.deferredGrowthBytes > 0 {
            reason = "deferred_grow"
        } else if shortfall.strandedBytes > 0 {
            reason = "unreclaimed_shrink"
        } else {
            reason = "exact"
        }
        emit(
            EngineHealthEvent.make(
                severity: shortfall.isExact ? .info : .warn,
                message: shortfall.isExact
                    ? "engine_v2: paged pool matches the re-sliced grant"
                    : "engine_v2: paged pool cannot follow the re-sliced grant "
                        + "(pool \(shortfall.poolBytes) B vs grant \(shortfall.requestedBytes) B)",
                operation: "paged_pool_resize_clamped",
                model: modelId,
                // Literal "paged": this event only exists for a paged pool, so
                // it is a fact about the code path, not a read of this slot.
                kvBackend: EngineV2KVBackendKind.paged.rawValue,
                extra: [
                    "reason": .string(reason),
                    "pool_bytes": .int(shortfall.poolBytes),
                    "pool_deferred_growth_bytes": .int(shortfall.deferredGrowthBytes),
                    "pool_stranded_bytes": .int(shortfall.strandedBytes),
                ]))
    }

    /// Runtime fan-out helper: cancel iff this bridge owns the request-id.
    func cancelIfOwned(requestId: String) -> Bool {
        guard let cbv2Id = idMap[requestId], let engine = ownedEngine else { return false }
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
        let statsTask = prefixCacheStatsTask
        prefixCacheStatsTask = nil
        statsTask?.cancel()
        slotPostureTask?.cancel()
        slotPostureTask = nil
        let live = pumpTasks
        pumpTasks.removeAll()
        for task in live.values { task.cancel() }
        if let engine = ownedEngine {
            await engine.shutdown()
        }
        for task in live.values {
            await task.value
        }
        _ = await statsTask?.value
        // The bridge may remain in a local teardown variable; explicitly drop
        // the concrete engine so target and assistant ownership does not.
        ownedEngine = nil
        prefixCacheEvidenceSequencer?.shutdown()
        // SSD tier teardown AFTER the engine drain: queued donation writes
        // are dropped, staging pins/reservations released, on-disk files
        // KEPT — durable warmth across unload/restart is the feature.
        await ssdPrefixCache?.closeAndWait()
    }

    /// Deterministic timing seam for prefill-sampling tests.
    func backdateSubmissionForTesting(requestId: String, byMilliseconds milliseconds: Int64) {
        guard var state = active[requestId] else { return }
        state.submittedAt = state.submittedAt.advanced(by: .milliseconds(-milliseconds))
        active[requestId] = state
    }

    // MARK: - Event pump (CBv2Event → GenerationEvent)

    private func runPump(
        id: String,
        events: AsyncStream<CBv2Event>,
        continuation: AsyncStream<GenerationEvent>.Continuation,
        holdsSharedReservation: Bool,
        stopSequences: [String] = [],
        logprobsChannel: EngineV2LogprobsChannel? = nil,
        usageSignal: EngineV2RequestUsageSignal? = nil,
        prefixCacheReceiptID: CBv2RequestID? = nil,
        readyReceiptRegistered: Bool = false
    ) {
        let bridge = self
        let task = Task {
            await bridge.pump(
                id: id, events: events, continuation: continuation,
                holdsSharedReservation: holdsSharedReservation,
                stopSequences: stopSequences,
                logprobsChannel: logprobsChannel,
                usageSignal: usageSignal,
                prefixCacheReceiptID: prefixCacheReceiptID,
                readyReceiptRegistered: readyReceiptRegistered
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
        stopSequences: [String] = [],
        logprobsChannel: EngineV2LogprobsChannel? = nil,
        usageSignal: EngineV2RequestUsageSignal? = nil,
        prefixCacheReceiptID: CBv2RequestID? = nil,
        readyReceiptRegistered: Bool = false
    ) async {
        // NOTE: the shared-budget KV reservation is taken in `submitTokenized`
        // (the pre-engine admission gate), NOT here — the pump only RELEASES
        // it on the terminal/teardown paths below, and ONLY when THIS request
        // took one (`holdsSharedReservation`): an unconditional release could
        // drop a same-keyed reservation owned by a different submission in
        // the pathological duplicate-id corner.
        var sawFirstToken = false
        var sawTerminal = false
        var generatedTokens: [Int] = []
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
                if !stopSequences.isEmpty {
                    // EngineLoopV2 suppresses stop-token text before the
                    // stop-string holdback sees it. Exclude those raw tokens
                    // from replay too, or an EOS token whose debug rendering
                    // equals a caller sequence would become a false match.
                    generatedTokens.append(
                        contentsOf: tokens.filter { !stopTokenIds.contains($0) })
                }
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
                if reason == .stop || reason == .length {
                    usageSignal?.record(matchedStopSequence: matchedStopSequence(
                        candidates: stopSequences,
                        generatedTokens: generatedTokens
                    ))
                }
                // Out-of-band usage detail (logprobs-channel pattern): the
                // engine's prefix-cache detail has no seat in the shared
                // `GenerationEvent.info` shape, so the frames loop reads it
                // from this per-request signal and splices
                // `usage.prompt_tokens_details.cached_tokens` into the
                // trailing SSE usage chunk. Recorded BEFORE the terminal
                // events are yielded, so it is set by the time any
                // downstream consumer sees the usage frame.
                usageSignal?.record(
                    usage: usage,
                    fallbackTier: ssdPrefixCache == nil ? .memory : .ssd)
                ssdPrefixCache?.recordPrefillTokensSaved(
                    usage.prefixCachePrefillTokensSaved)
                emitPrefixReuseTelemetry(requestId: id, usage: usage)
                finishAndEmit(
                    id: id, reason: reason, usage: usage,
                    sawFirstToken: sawFirstToken, continuation: continuation
                )
                // Release the shared-budget KV reservation on the terminal
                // (only when this request took one; release is idempotent).
                if holdsSharedReservation {
                    await kvBudget?.release(requestID: id)
                }
                // SSD staging backstop: usually a no-op (the engine's
                // endAdoption already balanced the ticket at adoption
                // time); covers the lookup-missed corner. Idempotent.
                if let prefixCacheReceiptID {
                    ssdPrefixCache?.completeStaging(requestID: prefixCacheReceiptID)
                }
                if readyReceiptRegistered, let prefixCacheReceiptID {
                    ssdPrefixCache?.markReadyReceiptTerminal(
                        requestID: prefixCacheReceiptID)
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
            if let prefixCacheReceiptID {
                ssdPrefixCache?.completeStaging(requestID: prefixCacheReceiptID)
            }
            usageSignal?.finalizeLookup(
                failure: .policy,
                fallbackTier: ssdPrefixCache == nil ? .memory : .ssd)
            if readyReceiptRegistered, let prefixCacheReceiptID {
                ssdPrefixCache?.markReadyReceiptTerminal(
                    requestID: prefixCacheReceiptID)
            }
            continuation.finish()
        }
    }

    private static func prefixCacheFailureClass(
        for error: Error
    ) -> PrefixCacheLookupFailureClass {
        error is CBv2KVError ? .capacity : .policy
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
        case .terminal(let cbCause, let message):
            // Typed platform/engine terminal (a monotonic deadline lease or
            // the step watchdog). Reconcile usage the same way as any other
            // non-natural finish, then carry BOTH the machine-readable cause
            // AND that usage through — instead of flattening the deadline into
            // a generic string with zero usage (the incident behavior).
            let final = recordFinish(id: id, usage: usage, success: false)
            emitInferenceErrorTelemetry(requestId: id)
            if let wireCause = Self.wireTerminalCause(cbCause) {
                continuation.yield(.terminal(
                    cause: wireCause,
                    message: message,
                    promptTokens: final.prompt,
                    completionTokens: final.completion))
            } else {
                // No wire mapping (the `.legacyRequestTimeout` kill-switch, or
                // any future engine cause): fall back to the legacy string
                // shape byte-for-byte — never guess a typed cause.
                continuation.yield(.error(message))
            }
        case .error(let message):
            _ = recordFinish(id: id, usage: usage, success: false)
            emitInferenceErrorTelemetry(requestId: id)
            if message.hasPrefix(CBv2KVError.capacityExhaustedFinishPrefix) {
                // Engine-side TERMINAL capacity exhaustion (the paged pool
                // stayed full through the whole requeue budget). Retryable
                // by definition — the backend is full of other tenants'
                // KV, not broken — so surface the canonical capacity
                // marker (429-class, the OpenRouter never-serve-5xx
                // posture), never an in-band server error.
                continuation.yield(.error(
                    "token_budget_exhausted: KV capacity exhausted after "
                        + "requeues (\(message))"))
            } else {
                continuation.yield(.error(message))
            }
        }
        if !sawFirstToken {
            wedgeMonitor.recordTerminalWithoutFirstToken()
        }
    }

    /// Map an engine terminal cause to its wire vocabulary, or nil when there
    /// is no mapping (the request then falls back to the legacy `.error(String)`
    /// shape — NEVER guess a cause). Only the six lease/watchdog causes have a
    /// wire mapping; `.legacyRequestTimeout` (the rollback kill-switch) and any
    /// future engine case stay untyped, matching the pre-fix behavior exactly.
    private static func wireTerminalCause(
        _ cause: CBv2TerminalCause
    ) -> InferenceTerminalCause? {
        switch cause {
        case .admissionTimeout: return .admissionTimeout
        case .prefillStall: return .prefillStall
        case .decodeStall: return .decodeStall
        case .safetyDeadline: return .safetyDeadline
        case .backpressureTimeout: return .backpressureTimeout
        case .watchdog: return .watchdog
        case .legacyRequestTimeout: return nil
        @unknown default: return nil
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
        if success {
            recordPrefillSample(
                promptTokens: prompt,
                usage: usage,
                submittedAt: state.submittedAt,
                firstTokenAt: state.firstTokenAt,
                uncontendedAtSubmit: state.uncontendedAtSubmit)
        }
        return (prompt, completion, tps)
    }

    // MARK: - Prefill deadline admission

    /// Consumer TTFT budget base (ms). Mirrors the coordinator's verified
    /// OpenRouter SLA base (`registry/ttft_shadow.go`
    /// `defaultTTFTDeadlineBaseMs`): observed cancels fit
    /// `10_000 ms + 1 ms x prompt_tokens` at a median ratio of 1.002.
    static let defaultPrefillDeadlineBaseMs = 10_000.0

    /// Override / kill switch. A non-positive value disables the gate and
    /// restores the accept-everything behaviour as the A/B control.
    static let prefillDeadlineBaseMsKey = "DARKBLOOM_PREFILL_DEADLINE_BASE_MS"

    static let resolvedPrefillDeadlineBaseMs: Double = {
        guard let raw = ProcessInfo.processInfo.environment[prefillDeadlineBaseMsKey],
            let value = Double(raw.trimmingCharacters(in: .whitespaces))
        else { return defaultPrefillDeadlineBaseMs }
        return value
    }()

    /// Pure verdict: can a row of `promptTokens` reach first token inside its
    /// own budget, given `queuedAheadTokens` of prefill still to run before it?
    ///
    /// Budget is `baseMs + 1 ms x promptTokens`. Separated from the bridge so
    /// the arithmetic is testable without an engine.
    /// Returns `nil` when the row fits or when the inputs cannot support a
    /// verdict (non-positive rate or disabled gate) — never refuse on a guess.
    static func prefillDeadlineProjection(
        queuedAheadTokens: Int,
        promptTokens: Int,
        prefillTps: Double,
        baseMs: Double
    ) -> (projectedMs: Double, budgetMs: Double)? {
        guard promptTokens > 0, prefillTps > 0, baseMs > 0 else { return nil }
        let projectedMs = Double(max(0, queuedAheadTokens) + promptTokens) / prefillTps * 1000.0
        let budgetMs = baseMs + Double(promptTokens)
        guard projectedMs > budgetMs else { return nil }
        return (projectedMs, budgetMs)
    }

    /// Prompt tokens still unprocessed on rows that have not reached first
    /// token. Elapsed time at the measured rate discounts what each has already
    /// consumed, so a nearly-drained queue does not refuse its successor.
    func queuedPrefillTokensAhead(now: ContinuousClock.Instant, prefillTps: Double) -> Int {
        guard prefillTps > 0 else { return 0 }
        var queued = 0
        for state in active.values where state.firstTokenAt == nil {
            let elapsed = WedgeMonitor.seconds(now - state.submittedAt)
            let consumed = elapsed > 0 ? Int((elapsed * prefillTps).rounded(.down)) : 0
            queued += max(0, state.promptTokens - consumed)
        }
        return queued
    }

    /// Refusal message for a row that cannot land in time, `nil` when it can
    /// (or when we cannot tell).
    func prefillDeadlineRefusal(promptTokens: Int) -> String? {
        // Queue-EXCLUDED rate: the projection adds `queuedAhead` explicitly,
        // so dividing by the load-inclusive `observedPrefillTpsEwma` would
        // count contention twice (~(K+1)/2 overestimate at depth K) and refuse
        // rows that fit. Unmeasured: admit — this EWMA is cold-prefill-fed AND
        // uncontended-fed, so it starts at 0 and stays 0 on a box that has
        // never seen an idle prefill. Gating on a guess would refuse real
        // traffic on a fresh process.
        let tps = isolatedPrefillTpsEwma
        guard tps > 0 else { return nil }
        let queuedAhead = queuedPrefillTokensAhead(now: .now, prefillTps: tps)
        guard let projection = Self.prefillDeadlineProjection(
            queuedAheadTokens: queuedAhead,
            promptTokens: promptTokens,
            prefillTps: tps,
            baseMs: Self.resolvedPrefillDeadlineBaseMs)
        else { return nil }
        return "token_budget_exhausted: request queue full, prefill deadline "
            + "(projected \(Int(projection.projectedMs)) ms over budget "
            + "\(Int(projection.budgetMs)) ms; \(queuedAhead) prompt tokens "
            + "queued at \(Int(tps)) tok/s)"
    }

    // MARK: - Prefill sampling (observed_prefill_tps)

    /// Minimum submit→first-token window (seconds) for a prefill sample to
    /// count. A near-zero window (scripted engines, degenerate prompts)
    /// divides into an absurd rate; 1 ms is far below any real cold
    /// prefill. Same floor as the legacy classifier (PR #454 lineage).
    static let minPrefillWindowSeconds = 0.001

    /// Upper plausibility bound (tok/s) for a prefill sample — PR #454's
    /// raised ceiling: above the MEASURED real-prefill p90 (~17,707 tok/s,
    /// docs/reports/2026-06-22-live-prefill-tps-check.md) so a legitimately
    /// fast cold prefill registers, finite so a window-collapse artifact is
    /// still rejected.
    static let maxPlausiblePrefillTps = 20_000.0

    /// Classify one prefill sample against the plausibility bounds. Pure —
    /// mirrors `BatchScheduler.classifyPrefillSample`'s floor/ceiling shape
    /// with the v2 measurement (window = first token − SUBMIT: the bridge
    /// owns both timestamps, so no engine prefill-start marker is needed;
    /// under load the window includes engine queue wait, making this the
    /// same load-inclusive observed rate the decode EWMA reports).
    static func classifyPrefillSample(
        prefilledTokens: Int, prefillSeconds: Double
    ) -> Double? {
        guard prefilledTokens > 0 else { return nil }
        guard prefillSeconds >= minPrefillWindowSeconds else { return nil }
        let tps = Double(prefilledTokens) / prefillSeconds
        guard tps.isFinite, tps <= maxPlausiblePrefillTps else { return nil }
        return tps
    }

    /// Feed the prefill EWMA (α = 0.3, mirroring the decode EWMA) from a
    /// successful request's timing only when terminal engine usage proves the
    /// request performed a cold prefill. Cache hits have a different latency
    /// distribution and must never calibrate the coordinator's cold TTFT model.
    private func recordPrefillSample(
        promptTokens: Int,
        usage: CBv2Usage,
        submittedAt: ContinuousClock.Instant,
        firstTokenAt: ContinuousClock.Instant?,
        uncontendedAtSubmit: Bool
    ) {
        guard Self.isColdPrefillSample(usage: usage) else { return }
        guard let firstTokenAt else { return }
        let prefillSeconds = WedgeMonitor.seconds(firstTokenAt - submittedAt)
        guard
            let tps = Self.classifyPrefillSample(
                prefilledTokens: promptTokens, prefillSeconds: prefillSeconds)
        else { return }
        let alpha = 0.3
        if prefillEwmaInitialized {
            observedPrefillTpsEwma = alpha * tps + (1 - alpha) * observedPrefillTpsEwma
        } else {
            observedPrefillTpsEwma = tps
            prefillEwmaInitialized = true
        }
        // Queue-excluded companion: same sample, but only when nothing was
        // prefilling ahead of this row. Drives the admission projection.
        guard uncontendedAtSubmit else { return }
        if isolatedPrefillEwmaInitialized {
            isolatedPrefillTpsEwma = alpha * tps + (1 - alpha) * isolatedPrefillTpsEwma
        } else {
            isolatedPrefillTpsEwma = tps
            isolatedPrefillEwmaInitialized = true
        }
    }

    static func isColdPrefillSample(usage: CBv2Usage) -> Bool {
        guard usage.prefixCacheOutcome != .hit else { return false }
        return max(
            usage.prefixCacheHitTokens,
            usage.prefixCacheMatchedTokens,
            usage.prefixCachePrefillTokensSaved
        ) <= 0
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

    /// Media-through-v2 engagement (v0.7.5; media-kind tagged since
    /// v0.7.5): INFO per engine-accepted image/video request. PRIVACY:
    /// allowlisted operational fields only — the request's media/prompt
    /// content never rides telemetry; `multimodal` is a bare boolean tag
    /// and `media_kind` is one of image/video/mixed.
    private func emitVisionSubmitTelemetry(requestId: String, mediaKind: EngineV2MediaKind?) {
        var event = TelemetryEvent(
            source: .provider,
            severity: .info,
            kind: .engineHealth,
            message: "engine_v2: media request served via ContinuousBatchingV2"
        )
        // Filter-at-source, matching the other engine_health builders —
        // every key is allowlisted already; the filter enforces it stays so.
        var fields: [String: AnyCodableValue] = [
            "component": .string("engine"),
            "operation": .string("engine_v2_vision"),
            "backend": .string("engine_v2"),
            "model": .string(modelId),
            "multimodal": .bool(true),
        ]
        if let mediaKind {
            fields["media_kind"] = .string(mediaKind.rawValue)
        }
        event.fields = TelemetryFieldFilter.filter(fields)
        event.requestId = requestId
        emit(event)
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
    /// client (production). The rule itself lives in `emitEngineHealth` so the
    /// static builders in `EngineV2Config` / `EngineV2SlotFactory`, which have
    /// no bridge to call, cannot drift from it.
    func emit(_ event: TelemetryEvent) {
        emitEngineHealth(event, sink: emitTelemetry)
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

    /// Monotonic correlation identity for one receipt-enabled submission.
    /// It is deliberately independent of `mintEngineRequestId`: seeded engine
    /// ids may repeat after terminal for deterministic sampling, while receipt
    /// callbacks remain retained for the coordinator settlement window.
    private func mintPrefixCacheReceiptID() -> CBv2RequestID {
        let id = CBv2RequestID(nextPrefixCacheReceiptRawId)
        nextPrefixCacheReceiptRawId &+= 1
        return id
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

    /// Live provider request-ids (live co-residency test cancels by id).
    func _testActiveRequestIds() -> [String] { Array(active.keys) }

    /// Snapshot of internal counters for unit assertions.
    func _testCounters() -> (active: Int, admits: Int, firstTokens: Int) {
        (active.count, wedgeMonitor.admits, wedgeMonitor.firstTokens)
    }

    /// The engine request-id minted for a provider request-id, if active.
    func _testEngineRequestId(for requestId: String) -> CBv2RequestID? {
        idMap[requestId]
    }
}
