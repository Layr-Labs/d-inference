import Foundation
import Testing
@testable import ProviderCore

private let gib = 1024 * 1024 * 1024

@Test func mlxGuardSizesMemoryLimitBelowPhysical() {
    // 64 GiB box, 6 GiB reserve → 58 GiB ceiling.
    let limits = MLXMemoryGuard.recommendedLimits(
        physicalBytes: UInt64(64 * gib), reserveBytes: UInt64(6 * gib))
    #expect(limits.memoryLimitBytes == 58 * gib)
    // The absolute cache cap binds well below the 0.75 fraction here
    // (0.75 × 58 GiB = 43.5 GiB of allowed hoard was the field bug).
    #expect(limits.cacheLimitBytes == 8 * gib)
    #expect(limits.cacheLimitBytes <= limits.memoryLimitBytes)
}

@Test func mlxGuardCacheCapBoundsBigMachines() {
    // The field incident: a 512 GB Mac Studio serving a ~21 GB model
    // accumulated ~377 GB of freed buffers in MLX's cache — exactly the
    // old 0.75 × (512 − 6) GiB ≈ 379.5 GiB allowance. The absolute cap
    // must bound the pool by WORKLOAD, not machine size.
    let limits = MLXMemoryGuard.recommendedLimits(
        physicalBytes: UInt64(512 * gib), reserveBytes: UInt64(6 * gib))
    #expect(limits.memoryLimitBytes == 506 * gib)
    #expect(limits.cacheLimitBytes == Int(MLXMemoryGuard.defaultCacheLimitGB) * gib)
}

@Test func mlxGuardCacheFractionStillBindsSmallMachines() {
    // 16 GiB box: 0.75 × (16 − 6) GiB = 7.5 GiB < the 8 GiB absolute cap,
    // so the proportional scale-down still governs small machines.
    let limits = MLXMemoryGuard.recommendedLimits(
        physicalBytes: UInt64(16 * gib), reserveBytes: UInt64(6 * gib))
    #expect(limits.memoryLimitBytes == 10 * gib)
    #expect(limits.cacheLimitBytes == Int(Double(10 * gib) * 0.75))
}

@Test func mlxGuardCacheCapOverridesClampToFloorAndCeiling() {
    // A raised cap is honored up to the fraction bound (an operator can
    // restore bigger pools), never past the memory limit.
    let raised = MLXMemoryGuard.recommendedLimits(
        physicalBytes: UInt64(512 * gib), reserveBytes: UInt64(6 * gib),
        cacheCapBytes: UInt64(64 * gib))
    #expect(raised.cacheLimitBytes == 64 * gib)

    // A zero/tiny cap lands on the 1 GiB floor so buffer reuse survives a
    // pathological override.
    let floored = MLXMemoryGuard.recommendedLimits(
        physicalBytes: UInt64(64 * gib), reserveBytes: UInt64(6 * gib),
        cacheCapBytes: 0)
    #expect(floored.cacheLimitBytes == MLXMemoryGuard.minimumLimitBytes / 2)

    // A huge cap can never push the cache past the memory limit itself.
    let huge = MLXMemoryGuard.recommendedLimits(
        physicalBytes: UInt64(16 * gib), reserveBytes: UInt64(6 * gib),
        cacheFraction: 1.0, cacheCapBytes: UInt64.max)
    #expect(huge.cacheLimitBytes <= huge.memoryLimitBytes)
}

@Test func mlxGuardCacheCapResolutionPrefersExplicitThenEnvThenDefault() {
    #expect(MLXMemoryGuard.resolvedCacheCapBytes(explicit: UInt64(3 * gib), env: [:]) == UInt64(3 * gib))
    #expect(MLXMemoryGuard.resolvedCacheCapBytes(
        explicit: nil, env: ["DARKBLOOM_MLX_CACHE_LIMIT_GB": "32"]) == UInt64(32) * 1_073_741_824)
    #expect(MLXMemoryGuard.resolvedCacheCapBytes(explicit: nil, env: [:])
        == MLXMemoryGuard.defaultCacheLimitGB * 1_073_741_824)
    // Garbage env falls back to the default rather than crashing.
    #expect(MLXMemoryGuard.resolvedCacheCapBytes(
        explicit: nil, env: ["DARKBLOOM_MLX_CACHE_LIMIT_GB": "not-a-number"])
        == MLXMemoryGuard.defaultCacheLimitGB * 1_073_741_824)
    // Same saturation contract as the reserve: a huge finite override clamps,
    // never traps (the configureOnce-crash class the reserve fix covered).
    #expect(MLXMemoryGuard.resolvedCacheCapBytes(
        explicit: nil, env: ["DARKBLOOM_MLX_CACHE_LIMIT_GB": "1e308"]) == UInt64.max)
    // Zero is honored (lands on the 1 GiB floor in recommendedLimits).
    #expect(MLXMemoryGuard.resolvedCacheCapBytes(
        explicit: nil, env: ["DARKBLOOM_MLX_CACHE_LIMIT_GB": "0"]) == 0)
}

@Test func mlxGuardNeverExceedsPhysicalRAM() {
    // The whole point: the ceiling must be strictly below physical RAM so MLX
    // can't allocate the box into a jetsam kill.
    for physGB in [16, 24, 36, 64, 128] {
        let limits = MLXMemoryGuard.recommendedLimits(
            physicalBytes: UInt64(physGB * gib), reserveBytes: UInt64(6 * gib))
        #expect(limits.memoryLimitBytes < physGB * gib, "ceiling must be below physical on a \(physGB)GB box")
    }
}

@Test func mlxGuardFloorsTinyOrMisreportedMachines() {
    // Reserve >= physical would yield a non-positive limit; must floor instead.
    let limits = MLXMemoryGuard.recommendedLimits(
        physicalBytes: UInt64(4 * gib), reserveBytes: UInt64(8 * gib))
    #expect(limits.memoryLimitBytes == MLXMemoryGuard.minimumLimitBytes)
    #expect(limits.cacheLimitBytes <= limits.memoryLimitBytes)
}

@Test func mlxGuardReserveResolutionPrefersExplicitThenEnvThenDefault() {
    // explicit is BYTES (consistent with reserveBytes everywhere else).
    #expect(MLXMemoryGuard.resolvedReserveBytes(explicit: UInt64(10 * gib), env: [:]) == UInt64(10 * gib))
    // env override is in GB and is converted to bytes.
    #expect(MLXMemoryGuard.resolvedReserveBytes(
        explicit: nil, env: ["DARKBLOOM_MLX_MEMORY_RESERVE_GB": "12"]) == UInt64(12) * 1_073_741_824)
    #expect(MLXMemoryGuard.resolvedReserveBytes(explicit: nil, env: [:])
        == MLXMemoryGuard.defaultReserveGB * 1_073_741_824)
    // Garbage env falls back to the default rather than crashing.
    #expect(MLXMemoryGuard.resolvedReserveBytes(
        explicit: nil, env: ["DARKBLOOM_MLX_MEMORY_RESERVE_GB": "not-a-number"])
        == MLXMemoryGuard.defaultReserveGB * 1_073_741_824)
}

@Test func mlxGuardReserveEnvClampsHugeValueInsteadOfTrapping() {
    // A huge-but-finite GB override would, naively, do
    // `UInt64(min(gb * 1GiB, Double(UInt64.max)))` — but `Double(UInt64.max)`
    // rounds up to 2^64, which is outside UInt64, so `UInt64(...)` traps and
    // crashes the provider in configureOnce() at startup. The fix saturates.
    #expect(MLXMemoryGuard.resolvedReserveBytes(
        explicit: nil, env: ["DARKBLOOM_MLX_MEMORY_RESERVE_GB": "1e308"]) == UInt64.max)
    // A value whose ×1GiB lands exactly at the 2^64 boundary also saturates,
    // not traps.
    let boundaryGB = String(MLXMemoryGuard.uint64MaxAsDouble / 1_073_741_824)
    #expect(MLXMemoryGuard.resolvedReserveBytes(
        explicit: nil, env: ["DARKBLOOM_MLX_MEMORY_RESERVE_GB": boundaryGB]) == UInt64.max)
    // A normal large-but-representable value still converts correctly.
    #expect(MLXMemoryGuard.resolvedReserveBytes(
        explicit: nil, env: ["DARKBLOOM_MLX_MEMORY_RESERVE_GB": "64"])
        == UInt64(64) * 1_073_741_824)
    // Zero is honored (operator's accepted DoS knob; must not trap or fall back).
    #expect(MLXMemoryGuard.resolvedReserveBytes(
        explicit: nil, env: ["DARKBLOOM_MLX_MEMORY_RESERVE_GB": "0"]) == 0)
}

// MARK: - Cap alignment (T3-04)

@Test func mlxGuardCapDerivedReserveAlignsTheLimitWithTheEffectiveCap() {
    // memoryLimit == max(min(0.9 × physical, physical − memory_reserve_gb),
    // physical − 6 GiB) across the fleet's tiers with the 4 GiB default
    // reserve; the cache limit is pinned unchanged (the 8 GiB absolute cap
    // binds everywhere ≥ 24 GB).
    let configReserve = UInt64(4 * gib)
    let legacyReserve = Int(MLXMemoryGuard.defaultReserveGB) * gib
    for physGB in [24, 32, 36, 40, 48, 64, 128] {
        let physical = UInt64(physGB * gib)
        let reserve = MLXMemoryGuard.capDerivedReserveBytes(
            physicalBytes: physical, configReserveBytes: configReserve)
        let limits = MLXMemoryGuard.recommendedLimits(physicalBytes: physical, reserveBytes: reserve)
        let effectiveCap = UnifiedMemoryCap.effectiveCapBytes(
            physicalBytes: physical, configReserveBytes: configReserve)
        #expect(
            limits.memoryLimitBytes == max(Int(effectiveCap), physGB * gib - legacyReserve),
            "\(physGB) GB")
        #expect(limits.memoryLimitBytes >= physGB * gib - legacyReserve, "\(physGB) GB never tighter than legacy")
        #expect(limits.cacheLimitBytes == 8 * gib, "\(physGB) GB cache limit must not move")
        #expect(limits.memoryLimitBytes < physGB * gib)
    }
    // The tiers where the legacy 6 GiB pin sat INSIDE sanctioned usage
    // (0.9 × physical > physical − 6 GiB ⇔ physical < 60 GB): the limit is
    // now 2 GiB looser on 24/32/36/40 GB and 1.2 GiB looser on 48 GB…
    #expect(MLXMemoryGuard.recommendedLimits(
        physicalBytes: UInt64(32 * gib),
        reserveBytes: MLXMemoryGuard.capDerivedReserveBytes(
            physicalBytes: UInt64(32 * gib), configReserveBytes: configReserve)
    ).memoryLimitBytes == 28 * gib)  // was 26 GiB
    #expect(MLXMemoryGuard.recommendedLimits(
        physicalBytes: UInt64(24 * gib),
        reserveBytes: MLXMemoryGuard.capDerivedReserveBytes(
            physicalBytes: UInt64(24 * gib), configReserveBytes: configReserve)
    ).memoryLimitBytes == 20 * gib)  // was 18 GiB
    #expect(MLXMemoryGuard.recommendedLimits(
        physicalBytes: UInt64(40 * gib),
        reserveBytes: MLXMemoryGuard.capDerivedReserveBytes(
            physicalBytes: UInt64(40 * gib), configReserveBytes: configReserve)
    ).memoryLimitBytes == 36 * gib)  // was 34 GiB
    // …and UNCHANGED (physical − 6 GiB) at 64 GB and above, where the
    // cap-implied reserve (0.1 × physical) exceeds the legacy pin: the
    // activation reserve is a max over models, not a sum over stepping
    // slots, so a limit at 0.9 × physical would sit inside sanctioned
    // multi-slot step-time usage (review fix, S4 P2).
    #expect(MLXMemoryGuard.recommendedLimits(
        physicalBytes: UInt64(64 * gib),
        reserveBytes: MLXMemoryGuard.capDerivedReserveBytes(
            physicalBytes: UInt64(64 * gib), configReserveBytes: configReserve)
    ).memoryLimitBytes == 58 * gib)  // was 58; 0.9 × physical would be 57.6
    #expect(MLXMemoryGuard.recommendedLimits(
        physicalBytes: UInt64(128 * gib),
        reserveBytes: MLXMemoryGuard.capDerivedReserveBytes(
            physicalBytes: UInt64(128 * gib), configReserveBytes: configReserve)
    ).memoryLimitBytes == 122 * gib)  // was 122; 0.9 × physical would be 115.2
}

@Test func mlxGuardCapDerivedReserveNeverTightensTheLegacyPin() {
    // Loosen-only across the big-box tiers: the reserve is exactly the
    // legacy 6 GiB wherever the cap-implied reserve would exceed it, so the
    // limit equals the pre-T3-04 `physical − 6 GiB` there.
    let legacyReserve = MLXMemoryGuard.defaultReserveGB * 1_073_741_824
    for physGB in [60, 64, 96, 128, 192, 512] {
        let physical = UInt64(physGB * gib)
        let reserve = MLXMemoryGuard.capDerivedReserveBytes(
            physicalBytes: physical, configReserveBytes: UInt64(4 * gib))
        #expect(reserve == legacyReserve, "\(physGB) GB reserve \(reserve)")
        #expect(
            MLXMemoryGuard.recommendedLimits(physicalBytes: physical, reserveBytes: reserve)
                .memoryLimitBytes == physGB * gib - Int(legacyReserve),
            "\(physGB) GB")
    }
    // An operator reserve LARGER than 6 GiB still does not tighten the MLX
    // threshold: the gate enforces it, the threshold only needs to be no
    // tighter than sanctioned usage.
    #expect(MLXMemoryGuard.capDerivedReserveBytes(
        physicalBytes: UInt64(128 * gib), configReserveBytes: UInt64(20 * gib)) == legacyReserve)
}

@Test func mlxGuardReservePrecedenceIsExplicitThenEnvThenCapDerivedThenDefault() {
    let capDerived = UInt64(3 * gib)
    // explicit wins over everything.
    #expect(MLXMemoryGuard.resolvedReserveBytes(
        explicit: UInt64(10 * gib), capDerived: capDerived,
        env: ["DARKBLOOM_MLX_MEMORY_RESERVE_GB": "12"]) == UInt64(10 * gib))
    // env wins over the cap-derived figure (the operator's measurement lever).
    #expect(MLXMemoryGuard.resolvedReserveBytes(
        explicit: nil, capDerived: capDerived,
        env: ["DARKBLOOM_MLX_MEMORY_RESERVE_GB": "12"]) == UInt64(12) * 1_073_741_824)
    // cap-derived wins over the legacy default…
    #expect(MLXMemoryGuard.resolvedReserveBytes(
        explicit: nil, capDerived: capDerived, env: [:]) == capDerived)
    // …and garbage env falls through to it, not to the 6 GiB default.
    #expect(MLXMemoryGuard.resolvedReserveBytes(
        explicit: nil, capDerived: capDerived,
        env: ["DARKBLOOM_MLX_MEMORY_RESERVE_GB": "not-a-number"]) == capDerived)
    // No cap-derived figure: the legacy default (tools that never resolve a cap).
    #expect(MLXMemoryGuard.resolvedReserveBytes(explicit: nil, capDerived: nil, env: [:])
        == MLXMemoryGuard.defaultReserveGB * 1_073_741_824)
}

@Test func mlxGuardCapDerivedReserveIsPhysicalMinusEffectiveCap() {
    // Config reserve below the cap-implied reserve: 10% of physical — but
    // never more than the legacy 6 GiB (loosen-only): 6.4 GiB → 6 GiB.
    #expect(MLXMemoryGuard.capDerivedReserveBytes(
        physicalBytes: UInt64(64 * gib), configReserveBytes: UInt64(4 * gib))
        == MLXMemoryGuard.defaultReserveGB * 1_073_741_824)
    // Below the crossover the cap-implied reserve is exact: 48 GB → 4.8 GiB.
    #expect(MLXMemoryGuard.capDerivedReserveBytes(
        physicalBytes: UInt64(48 * gib), configReserveBytes: UInt64(4 * gib))
        == UInt64(48 * gib) - UInt64(Double(48 * gib) * 0.9))
    // Config reserve above it: the operator's reserve, exactly.
    #expect(MLXMemoryGuard.capDerivedReserveBytes(
        physicalBytes: UInt64(32 * gib), configReserveBytes: UInt64(4 * gib)) == UInt64(4 * gib))
    // Never underflows.
    #expect(MLXMemoryGuard.capDerivedReserveBytes(physicalBytes: 0, configReserveBytes: UInt64(4 * gib)) == 0)
}

/// Serialized: both tests reset + trip the process-global once-flag, so
/// running them in parallel would race `configured` and flake.
@Suite("MLXMemoryGuard.configureOnce", .serialized)
struct MLXMemoryGuardConfigureOnceTests {

    @Test func mlxGuardConfigureOnceAppliesExactlyOnce() {
        MLXMemoryGuard._resetForTest()
        var applied: [MLXMemoryGuard.Limits] = []
        let first = MLXMemoryGuard.configureOnce(
            reserveBytes: UInt64(6 * gib),
            physicalBytes: UInt64(32 * gib),
            apply: { applied.append($0) })
        let second = MLXMemoryGuard.configureOnce(
            reserveBytes: UInt64(6 * gib),
            physicalBytes: UInt64(32 * gib),
            apply: { applied.append($0) })

        #expect(first != nil)
        #expect(second == nil, "second call must be a no-op (ceiling set once per process)")
        #expect(applied.count == 1)
        #expect(applied.first?.memoryLimitBytes == 26 * gib)
        MLXMemoryGuard._resetForTest()
    }

    @Test func mlxGuardConfigureOnceThreadsTheCacheCapThrough() {
        // Pins the configureOnce → recommendedLimits(cacheCapBytes:) composition:
        // dropping the argument would silently fall back to the default cap
        // (the values coincide) and only the override path would break — the
        // shape of bug a defaulted parameter invites.
        MLXMemoryGuard._resetForTest()
        var applied: [MLXMemoryGuard.Limits] = []
        let limits = MLXMemoryGuard.configureOnce(
            reserveBytes: UInt64(6 * gib),
            cacheCapBytes: UInt64(2 * gib),
            physicalBytes: UInt64(64 * gib),
            apply: { applied.append($0) })
        #expect(limits?.cacheLimitBytes == 2 * gib)
        #expect(applied.first?.cacheLimitBytes == 2 * gib)
        #expect(MLXMemoryGuard.configuredLimitsSnapshot() == limits)
        MLXMemoryGuard._resetForTest()
        #expect(MLXMemoryGuard.configuredLimitsSnapshot() == nil)
    }

    @Test func mlxGuardConfigureOnceUsesTheCapDerivedReserveWhenNothingOverridesIt() {
        // Production shape: no explicit reserve, the cap-derived figure is
        // passed, env is whatever the process has (the test asserts the
        // NON-override path, so it skips when the operator lever is set).
        guard ProcessInfo.processInfo.environment["DARKBLOOM_MLX_MEMORY_RESERVE_GB"] == nil else { return }
        MLXMemoryGuard._resetForTest()
        var applied: [MLXMemoryGuard.Limits] = []
        let physical = UInt64(32 * gib)
        let limits = MLXMemoryGuard.configureOnce(
            capDerivedReserveBytes: MLXMemoryGuard.capDerivedReserveBytes(
                physicalBytes: physical, configReserveBytes: UInt64(4 * gib)),
            physicalBytes: physical,
            apply: { applied.append($0) })
        // 32 GB box: the limit is the provider's effective cap (28 GiB), no
        // longer the legacy physical − 6 GiB (26 GiB) that sat inside
        // sanctioned usage.
        #expect(limits?.memoryLimitBytes == 28 * gib)
        #expect(applied.first?.memoryLimitBytes == 28 * gib)
        #expect(MLXMemoryGuard.configuredLimitsSnapshot()?.memoryLimitBytes == 28 * gib)
        MLXMemoryGuard._resetForTest()
    }
}
