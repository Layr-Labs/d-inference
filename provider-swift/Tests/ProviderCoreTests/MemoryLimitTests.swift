import Testing
@testable import ProviderCore

private let gib: UInt64 = 1024 * 1024 * 1024

// MARK: - limitBytes (normalization of the operator's memory_limit_gb)

@Test func limitBytesNilMeansNoLimit() {
    #expect(MemoryLimit.limitBytes(limitGB: nil, physicalBytes: 256 * gib) == nil)
}

@Test func limitBytesZeroMeansNoLimit() {
    // 0 is the config's "unset" sentinel — never a 0-byte cap.
    #expect(MemoryLimit.limitBytes(limitGB: 0, physicalBytes: 256 * gib) == nil)
}

@Test func limitBytesAtOrAbovePhysicalMeansNoLimit() {
    // A limit that can't bind is no limit — both exactly-at and above physical.
    #expect(MemoryLimit.limitBytes(limitGB: 256, physicalBytes: 256 * gib) == nil)
    #expect(MemoryLimit.limitBytes(limitGB: 300, physicalBytes: 256 * gib) == nil)
}

@Test func limitBytesNormalCaseConvertsToBytes() {
    // The headline scenario: 150 GB limit on a 256 GB box.
    #expect(MemoryLimit.limitBytes(limitGB: 150, physicalBytes: 256 * gib) == 150 * gib)
}

@Test func limitBytesAbsurdValueSaturatesInsteadOfTrapping() {
    // UInt64.max/2 GB × 1 GiB overflows UInt64; the conversion must saturate
    // (treated as ≥ physical → no limit), never trap in a config path.
    #expect(MemoryLimit.limitBytes(limitGB: UInt64.max / 2, physicalBytes: 256 * gib) == nil)
    #expect(MemoryLimit.limitBytes(limitGB: UInt64.max, physicalBytes: 256 * gib) == nil)
}

@Test func limitBytesSubFloorClampsUpToMinimum() {
    // A hand-edited TOML below the CLI floor is clamped UP, not honored
    // (a 2 GB cap can hold no weights → silent blackhole) and not dropped
    // (the operator asked for a cap; removing it inverts intent).
    #expect(MemoryLimit.limitBytes(limitGB: 2, physicalBytes: 64 * gib) == 8 * gib)
    #expect(MemoryLimit.limitBytes(limitGB: 7, physicalBytes: 64 * gib) == 8 * gib)
    #expect(MemoryLimit.limitBytes(limitGB: 8, physicalBytes: 64 * gib) == 8 * gib)
}

@Test func limitBytesSubFloorOnTinyBoxDegradesToUnset() {
    // Clamping to the floor on a box at/below the floor would mean
    // limit ≥ physical — normalized away like any other non-binding limit.
    #expect(MemoryLimit.limitBytes(limitGB: 4, physicalBytes: 8 * gib) == nil)
}

@Test func effectiveReserveStaticTakesTheLargerHoldback() {
    // A reserve larger than the limit-implied one dominates: 120 GB reserve
    // beats the 106 GB implied by a 150 GB limit on a 256 GB box.
    #expect(
        MemoryLimit.effectiveReserveBytes(reserveGB: 120, limitGB: 150, physicalBytes: 256 * gib)
            == 120 * gib)
    // And the converse: the limit-implied reserve dominates a small reserve.
    #expect(
        MemoryLimit.effectiveReserveBytes(reserveGB: 4, limitGB: 150, physicalBytes: 256 * gib)
            == 106 * gib)
}

@Test func effectiveCapBytesIsTheSingleDisplayAndFitFormula() {
    // Capped: min(0.90 × 256, 256 − max(4, 106)) = min(230.4, 150) = 150.
    #expect(
        MemoryLimit.effectiveCapBytes(reserveGB: 4, limitGB: 150, physicalBytes: 256 * gib)
            == 150 * gib)
    // Uncapped big box: the 0.90 fraction binds.
    #expect(
        MemoryLimit.effectiveCapBytes(reserveGB: 4, limitGB: nil, physicalBytes: 256 * gib)
            == UnifiedMemoryCap.hardCapBytes(physicalBytes: 256 * gib))
    // Reserve larger than the cap-implied holdback binds below the fraction.
    #expect(
        MemoryLimit.effectiveCapBytes(reserveGB: 120, limitGB: nil, physicalBytes: 256 * gib)
            == 136 * gib)
}

// MARK: - impliedReserveBytes (physical − limit, the reserve a limit implies)

@Test func impliedReserveIsZeroWithoutEffectiveLimit() {
    #expect(MemoryLimit.impliedReserveBytes(limitGB: nil, physicalBytes: 256 * gib) == 0)
    #expect(MemoryLimit.impliedReserveBytes(limitGB: 0, physicalBytes: 256 * gib) == 0)
    #expect(MemoryLimit.impliedReserveBytes(limitGB: 256, physicalBytes: 256 * gib) == 0)
    #expect(MemoryLimit.impliedReserveBytes(limitGB: 300, physicalBytes: 256 * gib) == 0)
}

@Test func impliedReserveIsPhysicalMinusLimit() {
    // 256 − 150 = 106 GiB held back from the provider.
    #expect(MemoryLimit.impliedReserveBytes(limitGB: 150, physicalBytes: 256 * gib) == 106 * gib)
}

// MARK: - ProviderSettings.effectiveReserveBytes (max of config reserve and limit-implied reserve)

@Test func effectiveReserveLimitDominatesSmallConfigReserve() {
    // reserve 4 GiB, limit 150 on 256: the limit implies a 106 GiB reserve,
    // which dwarfs the config reserve.
    let settings = ProviderSettings(name: "test-provider", memoryReserveGB: 4, memoryLimitGB: 150)
    #expect(settings.effectiveReserveBytes(physicalBytes: 256 * gib) == 106 * gib)
}

@Test func effectiveReserveConfigReserveDominatesLooseLimit() {
    // reserve 120 GiB, limit 150 on 256: the limit only implies 106 GiB, so
    // the larger explicit reserve wins.
    let settings = ProviderSettings(name: "test-provider", memoryReserveGB: 120, memoryLimitGB: 150)
    #expect(settings.effectiveReserveBytes(physicalBytes: 256 * gib) == 120 * gib)
}

@Test func effectiveReserveIsConfigReserveWithoutLimit() {
    let settings = ProviderSettings(name: "test-provider", memoryReserveGB: 4, memoryLimitGB: nil)
    #expect(settings.effectiveReserveBytes(physicalBytes: 256 * gib) == 4 * gib)
}

@Test func effectiveReserveIdentityWithCapArithmetic() {
    // The whole design hangs on this identity: capping the budget at
    // min(physical − reserve, limit) is EXACTLY reserving
    // physical − effectiveReserve. If it drifts, the limit leaks somewhere.
    let cases: [(reserveGB: UInt64, limitGB: UInt64?, physGB: UInt64)] = [
        (4, 150, 256),   // limit dominates
        (120, 150, 256), // reserve dominates
        (6, 58, 64),     // tight box, tight limit
        (4, nil, 256),   // no limit at all
        (4, 300, 256),   // limit above physical → inert
    ]
    for c in cases {
        let physical = c.physGB * gib
        let settings = ProviderSettings(
            name: "test-provider", memoryReserveGB: c.reserveGB, memoryLimitGB: c.limitGB)
        let budgetViaLimit = min(
            physical - c.reserveGB * gib,
            settings.memoryLimitBytes(physicalBytes: physical) ?? physical)
        let budgetViaReserve = physical - settings.effectiveReserveBytes(physicalBytes: physical)
        #expect(
            budgetViaLimit == budgetViaReserve,
            "identity broke for reserve=\(c.reserveGB) limit=\(String(describing: c.limitGB)) phys=\(c.physGB)")
    }
}

// MARK: - ProviderSettings.memoryLimitBytes (must mirror MemoryLimit.limitBytes)

@Test func settingsMemoryLimitBytesMirrorsMemoryLimit() {
    let physical = 256 * gib
    for limitGB: UInt64? in [nil, 0, 8, 150, 256, 300, UInt64.max / 2] {
        let settings = ProviderSettings(
            name: "test-provider", memoryReserveGB: 4, memoryLimitGB: limitGB)
        #expect(
            settings.memoryLimitBytes(physicalBytes: physical)
                == MemoryLimit.limitBytes(limitGB: limitGB, physicalBytes: physical),
            "extension diverged from MemoryLimit for limitGB=\(String(describing: limitGB))")
    }
}
