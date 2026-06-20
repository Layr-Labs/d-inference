import Foundation
import Testing
@testable import ProviderCore

private let gib: UInt64 = 1024 * 1024 * 1024

// New admission contract.
//
// The KV reclaimable-pool self-heal flush is a blocking GPU synchronize. It used
// to run inside `GlobalKVCacheBudget`'s `commit` (flush-then-resample-then-admit),
// serializing every other reservation behind a GPU sync — the fleet-wide wedge.
//
// Now the admission decision is made against the current snapshot and returns
// immediately; a near-miss merely signals the off-actor `KVPoolReclaimer`, whose
// flush runs on the reclaimer's executor, never the budget actor's. So:
//   * a near-miss the pool could cover is now rejected (no inline flush-and-admit),
//   * `reserve`/`reserveBytes` return promptly even while the flush is blocking,
//   * the flush still happens — in the background, coalesced and rate-limited (its
//     mechanics are pinned in `KVPoolReclaimerTests`).
//
// Invariant under test: the budget actor is never blocked on a GPU sync.

@Test func admissionRejectsNearMissOnCurrentSnapshotInsteadOfFlushingInline() async {
    // cap = 6 GiB (the 2 GiB OS floor binds: 8 − 2); mlxUsed = active 5 + cache 2
    // = 7 GiB → 0 free. The old code flushed the 2 GiB pool inline and admitted
    // the 1 GiB request. The new code rejects it against the current snapshot.
    let memory = MutableMemorySnapshot(cacheAfterClear: 0)
    let budget = GlobalKVCacheBudget(
        capFraction: 1.0,
        activationReserveBytes: 0,
        memorySnapshot: { memory.snapshot() },
        clearCache: { memory.clearCache() })

    #expect(!(await budget.reserve(requestID: "near-miss", kvBytesPerToken: 1, tokenCount: Int(gib))))
    // The flush is signalled to the off-actor reclaimer and runs in the
    // background (the pool could cover the 1 GiB shortfall).
    #expect(await eventually { memory.clearCount == 1 })
}

@Test func reserveBytesRejectsNearMissOnCurrentSnapshot() async {
    let memory = MutableMemorySnapshot(cacheAfterClear: 0)
    let budget = GlobalKVCacheBudget(
        capFraction: 1.0,
        activationReserveBytes: 0,
        memorySnapshot: { memory.snapshot() },
        clearCache: { memory.clearCache() })

    #expect(!(await budget.reserveBytes(requestID: "near-miss-bytes", bytes: gib)))
    #expect(await eventually { memory.clearCount == 1 })
}

@Test func admissionDoesNotBlockTheActorOnTheReclaimFlush() async {
    // The core contract. The injected clearCache blocks for 0.5s (it simulates
    // the GPU synchronize). `reserve` must return promptly — proving the
    // admission decision did not wait on the flush — while the flush completes
    // later, off the budget actor.
    let spy = BlockingClearSpy(blockSeconds: 0.5)
    let memory = MutableMemorySnapshot(cacheAfterClear: 2 * gib)  // pool never shrinks here
    let budget = GlobalKVCacheBudget(
        capFraction: 1.0,
        activationReserveBytes: 0,
        memorySnapshot: { memory.snapshot() },
        clearCache: { spy.clear() })

    let start = ContinuousClock.now
    let admitted = await budget.reserve(requestID: "fast-return", kvBytesPerToken: 1, tokenCount: Int(gib))
    let elapsed = ContinuousClock.now - start

    #expect(!admitted)                                   // rejected on current snapshot
    #expect(elapsed < .milliseconds(250))                // returned well before the 0.5s flush
    #expect(spy.completedCount == 0)                     // flush not finished when reserve returned
    #expect(await eventually(timeout: .seconds(3)) { spy.completedCount == 1 })  // it did run, off-actor
}

@Test func admissionAdmitsImmediatelyWhenItFitsWithoutAnyFlush() async {
    // The happy path is unchanged: a request that fits the current snapshot is
    // admitted with no reclaim signalled at all.
    let memory = MutableMemorySnapshot(total: 8 * gib, active: 0, cache: 0, cacheAfterClear: 0)
    let budget = GlobalKVCacheBudget(
        capFraction: 1.0,
        activationReserveBytes: 0,
        memorySnapshot: { memory.snapshot() },
        clearCache: { memory.clearCache() })

    #expect(await budget.reserve(requestID: "fits", kvBytesPerToken: 1, tokenCount: Int(gib)))
    // Give any (erroneously) scheduled background flush a chance to run, then
    // confirm none did.
    try? await Task.sleep(for: .milliseconds(50))
    #expect(memory.clearCount == 0)
}

// MARK: - helpers

/// Poll a condition up to `timeout`, so a background (off-actor) flush can be
/// observed without racing a fixed sleep.
private func eventually(
    timeout: Duration = .seconds(2),
    _ condition: @Sendable () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

/// A clearCache spy whose flush blocks (like the real GPU synchronize), so a test
/// can prove the budget actor doesn't wait on it.
private final class BlockingClearSpy: @unchecked Sendable {
    private let lock = NSLock()
    private let blockSeconds: Double
    private var _completed = 0

    init(blockSeconds: Double) { self.blockSeconds = blockSeconds }

    func clear() {
        Thread.sleep(forTimeInterval: blockSeconds)   // simulate the blocking GPU sync
        lock.lock(); _completed += 1; lock.unlock()
    }

    var completedCount: Int {
        lock.lock(); defer { lock.unlock() }; return _completed
    }
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
