import Testing
@testable import ProviderCore

@Test func globalKVCacheBudgetRejectsDuplicateReservationIDs() async {
    let budget = GlobalKVCacheBudget(safetyFactor: 1.0) {
        GlobalKVCacheBudget.MemorySnapshot(total: 1024, active: 0, cache: 0, systemAvailable: .max)
    }

    #expect(await budget.reserve(requestID: "same", kvBytesPerToken: 1, tokenCount: 1))
    #expect(!(await budget.reserve(requestID: "same", kvBytesPerToken: 1, tokenCount: 1)))

    await budget.release(requestID: "same")
    #expect(await budget.reserve(requestID: "same", kvBytesPerToken: 1, tokenCount: 1))
}

@Test func globalKVCacheBudgetRejectsOverflowingReservationSize() async {
    let budget = GlobalKVCacheBudget(safetyFactor: 1.0) {
        GlobalKVCacheBudget.MemorySnapshot(total: UInt64.max, active: 0, cache: 0, systemAvailable: .max)
    }

    #expect(!(await budget.reserve(requestID: "overflow", kvBytesPerToken: Int.max, tokenCount: Int.max)))
}

@Test func globalKVCacheBudgetHonorsSafetyFactorAsTotalReservationCap() async {
    let budget = GlobalKVCacheBudget(safetyFactor: 0.5) {
        GlobalKVCacheBudget.MemorySnapshot(total: 1000, active: 0, cache: 0, systemAvailable: .max)
    }

    #expect(await budget.reserve(requestID: "first", kvBytesPerToken: 1, tokenCount: 400))
    #expect(!(await budget.reserve(requestID: "second", kvBytesPerToken: 1, tokenCount: 200)))
}

/// The OOM fix: the runtime KV budget must clamp to real OS-available memory,
/// not just the MLX-only view, or it over-admits on a shared box → jetsam OOM.
@Test func globalKVCacheBudgetClampsToOSAvailableWhenItIsTighter() async {
    // MLX-only view says ~1000 bytes free (total 1000, nothing held by MLX),
    // but the OS reports only 100 bytes actually available (other apps hold the
    // rest). The budget must bind to the 100, not the 1000.
    let budget = GlobalKVCacheBudget(safetyFactor: 1.0) {
        GlobalKVCacheBudget.MemorySnapshot(total: 1000, active: 0, cache: 0, systemAvailable: 100)
    }

    // 150 bytes exceeds the real 100-byte OS headroom — must be rejected even
    // though the stale MLX-only math would have admitted it.
    #expect(!(await budget.reserve(requestID: "over-os", kvBytesPerToken: 1, tokenCount: 150)))
    // 100 bytes fits exactly within the OS-available headroom.
    #expect(await budget.reserve(requestID: "at-os", kvBytesPerToken: 1, tokenCount: 100))
}

/// When MLX's own held memory is the tighter bound, that still wins — the clamp
/// takes the smaller of the two views, never the larger.
@Test func globalKVCacheBudgetUsesMLXViewWhenItIsTighterThanOS() async {
    // OS says everything is free, but MLX already holds 900 of 1000 bytes
    // (resident weights) → only 100 free for KV.
    let budget = GlobalKVCacheBudget(safetyFactor: 1.0) {
        GlobalKVCacheBudget.MemorySnapshot(total: 1000, active: 900, cache: 0, systemAvailable: .max)
    }
    #expect(!(await budget.reserve(requestID: "over-mlx", kvBytesPerToken: 1, tokenCount: 150)))
    #expect(await budget.reserve(requestID: "at-mlx", kvBytesPerToken: 1, tokenCount: 100))
}

/// The OS reserve is subtracted from real free memory before the safety factor,
/// matching the load gate's accounting.
@Test func globalKVCacheBudgetSubtractsReserveFromOSAvailable() async {
    // OS reports 1000 free, reserve 600 → 400 usable; safetyFactor 1.0.
    let budget = GlobalKVCacheBudget(reserveBytes: 600, safetyFactor: 1.0) {
        GlobalKVCacheBudget.MemorySnapshot(total: 100_000, active: 0, cache: 0, systemAvailable: 1000)
    }
    #expect(!(await budget.reserve(requestID: "over", kvBytesPerToken: 1, tokenCount: 401)))
    #expect(await budget.reserve(requestID: "fits", kvBytesPerToken: 1, tokenCount: 400))
}

@Test func providerLoopMemoryReserveBytesSaturatesOnOverflow() {
    #expect(ProviderLoop.memoryReserveBytes(forGiB: 4) == 4 * 1024 * 1024 * 1024)
    #expect(ProviderLoop.memoryReserveBytes(forGiB: UInt64.max) == UInt64.max)
}
