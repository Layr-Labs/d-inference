import Testing
@testable import ProviderCore

// These exercise GlobalKVCacheBudget against the unified-cap headroom formula
// (UnifiedMemoryCap.liveKVHeadroomBytes): headroom =
//   min(capFraction × total − mlxUsed, systemAvailable) − activationReserve
// then minus already-reserved bytes. Tests pin capFraction / activationReserve
// so the arithmetic is exact; production uses the 0.90 / 3 GiB defaults.

@Test func globalKVCacheBudgetRejectsDuplicateReservationIDs() async {
    let budget = GlobalKVCacheBudget(capFraction: 1.0, activationReserveBytes: 0) {
        GlobalKVCacheBudget.MemorySnapshot(total: 1024, active: 0, cache: 0, systemAvailable: .max)
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

/// The cap fraction bounds the total reservable bytes: 0.5 × 1000 = 500, so a
/// 400-byte reservation fits but a further 200 (→600) does not.
@Test func globalKVCacheBudgetHonorsCapFractionAsTotalReservationCap() async {
    let budget = GlobalKVCacheBudget(capFraction: 0.5, activationReserveBytes: 0) {
        GlobalKVCacheBudget.MemorySnapshot(total: 1000, active: 0, cache: 0, systemAvailable: .max)
    }

    #expect(await budget.reserve(requestID: "first", kvBytesPerToken: 1, tokenCount: 400))
    #expect(!(await budget.reserve(requestID: "second", kvBytesPerToken: 1, tokenCount: 200)))
}

/// The runtime KV budget must clamp to real OS-available memory, not just the
/// MLX-only view, or it over-admits on a shared box → jetsam OOM.
@Test func globalKVCacheBudgetClampsToOSAvailableWhenItIsTighter() async {
    // capFraction 1.0 → cap 1000, nothing held by MLX → 1000 under cap, but the
    // OS reports only 100 actually available. The budget must bind to the 100.
    let budget = GlobalKVCacheBudget(capFraction: 1.0, activationReserveBytes: 0) {
        GlobalKVCacheBudget.MemorySnapshot(total: 1000, active: 0, cache: 0, systemAvailable: 100)
    }

    #expect(!(await budget.reserve(requestID: "over-os", kvBytesPerToken: 1, tokenCount: 150)))
    #expect(await budget.reserve(requestID: "at-os", kvBytesPerToken: 1, tokenCount: 100))
}

/// When MLX's own held memory is the tighter bound, that still wins — the
/// under-cap headroom (cap − mlxUsed) is the smaller of the two views.
@Test func globalKVCacheBudgetUsesMLXViewWhenItIsTighterThanOS() async {
    // cap 1000, MLX already holds 900 (resident weights) → only 100 under cap.
    let budget = GlobalKVCacheBudget(capFraction: 1.0, activationReserveBytes: 0) {
        GlobalKVCacheBudget.MemorySnapshot(total: 1000, active: 900, cache: 0, systemAvailable: .max)
    }
    #expect(!(await budget.reserve(requestID: "over-mlx", kvBytesPerToken: 1, tokenCount: 150)))
    #expect(await budget.reserve(requestID: "at-mlx", kvBytesPerToken: 1, tokenCount: 100))
}

/// The activation reserve is subtracted from real free memory before any KV may
/// be reserved — it carves out forward-pass working memory under the cap.
@Test func globalKVCacheBudgetSubtractsActivationReserveFromHeadroom() async {
    // cap 100_000, OS reports 1000 free, activation reserve 600 → 400 for KV.
    let budget = GlobalKVCacheBudget(capFraction: 1.0, activationReserveBytes: 600) {
        GlobalKVCacheBudget.MemorySnapshot(total: 100_000, active: 0, cache: 0, systemAvailable: 1000)
    }
    #expect(!(await budget.reserve(requestID: "over", kvBytesPerToken: 1, tokenCount: 401)))
    #expect(await budget.reserve(requestID: "fits", kvBytesPerToken: 1, tokenCount: 400))
}

@Test func providerLoopMemoryReserveBytesSaturatesOnOverflow() {
    #expect(ProviderLoop.memoryReserveBytes(forGiB: 4) == 4 * 1024 * 1024 * 1024)
    #expect(ProviderLoop.memoryReserveBytes(forGiB: UInt64.max) == UInt64.max)
}
