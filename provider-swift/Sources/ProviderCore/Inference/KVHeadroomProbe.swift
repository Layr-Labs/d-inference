// Copyright © 2026 Eigen Labs.
//
// Live KV-headroom probe — scheduler-free home (v0.7.5).
//
// Re-homed unchanged from `BatchScheduler+Telemetry`'s
// `measuredLiveKVHeadroomBytes` / `hasServeableKVHeadroom`: pure
// `UnifiedMemoryCap` math over the live MLX + OS memory counters, used by
// the post-load guard in `ensureModelLoaded` (a model that loads with no
// serveable KV headroom is unloaded + 503'd instead of advertising a slot
// whose every request the KV gate would reject). The `BatchScheduler`
// members forward here until the legacy scheduler is deleted.

import Foundation
import MLX

public enum KVHeadroomProbe {
    /// MEASURED live KV headroom in bytes right now —
    /// `UnifiedMemoryCap.liveKVHeadroomBytes` computed from actual MLX usage
    /// (`active + cache`, reflecting every co-resident model's weights and
    /// KV) clamped to real OS-available memory. NO floor is applied, so it
    /// reports a true zero when the cap is already exhausted.
    public static var measuredLiveKVHeadroomBytes: UInt64 {
        let mlxUsed = UInt64(max(0, MLX.GPU.activeMemory)) + UInt64(max(0, MLX.GPU.cacheMemory))
        return UnifiedMemoryCap.liveKVHeadroomBytes(
            mlxUsedBytes: mlxUsed,
            systemAvailableBytes: SystemMemory.availableBytes() ?? .max)
    }

    /// Post-load guard: true iff the freshly-loaded model leaves at least
    /// the minimum serveable KV headroom under the cap. When false the
    /// caller must unload + clearCache + reject — keeping the model would
    /// advertise a "loaded but unserveable" slot (the v0.7.2 black-hole
    /// shape). Trim the cold-load buffer pool (`MLX.Memory.clearCache()`)
    /// BEFORE probing, or transient load buffers false-reject a serveable
    /// model.
    public static func hasServeableKVHeadroom() -> Bool {
        UnifiedMemoryCap.loadIsServeable(
            measuredLiveKVHeadroomBytes: measuredLiveKVHeadroomBytes)
    }
}
