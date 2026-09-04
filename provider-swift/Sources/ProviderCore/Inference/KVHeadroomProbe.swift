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
    /// `activationReserveBytes` is the reserve the caller's serving set
    /// resolves to (`UnifiedMemoryCap.resolvedActivationReserveBytes
    /// (modelIDs:)`); nil keeps the flat default. The load gate and this
    /// measured guard MUST carve the same reserve, or a model the gate
    /// admits at the serving-set floor is unloaded here against the larger
    /// flat one — the admit-then-fail churn #653 removes.
    ///
    /// `configReserveBytes` is the operator's `memory_reserve_gb` — the SAME
    /// reserve `GlobalKVCacheBudget` holds back on every request
    /// (`effectiveCap = min(0.9 × physical, physical − configReserve)`).
    /// Measuring here against the bare 0.9 cap over-reports headroom by
    /// `configReserve − 0.1 × physical` whenever physical < 40 GiB (1.6 /
    /// 0.8 / 0.4 GiB at 24 / 32 / 36 GB with the 4 GiB default) — wider than
    /// the 1 GiB serveable minimum, so a model could pass this guard, be
    /// advertised, and then have the live gate reject every request: the
    /// loaded-but-unserveable black hole the guard exists to prevent. 0 for
    /// a budget that carries no operator reserve (standalone direct mode).
    ///
    /// `physicalBytes`, `mlxUsedBytes` and `systemAvailableBytes` default to
    /// the live counters; tests inject them so the parity with the gate is
    /// checked without touching MLX globals.
    public static func measuredLiveKVHeadroomBytes(
        activationReserveBytes: UInt64? = nil,
        configReserveBytes: UInt64 = 0,
        physicalBytes: UInt64 = ProcessInfo.processInfo.physicalMemory,
        mlxUsedBytes: UInt64? = nil,
        systemAvailableBytes: UInt64? = nil
    ) -> UInt64 {
        let mlxUsed = mlxUsedBytes
            ?? (UInt64(max(0, MLX.Memory.activeMemory)) + UInt64(max(0, MLX.Memory.cacheMemory)))
        return UnifiedMemoryCap.liveKVHeadroomBytes(
            physicalBytes: physicalBytes,
            mlxUsedBytes: mlxUsed,
            systemAvailableBytes: systemAvailableBytes ?? (SystemMemory.availableBytes() ?? .max),
            activationReserveBytes: activationReserveBytes,
            configReserveBytes: configReserveBytes)
    }

    /// Post-load guard: true iff the freshly-loaded model leaves at least
    /// the minimum serveable KV headroom under the cap. When false the
    /// caller must unload + clearCache + reject — keeping the model would
    /// advertise a "loaded but unserveable" slot (the v0.7.2 black-hole
    /// shape). Trim the cold-load buffer pool (`MLX.Memory.clearCache()`)
    /// BEFORE probing, or transient load buffers false-reject a serveable
    /// model. Same injectable inputs as `measuredLiveKVHeadroomBytes`.
    public static func hasServeableKVHeadroom(
        activationReserveBytes: UInt64? = nil,
        configReserveBytes: UInt64 = 0,
        physicalBytes: UInt64 = ProcessInfo.processInfo.physicalMemory,
        mlxUsedBytes: UInt64? = nil,
        systemAvailableBytes: UInt64? = nil
    ) -> Bool {
        UnifiedMemoryCap.loadIsServeable(
            measuredLiveKVHeadroomBytes: measuredLiveKVHeadroomBytes(
                activationReserveBytes: activationReserveBytes,
                configReserveBytes: configReserveBytes,
                physicalBytes: physicalBytes,
                mlxUsedBytes: mlxUsedBytes,
                systemAvailableBytes: systemAvailableBytes))
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
    /// counters. `configReserveBytes` reaches the live measurement exactly
    /// as in `measuredLiveKVHeadroomBytes`.
    public static func postBuildServeable(
        kvBackendKind: EngineV2KVBackendKind,
        pagedPoolBytes: UInt64,
        activationReserveBytes: UInt64? = nil,
        configReserveBytes: UInt64 = 0,
        measuredHeadroomBytes: @autoclosure () -> UInt64? = nil
    ) -> Bool {
        let measured = measuredHeadroomBytes()
            ?? measuredLiveKVHeadroomBytes(
                activationReserveBytes: activationReserveBytes,
                configReserveBytes: configReserveBytes)
        switch kvBackendKind {
        case .paged:
            return pagedPoolBytes >= UnifiedMemoryCap.minimumLoadKVBytes
                && UnifiedMemoryCap.loadIsServeable(measuredLiveKVHeadroomBytes: measured)
        case .contiguous:
            return UnifiedMemoryCap.loadIsServeable(measuredLiveKVHeadroomBytes: measured)
        }
    }
}
