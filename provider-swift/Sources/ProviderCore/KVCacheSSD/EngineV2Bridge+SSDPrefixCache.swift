// Copyright © 2026 Eigen Labs.
//
// SSD-tier stats logging for the v2 bridge — extends the existing
// `engine=v2` prefix-cache log line shape with `tier=ssd` counters
// (writes, bytes, hits, staged bytes, evictions, sweeps). Counts only;
// token content never appears here.

import Foundation
#if canImport(os)
import os
#endif

extension EngineV2Bridge {

    #if canImport(os)
    private static let ssdStatsLogger = Logger(
        subsystem: "com.darkbloom.provider", category: "prefix_cache")
    #endif

    /// Start the periodic stats logger over the SSD tier. Reuses the
    /// bridge's single stats-task slot (a slot runs ONE tier), same
    /// cadence contract as the RAM logger (`intervalSecs ≤ 0` disables);
    /// cancelled in `shutdown()`.
    func startSSDPrefixCacheStatsLogger(
        cache: SSDPrefixCache,
        intervalSecs: Int = PrefixCachePolicy.statsIntervalSecs()
    ) {
        prefixCacheStatsTask?.cancel()
        prefixCacheStatsTask = nil
        guard intervalSecs > 0 else { return }
        let modelId = self.modelId
        prefixCacheStatsTask = Task.detached { [weak cache] in
            while !Task.isCancelled {
                try? await taskSleep(.seconds(intervalSecs))
                if Task.isCancelled { return }
                guard let cache, !cache.isClosed else { return }
                Self.logSSDPrefixCacheStats(cache: cache, modelId: modelId)
            }
        }
    }

    /// One info line per interval — the `tier=ssd` sibling of the
    /// `engine=v2` RAM-cache line in `darkbloom logs`.
    static func logSSDPrefixCacheStats(cache: SSDPrefixCache, modelId: String) {
        let s = cache.stats()
        let lookups = s.hits + s.misses
        let rate = lookups > 0 ? (Double(s.hits) * 100.0 / Double(lookups)) : 0.0
        #if canImport(os)
        let rateStr = String(format: "%.1f", rate)
        Self.ssdStatsLogger.info(
            "prefix cache stats (engine=v2, tier=ssd, model=\(modelId, privacy: .public)): lookups=\(lookups) hits=\(s.hits) misses=\(s.misses) hitRate=\(rateStr, privacy: .public)% tokensSaved=\(s.tokensSaved) stages=\(s.stages) stagedBytes=\(s.stagedBytesInUse) blocksWritten=\(s.blocksWritten) bytesWritten=\(s.bytesWritten) windowSidecars=\(s.windowSidecarsWritten) windowsRestored=\(s.windowsRestored) donationsDropped=\(s.donationsDropped) rateLimited=\(s.writeRateLimited) corruptDropped=\(s.corruptDropped) evictions=\(s.evictions) ttlExpired=\(s.ttlExpired) entries=\(s.entries) bytesOnDisk=\(s.bytesOnDisk)"
        )
        #endif
    }
}
