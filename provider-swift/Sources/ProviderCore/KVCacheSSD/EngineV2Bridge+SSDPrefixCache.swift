// Copyright © 2026 Eigen Labs.

import Foundation
#if canImport(os)
import os
#endif

extension EngineV2Bridge {
    #if canImport(os)
    private static let ssdStatsLogger = Logger(
        subsystem: "com.darkbloom.provider", category: "prefix_cache")
    #endif

    /// One low-rate snapshot from the slot's accepted durable cache. This task
    /// owns no cache arrays and ends when the store closes or the bridge stops.
    func startSSDPrefixCacheStatsLogger(
        intervalSecs: Int = PrefixCachePolicy.statsIntervalSecs()
    ) {
        prefixCacheStatsTask?.cancel()
        prefixCacheStatsTask = nil
        guard intervalSecs > 0 else { return }
        let snapshot: @Sendable () -> PrefixCacheTelemetry?
        if let store = ssdHybridCheckpointStore {
            snapshot = { [weak store] in
                guard let store, !store.isClosed else { return nil }
                return PrefixCacheTelemetry(complete: store.stats())
            }
        } else if let cache = ssdPrefixCache {
            snapshot = { [weak cache] in
                guard let cache, !cache.isClosed else { return nil }
                return PrefixCacheTelemetry(attention: cache.stats())
            }
        } else { return }
        let model = modelId
        let telemetry = prefixCacheTelemetry
        if let initial = snapshot() { telemetry.publish(initial) }
        prefixCacheStatsTask = Task.detached {
            while !Task.isCancelled {
                try? await taskSleep(.seconds(intervalSecs))
                guard !Task.isCancelled, let current = snapshot() else { return }
                #if canImport(os)
                let summary = String(describing: current)
                Self.ssdStatsLogger.info(
                    "prefix cache stats (engine=v2, tier=ssd, model=\(model, privacy: .public)): \(summary, privacy: .public)")
                #endif
                telemetry.publish(current)
            }
        }
    }
}
