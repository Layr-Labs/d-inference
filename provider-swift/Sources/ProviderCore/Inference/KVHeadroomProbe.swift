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
    ///
    /// `configReserveBytes` is REQUIRED, not defaulted, and must be the same
    /// effective reserve `GlobalKVCacheBudget` was built with
    /// (`ProviderSettings.effectiveReserveBytes`, which folds in
    /// `memory_limit_gb`). A probe that omits it measures headroom against
    /// `0.90 × physical` while the gate that actually admits requests enforces
    /// `physical − reserve`: on a 256 GB box limited to 150 GB that is an
    /// ~80 GB overstatement, and the post-load guard below would then admit
    /// exactly the "loaded but unserveable" slot it exists to reject. A default
    /// of 0 would make that divergence the silent behavior at any call site
    /// someone forgets to update, so there is no default.
    public static func measuredLiveKVHeadroomBytes(configReserveBytes: UInt64) -> UInt64 {
        let mlxUsed = UInt64(max(0, MLX.GPU.activeMemory)) + UInt64(max(0, MLX.GPU.cacheMemory))
        return UnifiedMemoryCap.liveKVHeadroomBytes(
            mlxUsedBytes: mlxUsed,
            systemAvailableBytes: SystemMemory.availableBytes() ?? .max,
            configReserveBytes: configReserveBytes)
    }

    /// Post-load guard: true iff the freshly-loaded model leaves at least
    /// the minimum serveable KV headroom under the cap. When false the
    /// caller must unload + clearCache + reject — keeping the model would
    /// advertise a "loaded but unserveable" slot (the v0.7.2 black-hole
    /// shape). Trim the cold-load buffer pool (`MLX.Memory.clearCache()`)
    /// BEFORE probing, or transient load buffers false-reject a serveable
    /// model.
    public static func hasServeableKVHeadroom(configReserveBytes: UInt64) -> Bool {
        UnifiedMemoryCap.loadIsServeable(
            measuredLiveKVHeadroomBytes: measuredLiveKVHeadroomBytes(
                configReserveBytes: configReserveBytes))
    }

    /// Post-BRIDGE serveable-KV verdict for a freshly-built slot.
    ///
    /// The question this guard answers is "does this slot have at least
    /// `UnifiedMemoryCap.minimumLoadKVBytes` of KV to serve with?" — and
    /// the honest measurement differs by backend:
    ///
    ///   * CONTIGUOUS: KV allocates lazily from free headroom, so measure
    ///     live headroom (the classic guard).
    ///   * PAGED: require BOTH a serveable committed pool and the same
    ///     minimum residual whole-machine headroom. Physical sizing uses
    ///     only a conservative fraction of the pre-build live headroom, so
    ///     the residual check catches unaccounted engine/JIT residency or
    ///     concurrent OS pressure without rejecting every valid pool.
    ///
    /// Live form: measures headroom now, so the operator reserve is REQUIRED.
    /// There is deliberately no default — a `= 0` here would silently restore
    /// the reserve-blind measurement at any call site that forgets it, which is
    /// the exact defect this overload exists to prevent.
    public static func postBuildServeable(
        kvBackendKind: EngineV2KVBackendKind,
        pagedPoolBytes: UInt64,
        configReserveBytes: UInt64
    ) -> Bool {
        postBuildServeable(
            kvBackendKind: kvBackendKind,
            pagedPoolBytes: pagedPoolBytes,
            measuredHeadroomBytes: measuredLiveKVHeadroomBytes(
                configReserveBytes: configReserveBytes))
    }

    /// Pure form: the caller supplies the measurement, so no reserve is
    /// involved. Splitting the two overloads makes "measured live" and
    /// "supplied" mutually exclusive at the type level — you cannot get a
    /// reserve-blind live measurement by omitting an argument.
    public static func postBuildServeable(
        kvBackendKind: EngineV2KVBackendKind,
        pagedPoolBytes: UInt64,
        measuredHeadroomBytes: UInt64
    ) -> Bool {
        switch kvBackendKind {
        case .paged:
            return pagedPoolBytes >= UnifiedMemoryCap.minimumLoadKVBytes
                && UnifiedMemoryCap.loadIsServeable(
                    measuredLiveKVHeadroomBytes: measuredHeadroomBytes)
        case .contiguous:
            return UnifiedMemoryCap.loadIsServeable(
                measuredLiveKVHeadroomBytes: measuredHeadroomBytes)
        }
    }
}
