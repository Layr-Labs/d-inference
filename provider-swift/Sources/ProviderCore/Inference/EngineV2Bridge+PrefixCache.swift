// Copyright © 2026 Eigen Labs.
//
// Prefix-cache surfaces of the v2 bridge:
//
//   * `slotKVBytesClaim()` — the slot's KV claim for fleet sizing.
//
//   * `EngineV2RequestUsageSignal` — per-request out-of-band carrier for
//     the engine's terminal `prefixCacheHitTokens` (the logprobs-channel
//     pattern: `GenerationEvent.info` carries no prefix-cache DETAIL — the
//     shared event stays `.chunk/.info/.error/.terminal` — so usage DETAIL
//     rides beside the stream, not inside it).
//     The coordinator frames loop splices it into the trailing SSE usage
//     chunk as OpenAI-standard `prompt_tokens_details.cached_tokens`.
//
import Foundation
import MLXLMCommon

// MARK: - Per-request usage signal

/// Thread-safe, set-once-read-late box for a request's terminal usage detail,
/// exact matched stop sequence, and final lookup receipt. One instance per request
/// (created by the coordinator inference handler only when the slot serves
/// via the v2 engine); finalized by terminal usage or by the precise
/// pre-terminal failure path. On success the pump records BEFORE yielding
/// terminal events, so the trailing usage frame always observes the write.
public final class EngineV2RequestUsageSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var _matchedStopSequence: String?
    private var _prefixCacheHitTokens: Int?
    private var _prefixCachePrefillTokensSaved: Int?
    private var _stageResult: SSDPrefixCacheStageResult?
    private var _lookupResult: PrefixCacheLookupResult?
    private var _cacheDisabled = false
    /// A positive, advisory resident probe caused the bridge to skip SSD
    /// staging. If the page claim later races with allocator reuse, classify
    /// the cold fallback as memory rather than inventing an SSD miss.
    private var _residentCandidateSeen = false
    private var didEmitLookup = false
    /// Armed before the pump task can run; only the pump may resolve it.
    /// Waiters exist only on canceled settlement, never on ordinary decode.
    private var terminalObservationStarted = false
    private var terminalObservationPending = false
    private var terminalWaiters: [CheckedContinuation<Void, Never>] = []
    private var residentProof: ResidentPrefixCachePromptProof?
    private let onLookupResolved: (@Sendable (PrefixCacheLookupResult) -> Void)?
    let onCacheReady: (@Sendable (PrefixCacheReadyResult) -> Void)?

    public init(
        onLookupResolved: (@Sendable (PrefixCacheLookupResult) -> Void)? = nil,
        onCacheReady: (@Sendable (PrefixCacheReadyResult) -> Void)? = nil
    ) {
        self.onLookupResolved = onLookupResolved
        self.onCacheReady = onCacheReady
    }

    func beginTerminalObservation() {
        lock.withLock {
            precondition(!terminalObservationStarted, "usage signal belongs to one request")
            terminalObservationStarted = true
            terminalObservationPending = true
        }
    }

    /// Called after lookup delivery and the pump's resource cleanup, including
    /// teardown without a native terminal. Resume outside the signal lock.
    func completeTerminalObservation() {
        let waiters = lock.withLock {
            terminalObservationPending = false
            let pending = terminalWaiters
            terminalWaiters.removeAll(keepingCapacity: false)
            return pending
        }
        for waiter in waiters { waiter.resume() }
    }

    /// Cancellation of the consumer must not skip native settlement. The
    /// owning pump is independent of that task and resolves on native finish
    /// or shutdown/stream teardown. A request that never reached a pump has
    /// no observation to await. First content cannot precede pump registration.
    func waitForTerminalObservation() async {
        await withCheckedContinuation { continuation in
            let waiting = lock.withLock {
                guard terminalObservationPending else { return false }
                terminalWaiters.append(continuation)
                return true
            }
            if !waiting { continuation.resume() }
        }
    }

    /// Record the engine-reported prefix-cache hit tokens for this request.
    func record(
        usage: CBv2Usage,
        fallbackTier: PrefixCacheTier = .memory
    ) {
        let resolved: PrefixCacheLookupResult? = lock.withLock {
            // `prefixCacheHitTokens` is the pre-v1 compatibility alias. Old
            // scripted engines may set only that field, so let it raise (never
            // lower) the richer counts.
            let matched = max(0, usage.prefixCacheMatchedTokens, usage.prefixCacheHitTokens)
            let saved = max(0, usage.prefixCachePrefillTokensSaved, usage.prefixCacheHitTokens)
            let engineOutcome: CBv2PrefixCacheOutcome =
                usage.prefixCacheOutcome == .disabled && usage.prefixCacheHitTokens > 0
                ? .hit : usage.prefixCacheOutcome
            // EngineV2 reports the tier that ACTUALLY won adoption. This is
            // essential when resident L1 and staged SSD L2 both match: SSD
            // may have completed its pre-submit read, but a zero-copy L1 win
            // must be billed/telemetried as memory and must not mint a durable
            // holder receipt. nil preserves scripted/older-engine fallback.
            let engineTier: PrefixCacheTier? = switch usage.prefixCacheTier {
            case .resident: .memory
            case .snapshot: .ssd
            case nil: nil
            }
            _prefixCacheHitTokens = matched
            _prefixCachePrefillTokensSaved = saved
            if _cacheDisabled { return nil }
            let unresolvedTier: PrefixCacheTier =
                _residentCandidateSeen ? .memory : fallbackTier
            switch engineOutcome {
            case .hit:
                if engineTier == .memory {
                    _lookupResult = PrefixCacheLookupResult(
                        outcome: .hit,
                        tier: .memory,
                        cachedTokens: matched,
                        prefillTokensSaved: saved,
                        requiredRecomputeTokens: max(0, matched - saved))
                } else if let stage = _stageResult {
                    _lookupResult = stage.resolved(
                        actualCachedTokens: matched,
                        actualPrefillTokensSaved: saved)
                } else {
                    _lookupResult = PrefixCacheLookupResult(
                        outcome: .hit,
                        tier: engineTier ?? unresolvedTier,
                        cachedTokens: matched,
                        prefillTokensSaved: saved)
                }
            case .miss:
                if let stage = _stageResult {
                    _lookupResult = stage.resolved(actualCachedTokens: 0)
                } else {
                    _lookupResult = PrefixCacheLookupResult(
                        outcome: .missAbsent, tier: unresolvedTier)
                }
            case .skippedCapacity:
                _lookupResult = _stageResult?.resolved(failure: .capacity)
                    ?? PrefixCacheLookupResult(
                        outcome: .skippedCapacity, tier: unresolvedTier)
            case .skippedPolicy, .disabled, .adoptionFailed:
                _lookupResult = _stageResult?.resolved(failure: .policy)
                    ?? PrefixCacheLookupResult(
                        outcome: .skippedPolicy, tier: unresolvedTier)
            }
            if let result = _lookupResult, result.tier == .memory, let residentProof {
                _lookupResult = residentProof.resolve(result)
            }
            guard !didEmitLookup, let result = _lookupResult else { return nil }
            didEmitLookup = true
            return result
        }
        if let resolved { onLookupResolved?(resolved) }
    }

    /// Compatibility helper for scripted tests/older callers whose usage did
    /// not yet expose the richer engine outcome.
    func record(prefixCacheHitTokens: Int) {
        let tokens = max(0, prefixCacheHitTokens)
        record(
            usage: CBv2Usage(
                promptTokens: 0,
                completionTokens: 0,
                prefixCacheHitTokens: tokens,
                prefixCacheOutcome: tokens > 0 ? .hit : .miss,
                prefixCacheMatchedTokens: tokens,
                prefixCachePrefillTokensSaved: tokens))
    }

    func record(stageResult: SSDPrefixCacheStageResult) {
        lock.withLock { _stageResult = stageResult }
    }

    func recordResidentPrompt(_ proof: ResidentPrefixCachePromptProof) {
        lock.withLock { residentProof = proof }
    }

    func recordResidentPublication(checkpointTokens: [Int]) {
        let proof = lock.withLock { residentProof }
        if let ready = proof?.publication(checkpointTokens: checkpointTokens) {
            onCacheReady?(ready)
        }
    }

    func recordResidentPrefixCandidate() {
        lock.withLock { _residentCandidateSeen = true }
    }

    func finalizeLookup(
        failure: PrefixCacheLookupFailureClass,
        fallbackTier: PrefixCacheTier
    ) {
        let resolved: PrefixCacheLookupResult? = lock.withLock {
            guard !didEmitLookup else { return nil }
            let unresolvedTier: PrefixCacheTier =
                _residentCandidateSeen ? .memory : fallbackTier
            let result = _stageResult?.resolved(failure: failure)
                ?? PrefixCacheLookupResult(
                    outcome: failure == .capacity ? .skippedCapacity : .skippedPolicy,
                    tier: unresolvedTier)
            let resolved = result.tier == .memory
                ? (residentProof?.resolve(result) ?? result) : result
            _lookupResult = resolved
            didEmitLookup = true
            return resolved
        }
        if let resolved { onLookupResolved?(resolved) }
    }

    func recordCacheDisabled(tier: PrefixCacheTier?) {
        let resolved: PrefixCacheLookupResult? = lock.withLock {
            _cacheDisabled = true
            _lookupResult = PrefixCacheLookupResult(
                outcome: .skippedPolicy, tier: tier)
            guard !didEmitLookup, let result = _lookupResult else { return nil }
            didEmitLookup = true
            return result
        }
        if let resolved { onLookupResolved?(resolved) }
    }

    func record(matchedStopSequence: String?) {
        guard let matchedStopSequence, !matchedStopSequence.isEmpty else { return }
        lock.withLock { _matchedStopSequence = matchedStopSequence }
    }

    public var matchedStopSequence: String? {
        lock.withLock { _matchedStopSequence }
    }

    /// Engine-reported prompt tokens whose KV was adopted from the prefix
    /// cache (0 on a miss). nil until the request reached its terminal.
    public var prefixCacheHitTokens: Int? {
        lock.withLock { _prefixCacheHitTokens }
    }

    public var prefixCachePrefillTokensSaved: Int? {
        lock.withLock { _prefixCachePrefillTokensSaved }
    }

    public var lookupResult: PrefixCacheLookupResult? {
        lock.withLock { _lookupResult }
    }
}

// MARK: - Bridge surfaces

extension EngineV2Bridge {

    nonisolated func prefixCacheEvidenceCallbacks(
        requestID: String, nonce: String, send: SendHandle,
        readyBoundaryMode: String? = nil
    ) -> PrefixCacheV2EvidenceCallbacks? {
        let ssd = prefixCacheEvidenceSequencer?.callbacks(
            requestID: requestID, nonce: nonce, send: send,
            readyBoundaryMode: readyBoundaryMode)
        let memory = residentPrefixCacheEvidenceSequencer?.callbacks(
            requestID: requestID, nonce: nonce, send: send,
            forwardTerminal: ssd == nil)
        guard ssd != nil || memory != nil else { return nil }
        return PrefixCacheV2EvidenceCallbacks(
            lookup: { result in
                ssd?.lookup(result)
                memory?.lookup(result)
            },
            ready: { result in
                ssd?.ready(result)
                memory?.ready(result)
            },
            terminal: { message in
                memory?.terminal(message)
                ssd?.terminal(message)
            })
    }

    nonisolated func prefixCacheModelStatus() -> PrefixCacheModelStatus {
        guard let durablePrefixCacheEvidenceSource else { return prefixCacheBaseStatus }
        return durablePrefixCacheEvidenceSource.prefixCacheAdvertisement(base: prefixCacheBaseStatus).status
    }

    func emitPrefixCacheColdFallback(
        requestId: String,
        reason: String,
        capacityRefusal: Bool
    ) {
        prefixCacheFallbackTelemetrySeen &+= 1
        guard prefixCacheFallbackTelemetrySeen == 1
            || prefixCacheFallbackTelemetrySeen.isMultiple(of: 64)
        else { return }
        var event = TelemetryEvent(
            source: .provider,
            severity: .warn,
            kind: .engineHealth,
            message: "engine_v2: prefix reuse fell back cold"
        )
        event.fields = TelemetryFieldFilter.filter([
            "component": .string("engine"),
            "operation": .string("prefix_cache_replay"),
            // `backend` names the ENGINE executing inference, matching
            // RegisterMessage.backend on the wire. The KV STORAGE KIND is a
            // separate axis and rides `kv_backend` — deliberately the same
            // key and vocabulary as BackendSlotCapacity.KVBackend on the
            // heartbeat wire, so telemetry and per-slot capacity group
            // identically. Never fold one into the other.
            "backend": .string("engine_v2"),
            "kv_backend": .string(kvBackendKind.rawValue),
            "model": .string(modelId),
            "reason": .string(reason),
            "prefix_reuse_strategy": .string("none"),
            "prefix_matched_tokens": .int(0),
            "prefix_replay_tokens": .int(0),
            "prefix_saved_tokens": .int(0),
            "prefix_boundary_splits": .int(0),
            "prefix_capacity_refusal": .bool(capacityRefusal),
            "prefix_cold_fallback": .bool(true),
        ])
        event.requestId = requestId
        emit(event)
    }

    /// Content-free exact-prefix replay outcome. All values are bounded enums,
    /// booleans, or aggregate counts; token ids and prompt/cache identities
    /// never enter telemetry.
    func emitPrefixReuseTelemetry(requestId: String, usage: CBv2Usage) {
        switch usage.prefixCacheOutcome {
        case .hit:
            prefixCacheHitTelemetrySeen &+= 1
            guard prefixCacheHitTelemetrySeen == 1
                || prefixCacheHitTelemetrySeen.isMultiple(of: 64)
            else { return }
        case .skippedCapacity, .adoptionFailed:
            prefixCacheFallbackTelemetrySeen &+= 1
            guard prefixCacheFallbackTelemetrySeen == 1
                || prefixCacheFallbackTelemetrySeen.isMultiple(of: 64)
            else { return }
        case .disabled, .skippedPolicy, .miss:
            return
        }
        let outcome: String
        switch usage.prefixCacheOutcome {
        case .disabled: outcome = "disabled"
        case .skippedPolicy: outcome = "skipped_policy"
        case .miss: outcome = "miss"
        case .hit: outcome = "hit"
        case .skippedCapacity: outcome = "skipped_capacity"
        case .adoptionFailed: outcome = "adoption_failed"
        }
        let coldFallback =
            usage.prefixCacheOutcome == .skippedPolicy
            || usage.prefixCacheOutcome == .skippedCapacity
            || usage.prefixCacheOutcome == .adoptionFailed
        var event = TelemetryEvent(
            source: .provider,
            severity: coldFallback ? .warn : .info,
            kind: .engineHealth,
            message: "engine_v2: exact prefix reuse resolved"
        )
        event.fields = TelemetryFieldFilter.filter([
            "component": .string("engine"),
            "operation": .string("prefix_cache_replay"),
            // Same two axes as the cold-fallback event above.
            "backend": .string("engine_v2"),
            "kv_backend": .string(kvBackendKind.rawValue),
            "model": .string(modelId),
            "reason": .string(outcome),
            "prefix_reuse_strategy": .string(
                usage.prefixCacheStrategy?.rawValue ?? "none"),
            "prefix_matched_tokens": .int(max(0, usage.prefixCacheMatchedTokens)),
            "prefix_replay_tokens": .int(max(0, usage.prefixCacheReplayTokens)),
            "prefix_saved_tokens": .int(max(0, usage.prefixCachePrefillTokensSaved)),
            "prefix_boundary_splits": .int(max(0, usage.prefixCacheBoundarySplits)),
            "prefix_capacity_refusal": .bool(
                usage.prefixCacheOutcome == .skippedCapacity),
            "prefix_cold_fallback": .bool(coldFallback),
        ])
        event.requestId = requestId
        emit(event)
    }

    /// Slot KV grant for contiguous/segmented storage; physical capacity for
    /// an explicit fixed-reference paged pool. Actual segmented ownership is
    /// tracked by native Admission and the shared process ledger.
    /// Fleet sizing (`makeEngineV2BridgeForSlot`) and the heartbeat clamp
    /// (`EngineV2Runtime.capacitySummary`) subtract THIS — not the bare
    /// engine capacity — for co-resident slots.
    public func slotKVBytesClaim() -> Int {
        let snapshot = capacitySnapshot()
        let engineClaim =
            kvBackendKind == .paged && snapshot.kvBytesBackendCapacity > 0
            ? snapshot.kvBytesBackendCapacity
            : snapshot.kvBytesCapacity
        return engineClaim
    }

    /// Current logical admission target. Re-slice rollback uses this exact
    /// value; unlike `slotKVBytesClaim()`, it does
    /// not replace a shrunk fixed-reference ledger with its larger physical pool.
    func resliceAdmissionBytesClaim() -> Int {
        engine.capacity().kvBytesCapacity
    }
}
