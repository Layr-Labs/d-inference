// Copyright © 2026 Eigen Labs.
//
// Prefix-cache surfaces of the v2 bridge:
//
//   * `slotKVBytesClaim()` — the slot's TOTAL KV claim (engine admission
//     ceiling + prefix-cache budget) for fleet sizing. The prefix budget
//     was carved OUT of the engine's `kvBytesCapacity` at construction
//     (`PrefixCachePolicy.carve`), so reading the engine's capacity alone
//     would under-count what this slot pins and let a later engine be
//     granted the bytes the cache is using.
//
//   * `EngineV2RequestUsageSignal` — per-request out-of-band carrier for
//     the engine's terminal `prefixCacheHitTokens` (the logprobs-channel
//     pattern: `GenerationEvent.info` deliberately stays `.chunk/.info/
//     .error`, so usage DETAIL rides beside the stream, not inside it).
//     The coordinator frames loop splices it into the trailing SSE usage
//     chunk as OpenAI-standard `prompt_tokens_details.cached_tokens`.
//
//   * the periodic stats logger — v2 analog of the legacy checkpoint-tier
//     `startPrefixCacheStatsLogger`: one os-log info line per interval
//     (`DARKBLOOM_PREFIX_CACHE_STATS_INTERVAL_SECS`, default 120s, 0
//     disables) reading `PrefixCacheV2.stats()`, tagged `engine=v2` to
//     distinguish it from the legacy line in `darkbloom logs`.

import Foundation
import MLXLMCommon
#if canImport(os)
import os
#endif

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
                _lookupResult = PrefixCacheLookupResult(
                    outcome: .hit,
                    tier: fallbackTier,
                    cachedTokens: matched,
                    prefillTokensSaved: saved,
                    stageMs: _stageResult?.stageMs)
            case .miss:
                if let stage = _stageResult {
                    _lookupResult = stage.resolved(actualCachedTokens: 0)
                } else {
                    _lookupResult = PrefixCacheLookupResult(
                        outcome: .missAbsent, tier: fallbackTier)
                }
            case .skippedCapacity:
                _lookupResult = PrefixCacheLookupResult(
                    outcome: .skippedCapacity,
                    tier: fallbackTier,
                    stageMs: _stageResult?.stageMs)
            case .skippedPolicy, .disabled, .adoptionFailed:
                _lookupResult = PrefixCacheLookupResult(
                    outcome: .skippedPolicy,
                    tier: fallbackTier,
                    stageMs: _stageResult?.stageMs)
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

    #if canImport(os)
    private static let prefixCacheLogger = Logger(
        subsystem: "com.darkbloom.provider", category: "prefix_cache")
    #endif

    /// The slot's TOTAL KV byte claim: for contiguous, the engine admission
    /// ceiling; for paged, the immutable PHYSICAL backend capacity; then
    /// PLUS the prefix-cache budget carved out of the slot grant.
    /// Fleet sizing (`makeEngineV2BridgeForSlot`) and the heartbeat clamp
    /// (`EngineV2Runtime.capacitySummary`) subtract THIS — not the bare
    /// engine capacity — for co-resident slots, so Σ(engine ceilings +
    /// cache budgets) never exceeds the unified-memory KV budget.
    public func slotKVBytesClaim() -> Int {
        let snapshot = engine.capacity()
        let engineClaim =
            kvBackendKind == .paged && snapshot.kvBytesBackendCapacity > 0
            ? snapshot.kvBytesBackendCapacity
            : snapshot.kvBytesCapacity
        let (sum, overflow) = engineClaim
            .addingReportingOverflow(prefixCacheBudgetBytes)
        return overflow ? Int.max : sum
    }

    /// Current logical admission target plus the fixed prefix carve. Re-slice
    /// rollback uses this exact value; unlike `slotKVBytesClaim()`, it does
    /// not replace a shrunk paged ledger with the larger immutable pool.
    func resliceAdmissionBytesClaim() -> Int {
        let (sum, overflow) = engine.capacity().kvBytesCapacity
            .addingReportingOverflow(prefixCacheBudgetBytes)
        return overflow ? Int.max : sum
    }

    /// Start the periodic stats logger over a funded cache. Idempotent per
    /// call (cancels any prior task); cancelled for good in `shutdown()`.
    /// `intervalSecs ≤ 0` disables (mirrors the legacy logger's contract).
    /// Internal (called by the slot factory; @testable for tests) — the
    /// default argument references the internal `PrefixCachePolicy`.
    func startPrefixCacheStatsLogger(
        cache: PrefixCacheV2,
        intervalSecs: Int = PrefixCachePolicy.statsIntervalSecs()
    ) {
        prefixCacheStatsTask?.cancel()
        prefixCacheStatsTask = nil
        guard intervalSecs > 0 else { return }
        let modelId = self.modelId
        let budget = self.prefixCacheBudgetBytes
        prefixCacheStatsTask = Task.detached { [weak cache] in
            while !Task.isCancelled {
                try? await taskSleep( .seconds(intervalSecs))
                if Task.isCancelled { return }
                guard let cache else { return }
                Self.logPrefixCacheStats(cache: cache, modelId: modelId, budgetBytes: budget)
            }
        }
    }

    /// One info line per interval — the v2 mirror of the legacy
    /// `logPrefixCacheStats` line, with an `engine=v2` distinguisher.
    /// Counts only (hits/misses/tokensSaved/entries/bytes) — token content
    /// never appears here.
    static func logPrefixCacheStats(
        cache: PrefixCacheV2, modelId: String, budgetBytes: Int
    ) {
        let s = cache.stats()
        let lookups = s.hits + s.misses
        let rate = lookups > 0 ? (Double(s.hits) * 100.0 / Double(lookups)) : 0.0
        #if canImport(os)
        // os.Logger redacts non-literal interpolations (String(format:)) as
        // <private> by default; mark the rate .public so it is readable.
        let rateStr = String(format: "%.1f", rate)
        Self.prefixCacheLogger.info(
            "prefix cache stats (engine=v2, model=\(modelId, privacy: .public)): lookups=\(lookups) hits=\(s.hits) misses=\(s.misses) hitRate=\(rateStr, privacy: .public)% tokensSaved=\(s.tokensSaved) entries=\(s.entryCount) bytesInUse=\(s.bytesInUse) budgetBytes=\(budgetBytes)"
        )
        #endif
    }
}
