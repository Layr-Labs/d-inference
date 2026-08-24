// Copyright © 2026 Eigen Labs.
//
// Status and periodic aggregate logging for the process-local exact-state RAM
// cache. No prompt tokens, scopes, artifact digests, or cache keys leave the
// cache object.

import Foundation
import MLXLMCommon
#if canImport(os)
import os
#endif

struct ExactPrefixCacheStatusSnapshot: Sendable, Equatable {
    let configured: Bool
    let active: Bool
    let reason: String
    let budgetBytes: Int
    let bytesInUse: Int
    let entries: Int
    let hits: Int
    let misses: Int
    let tokensSaved: Int
    let donations: Int
    let donationsDropped: Int
    let evictions: Int
}

extension EngineV2Bridge {
    #if canImport(os)
    private static let exactPrefixStatsLogger = Logger(
        subsystem: "com.darkbloom.provider", category: "prefix_cache")
    #endif

    nonisolated func exactPrefixCacheStatusSnapshot()
        -> ExactPrefixCacheStatusSnapshot
    {
        let stats = exactPrefixCache?.stats()
        return ExactPrefixCacheStatusSnapshot(
            configured: exactPrefixCacheConfigured,
            active: exactPrefixCache != nil,
            reason: exactPrefixCacheReason,
            budgetBytes: exactPrefixCacheBudgetBytes,
            bytesInUse: stats?.bytesInUse ?? 0,
            entries: stats?.entryCount ?? 0,
            hits: stats?.hits ?? 0,
            misses: stats?.misses ?? 0,
            tokensSaved: stats?.tokensSaved ?? 0,
            donations: stats?.donations ?? 0,
            donationsDropped: stats?.donationsDropped ?? 0,
            evictions: stats?.evictions ?? 0)
    }

    /// Reuses the bridge's one prefix-cache task slot. Exact RAM and legacy
    /// SSD are mutually exclusive for a slot.
    func startExactPrefixCacheStatsLogger(
        cache: ExactPrefixCacheV2,
        intervalSecs: Int = PrefixCachePolicy.statsIntervalSecs()
    ) {
        prefixCacheStatsTask?.cancel()
        prefixCacheStatsTask = nil
        guard intervalSecs > 0 else { return }
        let modelId = self.modelId
        let budgetBytes = exactPrefixCacheBudgetBytes
        prefixCacheStatsTask = Task.detached { [weak cache] in
            while !Task.isCancelled {
                try? await taskSleep(.seconds(intervalSecs))
                if Task.isCancelled { return }
                guard let cache else { return }
                Self.logExactPrefixCacheStats(
                    cache: cache, modelId: modelId, budgetBytes: budgetBytes)
            }
        }
    }

    static func logExactPrefixCacheStats(
        cache: ExactPrefixCacheV2,
        modelId: String,
        budgetBytes: Int
    ) {
        let stats = cache.stats()
        let (lookupSum, lookupOverflow) = stats.hits.addingReportingOverflow(
            stats.misses)
        let lookups = lookupOverflow ? Int.max : lookupSum
        let rate =
            lookups > 0
            ? Double(stats.hits) * 100.0 / Double(lookups)
            : 0
        #if canImport(os)
        let rateString = String(format: "%.1f", rate)
        Self.exactPrefixStatsLogger.info(
            "prefix cache stats (engine=v2, tier=ram_exact_state, model=\(modelId, privacy: .public)): budgetBytes=\(budgetBytes) bytesInUse=\(stats.bytesInUse) entries=\(stats.entryCount) lookups=\(lookups) hits=\(stats.hits) misses=\(stats.misses) hitRate=\(rateString, privacy: .public)% tokensSaved=\(stats.tokensSaved) donations=\(stats.donations) donationsDropped=\(stats.donationsDropped) evictions=\(stats.evictions)"
        )
        #endif
    }
}
