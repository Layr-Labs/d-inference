import Testing

@testable import ProviderCore

private let gib: UInt64 = 1024 * 1024 * 1024

// The post-load serveability guard (`KVHeadroomProbe`) and the gate that
// actually admits requests (`GlobalKVCacheBudget`) must subtract the SAME
// operator reserve. When they disagree a model loads, passes the guard, is
// advertised, and then has every request rejected by the KV gate — the "loaded
// but unserveable" black hole the guard exists to prevent.

// MARK: - The probe itself honors the reserve

/// Machine-independent: a reserve of `.max` drives `reserveFloor` to 0, so the
/// effective cap is 0 and headroom must be 0 on ANY box. Before the fix the
/// probe took no reserve at all, so this does not compile against the old API —
/// and semantically it would have reported the box's real headroom.
@Test func probeHonorsTheReserveItIsGiven() {
    #expect(KVHeadroomProbe.measuredLiveKVHeadroomBytes(configReserveBytes: .max) == 0)
    #expect(!KVHeadroomProbe.hasServeableKVHeadroom(configReserveBytes: .max))
}

/// Monotonicity, also machine-independent: holding more memory back can never
/// report MORE headroom. Pins the reserve as an actual input to the measurement
/// rather than an ignored argument.
@Test func probeHeadroomIsMonotonicInTheReserve() {
    let none = KVHeadroomProbe.measuredLiveKVHeadroomBytes(configReserveBytes: 0)
    let some = KVHeadroomProbe.measuredLiveKVHeadroomBytes(configReserveBytes: 200 * gib)
    #expect(some <= none)
}

/// The post-bridge guard reaches the same measurement: with everything held
/// back, a paged slot with a healthy pool is still not serveable.
@Test func postBuildGuardHonorsTheReserve() {
    #expect(
        !KVHeadroomProbe.postBuildServeable(
            kvBackendKind: .paged, pagedPoolBytes: 8 * gib, configReserveBytes: .max))
    #expect(
        !KVHeadroomProbe.postBuildServeable(
            kvBackendKind: .contiguous, pagedPoolBytes: 0, configReserveBytes: .max))
    // The pure overload takes a supplied measurement and no reserve at all —
    // the two are mutually exclusive, so no call can silently get a
    // reserve-blind LIVE measurement by omitting an argument.
    #expect(
        KVHeadroomProbe.postBuildServeable(
            kvBackendKind: .contiguous, pagedPoolBytes: 0, measuredHeadroomBytes: 2 * gib))
}

// MARK: - Why it matters (the divergence the fix removes)

/// The headline case: a 256 GiB box limited to 150 GiB. A reserve-blind probe
/// measures against 0.90 x physical (230.4 GiB) while serving is capped at 150.
@Test func aBlindProbeWouldOverstateACappedBox() {
    let physical = 256 * gib
    let limitReserve = physical - 150 * gib  // memory_limit_gb = 150
    let mlxUsed = 140 * gib                  // weights already resident

    func headroom(reserve: UInt64) -> UInt64 {
        UnifiedMemoryCap.liveKVHeadroomBytes(
            physicalBytes: physical, mlxUsedBytes: mlxUsed, systemAvailableBytes: .max,
            activationReserveBytes: 3 * gib, configReserveBytes: reserve)
    }

    // effectiveCap = min(230.4, 150) = 150 -> 150 - 140 - 3 = 7 GiB.
    #expect(headroom(reserve: limitReserve) == 7 * gib)
    // Blind: min(230.4, 256) = 230.4 -> 230.4 - 140 - 3 = 87.4 GiB.
    #expect(headroom(reserve: 0) - headroom(reserve: limitReserve) > 80 * gib)
}

/// At the limit the two verdicts actually differ: "serveable" vs "unload".
@Test func blindProbeCallsAnUnserveableSlotServeable() {
    let physical = 256 * gib
    let limitReserve = physical - 150 * gib

    func headroom(reserve: UInt64) -> UInt64 {
        UnifiedMemoryCap.liveKVHeadroomBytes(
            physicalBytes: physical, mlxUsedBytes: 149 * gib, systemAvailableBytes: .max,
            activationReserveBytes: 3 * gib, configReserveBytes: reserve)
    }

    #expect(UnifiedMemoryCap.loadIsServeable(measuredLiveKVHeadroomBytes: headroom(reserve: 0)))
    #expect(
        !UnifiedMemoryCap.loadIsServeable(
            measuredLiveKVHeadroomBytes: headroom(reserve: limitReserve)))
}

// MARK: - Effect on providers with no limit configured

/// On a big uncapped box the default 4 GiB `memory_reserve_gb` is below the
/// cap-implied reserve (256 - 230.4 = 25.6 GiB), so the 0.90 fraction still
/// binds and threading the reserve changes nothing.
@Test func largeUncappedBoxSeesNoChange() {
    let physical = 256 * gib
    let reserve = ProviderSettings(name: "t", memoryReserveGB: 4)
        .effectiveReserveBytes(physicalBytes: physical)
    #expect(reserve == 4 * gib)

    func headroom(_ r: UInt64) -> UInt64 {
        UnifiedMemoryCap.liveKVHeadroomBytes(
            physicalBytes: physical, mlxUsedBytes: 100 * gib, systemAvailableBytes: .max,
            activationReserveBytes: 3 * gib, configReserveBytes: r)
    }
    #expect(headroom(reserve) == headroom(0))
}

/// But on a SMALL uncapped box the 4 GiB reserve DOES bind (it exceeds the
/// cap-implied reserve once 0.1 x physical < 4 GiB, i.e. below ~40 GiB), so the
/// probe now reports less headroom than it did before this change. That is the
/// intended alignment — `GlobalKVCacheBudget` already enforced this reserve, so
/// the old probe was the optimistic outlier — and it converts a
/// "loads, then rejects every request" slot into a clean unload + 503.
@Test func smallUncappedBoxTightensToMatchTheAdmittingGate() {
    let physical = 16 * gib
    let reserve = ProviderSettings(name: "t", memoryReserveGB: 4)
        .effectiveReserveBytes(physicalBytes: physical)
    #expect(reserve == 4 * gib)

    func headroom(_ r: UInt64) -> UInt64 {
        UnifiedMemoryCap.liveKVHeadroomBytes(
            physicalBytes: physical, mlxUsedBytes: 8 * gib, systemAvailableBytes: .max,
            activationReserveBytes: 0, configReserveBytes: r)
    }
    // hardCap = min(14.4, 14) = 14 GiB. Old: 14 - 8 = 6 GiB.
    #expect(headroom(0) == 6 * gib)
    // New: effectiveCap = min(14, 16 - 4) = 12 GiB -> 12 - 8 = 4 GiB.
    #expect(headroom(reserve) == 4 * gib)
}
