// Copyright © 2026 Eigen Labs.
//
// Shared state and initialization for one provider model engine.
// Submission and admission live in +Submission / +Admission; cancellation and
// shutdown in +Lifecycle; KV grants in +Resizing; request IDs in +Identity.
// +Events translates the engine stream; +Accounting records usage and rates.

import Foundation
import MLXLMCommon
import ProviderCoreFoundation

/// Bridges one `CBv2Engine` (one loaded model) to the provider's
/// `GenerationEvent` streaming surface.
///
/// Event contract (fixture-pinned in `EngineV2BridgeTests`):
///   * text deltas       → `.chunk(text)` (empty deltas suppressed)
///   * finish stop/length→ `.info(prompt, completion, tps, reason)` then
///                         finish (reason "stop"/"length" preserved)
///   * cancelled         → `.info(usage, reason: nil)` if any tokens were
///                         produced, then `.error("request cancelled")`
///   * engine error      → `.error(message)` (no `.info`)
///   * admission failure → single `.error("token_budget_exhausted: …")`
///   * stream torn down  → `.error("request stream closed by engine teardown")`
public actor EngineV2Bridge {

    // MARK: - Immutable configuration

    /// Shutdown drains and releases the engine before the slot owner purges
    /// MLX cache or grows the surviving models' memory grants.
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
    /// Construction-time fallback reason, retained for heartbeat reporting.
    /// Admission and resizing depend on the actual kvBackendKind only.
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
    nonisolated let ssdHybridCheckpointStore: SSDHybridCheckpointStore?
    nonisolated var durablePrefixCacheEvidenceSource: (any DurablePrefixCacheEvidenceSource)? {
        if let ssdHybridCheckpointStore { return ssdHybridCheckpointStore }
        return ssdPrefixCache
    }
    nonisolated var prefixCacheFallbackTier: PrefixCacheTier {
        ssdPrefixCache != nil || ssdHybridCheckpointStore != nil ? .ssd : .memory
    }
    nonisolated let prefixCacheBaseStatus: PrefixCacheModelStatus
    nonisolated let prefixCacheEvidenceSequencer: PrefixCacheEvidenceSequencer?
    nonisolated let residentPrefixCacheEvidence: ResidentPrefixCacheEvidence?
    nonisolated let residentPrefixCacheEvidenceSequencer: PrefixCacheEvidenceSequencer?
    /// Periodic prefix-cache stats logger (v2 analog of the legacy
    /// checkpoint-tier logger). Started by the slot factory when an active
    /// cache exists; cancelled in `shutdown()`.
    var prefixCacheStatsTask: Task<Void, Never>?
    let prefixCacheTelemetry = SSDPrefixCacheTelemetryBox()
    var pagedStorageTelemetry = PagedStorageTelemetryAdapter()
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

    // MARK: - Health / telemetry state

    /// Heartbeat health is sampled from the engine's monotonic step counter.
    var wedgeMonitor = WedgeMonitor()
    var observedDecodeTpsEwma: Double = 0
    var ewmaInitialized = false
    /// Cold-prefill throughput from successful requests with no adopted KV.
    /// Uses engine admission → first token, with plausibility bounds applied
    /// by recordPrefillSample. Cache-hit latency never trains this estimate.
    var observedPrefillTpsEwma: Double = 0
    var prefillEwmaInitialized = false
    /// Queue- and decode-excluded cold-prefill service-rate EWMA used ONLY by
    /// atomic scheduler deadline projection. A sample is eligible only when
    /// no other request of any phase is active or pending at its exact submit
    /// boundary. Mixed decode work is priced separately; it must never be
    /// hidden inside this prefill denominator.
    var isolatedPrefillTpsEwma: Double = 0
    var isolatedPrefillEwmaInitialized = false
    /// Observed EWMAs are point estimates, not hard lower bounds. Deadline
    /// projection halves each available phase rate, providing a fixed 2x
    /// service-time envelope without letting one pathological minimum poison
    /// the bridge forever.
    static let deadlineProjectionRateHaircut = 0.5
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
    /// Last requested paged grant. Segmented storage follows it; an explicit
    /// fixed-reference pool uses it to report resize shortfall. nil before
    /// the first re-slice.
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
        ssdHybridCheckpointStore: SSDHybridCheckpointStore? = nil,
        residentPrefixCacheEvidence: ResidentPrefixCacheEvidence? = nil,
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
        let completeStore: SSDHybridCheckpointStore?
        if let candidate = ssdHybridCheckpointStore,
            let accepted = (engine as? EngineV2)?.completePrefixCache,
            accepted === candidate
        {
            completeStore = candidate
        } else {
            ssdHybridCheckpointStore?.close()
            completeStore = nil
        }
        self.ssdHybridCheckpointStore = completeStore
        let durableSource: (any DurablePrefixCacheEvidenceSource)? =
            completeStore.map { $0 as any DurablePrefixCacheEvidenceSource } ?? ssdPrefixCache
        let cacheRejected = ssdHybridCheckpointStore != nil && completeStore == nil
        self.prefixCacheBaseStatus = cacheRejected ? PrefixCacheModelStatus(
            modelId: modelId, backend: PrefixCacheStatusBackend(kvBackendKind),
            replayStrategy: .unknown, state: .disabled, reason: .unsupportedLayout
        ) : prefixCacheStatus ?? PrefixCacheModelStatus(
            modelId: modelId,
            backend: PrefixCacheStatusBackend(kvBackendKind),
            replayStrategy: .unknown,
            state: durableSource == nil ? .disabled : .pending,
            reason: durableSource == nil ? .unsupportedBackend : .scanPending)
        self.prefixCacheEvidenceSequencer = durableSource.map {
            PrefixCacheEvidenceSequencer(source: $0)
        }
        // Complete-checkpoint lookup always precedes the resident bank.
        // Do not advertise a tier this engine cannot adopt, including while
        // its durable capability is temporarily absent during a scan/epoch change.
        let residentEvidence = (engine as? EngineV2)?.hybridPrefixCache == nil
            || (engine as? EngineV2)?.completePrefixCache != nil
            ? nil : residentPrefixCacheEvidence
        self.residentPrefixCacheEvidence = residentEvidence
        self.residentPrefixCacheEvidenceSequencer = residentEvidence.map { evidence in
            PrefixCacheEvidenceSequencer(tier: .memory, capabilityProvider: { [weak evidence] in
                evidence?.capability()
            })
        }
        if let residentEvidence, let liveEngine = engine as? EngineV2 {
            liveEngine.setResidentPrefixPublicationHandler { [weak residentEvidence] receiptID, positions in
                residentEvidence?.publish(receiptID: receiptID, checkpointTokens: positions)
            }
        }
        if let completeStore, let liveEngine = engine as? EngineV2 {
            liveEngine.setCompletePrefixPublicationHandler { [weak completeStore] receiptID, positions in
                completeStore?.publishReady(requestID: receiptID, positions: positions)
            }
        }
        self.emitTelemetry = emitTelemetry
    }

    /// Deterministic timing seam for prefill-sampling tests.
    func backdateSubmissionForTesting(requestId: String, byMilliseconds milliseconds: Int64) {
        guard var state = active[requestId] else { return }
        state.submittedAt = state.submittedAt.advanced(by: .milliseconds(-milliseconds))
        active[requestId] = state
    }

    // MARK: - Test seams (internal; reachable via @testable only)

    /// Number of live pump tasks (shutdown-tracking assertions).
    func _testLivePumpCount() -> Int { pumpTasks.count }

    /// Number of bridge submissions currently suspended before admission.
    func _testPendingSubmissionCount() -> Int { pendingSubmissionIDs.count }
    /// Profiler identities still retained for pending submissions (leak check).
    func _testPendingProfileCount() -> Int { pendingProfiles.count }
    #if DEBUG
    var _testBeforeNativeTerminal: (@Sendable (CBv2Usage) async -> Void)?
    var _testOnCancelledSettlementWait: (@Sendable () -> Void)?

    func _testInstallCancelledSettlementHooks(
        beforeNativeTerminal: @escaping @Sendable (CBv2Usage) async -> Void,
        onSettlementWait: @escaping @Sendable () -> Void
    ) {
        _testBeforeNativeTerminal = beforeNativeTerminal
        _testOnCancelledSettlementWait = onSettlementWait
    }

    /// Install a one-shot gate awaited right after the pending id is
    /// registered in `submitTokenized` (see `_testPreSubmitGate`).
    func _testInstallPreSubmitGate(_ gate: @escaping @Sendable () async -> Void) {
        _testPreSubmitGate = gate
    }
    /// Seed the isolated cold-prefill EWMA so `firstTokenDeadlineAdmission`
    /// takes the atomic deadline-submit path against a fake engine.
    func _testSeedIsolatedPrefillEwma(_ tokensPerSecond: Double) {
        isolatedPrefillTpsEwma = tokensPerSecond
        isolatedPrefillEwmaInitialized = true
    }
    #endif

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
