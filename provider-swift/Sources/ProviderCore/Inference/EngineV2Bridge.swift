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

/// One-way handoff flag shared by submit defers and the detached retirement
/// owner. Once claimed, the submit path must leave provider/engine IDs and
/// resource reservations intact for that owner to release exactly once.
private final class EngineV2RetirementTransfer: @unchecked Sendable {
    private let lock = NSLock()
    private var transferred = false

    func claim() -> Bool {
        lock.withLock {
            guard !transferred else { return false }
            transferred = true
            return true
        }
    }

    var isClaimed: Bool {
        lock.withLock { transferred }
    }
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
    /// Operational control for atomic first-token deadline admission.
    /// Parsed once per bridge so runtime behavior cannot change mid-request.
    let prefillDeadlineMode: PrefillDeadlineMode
    /// Whether the configured scheduler posture can produce the bounded,
    /// authoritative first-token projection required by atomic admission.
    /// Production enables this only for serialized partial prefill (cap 1).
    /// Explicit cap 0/unlimited therefore keeps serving through ordinary
    /// submission while the hard absolute-expiry checks remain authoritative.
    let prefillDeadlineProjectionEnabled: Bool
    /// Resolved `DARKBLOOM_CBV2_MAX_PARTIAL_PREFILLS` cap the engine was built
    /// with (nil = unlimited). Reported per request as the profiler's
    /// `partial_prefill_cap`; never consulted for any decision here.
    let partialPrefillCap: Int?
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
        /// The row carries media blocks. Any such peer makes the engine's
        /// first-token projection `.unbounded` for EVERY later text arrival
        /// (`FirstTokenDeadlineAdmissionV2`: a multimodal peer row cannot be
        /// priced), so deadline admission fails open while one is active.
        var isMultimodal = false
        /// True only when no other bridge row (prefill or decode) and no other
        /// provider/engine submission existed at this request's exact
        /// engine-submit boundary.
        var isolatedPrefillSampleEligible: Bool
        var completionTokens: Int = 0
        var submittedAt: ContinuousClock.Instant
        var firstTokenAt: ContinuousClock.Instant?
        var firstEmissionTokens: Int = 0
        /// Profiler accumulator (coordinator requests only). Written at
        /// first token, cancel, and finish — never per token.
        var profile: RequestProfileBuilder? = nil
    }

    var active: [String: ActiveRequestState] = [:]
    /// Profiler: Σ `promptTokens` of requests inside `submitTokenized`
    /// (validated but not yet returned from engine submission). Heartbeat
    /// `telemetry.queued_prefill_tokens`; per-request
    /// `queued_prefill_tokens_at_admit` reports the OTHER requests' share.
    var queuedPrefillTokens = 0
    /// Profiler: cumulative Σ(prompt − cached) over finished requests
    /// (heartbeat `telemetry.prefill_tokens_total`; attributed at finish).
    var prefillTokensTotal: Int64 = 0
    /// IDs that have passed bridge validation but have not yet completed
    /// engine admission. Atomic deadline submission suspends this actor; this
    /// guard prevents a reentrant duplicate from acquiring resources or
    /// reaching the engine during that suspension.
    var pendingSubmissionIDs: Set<String> = []
    /// Provider cancellations that arrive while atomic engine admission has
    /// suspended this actor. The marker survives an early engine-cancel miss
    /// and is consumed only after pre-submit cleanup or queue acknowledgement.
    var pendingCancellationIDs: Set<String> = []
    /// Profiler identity for submissions that are pending engine admission
    /// (between `pendingSubmissionIDs.insert` and the row landing in
    /// `active`). A coordinator cancel arrives under the coordinator id and
    /// is matched by profile identity; without this map a cancel that lands
    /// while `engine.submit` is suspended would be invisible to the
    /// `tokens_after_cancel` snapshot. Removed wherever the pending id is.
    var pendingProfiles: [String: RequestProfileBuilder] = [:]
    #if DEBUG
    /// TEST SEAM (debug builds only): awaited once right after the pending id
    /// is registered so a test can interleave a cancel with a suspended
    /// submission. nil unless a test installed it (no suspension).
    var _testPreSubmitGate: (@Sendable () async -> Void)?
    #endif
    /// Engine identities reserved across async atomic admission. Provider
    /// request IDs are distinct: two concurrent deterministic seeded requests
    /// can have different provider IDs but derive the same engine ID.
    var pendingEngineIDs: Set<CBv2RequestID> = []
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
    ///
    /// STORAGE (kept under the historical name so the heartbeat and every
    /// reader stay untouched): the current rate ΣP/Σt over exponentially
    /// decayed samples (`prefillSampleDecay` per sample — the same memory as
    /// the α = 0.3 per-request EWMA it replaces). Token-weighted: a 16K
    /// prompt weighs 80× a 200-token one, so the rate long prompts are
    /// projected against is the one long prompts measured; a per-request
    /// EWMA let a fleet of short prompts (fixed overhead inside every window)
    /// drag the rate to a fraction of the chip's capability.
    var observedPrefillTpsEwma: Double = 0
    var prefillEwmaInitialized = false
    var observedPrefillTokensSum: Double = 0
    var observedPrefillSecondsSum: Double = 0
    /// Queue- and decode-excluded cold-prefill service rate used ONLY by
    /// atomic scheduler deadline projection. A sample is eligible only when
    /// no other request of any phase is active or pending at its exact submit
    /// boundary. Mixed decode work is priced separately; it must never be
    /// hidden inside this prefill denominator. Same decayed ΣP/Σt storage as
    /// `observedPrefillTpsEwma`.
    var isolatedPrefillTpsEwma: Double = 0
    var isolatedPrefillEwmaInitialized = false
    var isolatedPrefillTokensSum: Double = 0
    var isolatedPrefillSecondsSum: Double = 0
    /// Dispersion of the isolated rate: decayed mean (α = 0.3) of each new
    /// sample's absolute deviation from the rate that would have projected
    /// it, |sample/rate − 1|. Sets the projection haircut.
    var isolatedPrefillDispersion: Double = 0
    var isolatedPrefillDispersionInitialized = false
    /// Per-sample decay of the (ΣP, Σt) pairs: 0.7 ⇒ the same effective
    /// memory as an α = 0.3 EWMA.
    static let prefillSampleDecay = 0.7
    /// Isolated cold samples folded into `isolatedPrefillTpsEwma` so far.
    /// Deadline projection is enforced only once `isolatedPrefillSampleFloor`
    /// samples exist: the FIRST request after a load (the startup self-test
    /// on a preloaded slot, the first real request on an on-demand load) pays
    /// Metal JIT / first-shape compilation inside its measured prefill window,
    /// and a rate estimator whose only update path is the admission it gates
    /// would otherwise wedge the slot on that one pathological seed (refusing
    /// every prompt above ~4.5·r tokens until a short isolated request
    /// happened to heal it).
    var isolatedPrefillSampleCount = 0
    static let isolatedPrefillSampleFloor = 3
    /// Consecutive `deadline_unreachable` refusals since the last admitted or
    /// ordinary submission. At `deadlineRefusalProbeThreshold` the next
    /// request that arrives at an ISOLATED submit boundary is admitted as an
    /// ordinary submission (a refusal-driven probe): being isolated by
    /// construction, its finish re-samples the isolated rate (if cold) and
    /// moves it toward truth, so a slot can never refuse forever. The absolute
    /// expiry still applies to the probe.
    var consecutiveDeadlineRefusals = 0
    static let deadlineRefusalProbeThreshold = 3
    /// Observed rates are point estimates, not hard lower bounds. Deadline
    /// projection scales each available phase rate by a haircut DERIVED from
    /// the isolated rate's measured dispersion: 1 − 2·CV, clamped to
    /// [0.5, 0.85]. A slot whose isolated samples agree within a few percent
    /// projects at 0.85 of its measured rate; one whose samples scatter by
    /// ±25 % or more keeps the historical 0.5 envelope. Never above 0.85: the
    /// engine window still spans one sampling step and host readback, and
    /// the absolute expiry — not this margin — is the backstop.
    static let deadlineProjectionRateHaircutFloor = 0.5
    static let deadlineProjectionRateHaircutCeiling = 0.85

    static func deadlineProjectionRateHaircut(dispersion: Double) -> Double {
        guard dispersion.isFinite, dispersion >= 0 else {
            return deadlineProjectionRateHaircutFloor
        }
        return min(
            deadlineProjectionRateHaircutCeiling,
            max(deadlineProjectionRateHaircutFloor, 1 - 2 * dispersion))
    }

    /// The haircut deadline projection applies right now.
    var deadlineProjectionRateHaircut: Double {
        Self.deadlineProjectionRateHaircut(dispersion: isolatedPrefillDispersion)
    }
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
        prefillDeadlineMode: PrefillDeadlineMode = PrefillDeadlineMode.resolve(),
        prefillDeadlineProjectionEnabled: Bool = true,
        partialPrefillCap: Int? = nil,
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
        self.prefillDeadlineMode = prefillDeadlineMode
        self.prefillDeadlineProjectionEnabled = prefillDeadlineProjectionEnabled
        self.partialPrefillCap = partialPrefillCap
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
        do {
            return try await submitTokenized(
                promptTokens: promptTokens,
                request: request,
                requestId: requestId,
                cacheScope: cacheScope,
                cacheEnabled: cacheEnabled,
                logprobsChannel: logprobsChannel,
                usageSignal: usageSignal,
                multimodal: multimodal,
                positionState: positionState,
                mediaKind: mediaKind,
                tokenConstraint: tokenConstraint,
                firstContentDeadline: nil)
        } catch {
            // A nil deadline cannot produce the only thrown error in the
            // deadline-aware overload. Keep legacy/local callers non-throwing
            // without turning a future invariant violation into a process crash.
            let (stream, continuation) = AsyncStream<GenerationEvent>.makeStream()
            usageSignal?.finalizeLookup(
                failure: .policy,
                fallbackTier: ssdPrefixCache == nil ? .memory : .ssd)
            continuation.yield(.error("request rejected before engine submission"))
            continuation.finish()
            return stream
        }
    }

    /// Deadline-aware remote submission. The absolute deadline was derived
    /// once at coordinator-frame receipt and converted to a remaining
    /// monotonic duration only at atomic engine admission. Existing local/test
    /// callers use the non-throwing overload.
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
        tokenConstraint: (any CBv2TokenConstraint)? = nil,
        firstContentDeadline: FirstContentDeadline?,
        profile: RequestProfileBuilder? = nil
    ) async throws -> AsyncStream<GenerationEvent> {
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
        guard active[id] == nil, !pendingSubmissionIDs.contains(id) else {
            usageSignal?.finalizeLookup(
                failure: .policy,
                fallbackTier: ssdPrefixCache == nil ? .memory : .ssd)
            continuation.yield(.error("token_budget_exhausted: duplicate request ID"))
            continuation.finish()
            return stream
        }
        let retirementTransfer = EngineV2RetirementTransfer()
        pendingSubmissionIDs.insert(id)
        if let profile { pendingProfiles[id] = profile }
        // Profiler: this prompt is "queued for prefill" for exactly the span
        // of this call (every exit path, admitted or rejected).
        queuedPrefillTokens += promptTokens.count
        defer { queuedPrefillTokens = max(0, queuedPrefillTokens - promptTokens.count) }
        defer {
            if !retirementTransfer.isClaimed {
                pendingSubmissionIDs.remove(id)
                pendingCancellationIDs.remove(id)
                pendingProfiles.removeValue(forKey: id)
            }
        }
        #if DEBUG
        if let gate = _testPreSubmitGate {
            _testPreSubmitGate = nil
            await gate()
        }
        #endif
        try await checkFirstContentDeadline(
            firstContentDeadline,
            requestID: id,
            sharedKVReserved: false,
            prefixCacheReceiptID: nil,
            ssdStaged: false,
            readyReceiptRegistered: false,
            usageSignal: usageSignal)

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
        try await checkFirstContentDeadline(
            firstContentDeadline,
            requestID: id,
            sharedKVReserved: false,
            prefixCacheReceiptID: nil,
            ssdStaged: false,
            readyReceiptRegistered: false,
            usageSignal: usageSignal)
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
            let stageStart = SuspendingClock.now
            let stageResult = await ssd.stage(
                requestID: prefixCacheReceiptID,
                promptTokens: promptTokens,
                cacheScope: cacheScope)
            profile?.markDuration(.ssdStage, start: stageStart)
            ssdStaged = stageResult.staged
            ssdReuseAttempted = stageResult.staged
            usageSignal?.record(stageResult: stageResult)
            if case .skippedCapacity = stageResult.disposition {
                emitPrefixCacheColdFallback(
                    requestId: id,
                    reason: "stage_capacity",
                    capacityRefusal: true)
            }
        }
        cbv2Request.prefixCacheReceiptID = prefixCacheReceiptID
        try await checkFirstContentDeadline(
            firstContentDeadline,
            requestID: id,
            sharedKVReserved: false,
            prefixCacheReceiptID: prefixCacheReceiptID,
            ssdStaged: ssdStaged,
            readyReceiptRegistered: readyReceiptRegistered,
            usageSignal: usageSignal)

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
                budget: kvBudget, requestID: id, tokenCount: worstCaseTokens,
                profile: profile)
            try await checkFirstContentDeadline(
                firstContentDeadline,
                requestID: id,
                sharedKVReserved: sharedKVReserved,
                prefixCacheReceiptID: prefixCacheReceiptID,
                ssdStaged: ssdStaged,
                readyReceiptRegistered: readyReceiptRegistered,
                usageSignal: usageSignal)
            if !sharedKVReserved, ssdStaged, let prefixCacheReceiptID {
                // Optional adoption may be the only reason R no longer fits:
                // retire S synchronously, then retry the full cold request R.
                await ssdPrefixCache?.abandonStaging(requestID: prefixCacheReceiptID)
                ssdStaged = false
                try await checkFirstContentDeadline(
                    firstContentDeadline,
                    requestID: id,
                    sharedKVReserved: false,
                    prefixCacheReceiptID: prefixCacheReceiptID,
                    ssdStaged: false,
                    readyReceiptRegistered: readyReceiptRegistered,
                    usageSignal: usageSignal)
                sharedKVReserved = await reserveSharedRequestBytes(
                    budget: kvBudget, requestID: id, tokenCount: worstCaseTokens,
                profile: profile)
                try await checkFirstContentDeadline(
                    firstContentDeadline,
                    requestID: id,
                    sharedKVReserved: sharedKVReserved,
                    prefixCacheReceiptID: prefixCacheReceiptID,
                    ssdStaged: false,
                    readyReceiptRegistered: readyReceiptRegistered,
                    usageSignal: usageSignal)
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
        }

        // Expiry is authoritative even when projection policy will fail open.
        // This is the final check after every provider-owned suspension.
        try await checkFirstContentDeadline(
            firstContentDeadline,
            requestID: id,
            sharedKVReserved: sharedKVReserved,
            prefixCacheReceiptID: prefixCacheReceiptID,
            ssdStaged: ssdStaged,
            readyReceiptRegistered: readyReceiptRegistered,
            usageSignal: usageSignal)

        // Snapshot queue isolation at the exact engine-submit boundary. The
        // current provider request is already in `pendingSubmissionIDs`; every
        // other active or pending row disqualifies this sample.
        disqualifyOverlappedPrefillSamples()
        let isolatedPrefillSampleEligible =
            isIsolatedPrefillSubmitBoundary(currentProviderRequestID: id)

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
        let engineRequest = cbv2Request
        pendingEngineIDs.insert(cbv2Id)
        idMap[id] = cbv2Id
        defer {
            if !retirementTransfer.isClaimed {
                pendingEngineIDs.remove(cbv2Id)
                if active[id] == nil, idMap[id] == cbv2Id {
                    idMap.removeValue(forKey: id)
                }
            }
        }

        // Hoisted so the profiler can name the deadline mode; pure function of
        // bridge state, no suspension between here and the submit below.
        let deadlineAdmission = firstTokenDeadlineAdmission(
            deadline: firstContentDeadline,
            isMultimodal: multimodal != nil,
            isolatedSubmitBoundary: isolatedPrefillSampleEligible)
        if let profile {
            // Profiler engine-submit snapshot: ONE lock for the stamp and the
            // whole occupancy posture at the submit boundary.
            let snapshot = capacitySnapshot()
            let queuedOthers = max(0, queuedPrefillTokens - promptTokens.count)
            let deadlineMode: DeadlineMode
            if firstContentDeadline == nil {
                deadlineMode = .none
            } else if deadlineAdmission != nil {
                deadlineMode = .projected
            } else {
                deadlineMode = .legacy
            }
            let mtpActive = mtpActivationStatus.active
            let cap = partialPrefillCap
            profile.update { f, now in
                f.mark(.engineSubmit, offsetUs: now)
                f.set(.runningAtAdmit, Int64(snapshot.activeRequests))
                f.set(.waitingAtAdmit, Int64(snapshot.waitingRequests))
                f.set(.kvBytesInUseAtAdmit, Int64(snapshot.kvBytesInUse))
                f.set(.kvBytesCapacity, Int64(snapshot.kvBytesCapacity))
                f.set(.stepsAtSubmit, Int64(snapshot.stepsExecuted))
                f.set(.queuedPrefillTokensAtAdmit, Int64(queuedOthers))
                f.set(.mtpActive, mtpActive)
                if let cap { f.set(.partialPrefillCap, Int64(cap)) }
                f.deadlineMode = deadlineMode
            }
        }

        let events: AsyncStream<CBv2Event>
        // Ordinary submission registers synchronously; atomic submission
        // replaces this with the engine-queue commit instant returned by the
        // admission transaction.
        var engineAdmittedAt = ContinuousClock.now
        guard let engine = ownedEngine else {
            await releasePreSubmitResources(
                requestID: id,
                sharedKVReserved: sharedKVReserved,
                prefixCacheReceiptID: prefixCacheReceiptID,
                ssdStaged: ssdStaged,
                readyReceiptRegistered: readyReceiptRegistered,
                usageSignal: usageSignal,
                failure: .policy)
            continuation.yield(.error("request queue full: engine is shutting down"))
            continuation.finish()
            return stream
        }
        do {
            if let admission = deadlineAdmission {
                // The engine's serialized closure compares projection against
                // this same absolute deadline. A second task-group race would
                // cancel after commit and hide the generation-bound retirement
                // handle needed to transfer resource ownership safely.
                let result = try await engine.submit(
                    engineRequest,
                    firstTokenDeadline: admission)
                switch result {
                case .admitted(let stream, let projectedWork, let admittedAt, let retirement):
                    consecutiveDeadlineRefusals = 0
                    if Task.isCancelled || pendingCancellationIDs.contains(id) {
                        engine.cancel(cbv2Id)
                        // Admitted, then torn down: an in-flight engine step
                        // may already have produced a token before the cancel
                        // was processed, so `tokens_after_cancel` is OMITTED
                        // here (never a fabricated 0 — see
                        // `recordCancelledBeforeGeneration`).
                        transferPreSubmitRetirement(
                            retirementTransfer,
                            requestID: id,
                            engineID: cbv2Id,
                            stream: stream,
                            retirement: retirement,
                            sharedKVReserved: sharedKVReserved,
                            prefixCacheReceiptID: prefixCacheReceiptID,
                            ssdStaged: ssdStaged,
                            readyReceiptRegistered: readyReceiptRegistered,
                            usageSignal: usageSignal,
                            failure: .policy)
                        throw CancellationError()
                    }
                    do {
                        try firstContentDeadline?.check()
                    } catch {
                        engine.cancel(cbv2Id)
                        // Admission committed at the deadline boundary. Keep
                        // provider-global reservations until the generation-
                        // bound engine acknowledgement proves the row and KV
                        // ownership are gone. A watchdog terminal alone is not
                        // that acknowledgement.
                        transferPreSubmitRetirement(
                            retirementTransfer,
                            requestID: id,
                            engineID: cbv2Id,
                            stream: stream,
                            retirement: retirement,
                            sharedKVReserved: sharedKVReserved,
                            prefixCacheReceiptID: prefixCacheReceiptID,
                            ssdStaged: ssdStaged,
                            readyReceiptRegistered: readyReceiptRegistered,
                            usageSignal: usageSignal,
                            failure: .capacity)
                        throw error
                    }
                    events = stream
                    engineAdmittedAt = admittedAt
                    if let profile {
                        // The engine's commit instant is on the deadline
                        // (continuous) clock: convert into the suspending
                        // anchor's domain (µs window, no sleep possible) and
                        // clamp ≥ engine_submit for the wire order invariant.
                        // `projectedWork` was previously discarded here.
                        let admittedOffset = profile.offsetUs(
                            of: profile.suspendingInstant(fromContinuous: admittedAt))
                        let remainingUs = firstContentDeadline.map {
                            RequestProfileBuilder.budgetRemainingUs(
                                $0.remainingDuration(now: admittedAt))
                        }
                        profile.update { f, _ in
                            f.mark(.engineAdmitted,
                                   offsetUs: max(admittedOffset, f.offset(.engineSubmit) ?? 0))
                            Self.stampProjection(
                                &f, projectedWork: projectedWork, remainingUs: remainingUs)
                        }
                    }
                case .deadlineUnreachable(let projectedWork):
                    // Counted where the verdict is produced: a refusal leaves
                    // no `active` row, no sample and no other trace, so this
                    // counter is the only thing that can break a wedge.
                    consecutiveDeadlineRefusals += 1
                    // The engine's verdict is the one fact a refusal has.
                    // Stamp it on the profile that rides the 503 terminal —
                    // projected_* for a bounded projection, only the
                    // remaining budget for `.unbounded` — and NEVER
                    // `engine_admitted` (its absence is how the coordinator
                    // tells a refusal from an admit-then-expire).
                    let remaining = firstContentDeadline?.remainingDuration()
                    if let profile {
                        let remainingUs = remaining.map(RequestProfileBuilder.budgetRemainingUs)
                        profile.update { f, _ in
                            Self.stampProjection(
                                &f, projectedWork: projectedWork, remainingUs: remainingUs)
                        }
                    }
                    logDeadlineRefusal(
                        projectedWork: projectedWork,
                        promptTokens: promptTokens.count,
                        remaining: remaining)
                    if Task.isCancelled || pendingCancellationIDs.contains(id) {
                        // Refused at admission after a latched cancel: nothing
                        // was generated, record the explicit 0 (see the
                        // `.admitted` teardown above).
                        recordCancelledBeforeGeneration(profile)
                        throw CancellationError()
                    }
                    throw PreContentDeadlineFailure.deadlineUnreachable
                }
            } else {
                // Projection fails open when mode is off, too few isolated
                // samples exist, the refusal-driven probe is due, the engine
                // would price a posture as `.unbounded` (decode rate unmeasured
                // with rows running, a multimodal peer row, a full batch), or
                // media makes token projection incomplete. Absolute expiry
                // does not: it was checked immediately above.
                events = try engine.submit(engineRequest)
                consecutiveDeadlineRefusals = 0
                if let profile {
                    // Evaluated AFTER the submit returned: the deadline may
                    // have expired meanwhile, hence the zero clamp.
                    let remainingUs = firstContentDeadline.map {
                        RequestProfileBuilder.budgetRemainingUs($0.remainingDuration())
                    }
                    profile.update { f, now in
                        f.mark(.engineAdmitted, offsetUs: max(now, f.offset(.engineSubmit) ?? 0))
                        if let remainingUs { f.set(.budgetRemainingAtAdmitUs, remainingUs) }
                    }
                }
            }
        } catch let cancellation as CBv2FirstTokenAdmissionCancellation {
            engine.cancel(cbv2Id)
            // Post-admission cancellation: same rule as the `.admitted`
            // teardown above — the field stays absent.
            transferPreSubmitRetirement(
                retirementTransfer,
                requestID: id,
                engineID: cbv2Id,
                stream: cancellation.stream,
                retirement: cancellation.retirement,
                sharedKVReserved: sharedKVReserved,
                prefixCacheReceiptID: prefixCacheReceiptID,
                ssdStaged: ssdStaged,
                readyReceiptRegistered: readyReceiptRegistered,
                usageSignal: usageSignal,
                failure: .policy)
            throw CancellationError()
        } catch let failure as PreContentDeadlineFailure {
            if !retirementTransfer.isClaimed {
                await releasePreSubmitResources(
                    requestID: id,
                    sharedKVReserved: sharedKVReserved,
                    prefixCacheReceiptID: prefixCacheReceiptID,
                    ssdStaged: ssdStaged,
                    readyReceiptRegistered: readyReceiptRegistered,
                    usageSignal: usageSignal,
                    failure: .capacity)
            }
            throw failure
        } catch is CancellationError {
            if !retirementTransfer.isClaimed {
                await releasePreSubmitResources(
                    requestID: id,
                    sharedKVReserved: sharedKVReserved,
                    prefixCacheReceiptID: prefixCacheReceiptID,
                    ssdStaged: ssdStaged,
                    readyReceiptRegistered: readyReceiptRegistered,
                    usageSignal: usageSignal,
                    failure: .policy)
            }
            throw CancellationError()
        } catch {
            // Engine rejected AFTER the shared reservation was taken — release
            // it before surfacing the error (no pump will ever finish it).
            // A rejected submit also never ran the prefix-cache lookup, so
            // the engine can never balance the staging ticket — backstop it.
            if !retirementTransfer.isClaimed {
                await releasePreSubmitResources(
                    requestID: id,
                    sharedKVReserved: sharedKVReserved,
                    prefixCacheReceiptID: prefixCacheReceiptID,
                    ssdStaged: ssdStaged,
                    readyReceiptRegistered: readyReceiptRegistered,
                    usageSignal: usageSignal,
                    failure: Self.prefixCacheFailureClass(for: error))
            }
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
            isMultimodal: multimodal != nil,
            isolatedPrefillSampleEligible:
                isolatedPrefillSampleEligible
                && pendingSubmissionIDs.allSatisfy({ $0 == id })
                && pendingEngineIDs.allSatisfy({ $0 == cbv2Id })
                && active.isEmpty,
            submittedAt: engineAdmittedAt,
            profile: profile
        )
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
            readyReceiptRegistered: readyReceiptRegistered,
            profile: profile
        )

        let bridge = self
        continuation.onTermination = { @Sendable termination in
            if case .cancelled = termination {
                Task { await bridge.cancel(requestId: id) }
            }
        }
        return stream
    }

    /// Build the caller-owned policy passed into the engine's atomic
    /// projection. This runs immediately before submission, after every SSD
    /// and shared-KV suspension. The absolute monotonic instant is carried
    /// unchanged; only the engine queue reads "now" for the final verdict.
    ///
    /// Returns nil (ordinary submission; the absolute expiry was already
    /// enforced by the caller and is re-checked by the pump path) whenever
    /// projection cannot be trusted to be both bounded AND self-correcting:
    /// - fewer than `isolatedPrefillSampleFloor` isolated samples — the seed
    ///   is structurally the post-load JIT request;
    /// - `deadlineRefusalProbeThreshold` consecutive refusals and this request
    ///   sits at an isolated boundary — the refusal-driven probe whose finish
    ///   re-samples the rate the refusals were based on;
    /// - a posture the engine would price as `.unbounded` although it is not
    ///   a first-content fact about THIS request: the decode rate is still
    ///   unmeasured while rows are running (their decode phase cannot be
    ///   priced), a running row carries media (its steps cannot be priced),
    ///   or the batch is full (the projection then jumps by
    ///   `count × min(maxTokens − generated)` — minutes for gpt-oss — and
    ///   the request waits under the engine's own admission lease instead).
    private func firstTokenDeadlineAdmission(
        deadline: FirstContentDeadline?,
        isMultimodal: Bool,
        isolatedSubmitBoundary: Bool
    ) -> CBv2FirstTokenDeadlineAdmission? {
        guard prefillDeadlineMode == .enforce,
            prefillDeadlineProjectionEnabled,
            !isMultimodal,
            let deadline,
            isolatedPrefillEwmaInitialized
        else {
            return nil
        }
        guard isolatedPrefillSampleCount >= Self.isolatedPrefillSampleFloor else {
            logDeadlineFailOpen("below_sample_floor")
            return nil
        }
        if consecutiveDeadlineRefusals >= Self.deadlineRefusalProbeThreshold,
            isolatedSubmitBoundary
        {
            logDeadlineFailOpen("refusal_probe")
            return nil
        }

        let haircut = deadlineProjectionRateHaircut
        let prefillRate = isolatedPrefillTpsEwma * haircut
        let decodeCandidate = observedDecodeTpsEwma * haircut
        let decodeRate =
            ewmaInitialized && decodeCandidate.isFinite && decodeCandidate > 0
            ? decodeCandidate
            : nil
        guard prefillRate.isFinite, prefillRate > 0 else {
            return nil
        }
        if decodeRate == nil, !active.isEmpty {
            logDeadlineFailOpen("decode_rate_unmeasured_with_rows")
            return nil
        }
        if active.values.contains(where: { $0.isMultimodal }) {
            logDeadlineFailOpen("multimodal_peer")
            return nil
        }
        if active.count >= maxConcurrentRequests {
            logDeadlineFailOpen("full_batch")
            return nil
        }

        return CBv2FirstTokenDeadlineAdmission(
            deadline: deadline.instant,
            conservativePrefillTokensPerSecond: prefillRate,
            conservativeDecodeTokensPerSecond: decodeRate)
    }

    private func isIsolatedPrefillSubmitBoundary(
        currentProviderRequestID: String
    ) -> Bool {
        guard pendingEngineIDs.isEmpty else { return false }
        guard pendingSubmissionIDs.allSatisfy({ $0 == currentProviderRequestID }) else {
            return false
        }
        return active.isEmpty
    }

    /// Posture tag for a deadline-bearing request that took the ordinary
    /// submission path on one of the self-correcting fail-open branches
    /// (the profile only says `deadline_mode=legacy`). Debug level: this is
    /// a per-request line on the admission path.
    private func logDeadlineFailOpen(_ posture: String) {
        #if canImport(os)
        Self.logger.debug(
            "engine_v2: deadline projection fails open posture=\(posture, privacy: .public) model=\(self.modelId, privacy: .public) running=\(self.active.count) isolated_samples=\(self.isolatedPrefillSampleCount) refusals=\(self.consecutiveDeadlineRefusals)"
        )
        #endif
    }

    /// The engine's first-token projection, on the profile. Shared by the
    /// `.admitted` and `.deadlineUnreachable` arms so a refusal carries the
    /// same `projected_*` fields as an admit; `.unbounded` leaves them absent
    /// (there is no finite projection to report). `budget_remaining_at_admit_us`
    /// is the deadline's remaining window at the verdict instant.
    private static func stampProjection(
        _ f: inout RequestProfileBuilder.Fields,
        projectedWork: CBv2FirstTokenProjectedWork,
        remainingUs: Int64?
    ) {
        if case .bounded(let work, let serviceDuration) = projectedWork {
            f.set(.projectedPrefillTokens, Int64(work.prefillTokens))
            f.set(.projectedDecodeTokens, Int64(work.decodeTokens))
            f.set(.projectedServiceUs,
                  RequestProfileBuilder.microseconds(serviceDuration))
        }
        if let remainingUs { f.set(.budgetRemainingAtAdmitUs, remainingUs) }
    }

    /// One line per refusal with the posture the verdict was based on —
    /// the numbers the profile now carries, readable on the box.
    private func logDeadlineRefusal(
        projectedWork: CBv2FirstTokenProjectedWork,
        promptTokens: Int,
        remaining: Duration?
    ) {
        #if canImport(os)
        let projectedMs: Int64
        let posture: String
        switch projectedWork {
        case .bounded(let work, let serviceDuration):
            projectedMs = RequestProfileBuilder.microseconds(serviceDuration) / 1_000
            posture = "bounded(prefill=\(work.prefillTokens),decode=\(work.decodeTokens))"
        case .unbounded:
            projectedMs = -1
            posture = "unbounded"
        }
        let budgetMs = remaining.map { RequestProfileBuilder.microseconds($0) / 1_000 } ?? -1
        Self.logger.info(
            "engine_v2: deadline refused model=\(self.modelId, privacy: .public) posture=\(posture, privacy: .public) projected_ms=\(projectedMs) prompt_tokens=\(promptTokens) budget_ms=\(budgetMs) running=\(self.active.count) refusals=\(self.consecutiveDeadlineRefusals)"
        )
        #endif
    }

    /// A later arrival can share a step with an already-prefilling row. Mark
    /// that older sample non-isolated before submitting the newcomer; rows
    /// that already emitted their first token keep their completed prefill
    /// observation.
    private func disqualifyOverlappedPrefillSamples() {
        for id in Array(active.keys) {
            guard var state = active[id], state.firstTokenAt == nil else {
                continue
            }
            state.isolatedPrefillSampleEligible = false
            active[id] = state
        }
    }

    /// Move post-commit cancellation cleanup out of the cancelling task. The
    /// retained IDs block provider- and engine-ID reuse while the background
    /// owner holds every pre-submit reservation through actual engine
    /// retirement. A permanent engine wedge therefore retains capacity (safe)
    /// without synchronously deadlocking cancellation.
    private func transferPreSubmitRetirement(
        _ transfer: EngineV2RetirementTransfer,
        requestID: String,
        engineID: CBv2RequestID,
        stream: AsyncStream<CBv2Event>,
        retirement: CBv2RequestRetirement,
        sharedKVReserved: Bool,
        prefixCacheReceiptID: CBv2RequestID?,
        ssdStaged: Bool,
        readyReceiptRegistered: Bool,
        usageSignal: EngineV2RequestUsageSignal?,
        failure: PrefixCacheLookupFailureClass
    ) {
        guard transfer.claim() else { return }
        let bridge = self
        Task {
            await retirement.wait()
            withExtendedLifetime(stream) {}
            await bridge.completeTransferredPreSubmitRetirement(
                requestID: requestID,
                engineID: engineID,
                sharedKVReserved: sharedKVReserved,
                prefixCacheReceiptID: prefixCacheReceiptID,
                ssdStaged: ssdStaged,
                readyReceiptRegistered: readyReceiptRegistered,
                usageSignal: usageSignal,
                failure: failure)
        }
    }

    private func completeTransferredPreSubmitRetirement(
        requestID: String,
        engineID: CBv2RequestID,
        sharedKVReserved: Bool,
        prefixCacheReceiptID: CBv2RequestID?,
        ssdStaged: Bool,
        readyReceiptRegistered: Bool,
        usageSignal: EngineV2RequestUsageSignal?,
        failure: PrefixCacheLookupFailureClass
    ) async {
        await releasePreSubmitResources(
            requestID: requestID,
            sharedKVReserved: sharedKVReserved,
            prefixCacheReceiptID: prefixCacheReceiptID,
            ssdStaged: ssdStaged,
            readyReceiptRegistered: readyReceiptRegistered,
            usageSignal: usageSignal,
            failure: failure)
        pendingSubmissionIDs.remove(requestID)
        pendingCancellationIDs.remove(requestID)
        pendingProfiles.removeValue(forKey: requestID)
        pendingEngineIDs.remove(engineID)
        if active[requestID] == nil, idMap[requestID] == engineID {
            idMap.removeValue(forKey: requestID)
        }
    }

    /// Enforce absolute expiry independently from projection mode and balance
    /// every resource acquired before this boundary.
    private func checkFirstContentDeadline(
        _ deadline: FirstContentDeadline?,
        requestID: String,
        sharedKVReserved: Bool,
        prefixCacheReceiptID: CBv2RequestID?,
        ssdStaged: Bool,
        readyReceiptRegistered: Bool,
        usageSignal: EngineV2RequestUsageSignal?
    ) async throws {
        if pendingCancellationIDs.contains(requestID) {
            // Refused before the engine ever sees the row: nothing was
            // generated after the cancel, so the profile records an explicit
            // `tokens_after_cancel = 0` (baseline seeded by `latchPendingCancel`).
            recordCancelledBeforeGeneration(pendingProfiles[requestID])
            await releasePreSubmitResources(
                requestID: requestID,
                sharedKVReserved: sharedKVReserved,
                prefixCacheReceiptID: prefixCacheReceiptID,
                ssdStaged: ssdStaged,
                readyReceiptRegistered: readyReceiptRegistered,
                usageSignal: usageSignal,
                failure: .policy)
            throw CancellationError()
        }
        do {
            try deadline?.check()
        } catch let failure as PreContentDeadlineFailure {
            await releasePreSubmitResources(
                requestID: requestID,
                sharedKVReserved: sharedKVReserved,
                prefixCacheReceiptID: prefixCacheReceiptID,
                ssdStaged: ssdStaged,
                readyReceiptRegistered: readyReceiptRegistered,
                usageSignal: usageSignal,
                failure: .capacity)
            throw failure
        }
    }

    /// Balance every provider-owned resource acquired before engine
    /// submission. Engine-owned prefix/KV state is released atomically by the
    /// deadline API before it returns a rejection.
    private func releasePreSubmitResources(
        requestID: String,
        sharedKVReserved: Bool,
        prefixCacheReceiptID: CBv2RequestID?,
        ssdStaged: Bool,
        readyReceiptRegistered: Bool,
        usageSignal: EngineV2RequestUsageSignal?,
        failure: PrefixCacheLookupFailureClass
    ) async {
        if sharedKVReserved {
            await kvBudget?.release(requestID: requestID)
        }
        if let prefixCacheReceiptID {
            if ssdStaged {
                await ssdPrefixCache?.abandonStaging(
                    requestID: prefixCacheReceiptID)
            }
            if readyReceiptRegistered {
                ssdPrefixCache?.discardReadyReceipt(
                    requestID: prefixCacheReceiptID)
            }
        }
        usageSignal?.finalizeLookup(
            failure: failure,
            fallbackTier: ssdPrefixCache == nil ? .memory : .ssd)
    }

    private func reserveSharedRequestBytes(
        budget: GlobalKVCacheBudget, requestID: String, tokenCount: Int,
        profile: RequestProfileBuilder? = nil
    ) async -> Bool {
        guard let total = requestReservationBytes(tokenCount: tokenCount), total > 0 else {
            return false
        }
        // Profiler `kv_reserve_us`: the shared-budget actor hop (accumulates
        // across the SSD-abandon retry).
        let reserveStart = SuspendingClock.now
        let reserved = await budget.reserveBytes(requestID: requestID, bytes: UInt64(total))
        profile?.markDuration(.kvReserve, start: reserveStart)
        return reserved
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
        // Same order as `cancelIfOwned`: an admitted row's real completion
        // count wins; only a row that is still pending gets the 0 seed (a
        // request briefly sits in both maps between `active[id] = …` and the
        // pending id's removal, and the seed must never shadow the count).
        if let state = active[requestId] {
            snapshotTokensAtCancel(state)
        } else if pendingSubmissionIDs.contains(requestId) {
            latchPendingCancel(id: requestId)
        }
        if let cbv2Id = idMap[requestId] {
            ownedEngine?.cancel(cbv2Id)
        }
    }

    /// A cancel reached the bridge while `id` is still pending engine
    /// admission: latch it (the existing minted-id latch — the submission is
    /// REFUSED at its next pre-submit check, strictly before the engine sees
    /// the row, or torn down at atomic admission on the deadline path) and
    /// seed the `tokens_after_cancel` baseline at 0, since the row has
    /// produced nothing yet. First cancel wins; one lock, cancel path only.
    private func latchPendingCancel(id: String) {
        pendingCancellationIDs.insert(id)
        guard let profile = pendingProfiles[id] else { return }
        profile.update { f, _ in
            if f.count(.tokensAtCancel) == nil {
                f.set(.tokensAtCancel, 0)
            }
        }
    }

    /// RULE: `tokens_after_cancel = 0` is written only when the engine
    /// PROVABLY never ran the row — the pre-submit refusal (latched before the
    /// engine saw it) and the `.deadlineUnreachable` verdict (never admitted).
    /// Once a row was admitted (the `.admitted` teardown, the
    /// `CBv2FirstTokenAdmissionCancellation` catch) an in-flight step may
    /// have produced a token before the cancel was processed and no pump will
    /// reconcile it, so the field is OMITTED rather than fabricated. Writes
    /// only when a cancel was actually received (baseline present).
    private func recordCancelledBeforeGeneration(_ profile: RequestProfileBuilder?) {
        profile?.update { f, _ in
            if f.count(.tokensAtCancel) != nil, f.count(.tokensAfterCancel) == nil {
                f.set(.tokensAfterCancel, 0)
            }
        }
    }

    /// Profiler `tokens_after_cancel`: snapshot the completion count the
    /// moment a cancel reaches the bridge (first cancel wins); the delta is
    /// computed at finish. One lock, cancel path only.
    private func snapshotTokensAtCancel(_ state: ActiveRequestState) {
        guard let profile = state.profile else { return }
        let tokensNow = Int64(state.completionTokens)
        profile.update { f, _ in
            if f.count(.tokensAtCancel) == nil {
                f.set(.tokensAtCancel, tokensNow)
            }
        }
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
    func cancelIfOwned(requestId: String, profile: RequestProfileBuilder? = nil) -> Bool {
        if let cbv2Id = idMap[requestId], let engine = ownedEngine {
            if let state = active[requestId] {
                snapshotTokensAtCancel(state)
            } else if pendingSubmissionIDs.contains(requestId) {
                latchPendingCancel(id: requestId)
            }
            engine.cancel(cbv2Id)
            return true
        }
        // Miss path — the expected case for a COORDINATOR cancel: the
        // coordinator id never matches the `req-…` id the engine tracks (see
        // ProviderLoop+Cancellation). The request's profile is the one handle
        // both sides share, so match on its identity. O(rows), cancel path only.
        guard let profile else { return false }
        // Admitted row: take the `tokens_after_cancel` snapshot NOW, at
        // cancel receipt, and drop the engine row NOW — the coordinator's
        // cancel no longer waits for Task-propagation to walk three stream
        // teardowns before `CBv2Engine.cancel` runs (the row kept decoding
        // for tens to hundreds of ms). The later propagation-driven cancel
        // under the minted id is a no-op in the engine (`requestCancel`
        // guards on the live stream and the pending-cancel map assignment
        // is idempotent). Owned — nothing else can hold this profile.
        if let (providerId, state) = active.first(where: { $0.value.profile === profile }) {
            snapshotTokensAtCancel(state)
            if let cbv2Id = idMap[providerId], let engine = ownedEngine {
                engine.cancel(cbv2Id)
            }
            return true
        }
        // Still pending engine admission: seed the zero baseline and latch
        // the cancellation so the row is cancelled the moment submit returns
        // (ordinary path) or torn down at atomic admission (deadline path).
        // Owned — nothing else can hold this profile, so stop scanning.
        if let pendingId = pendingProfiles.first(where: { $0.value === profile })?.key {
            latchPendingCancel(id: pendingId)
            return true
        }
        return false
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
        readyReceiptRegistered: Bool = false,
        profile: RequestProfileBuilder? = nil
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
                readyReceiptRegistered: readyReceiptRegistered,
                profile: profile
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
        readyReceiptRegistered: Bool = false,
        profile: RequestProfileBuilder? = nil
    ) async {
        // NOTE: the shared-budget KV reservation is taken in `submitTokenized`
        // (the pre-engine admission gate), NOT here — the pump only RELEASES
        // it on the terminal/teardown paths below, and ONLY when THIS request
        // took one (`holdsSharedReservation`): an unconditional release could
        // drop a same-keyed reservation owned by a different submission in
        // the pathological duplicate-id corner.
        var sawFirstToken = false
        var sawTerminal = false
        // Bounded stop-string replay tail (see `stopTailTokenLimit`): only
        // the last few filtered tokens are retained, never the whole
        // output.
        let stopTailLimit = Self.stopTailTokenLimit(for: stopSequences)
        var generatedTokens: [Int] = []
        generatedTokens.reserveCapacity(stopTailLimit)
        // Profiler: pump-LOCAL last-delta instant (one clock read per delta,
        // no lock), written to the profile exactly once at finish.
        var lastDeltaAt: SuspendingClock.Instant?
        // The engine's exact prompt count, published before the first delta
        // can reach the frames loop: a cancel settlement (no usage frame in
        // the normal cancel ordering) bills THIS instead of re-rendering the
        // chat template to recover it. `active[id]` is seeded at admission,
        // strictly before the pump task starts.
        if let usageSignal, let promptTokens = active[id]?.promptTokens {
            usageSignal.recordPromptTokens(promptTokens)
        }
        // Pump-local running completion count (one lock write per delta).
        var forwardedTokens = 0
        for await event in events {
            switch event {
            case .delta(let text, let tokens, let logprobs):
                if profile != nil, !tokens.isEmpty {
                    lastDeltaAt = .now
                }
                if let usageSignal, !tokens.isEmpty {
                    forwardedTokens += tokens.count
                    usageSignal.recordCompletionTokens(forwardedTokens)
                }
                // Key first-token on TOKEN count, not text: some tokens
                // (BPE intermediates, specials) detokenize to "" and would
                // otherwise leave the first-token bookkeeping unset.
                if !sawFirstToken, !tokens.isEmpty {
                    sawFirstToken = true
                    recordFirstToken(
                        id: id, emissionTokens: tokens.count, profileNow: lastDeltaAt)
                }
                recordProgress(id: id, newTokens: tokens.count)
                if stopTailLimit > 0 {
                    // EngineLoopV2 suppresses stop-token text before the
                    // stop-string holdback sees it. Exclude those raw tokens
                    // from replay too, or an EOS token whose debug rendering
                    // equals a caller sequence would become a false match.
                    generatedTokens.append(
                        contentsOf: tokens.filter { !stopTokenIds.contains($0) })
                    let excess = generatedTokens.count - stopTailLimit
                    if excess > 0 {
                        generatedTokens.removeFirst(excess)
                    }
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
                    sawFirstToken: sawFirstToken, continuation: continuation,
                    lastDeltaAt: lastDeltaAt
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
        continuation: AsyncStream<GenerationEvent>.Continuation,
        lastDeltaAt: SuspendingClock.Instant? = nil
    ) {
        switch reason {
        case .stop, .length:
            let final = recordFinish(id: id, usage: usage, lastDeltaAt: lastDeltaAt, finishReason: reason)
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
            let final = recordFinish(
                id: id, usage: usage, lastDeltaAt: lastDeltaAt,
                finishReason: reason)
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
            let final = recordFinish(
                id: id, usage: usage, lastDeltaAt: lastDeltaAt,
                finishReason: reason)
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
            _ = recordFinish(
                id: id, usage: usage, lastDeltaAt: lastDeltaAt,
                finishReason: reason)
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

    private func recordFirstToken(
        id: String, emissionTokens: Int, profileNow: SuspendingClock.Instant? = nil
    ) {
        let now = ContinuousClock.Instant.now
        wedgeMonitor.recordFirstToken(now: now)
        guard var state = active[id] else { return }
        if state.firstTokenAt == nil {
            state.firstTokenAt = now
            state.firstEmissionTokens = max(1, emissionTokens)
            active[id] = state
            // Profiler `first_delta_us`: the same instant the pump stored as
            // its last-delta, so a one-token response keeps first ≤ last.
            // Clamped to `terminal_built`: on the cancel path the handler
            // builds its terminal BEFORE the engine delivers `.finished`, so a
            // late delta must never land after it (wire order invariant).
            if let profileNow, let profile = state.profile {
                profile.mark(
                    .firstDelta, at: profileNow,
                    notBefore: .engineAdmitted, notAfter: .terminalBuilt)
            }
        }
    }

    private func recordProgress(id: String, newTokens: Int) {
        // In-place `_modify` through the dictionary subscript: one hash
        // and no copy of the state struct (which holds a class reference)
        // per delta.
        guard newTokens > 0 else { return }
        active[id]?.completionTokens += newTokens
    }

    /// Finish bookkeeping with the legacy billing-zero defense: the
    /// terminal usage can only ever RAISE observed counts, never zero them.
    /// TPS methodology matches `BatchScheduler.recordFinish` (decode rate
    /// measured first-token→finish over `completion - 1` tokens).
    private func recordFinish(
        id: String,
        usage: CBv2Usage,
        lastDeltaAt: SuspendingClock.Instant? = nil,
        finishReason: CBv2FinishReason? = nil
    ) -> (prompt: Int, completion: Int, tps: Double) {
        idMap.removeValue(forKey: id)
        let now = ContinuousClock.Instant.now
        guard var state = active.removeValue(forKey: id) else {
            return (max(0, usage.promptTokens), max(0, usage.completionTokens), 0)
        }
        state.completionTokens = max(state.completionTokens, usage.completionTokens)
        let prompt = max(state.promptTokens, usage.promptTokens)
        let completion = state.completionTokens

        // Profiler: cumulative cold-prefill tokens for the heartbeat (the
        // cached count is only known from terminal usage, so attribution
        // lands at finish, not first token) and the per-request finish
        // fields — ONE lock.
        let cachedTokens = max(
            0,
            usage.prefixCacheHitTokens,
            usage.prefixCacheMatchedTokens,
            usage.prefixCachePrefillTokensSaved)
        let (nextPrefillTotal, prefillOverflow) = prefillTokensTotal
            .addingReportingOverflow(Int64(max(0, prompt - cachedTokens)))
        prefillTokensTotal = prefillOverflow ? .max : nextPrefillTotal
        if let profile = state.profile {
            let stepsNow = Int64(capacitySnapshot().stepsExecuted)
            let lastDeltaOffset = lastDeltaAt.map { profile.offsetUs(of: $0) }
            let completionNow = Int64(completion)
            var tokensAfterCancel: Int64?
            var tokensAfterCancelHook: (@Sendable (Int64) -> Void)?
            profile.update { f, _ in
                if let lastDeltaOffset {
                    // Same ceiling as `first_delta`: never past the handler's
                    // (possibly already built) terminal.
                    f.mark(.lastDelta,
                           offsetUs: f.clamp(
                               lastDeltaOffset, notBefore: .firstDelta, notAfter: .terminalBuilt))
                }
                f.set(.stepsAtFinish, max(stepsNow, f.count(.stepsAtSubmit) ?? 0))
                if let atCancel = f.count(.tokensAtCancel) {
                    let after = max(0, completionNow - atCancel)
                    f.set(.tokensAfterCancel, after)
                    tokensAfterCancel = after
                    tokensAfterCancelHook = f.onTokensAfterCancel
                }
                f.engine = EngineProfile(timing: usage.timing, finishReason: finishReason)
            }
            // Cumulative heartbeat counter, bumped HERE (outside the lock):
            // the handler task's defer may already have run when a cancelled
            // request's engine terminal arrives, so it cannot own this add.
            if let tokensAfterCancel {
                tokensAfterCancelHook?(tokensAfterCancel)
            }
        }

        let tps: Double
        if let firstTokenAt = state.firstTokenAt, completion > 1 {
            let seconds = WedgeMonitor.seconds(now - firstTokenAt)
            tps = seconds > 0 ? Double(completion - 1) / seconds : 0
        } else {
            let seconds = WedgeMonitor.seconds(now - state.submittedAt)
            tps = seconds > 0 ? Double(completion) / seconds : 0
        }
        // Rate-sample eligibility keys on the finish reason, not `success`:
        // a request cancelled AFTER its first token performed a complete
        // cold prefill (the hedge losers and client disconnects that are the
        // long-prompt samples a slow rate needs to heal), and — with enough
        // decode steps — a real decode observation. A cancel BEFORE the first
        // token, an engine error or a typed terminal observed nothing.
        let sampleEligible: Bool
        switch finishReason {
        case .stop, .length: sampleEligible = true
        case .cancelled: sampleEligible = state.firstTokenAt != nil
        default: sampleEligible = false
        }
        // Only tokens emitted strictly after the first engine emission are a
        // decode observation. MTP can deliver several accepted tokens in that
        // first burst; charging all but one over a near-zero interval would
        // catastrophically inflate the conservative decode rate.
        if sampleEligible, let firstTokenAt = state.firstTokenAt,
            completion > state.firstEmissionTokens
        {
            let decodeSeconds = WedgeMonitor.seconds(now - firstTokenAt)
            let decodeTokens = completion - state.firstEmissionTokens
            // A cancel lands asynchronously at a step boundary, so its
            // window includes the cancel latency: a handful of tokens over
            // it would read low. Require a real decode run first.
            let cancelledTooShort =
                finishReason == .cancelled
                && decodeTokens < Self.minCancelledDecodeSampleTokens
            let decodeTps =
                decodeSeconds > 0 ? Double(decodeTokens) / decodeSeconds : 0
            if decodeTps > 0, !cancelledTooShort {
                updateDecodeTpsEwma(decodeTps)
            }
        }
        if sampleEligible {
            recordPrefillSample(
                promptTokens: prompt,
                usage: usage,
                submittedAt: state.submittedAt,
                firstTokenAt: state.firstTokenAt,
                isolatedAtSubmit: state.isolatedPrefillSampleEligible)
        }
        return (prompt, completion, tps)
    }

    // MARK: - Prefill sampling (observed_prefill_tps)

    /// Minimum decode tokens after the first emission for a CANCELLED
    /// request's decode sample to count (see `recordFinish`).
    static let minCancelledDecodeSampleTokens = 8

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
    /// with the v2 measurement. The window starts at the atomic engine-queue
    /// admission instant, not before that queue await; admission delay is
    /// therefore never smuggled into isolated prefill throughput. Isolation
    /// is revoked if another row arrives before this row's first token.
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
        isolatedAtSubmit: Bool
    ) {
        guard Self.isColdPrefillSample(usage: usage) else { return }
        guard let firstTokenAt else { return }
        let prefillSeconds = Self.prefillWindowSeconds(
            timing: usage.timing, submittedAt: submittedAt, firstTokenAt: firstTokenAt)
        guard
            let tps = Self.classifyPrefillSample(
                prefilledTokens: promptTokens, prefillSeconds: prefillSeconds)
        else { return }
        let decay = Self.prefillSampleDecay
        observedPrefillTokensSum = decay * observedPrefillTokensSum + Double(promptTokens)
        observedPrefillSecondsSum = decay * observedPrefillSecondsSum + prefillSeconds
        observedPrefillTpsEwma = observedPrefillTokensSum / observedPrefillSecondsSum
        prefillEwmaInitialized = true
        guard isolatedAtSubmit else { return }
        if isolatedPrefillEwmaInitialized, isolatedPrefillTpsEwma > 0 {
            // Deviation from the rate that would have projected THIS sample.
            let alpha = 0.3
            let deviation = abs(tps / isolatedPrefillTpsEwma - 1)
            isolatedPrefillDispersion =
                isolatedPrefillDispersionInitialized
                ? alpha * deviation + (1 - alpha) * isolatedPrefillDispersion
                : deviation
            isolatedPrefillDispersionInitialized = true
        }
        isolatedPrefillTokensSum = decay * isolatedPrefillTokensSum + Double(promptTokens)
        isolatedPrefillSecondsSum = decay * isolatedPrefillSecondsSum + prefillSeconds
        isolatedPrefillTpsEwma = isolatedPrefillTokensSum / isolatedPrefillSecondsSum
        isolatedPrefillEwmaInitialized = true
        isolatedPrefillSampleCount += 1
    }

    /// The prefill window a sample is measured over. ENGINE-STAMPED when the
    /// terminal usage carries both stamps: first prefill-chunk launch → the
    /// readback-done instant of the step that confirmed the first token
    /// (`CBv2RequestTiming`, nanosecond offsets from engine enqueue). That
    /// window excludes the engine queue turn, the prefix-hash lookup inside
    /// `engine.submit`, and the detok/output-stream/pump hops the BRIDGE
    /// window (`firstTokenAt − submittedAt`) folds into every sample — fixed
    /// costs that made short prompts read as slow prefill and made the two
    /// submit paths (ordinary: bridge clock before submit; atomic: engine
    /// commit instant) measure different things. Residual: it still spans one
    /// sampling step plus host readback, and for a striped prompt any
    /// mixed-step peers (none for an isolated sample). Falls back to the
    /// bridge window byte-for-byte when either stamp is absent (fixture
    /// engines, pre-#809 usage).
    static func prefillWindowSeconds(
        timing: CBv2RequestTiming,
        submittedAt: ContinuousClock.Instant,
        firstTokenAt: ContinuousClock.Instant
    ) -> Double {
        if timing.prefillFirstLaunchNanos > 0,
            timing.firstTokenNanos > timing.prefillFirstLaunchNanos
        {
            return Double(timing.firstTokenNanos - timing.prefillFirstLaunchNanos) / 1e9
        }
        return WedgeMonitor.seconds(firstTokenAt - submittedAt)
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
        guard tps.isFinite, tps > 0 else { return }
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
    /// Collision guard: an IDENTICAL seeded request that is LIVE or awaiting
    /// async atomic admission would collide inside the engine's per-request
    /// maps, so the derived id falls back to a fresh monotonic id. DOCUMENTED LIMITS of seeded
    /// reproducibility: (a) submissions that overlap their own duplicate
    /// in-flight lose the stable id (this fallback); (b) under batching the
    /// contract is best-effort — the RNG key itself is batch-invariant, but
    /// non-deterministic kernel scheduling can still perturb floating-point
    /// reductions across different batch compositions.
    ///
    /// Its result is inserted into `pendingEngineIDs` in the same synchronous
    /// stretch. That reservation spans the async engine call and closes the
    /// actor-reentrancy gap before `idMap` registration.
    private func mintEngineRequestId(seed: UInt64?, promptTokens: [Int]) -> CBv2RequestID {
        if let seed {
            let stable = CBv2RequestID(
                Self.stableSeededRawId(seed: seed, promptTokens: promptTokens))
            // O(live requests) scan (≤ engine concurrency + waiting cap);
            // only taken on seeded submissions.
            if !idMap.values.contains(stable), !pendingEngineIDs.contains(stable) {
                return stable
            }
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

    /// Number of bridge submissions currently suspended before admission.
    func _testPendingSubmissionCount() -> Int { pendingSubmissionIDs.count }
    /// Profiler identities still retained for pending submissions (leak check).
    func _testPendingProfileCount() -> Int { pendingProfiles.count }
    #if DEBUG
    /// Install a one-shot gate awaited right after the pending id is
    /// registered in `submitTokenized` (see `_testPreSubmitGate`).
    func _testInstallPreSubmitGate(_ gate: @escaping @Sendable () async -> Void) {
        _testPreSubmitGate = gate
    }
    /// Seed the isolated cold-prefill EWMA so `firstTokenDeadlineAdmission`
    /// takes the atomic deadline-submit path against a fake engine.
    func _testSeedIsolatedPrefillEwma(_ tokensPerSecond: Double) {
        isolatedPrefillTokensSum = tokensPerSecond
        isolatedPrefillSecondsSum = 1
        isolatedPrefillTpsEwma = tokensPerSecond
        isolatedPrefillEwmaInitialized = true
        // The seed stands in for a fully measured slot: arm the enforcement
        // floor too, or every seeded test silently takes the fail-open path.
        isolatedPrefillSampleCount = Self.isolatedPrefillSampleFloor
    }
    #endif

    /// Isolated cold samples recorded so far (the enforcement floor input).
    func _testIsolatedPrefillSampleCount() -> Int { isolatedPrefillSampleCount }

    /// Consecutive `deadline_unreachable` refusals since the last submission.
    func _testConsecutiveDeadlineRefusals() -> Int { consecutiveDeadlineRefusals }

    /// Decayed dispersion of the isolated prefill samples (haircut input).
    func _testIsolatedPrefillDispersion() -> Double { isolatedPrefillDispersion }

    /// Number of deterministic/monotonic engine IDs reserved across admission.
    func _testPendingEngineIDCount() -> Int { pendingEngineIDs.count }

    /// Number of provider request IDs currently mapped to engine generations.
    func _testMappedRequestCount() -> Int { idMap.count }

    /// Queue-excluded service rate consumed by deadline projection.
    func _testIsolatedPrefillTps() -> Double {
        isolatedPrefillEwmaInitialized ? isolatedPrefillTpsEwma : 0
    }

    func _testSubmissionInstant(requestId: String) -> ContinuousClock.Instant? {
        active[requestId]?.submittedAt
    }

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
