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
    /// The operator reserve comes from ``ProviderMemoryPolicy`` (published at
    /// startup) rather than a parameter, because the deepest caller
    /// (`EngineV2Factory.prepareProductionBackend`) has no config in scope.
    /// It MUST be included: `GlobalKVCacheBudget` — the gate that actually
    /// admits requests — subtracts the same reserve, so a probe that omits it
    /// measures headroom against `0.90 × physical` while serving is capped at
    /// `physical − reserve`. On a 256 GB box limited to 150 GB that is an
    /// ~80 GB overstatement, and the post-load guard below would then admit
    /// exactly the "loaded but unserveable" slot it exists to reject.
    public static func measuredLiveKVHeadroomBytes(
        configReserveBytes: UInt64 = ProviderMemoryPolicy.effectiveReserveBytes
    ) -> UInt64 {
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
    public static func hasServeableKVHeadroom(
        configReserveBytes: UInt64 = ProviderMemoryPolicy.effectiveReserveBytes
    ) -> Bool {
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
    /// Pure over its inputs (the live measurement is a defaulted
    /// autoclosure) so the matrix is unit-testable without touching MLX
    /// counters.
    public static func postBuildServeable(
        kvBackendKind: EngineV2KVBackendKind,
        pagedPoolBytes: UInt64,
        measuredHeadroomBytes: @autoclosure () -> UInt64 = KVHeadroomProbe
            .measuredLiveKVHeadroomBytes()
    ) -> Bool {
        switch kvBackendKind {
        case .paged:
            return pagedPoolBytes >= UnifiedMemoryCap.minimumLoadKVBytes
                && UnifiedMemoryCap.loadIsServeable(
                    measuredLiveKVHeadroomBytes: measuredHeadroomBytes())
        case .contiguous:
            return UnifiedMemoryCap.loadIsServeable(
                measuredLiveKVHeadroomBytes: measuredHeadroomBytes())
        }
    }
}
