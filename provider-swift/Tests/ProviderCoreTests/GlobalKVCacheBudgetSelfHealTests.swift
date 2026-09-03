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
    await memory.didClear.wait()
    #expect(memory.clearCount == 1)
}

@Test func reserveBytesRejectsNearMissOnCurrentSnapshot() async {
    let memory = MutableMemorySnapshot(cacheAfterClear: 0)
    let budget = GlobalKVCacheBudget(
        capFraction: 1.0,
        activationReserveBytes: 0,
        memorySnapshot: { memory.snapshot() },
        clearCache: { memory.clearCache() })

    #expect(!(await budget.reserveBytes(requestID: "near-miss-bytes", bytes: gib)))
    await memory.didClear.wait()
    #expect(memory.clearCount == 1)
}

@Test func admissionReturnsBeforeTheReclaimFlushIsReleased() async {
    let spy = BlockingClearSpy()
    let memory = MutableMemorySnapshot(cacheAfterClear: 2 * gib)
    let budget = GlobalKVCacheBudget(
        capFraction: 1.0,
        activationReserveBytes: 0,
        memorySnapshot: { memory.snapshot() },
        clearCache: { spy.clear() })

    let reservation = Task {
        await budget.reserve(
            requestID: "ordered-return",
            kvBytesPerToken: 1,
            tokenCount: Int(gib))
    }
    await spy.started.wait()
    let admitted = await reservation.value

    #expect(!admitted)
    #expect(spy.completedCount == 0)
    spy.release()
    await spy.completed.wait()
    #expect(spy.completedCount == 1)
}


/// A clearCache spy that parks on an explicit latch, modelling a blocking GPU
/// synchronize without making correctness depend on elapsed wall time.
private final class BlockingClearSpy: @unchecked Sendable {
    let started = AsyncTestLatch()
    let completed = AsyncTestLatch()
    private let releaseGate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var _completed = 0

    func clear() {
        started.signal()
        releaseGate.wait()
        lock.lock()
        _completed += 1
        lock.unlock()
        completed.signal()
    }

    func release() { releaseGate.signal() }

    var completedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _completed
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
    let didClear = AsyncTestLatch()

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
        didClear.signal()
    }

    var clearCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return clears
    }
}
