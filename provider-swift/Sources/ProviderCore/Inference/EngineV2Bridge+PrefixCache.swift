// Copyright © 2026 Eigen Labs.
//
// Prefix-cache surfaces of the v2 bridge:
//
//   * `slotKVBytesClaim()` — the slot's KV claim for fleet sizing.
//
//   * `EngineV2RequestUsageSignal` — per-request out-of-band carrier for
//     the engine's terminal `prefixCacheHitTokens` (the logprobs-channel
//     pattern: `GenerationEvent.info` deliberately stays `.chunk/.info/
//     .error`, so usage DETAIL rides beside the stream, not inside it).
//     The coordinator frames loop splices it into the trailing SSE usage
//     chunk as OpenAI-standard `prompt_tokens_details.cached_tokens`.
//
import Foundation
import MLXLMCommon

// MARK: - Per-request usage signal

/// Thread-safe, set-once-read-late box for a request's terminal usage
/// detail and final lookup receipt. One instance per inference request
/// (created by the coordinator inference handler only when the slot serves
/// via the v2 engine); finalized by terminal usage or by the precise
/// pre-terminal failure path. On success the pump records BEFORE yielding
/// terminal events, so the trailing usage frame always observes the write.
public final class EngineV2RequestUsageSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var _prefixCacheHitTokens: Int?
    private var _prefixCachePrefillTokensSaved: Int?
    private var _stageResult: SSDPrefixCacheStageResult?
    private var _lookupResult: PrefixCacheLookupResult?
    private var _cacheDisabled = false
    private var didEmitLookup = false
    private let onLookupResolved: (@Sendable (PrefixCacheLookupResult) -> Void)?
    let onCacheReady: (@Sendable (PrefixCacheReadyResult) -> Void)?

    public init(
        onLookupResolved: (@Sendable (PrefixCacheLookupResult) -> Void)? = nil,
        onCacheReady: (@Sendable (PrefixCacheReadyResult) -> Void)? = nil
    ) {
        self.onLookupResolved = onLookupResolved
        self.onCacheReady = onCacheReady
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
            _prefixCacheHitTokens = matched
            _prefixCachePrefillTokensSaved = saved
            if _cacheDisabled { return nil }
            switch engineOutcome {
            case .hit:
                if let stage = _stageResult {
                    _lookupResult = stage.resolved(
                        actualCachedTokens: matched,
                        actualPrefillTokensSaved: saved)
                } else {
                    _lookupResult = PrefixCacheLookupResult(
                        outcome: .hit,
                        tier: fallbackTier,
                        cachedTokens: matched,
                        prefillTokensSaved: saved)
                }
            case .miss:
                if let stage = _stageResult {
                    _lookupResult = stage.resolved(actualCachedTokens: 0)
                } else {
                    _lookupResult = PrefixCacheLookupResult(
                        outcome: .missAbsent, tier: fallbackTier)
                }
            case .skippedCapacity:
                _lookupResult = _stageResult?.resolved(failure: .capacity)
                    ?? PrefixCacheLookupResult(
                        outcome: .skippedCapacity, tier: fallbackTier)
            case .skippedPolicy, .disabled, .adoptionFailed:
                _lookupResult = _stageResult?.resolved(failure: .policy)
                    ?? PrefixCacheLookupResult(
                        outcome: .skippedPolicy, tier: fallbackTier)
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

    func finalizeLookup(
        failure: PrefixCacheLookupFailureClass,
        fallbackTier: PrefixCacheTier
    ) {
        let resolved: PrefixCacheLookupResult? = lock.withLock {
            guard !didEmitLookup else { return nil }
            let result = _stageResult?.resolved(failure: failure)
                ?? PrefixCacheLookupResult(
                    outcome: failure == .capacity ? .skippedCapacity : .skippedPolicy,
                    tier: fallbackTier)
            _lookupResult = result
            didEmitLookup = true
            return result
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

    /// The slot's TOTAL KV byte claim: for contiguous, the engine admission
    /// ceiling; for paged, the immutable PHYSICAL backend capacity.
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
    /// not replace a shrunk paged ledger with the larger immutable pool.
    func resliceAdmissionBytesClaim() -> Int {
        engine.capacity().kvBytesCapacity
    }
}
