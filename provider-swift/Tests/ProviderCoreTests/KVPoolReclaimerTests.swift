import Foundation
import Testing
@testable import ProviderCore

private let gib: UInt64 = 1024 * 1024 * 1024

/// The off-actor KV-pool reclaimer. These drive the actor methods directly
/// (deterministic — the injected `clearCache` runs synchronously on the
/// reclaimer actor) to pin the shortfall gate, rate-limit, coalescing, and the
/// proactive-sweep threshold without a GPU.
@Suite("KV pool reclaimer")
struct KVPoolReclaimerTests {

    @Test("on-pressure: flushes when the reclaimable pool covers the shortfall")
    func flushesWhenPoolCoversShortfall() async {
        let spy = ReclaimSpy(reclaimable: 2 * gib)
        let reclaimer = KVPoolReclaimer(
            clearCache: { spy.clear() },
            reclaimableBytes: { spy.reclaimable },
            minInterval: .zero)

        #expect(await reclaimer.reclaimIfNeeded(shortfall: gib))
        #expect(await reclaimer.reclaimCount == 1)
        #expect(spy.clearCount == 1)
    }

    @Test("on-pressure: skips when the pool cannot cover the shortfall")
    func skipsWhenPoolCannotCoverShortfall() async {
        // Active-dominated near-cap: the reclaimable pool (100 MiB) can't cover the
        // 1 GiB shortfall, so a flush wouldn't admit anything — skip the GPU sync.
        let spy = ReclaimSpy(reclaimable: 100 * 1024 * 1024)
        let reclaimer = KVPoolReclaimer(
            clearCache: { spy.clear() },
            reclaimableBytes: { spy.reclaimable },
            minInterval: .zero)

        #expect(!(await reclaimer.reclaimIfNeeded(shortfall: gib)))
        #expect(await reclaimer.reclaimCount == 0)
        #expect(spy.clearCount == 0)
    }

    @Test("on-pressure: a zero shortfall never flushes")
    func zeroShortfallNeverFlushes() async {
        let spy = ReclaimSpy(reclaimable: 8 * gib)
        let reclaimer = KVPoolReclaimer(
            clearCache: { spy.clear() },
            reclaimableBytes: { spy.reclaimable },
            minInterval: .zero)
        #expect(!(await reclaimer.reclaimIfNeeded(shortfall: 0)))
        #expect(await reclaimer.reclaimCount == 0)
    }

    @Test("rate-limit: a second flush inside the window is coalesced away")
    func rateLimitsRepeatedFlushes() async {
        // A pool the fake clear doesn't shrink (simulating immediate refill), so
        // both calls pass the shortfall gate. With a long interval the second is
        // rate-limited — the blocking GPU sync runs at most once per window.
        let spy = ReclaimSpy(reclaimable: 2 * gib, shrinkOnClear: false)
        let reclaimer = KVPoolReclaimer(
            clearCache: { spy.clear() },
            reclaimableBytes: { spy.reclaimable },
            minInterval: .seconds(3600))

        #expect(await reclaimer.reclaimIfNeeded(shortfall: 2 * gib))
        #expect(!(await reclaimer.reclaimIfNeeded(shortfall: 2 * gib)))
        #expect(await reclaimer.reclaimCount == 1)
    }

    @Test("rate-limit: a second flush is allowed once the window elapses")
    func allowsSecondFlushAfterInterval() async {
        let spy = ReclaimSpy(reclaimable: 2 * gib, shrinkOnClear: false)
        let reclaimer = KVPoolReclaimer(
            clearCache: { spy.clear() },
            reclaimableBytes: { spy.reclaimable },
            minInterval: .zero)   // any elapsed gap clears the window

        #expect(await reclaimer.reclaimIfNeeded(shortfall: 2 * gib))
        #expect(await reclaimer.reclaimIfNeeded(shortfall: 2 * gib))
        #expect(await reclaimer.reclaimCount == 2)
    }

    @Test("proactive sweep: flushes only when the pool exceeds the threshold")
    func proactiveSweepRespectsThreshold() async {
        let spy = ReclaimSpy(reclaimable: 3 * gib, shrinkOnClear: false)
        let reclaimer = KVPoolReclaimer(
            clearCache: { spy.clear() },
            reclaimableBytes: { spy.reclaimable },
            minInterval: .zero,
            proactiveThresholdBytes: 2 * gib)

        #expect(await reclaimer.sweep())          // 3 GiB >= 2 GiB threshold
        #expect(await reclaimer.reclaimCount == 1)

        spy.reclaimable = 1 * gib                  // now below threshold
        #expect(!(await reclaimer.sweep()))
        #expect(await reclaimer.reclaimCount == 1)
    }

    @Test("the on-pressure and proactive paths share one rate-limit window")
    func sweepAndReclaimShareRateLimit() async {
        let spy = ReclaimSpy(reclaimable: 4 * gib, shrinkOnClear: false)
        let reclaimer = KVPoolReclaimer(
            clearCache: { spy.clear() },
            reclaimableBytes: { spy.reclaimable },
            minInterval: .seconds(3600),
            proactiveThresholdBytes: 2 * gib)

        #expect(await reclaimer.sweep())                          // flushes
        #expect(!(await reclaimer.reclaimIfNeeded(shortfall: gib)))  // shares window → skipped
        #expect(await reclaimer.reclaimCount == 1)
    }
}

/// Lock-guarded so the @Sendable reclaimer closures can read/mutate fake pool
/// state safely off the test's task.
private final class ReclaimSpy: @unchecked Sendable {
    private let lock = NSLock()
    private let shrinkOnClear: Bool
    private var _reclaimable: UInt64
    private var _clearCount = 0

    init(reclaimable: UInt64, shrinkOnClear: Bool = true) {
        self._reclaimable = reclaimable
        self.shrinkOnClear = shrinkOnClear
    }

    var reclaimable: UInt64 {
        get { lock.lock(); defer { lock.unlock() }; return _reclaimable }
        set { lock.lock(); _reclaimable = newValue; lock.unlock() }
    }

    func clear() {
        lock.lock()
        _clearCount += 1
        if shrinkOnClear { _reclaimable = 0 }
        lock.unlock()
    }

    var clearCount: Int {
        lock.lock(); defer { lock.unlock() }; return _clearCount
    }
}
