import Foundation
import Testing
@testable import ProviderCore

private let gib: UInt64 = 1024 * 1024 * 1024

@Test func globalKVCacheBudgetReserveClearsCacheAndAdmitsOnResample() async {
    // cap = 6 GiB (1.0 × 8 GiB, but the 2 GiB OS floor binds); mlxUsed = active 5
    // + cache 2 = 7 GiB → 0 free. The 2 GiB pool is above the heal threshold, so
    // clearCache drops cache → 0, leaving 1 GiB free — enough for the 1 GiB request.
    let memory = MutableMemorySnapshot(cacheAfterClear: 0)
    let budget = GlobalKVCacheBudget(
        capFraction: 1.0,
        activationReserveBytes: 0,
        memorySnapshot: { memory.snapshot() },
        clearCache: { memory.clearCache() })

    #expect(await budget.reserve(requestID: "fits-after-clear", kvBytesPerToken: 1, tokenCount: Int(gib)))
    #expect(memory.clearCount == 1)
}

@Test func globalKVCacheBudgetReserveStillRejectsAfterClearWhenTooLarge() async {
    // Same 6 GiB cap and 2 GiB pool, but the request needs 2 GiB. Even after the
    // pool is flushed only 1 GiB is free, so it's still rejected — one heal attempt.
    let memory = MutableMemorySnapshot(cacheAfterClear: 0)
    let budget = GlobalKVCacheBudget(
        capFraction: 1.0,
        activationReserveBytes: 0,
        memorySnapshot: { memory.snapshot() },
        clearCache: { memory.clearCache() })

    #expect(!(await budget.reserve(requestID: "too-large", kvBytesPerToken: 1, tokenCount: Int(2 * gib))))
    #expect(memory.clearCount == 1)
}

@Test func globalKVCacheBudgetReserveBytesClearsCacheAndAdmitsOnResample() async {
    // reserveBytes path: same headroom as the reserve() admit case — the 2 GiB
    // pool is flushed to free 1 GiB, admitting the 1 GiB byte reservation.
    let memory = MutableMemorySnapshot(cacheAfterClear: 0)
    let budget = GlobalKVCacheBudget(
        capFraction: 1.0,
        activationReserveBytes: 0,
        memorySnapshot: { memory.snapshot() },
        clearCache: { memory.clearCache() })

    #expect(await budget.reserveBytes(requestID: "bytes-fit-after-clear", bytes: gib))
    #expect(memory.clearCount == 1)
}

@Test func globalKVCacheBudgetSkipsHealWhenReclaimablePoolIsTiny() async {
    // Active-dominated near-cap with only a tiny reclaimable pool (100 MiB, below
    // the heal threshold): a flush would free almost nothing, so the self-heal is
    // skipped entirely (no clear, no GPU sync) and the request is rejected.
    let mib: UInt64 = 1024 * 1024
    let memory = MutableMemorySnapshot(
        total: 8 * gib, active: 6 * gib, cache: 100 * mib, cacheAfterClear: 0)
    let budget = GlobalKVCacheBudget(
        capFraction: 1.0,
        activationReserveBytes: 0,
        memorySnapshot: { memory.snapshot() },
        clearCache: { memory.clearCache() })

    #expect(!(await budget.reserve(requestID: "tiny-pool", kvBytesPerToken: 1, tokenCount: Int(gib))))
    #expect(memory.clearCount == 0)   // pool too small to be worth flushing
}

/// Lock-guarded so @Sendable closures can mutate fake MLX cache state safely.
private final class MutableMemorySnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private let total: UInt64
    private let active: UInt64
    private let cacheAfterClear: UInt64
    private let systemAvailable: UInt64
    private var cache: UInt64
    private var clears = 0

    init(
        total: UInt64 = 8 * gib,
        active: UInt64 = 5 * gib,
        cache: UInt64 = 2 * gib,
        cacheAfterClear: UInt64,
        systemAvailable: UInt64 = .max
    ) {
        self.total = total
        self.active = active
        self.cache = cache
        self.cacheAfterClear = cacheAfterClear
        self.systemAvailable = systemAvailable
    }

    func snapshot() -> GlobalKVCacheBudget.MemorySnapshot {
        lock.lock()
        defer { lock.unlock() }
        return GlobalKVCacheBudget.MemorySnapshot(
            total: total,
            active: active,
            cache: cache,
            systemAvailable: systemAvailable)
    }

    func clearCache() {
        lock.lock()
        clears += 1
        cache = cacheAfterClear
        lock.unlock()
    }

    var clearCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return clears
    }
}
