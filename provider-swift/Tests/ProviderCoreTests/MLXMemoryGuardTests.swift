import Testing
@testable import ProviderCore

private let gib = 1024 * 1024 * 1024

@Test func mlxGuardSizesMemoryLimitBelowPhysical() {
    // 64 GiB box, 6 GiB reserve → 58 GiB ceiling.
    let limits = MLXMemoryGuard.recommendedLimits(
        physicalBytes: UInt64(64 * gib), reserveBytes: UInt64(6 * gib))
    #expect(limits.memoryLimitBytes == 58 * gib)
    // cache fraction 0.75 of the ceiling, never above it.
    #expect(limits.cacheLimitBytes == Int(Double(58 * gib) * 0.75))
    #expect(limits.cacheLimitBytes <= limits.memoryLimitBytes)
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
