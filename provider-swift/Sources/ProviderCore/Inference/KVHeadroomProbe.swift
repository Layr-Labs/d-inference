// Copyright © 2026 Eigen Labs.
//
// Live KV-headroom probe — scheduler-free home (v0.7.5).
//
// Re-homed from the retired `BatchScheduler+Telemetry` implementation's
// `measuredLiveKVHeadroomBytes` / `hasServeableKVHeadroom`: pure
// `UnifiedMemoryCap` math over the live MLX + OS memory counters, used by
// the post-load guard in `ensureModelLoaded` (a model that loads with no
// serveable KV headroom is unloaded + 503'd instead of advertising a slot
// whose every request the KV gate would reject).

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

    /// Post-BRIDGE serveable-KV verdict for a freshly-built slot.
    ///
    /// The question this guard answers is "does this slot have at least
    /// `UnifiedMemoryCap.minimumLoadKVBytes` of KV to serve with?" — and
    /// the honest measurement differs by backend:
    ///
    ///   * CONTIGUOUS: KV allocates lazily from free headroom, so measure
    ///     live headroom (the classic guard).
    ///   * PAGED: the slot physically committed its serveable KV at
    ///     construction (`materializeSlabs` — the pool consumed the very
    ///     budget the measurement looks for), so measuring the residue
    ///     would reject EVERY paged slot by design. Hold the SAME floor
    ///     against the committed pool instead.
    ///
    /// Pure over its inputs (the live measurement is a defaulted
    /// autoclosure, never evaluated on the paged arm) so the matrix is
    /// unit-testable without touching MLX counters.
    public static func postBuildServeable(
        kvBackendKind: EngineV2KVBackendKind,
        pagedPoolBytes: UInt64,
        measuredHeadroomBytes: @autoclosure () -> UInt64 = KVHeadroomProbe
            .measuredLiveKVHeadroomBytes
    ) -> Bool {
        switch kvBackendKind {
        case .paged:
            return pagedPoolBytes >= UnifiedMemoryCap.minimumLoadKVBytes
        case .contiguous:
            return UnifiedMemoryCap.loadIsServeable(
                measuredLiveKVHeadroomBytes: measuredHeadroomBytes())
        }
    }
}
