import Testing

@testable import ProviderCore

private let gib: UInt64 = 1024 * 1024 * 1024

// The post-load serveability guard (KVHeadroomProbe) and the gate that actually
// admits requests (GlobalKVCacheBudget) must subtract the SAME operator reserve.
// When they disagree, a model loads, passes the guard, is advertised, and then
// has every request rejected by the KV gate — the "loaded but unserveable"
// black hole the guard exists to prevent. These tests pin the arithmetic that
// keeps them equal; `ProviderMemoryPolicy` is what carries the reserve to the
// probe, whose deepest caller (EngineV2Factory.prepareProductionBackend) has no
// config in scope.

@Test func probeReserveDefaultsToZeroWhenUnconfigured() {
    ProviderMemoryPolicy._resetForTest()
    #expect(ProviderMemoryPolicy.effectiveReserveBytes == 0)
}

@Test func probeReserveRoundTripsThroughTheProcessPolicy() {
    ProviderMemoryPolicy._resetForTest()
    defer { ProviderMemoryPolicy._resetForTest() }

    ProviderMemoryPolicy.configure(effectiveReserveBytes: 106 * gib)
    #expect(ProviderMemoryPolicy.effectiveReserveBytes == 106 * gib)

    // Overwrite, not latch: a second serve mode in the same process must end up
    // with the CURRENT config's reserve, not the first one ever published.
    ProviderMemoryPolicy.configure(effectiveReserveBytes: 4 * gib)
    #expect(ProviderMemoryPolicy.effectiveReserveBytes == 4 * gib)
}

/// The headline regression: on a 256 GiB box limited to 150 GiB, a probe that
/// omits the reserve reports headroom against 0.90 x physical (230.4 GiB) while
/// serving is capped at 150 GiB. Same inputs, two answers — and the optimistic
/// one is what the guard would have believed.
@Test func headroomWithoutTheReserveOverstatesACappedBox() {
    let physical = 256 * gib
    let limitReserve = physical - 150 * gib  // memory_limit_gb = 150
    let mlxUsed = 140 * gib                  // weights already resident
    let activations: UInt64 = 3 * gib

    let capped = UnifiedMemoryCap.liveKVHeadroomBytes(
        physicalBytes: physical,
        mlxUsedBytes: mlxUsed,
        systemAvailableBytes: .max,
        activationReserveBytes: activations,
        configReserveBytes: limitReserve)
    let blind = UnifiedMemoryCap.liveKVHeadroomBytes(
        physicalBytes: physical,
        mlxUsedBytes: mlxUsed,
        systemAvailableBytes: .max,
        activationReserveBytes: activations,
        configReserveBytes: 0)

    // effectiveCap = min(230.4, 150) = 150 → 150 - 140 - 3 = 7 GiB.
    #expect(capped == 7 * gib)
    // Blind: min(230.4, 256) = 230.4 → 230.4 - 140 - 3 = 87.4 GiB.
    #expect(blind > capped)
    #expect(blind - capped > 80 * gib)
}

/// The failure the divergence produces: the guard says "serveable" while the
/// runtime gate has nothing left to hand out.
@Test func blindProbeCallsAnUnserveableSlotServeable() {
    let physical = 256 * gib
    let limitReserve = physical - 150 * gib
    let mlxUsed = 149 * gib  // right at the 150 GiB limit
    let activations: UInt64 = 3 * gib

    let capped = UnifiedMemoryCap.liveKVHeadroomBytes(
        physicalBytes: physical,
        mlxUsedBytes: mlxUsed,
        systemAvailableBytes: .max,
        activationReserveBytes: activations,
        configReserveBytes: limitReserve)
    let blind = UnifiedMemoryCap.liveKVHeadroomBytes(
        physicalBytes: physical,
        mlxUsedBytes: mlxUsed,
        systemAvailableBytes: .max,
        activationReserveBytes: activations,
        configReserveBytes: 0)

    #expect(UnifiedMemoryCap.loadIsServeable(measuredLiveKVHeadroomBytes: blind))
    #expect(!UnifiedMemoryCap.loadIsServeable(measuredLiveKVHeadroomBytes: capped))
}

/// With no limit configured the reserve is the plain `memory_reserve_gb`, so
/// nothing about an uncapped box changes.
@Test func uncappedBoxIsUnaffectedByTheReserveThreading() {
    let physical = 256 * gib
    let settings = ProviderSettings(name: "t", memoryReserveGB: 4)
    let reserve = settings.effectiveReserveBytes(physicalBytes: physical)
    #expect(reserve == 4 * gib)

    // 4 GiB is below the cap-implied reserve (256 - 230.4 = 25.6 GiB), so the
    // 0.90 fraction still binds and headroom is identical with or without it.
    let withReserve = UnifiedMemoryCap.liveKVHeadroomBytes(
        physicalBytes: physical, mlxUsedBytes: 100 * gib, systemAvailableBytes: .max,
        activationReserveBytes: 3 * gib, configReserveBytes: reserve)
    let without = UnifiedMemoryCap.liveKVHeadroomBytes(
        physicalBytes: physical, mlxUsedBytes: 100 * gib, systemAvailableBytes: .max,
        activationReserveBytes: 3 * gib, configReserveBytes: 0)
    #expect(withReserve == without)
}
