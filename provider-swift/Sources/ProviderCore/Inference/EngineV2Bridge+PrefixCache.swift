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
/// detail. One instance per inference request (created by the coordinator
/// inference handler only when the slot serves via the v2 engine); written
/// by the bridge pump at the engine terminal, read by the frames loop when
/// the trailing usage chunk arrives. The pump records BEFORE yielding the
/// terminal events, and the usage SSE frame is only encoded downstream of
/// those events, so the read always observes the write.
public final class EngineV2RequestUsageSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var _prefixCacheHitTokens: Int?

    public init() {}

    /// Record the engine-reported prefix-cache hit tokens for this request.
    func record(prefixCacheHitTokens: Int) {
        lock.withLock { _prefixCacheHitTokens = max(0, prefixCacheHitTokens) }
    }

    /// Engine-reported prompt tokens whose KV was adopted from the prefix
    /// cache (0 on a miss). nil until the request reached its terminal.
    public var prefixCacheHitTokens: Int? {
        lock.withLock { _prefixCacheHitTokens }
    }
}

// MARK: - Bridge surfaces

extension EngineV2Bridge {

    #if canImport(os)
    private static let prefixCacheLogger = Logger(
        subsystem: "com.darkbloom.provider", category: "prefix_cache")
    #endif

    /// The slot's TOTAL KV byte claim: the engine's construction-fixed
    /// admission ceiling PLUS the prefix-cache budget carved out of it.
    /// Fleet sizing (`makeEngineV2BridgeForSlot`) and the heartbeat clamp
    /// (`EngineV2Runtime.capacitySummary`) subtract THIS — not the bare
    /// engine capacity — for co-resident slots, so Σ(engine ceilings +
    /// cache budgets) never exceeds the unified-memory KV budget.
    public func slotKVBytesClaim() -> Int {
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
                try? await Task.sleep(for: .seconds(intervalSecs))
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
