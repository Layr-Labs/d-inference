import Testing
@testable import ProviderCore

// These exercise GlobalKVCacheBudget against the unified-cap headroom formula
// (UnifiedMemoryCap.liveKVHeadroomBytes): headroom =
//   min(hardCap − mlxUsed, systemAvailable) − activationReserve
// where hardCap = min(capFraction × total, total − 2 GiB floor). Tests pin
// capFraction / activationReserve so the arithmetic is exact; production uses
// the 0.90 / 3 GiB defaults.
//
// NOTE: `total` must exceed the 2 GiB hardCap OS floor or hardCap collapses to 0
// (correct for a sub-2 GiB "machine", but not what these accounting tests model).
// So the memory figures are GiB-scaled; reservation footprints stay byte-sized
// (tokenCount × kvBytesPerToken) and are tiny relative to the headroom, which is
// what each test pins via `systemAvailable`.
private let gib: UInt64 = 1024 * 1024 * 1024

@Test func globalKVCacheBudgetRejectsDuplicateReservationIDs() async {
    let budget = GlobalKVCacheBudget(capFraction: 1.0, activationReserveBytes: 0) {
        GlobalKVCacheBudget.MemorySnapshot(total: 8 * gib, active: 0, cache: 0, systemAvailable: .max)
    }

    #expect(await budget.reserve(requestID: "same", kvBytesPerToken: 1, tokenCount: 1))
    #expect(!(await budget.reserve(requestID: "same", kvBytesPerToken: 1, tokenCount: 1)))

    await budget.release(requestID: "same")
    #expect(await budget.reserve(requestID: "same", kvBytesPerToken: 1, tokenCount: 1))
}

@Test func globalKVCacheBudgetRejectsOverflowingReservationSize() async {
    let budget = GlobalKVCacheBudget(capFraction: 1.0, activationReserveBytes: 0) {
        GlobalKVCacheBudget.MemorySnapshot(total: UInt64.max, active: 0, cache: 0, systemAvailable: .max)
    }

    #expect(!(await budget.reserve(requestID: "overflow", kvBytesPerToken: Int.max, tokenCount: Int.max)))
}

/// The cap fraction bounds the total reservable bytes: 0.5 × 8 GiB = 4 GiB cap
/// (the fraction binds, not the 6 GiB floor), so a 3 GiB reservation fits but a
/// further 2 GiB (→5 GiB) does not.
@Test func globalKVCacheBudgetHonorsCapFractionAsTotalReservationCap() async {
    let budget = GlobalKVCacheBudget(capFraction: 0.5, activationReserveBytes: 0) {
        GlobalKVCacheBudget.MemorySnapshot(total: 8 * gib, active: 0, cache: 0, systemAvailable: .max)
    }

    #expect(await budget.reserve(requestID: "first", kvBytesPerToken: 1, tokenCount: Int(3 * gib)))
    #expect(!(await budget.reserve(requestID: "second", kvBytesPerToken: 1, tokenCount: Int(2 * gib))))
}

/// The runtime KV budget must clamp to real OS-available memory, not just the
/// MLX-only view, or it over-admits on a shared box → jetsam OOM.
@Test func globalKVCacheBudgetClampsToOSAvailableWhenItIsTighter() async {
    // cap = 8 GiB (fraction 1.0, but floor 6 GiB binds → 6 GiB), nothing held by
    // MLX → 6 GiB under cap, but the OS reports only 1 GiB available. The budget
    // must bind to the tighter 1 GiB OS view.
    let budget = GlobalKVCacheBudget(capFraction: 1.0, activationReserveBytes: 0) {
        GlobalKVCacheBudget.MemorySnapshot(total: 8 * gib, active: 0, cache: 0, systemAvailable: 1 * gib)
    }

    #expect(!(await budget.reserve(requestID: "over-os", kvBytesPerToken: 1, tokenCount: Int(gib + 1))))
    #expect(await budget.reserve(requestID: "at-os", kvBytesPerToken: 1, tokenCount: Int(1 * gib)))
}

/// When MLX's own held memory is the tighter bound, that still wins — the
/// under-cap headroom (cap − mlxUsed) is the smaller of the two views.
@Test func globalKVCacheBudgetUsesMLXViewWhenItIsTighterThanOS() async {
    // 64 GiB box, cap 0.9×64 = 57.6 GiB. MLX already holds 56.6 GiB (resident
    // weights+KV) → only 1 GiB under cap, OS view unlimited.
    let cap = UInt64(Double(64 * gib) * 0.9)
    let budget = GlobalKVCacheBudget(capFraction: 0.9, activationReserveBytes: 0) {
        GlobalKVCacheBudget.MemorySnapshot(total: 64 * gib, active: cap - gib, cache: 0, systemAvailable: .max)
    }
    #expect(!(await budget.reserve(requestID: "over-mlx", kvBytesPerToken: 1, tokenCount: Int(gib + 1))))
    #expect(await budget.reserve(requestID: "at-mlx", kvBytesPerToken: 1, tokenCount: Int(1 * gib)))
}

/// The activation reserve is subtracted from real free memory before any KV may
/// be reserved — it carves out forward-pass working memory under the cap.
@Test func globalKVCacheBudgetSubtractsActivationReserveFromHeadroom() async {
    // 64 GiB box, OS reports 5 GiB free (the binding view), activation reserve
    // 3 GiB → 2 GiB left for KV.
    let budget = GlobalKVCacheBudget(capFraction: 0.9, activationReserveBytes: 3 * gib) {
        GlobalKVCacheBudget.MemorySnapshot(total: 64 * gib, active: 0, cache: 0, systemAvailable: 5 * gib)
    }
    #expect(!(await budget.reserve(requestID: "over", kvBytesPerToken: 1, tokenCount: Int(2 * gib + 1))))
    #expect(await budget.reserve(requestID: "fits", kvBytesPerToken: 1, tokenCount: Int(2 * gib)))
}

@Test func providerLoopMemoryReserveBytesSaturatesOnOverflow() {
    #expect(ProviderLoop.memoryReserveBytes(forGiB: 4) == 4 * 1024 * 1024 * 1024)
    #expect(ProviderLoop.memoryReserveBytes(forGiB: UInt64.max) == UInt64.max)
}
