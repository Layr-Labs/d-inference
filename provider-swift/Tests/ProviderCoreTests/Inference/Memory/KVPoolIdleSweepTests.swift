import Foundation
import MLX
import Testing
@testable import MLXLMCommon
@testable import ProviderCore

private let gib: UInt64 = 1024 * 1024 * 1024

/// The proactive sweep keeps busy engines' MLX buffer pool: it flushes on an
/// idle Mac (without reporting device activity) or when the pool crowds out
/// admission headroom, never merely because the pool crossed its threshold.
@Suite("KV pool idle sweep")
struct KVPoolIdleSweepTests {

    @Test("window: idle opens, healthy busy headroom closes, crowded headroom is pressure")
    func proactiveWindowPolicy() {
        #expect(KVPoolReclaimer.proactiveWindow(
            idle: true, reclaimableBytes: 3 * gib, remainingBytes: 100 * gib, thresholdBytes: 2 * gib) == .idle)
        // 100 GiB left for admission: a 3 GiB pool is reuse, not pressure.
        #expect(KVPoolReclaimer.proactiveWindow(
            idle: false, reclaimableBytes: 3 * gib, remainingBytes: 100 * gib, thresholdBytes: 2 * gib) == .closed)
        // Remaining headroom below pool + threshold: flush even while serving.
        #expect(KVPoolReclaimer.proactiveWindow(
            idle: false, reclaimableBytes: 3 * gib, remainingBytes: 4 * gib, thresholdBytes: 2 * gib) == .pressure)
        #expect(KVPoolReclaimer.proactiveWindow(
            idle: false, reclaimableBytes: .max, remainingBytes: 100 * gib, thresholdBytes: 2 * gib) == .pressure)
    }

    @Test("a closed window keeps the pool; the on-pressure reclaim still flushes")
    func closedWindowDefersOnlyTheProactiveSweep() async {
        let spy = SweepSpy(reclaimable: 3 * gib)
        let reclaimer = KVPoolReclaimer(
            clearCache: { spy.record("device") },
            reclaimableBytes: { spy.reclaimable },
            minInterval: .zero,
            proactiveThresholdBytes: 2 * gib,
            sweepWindow: { _ in .closed },
            idleClearCache: { spy.record("idle"); return true })

        #expect(!(await reclaimer.sweep()))
        #expect(await reclaimer.sweepSignalCount == 1)
        #expect(spy.flushes.isEmpty)

        #expect(await reclaimer.reclaimIfNeeded(shortfall: gib))
        #expect(spy.flushes == ["device"])
    }

    @Test("an idle window flushes with the activity-free idle flush")
    func idleWindowUsesIdleFlush() async {
        let spy = SweepSpy(reclaimable: 3 * gib)
        let reclaimer = KVPoolReclaimer(
            clearCache: { spy.record("device") },
            reclaimableBytes: { spy.reclaimable },
            minInterval: .zero,
            proactiveThresholdBytes: 2 * gib,
            sweepWindow: { _ in .idle },
            idleClearCache: { spy.record("idle"); return true })

        #expect(await reclaimer.sweep())
        #expect(spy.flushes == ["idle"])
        #expect(await reclaimer.reclaimCount == 1)
    }

    @Test("a pressure window flushes like the reference sweep and passes the pool size")
    func pressureWindowUsesDeviceFlush() async {
        let spy = SweepSpy(reclaimable: 5 * gib)
        let observed = SweepSpy(reclaimable: 0)
        let reclaimer = KVPoolReclaimer(
            clearCache: { spy.record("device") },
            reclaimableBytes: { spy.reclaimable },
            minInterval: .zero,
            proactiveThresholdBytes: 2 * gib,
            sweepWindow: { pool in
                observed.reclaimable = pool
                return .pressure
            },
            idleClearCache: { spy.record("idle"); return true })

        #expect(await reclaimer.sweep())
        #expect(spy.flushes == ["device"])
        #expect(observed.reclaimable == 5 * gib)
    }

    @Test("shortfall and pressure reclaims ask engines to drop retained KV segments")
    func reclaimsRequestRetainedSegmentRelease() async {
        let spy = SweepSpy(reclaimable: 3 * gib)
        let releases = SweepSpy(reclaimable: 0)
        // 0 keeps the proactive window closed; 1 reports pressure.
        let pressure = SweepSpy(reclaimable: 0)
        let reclaimer = KVPoolReclaimer(
            clearCache: { spy.record("device") },
            reclaimableBytes: { spy.reclaimable },
            minInterval: .zero,
            proactiveThresholdBytes: 2 * gib,
            sweepWindow: { _ in pressure.reclaimable == 0 ? .closed : .pressure },
            idleClearCache: { spy.record("idle"); return true },
            releaseRetained: { releases.record("release") })

        // The cache cannot cover this shortfall; retained backing still goes.
        #expect(!(await reclaimer.reclaimIfNeeded(shortfall: 4 * gib)))
        #expect(releases.flushes.count == 1 && spy.flushes.isEmpty)
        #expect(await reclaimer.reclaimIfNeeded(shortfall: gib))
        #expect(releases.flushes.count == 2 && spy.flushes == ["device"])

        #expect(!(await reclaimer.sweep()))
        #expect(releases.flushes.count == 2)
        pressure.reclaimable = 1
        #expect(await reclaimer.sweep())
        #expect(releases.flushes.count == 3 && spy.flushes == ["device", "device"])
    }

    @Test("the window is not consulted below the threshold")
    func windowIsNotConsultedBelowThreshold() async {
        let spy = SweepSpy(reclaimable: gib)
        let windows = SweepSpy(reclaimable: 0)
        let reclaimer = KVPoolReclaimer(
            clearCache: { spy.record("device") },
            reclaimableBytes: { spy.reclaimable },
            minInterval: .zero,
            proactiveThresholdBytes: 2 * gib,
            sweepWindow: { _ in
                windows.record("window")
                return .idle
            })
        #expect(!(await reclaimer.sweep()))
        #expect(spy.flushes.isEmpty && windows.flushes.isEmpty)
    }

    @Test("whole-Mac idleness requires the full duration with no charge or activity")
    func serviceBudgetIdleDuration() {
        let clock = SweepTestClock()
        let budget = WholeMacServiceBudget(clockNow: { clock.now })
        #expect(!budget.isIdle(for: .seconds(5)))
        clock.advance(.seconds(5))
        #expect(budget.isIdle(for: .seconds(5)))

        #expect(budget.acquire(ownerID: "request", concurrency: 4))
        #expect(!budget.isIdle(for: .zero))
        clock.advance(.seconds(30))
        #expect(!budget.isIdle(for: .seconds(5)))
        budget.release(ownerID: "request")
        #expect(budget.isIdle(for: .zero))
        clock.advance(.seconds(4))
        #expect(!budget.isIdle(for: .seconds(5)))
        clock.advance(.seconds(1))
        #expect(budget.isIdle(for: .seconds(5)))

        let activity = budget.beginUnboundedActivity()
        clock.advance(.seconds(10))
        #expect(!budget.isIdle(for: .seconds(5)))
        activity.finish()
        #expect(!budget.isIdle(for: .seconds(5)))
        clock.advance(.seconds(5))
        #expect(budget.isIdle(for: .seconds(5)))
    }

    @Test("an idle-only operation keeps request admission out until it returns")
    func idleOperationHoldsOffAdmission() async {
        let clock = SweepTestClock()
        let budget = WholeMacServiceBudget(clockNow: { clock.now })
        #expect(!budget.performIfIdle(for: .seconds(5)) { Issue.record("ran before 5 s of idleness") })
        clock.advance(.seconds(5))
        let events = SweepSpy(reclaimable: 0)
        var admission: Task<Void, Never>?
        let ran = budget.performIfIdle(for: .seconds(5)) {
            admission = Task.detached {
                #expect(budget.acquire(ownerID: "request", concurrency: 1))
                events.record("admitted")
            }
            usleep(100_000)
            events.record("idle operation")
        }
        #expect(ran)
        await admission?.value
        #expect(events.flushes == ["idle operation", "admitted"],
                "the request was admitted during the idle-only operation")
        #expect(budget.count == 1)
        #expect(!budget.performIfIdle(for: .zero) { Issue.record("ran while a request is charged") })
        budget.release(ownerID: "request")
    }

    @Test("a declined idle flush records no reclaim and leaves the rate-limit window open")
    func declinedIdleFlushLeavesRateLimitOpen() async {
        let spy = SweepSpy(reclaimable: 3 * gib)
        let reclaimer = KVPoolReclaimer(
            clearCache: { spy.record("device") },
            reclaimableBytes: { spy.reclaimable },
            minInterval: .seconds(3600),
            proactiveThresholdBytes: 2 * gib,
            sweepWindow: { _ in .idle },
            idleClearCache: {
                spy.record("declined")
                return false
            })

        // A request admitted after the window check declined the idle flush.
        #expect(!(await reclaimer.sweep()))
        #expect(await reclaimer.reclaimCount == 0)
        // Its shortfall reclaim still flushes inside the hour-long window.
        #expect(await reclaimer.reclaimIfNeeded(shortfall: gib))
        #expect(spy.flushes == ["declined", "device"])
        #expect(await reclaimer.reclaimCount == 1)
    }

    @Test("a refused engine-owned charge signals the bytes it was short by")
    func engineRefusalSignalsShortfall() throws {
        // Headroom = cap 8 GiB - (active 3 + cache 3) = 2 GiB.
        let ledger = ProcessMemoryLedger(
            policy: .init(epoch: 1, capBytes: 8 * gib, reserveBytes: 0),
            readUsage: { .init(activeBytes: 3 * gib, cacheBytes: 3 * gib, systemAvailableBytes: .max) })
        let signals = SweepSpy(reclaimable: 0)
        let owner = EngineProcessMemoryOwner(ledger: ledger, onRefusal: { signals.reclaimable = $0 })
        try owner.replaceCharge(gib)
        #expect(signals.reclaimable == 0)
        #expect(throws: ProcessMemoryLedger.Refusal.insufficientCapacity) {
            try owner.replaceCharge(4 * gib)
        }
        // The +3 GiB growth exceeded the 1 GiB still unpromised by 2 GiB.
        #expect(signals.reclaimable == 2 * gib)
        #expect(ledger.snapshot().chargedBytes == gib)
    }

    @Test("direct-charge refusals signal a reclaim unless both busy-engine rollbacks are set")
    func engineRefusalSignalFollowsKillSwitches() {
        let sweepOff = ["DARKBLOOM_TTFT_IDLE_CACHE_SWEEP": "0"]
        let retentionOff = ["DARKBLOOM_TTFT_SEGMENT_RETENTION": "0"]
        #expect(GlobalKVCacheBudget.idleCacheSweepEnabled(environment: [:]))
        #expect(!GlobalKVCacheBudget.idleCacheSweepEnabled(environment: sweepOff))
        #expect(EngineV2Factory.segmentRetentionEnabled(environment: [:]))
        #expect(!EngineV2Factory.segmentRetentionEnabled(environment: retentionOff))

        #expect(GlobalKVCacheBudget(environment: [:]).signalsEngineRefusals)
        #expect(GlobalKVCacheBudget(environment: retentionOff).signalsEngineRefusals)
        // Retained segments are still allocator-active memory only a release returns.
        let retentionOnly = GlobalKVCacheBudget(environment: sweepOff)
        #expect(retentionOnly.signalsEngineRefusals && retentionOnly.directChargeRefusalSignal() != nil)
        let rolledBack = GlobalKVCacheBudget(environment: sweepOff.merging(retentionOff) { $1 })
        #expect(!rolledBack.signalsEngineRefusals && rolledBack.directChargeRefusalSignal() == nil)
        let injected = GlobalKVCacheBudget(memorySnapshot: {
            .init(total: 64 * gib, active: 0, cache: 0, systemAvailable: 64 * gib)
        })
        #expect(!injected.signalsEngineRefusals)
    }

    @Test("the segmented factory retains min(2 GiB, grant / 8) with host zeros unless rolled back")
    func segmentedFactoryAppliesRetentionRollbacks() throws {
        let kind = CBv2LayerKind(attention: .full, headDim: 128, kvHeads: 2, queryHeads: 4)
        func config(grant: Int, _ environment: [String: String] = [:]) throws -> PagedKVPoolConfig {
            try EngineV2Factory.makeSegmentedPagedBackend(
                admittedGrantBytes: grant, layerKinds: [kind], layerDTypes: [.bfloat16],
                schedulerConfig: .init(), maxContextLength: 8192, maxBufferLength: 128 << 20,
                environment: environment
            ).pool.config
        }
        let defaults = try config(grant: 8 << 30)
        #expect(defaults.retainedFreeSegmentBytes == 1 << 30 && defaults.hostZeroedSegments)
        #expect(defaults.retainedFreeSegmentIdleSeconds == 30)
        #expect(try config(grant: 64 << 30).retainedFreeSegmentBytes == 2 << 30)
        let deviceFill = try config(grant: 8 << 30, ["DARKBLOOM_TTFT_SEGMENT_HOST_ZEROS": "0"])
        #expect(deviceFill.retainedFreeSegmentBytes == 1 << 30 && !deviceFill.hostZeroedSegments)
        let off = try config(grant: 8 << 30, ["DARKBLOOM_TTFT_SEGMENT_RETENTION": "0"])
        #expect(off.retainedFreeSegmentBytes == 0 && !off.hostZeroedSegments)
    }

    @Test("a load-time release waits for engine steps to drop retained KV segments")
    func loadReleaseWaitsForEngineSteps() async throws {
        let engine = try RetainingEngineStub()
        #expect(engine.parkedBytes > 0)
        #expect(CBv2RetainedKVSegments.retainedBytes >= engine.parkedBytes)
        let steps = engine.start()
        defer { steps.cancel() }
        await GlobalKVCacheBudget.releaseRetainedKVSegments(timeout: .seconds(2))
        #expect(engine.parkedBytes == 0)
    }

    @Test("a cancelled load stops waiting for engines to drop retained KV segments")
    func cancelledLoadReleaseStopsWaiting() async throws {
        // No engine steps, so the parked backing outlives any wait.
        let engine = try RetainingEngineStub()
        #expect(engine.parkedBytes > 0)
        let started = ContinuousClock.now
        let wait = Task { await GlobalKVCacheBudget.releaseRetainedKVSegments(timeout: .seconds(10)) }
        wait.cancel()
        await wait.value
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(engine.parkedBytes > 0)
    }
}

/// One paged pool holding parked free segments, plus an engine-queue stand-in
/// that honors process-wide release requests at each step like `EngineLoopV2`.
/// Host-zeroed 16 KiB pages keep segment growth free of GPU work.
final class RetainingEngineStub: @unchecked Sendable {
    private let lock = NSLock()
    private let backend: PagedKVBackend

    init() throws {
        let kind = CBv2LayerKind(attention: .full, headDim: 128, kvHeads: 2, queryHeads: 4)
        backend = try PagedKVBackend(layerKinds: [kind], config: .init(
            capacityBytes: 8 << 20, dtype: .bfloat16, maxPrefillChunk: 512,
            nominalMaxSequenceLength: 2048, maxBufferLength: 16 << 20,
            segmentSizeBytes: 9 * 16_384, retainedFreeSegmentBytes: 4 << 20,
            hostZeroedSegments: true))
        let rows = try backend.makeSequenceState(layerKinds: [kind], promptLength: 0, maxLength: 64)
        backend.release(rows)
    }

    var parkedBytes: Int { lock.withLock { backend.pool.retainedSegmentBytes } }

    func step() { lock.withLock { backend.pool.releaseRetainedSegmentsIfRequested() } }

    func start() -> Task<Void, Never> {
        Task.detached { [self] in
            while !Task.isCancelled {
                step()
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
    }
}

/// Parked retained-segment bytes seen when an evicted model shut down.
final class ParkedBytesRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: Int?

    var bytes: Int? { lock.withLock { recorded } }

    func record(_ bytes: Int) { lock.withLock { recorded = bytes } }
}

private final class SweepSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var _reclaimable: UInt64
    private var _flushes: [String] = []

    init(reclaimable: UInt64) { _reclaimable = reclaimable }

    var reclaimable: UInt64 {
        get { lock.withLock { _reclaimable } }
        set { lock.withLock { _reclaimable = newValue } }
    }

    var flushes: [String] { lock.withLock { _flushes } }

    func record(_ flush: String) { lock.withLock { _flushes.append(flush) } }
}

private final class SweepTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now
    var now: ContinuousClock.Instant { lock.withLock { instant } }
    func advance(_ duration: Duration) { lock.withLock { instant = instant.advanced(by: duration) } }
}
