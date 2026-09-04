import Foundation
import Testing
@testable import ProviderCore

/// T13-04 — cpu_usage from HOST_CPU_LOAD_INFO tick deltas instead of
/// loadavg/ncpu (port of PR #800's design, re-implemented with a minimum
/// window guard).
@Suite("system CPU metrics")
struct SystemMetricsTests {

    @Test("tick delta reports idle, mixed, and fully busy fractions")
    func busyFractionFromTicks() {
        let origin = CPUTickSample(user: 10, system: 5, idle: 20, nice: 1)

        #expect(
            CPUTickSample.busyFraction(
                from: origin,
                to: CPUTickSample(user: 10, system: 5, idle: 120, nice: 1)
            ) == 0.0
        )

        #expect(
            CPUTickSample.busyFraction(
                from: origin,
                to: CPUTickSample(user: 110, system: 5, idle: 20, nice: 1)
            ) == 1.0
        )

        // +30 user, +20 system, +50 idle: 50 busy / 100 total. (PR #800's
        // fixture of 60/25/70 is 70/120 = 0.583, not the 0.5 it asserted —
        // its CI never ran.)
        let mixed = CPUTickSample.busyFraction(
            from: origin,
            to: CPUTickSample(user: 40, system: 25, idle: 70, nice: 1)
        )
        #expect(abs(mixed - 0.5) < 0.0001)
    }

    @Test("zero elapsed ticks is 0 rather than NaN")
    func zeroElapsedTicks() {
        let sample = CPUTickSample(user: 1, system: 2, idle: 3, nice: 4)
        #expect(CPUTickSample.busyFraction(from: sample, to: sample) == 0.0)
    }

    @Test("UInt32 tick wrap uses wrapping subtract")
    func wrappingTicks() {
        let previous = CPUTickSample(user: UInt32.max - 5, system: 0, idle: 0, nice: 0)
        let current = CPUTickSample(user: 4, system: 0, idle: 10, nice: 0)
        // user delta = 10, idle delta = 10 → 50%
        #expect(
            abs(CPUTickSample.busyFraction(from: previous, to: current) - 0.5) < 0.0001
        )
        #expect(current.totalTicks(since: previous) == 20)
    }

    @Test("load-average / cores saturates to 100% on a thread-heavy Mac")
    func loadAverageSaturatesUnlikeTickUtilization() {
        // Observed on a serving M-series Mac: loadavg 30.58, 16 cores, while
        // `top` reported ~42% busy / 58% idle. The old formula clamped to 1.0
        // and the dashboard always showed 100% CPU.
        let loadAverage = 30.58
        let cores = 16.0
        let loadUsage = min(max(loadAverage / cores, 0.0), 1.0)
        #expect(loadUsage == 1.0)

        let tickUsage = CPUTickSample.busyFraction(
            from: CPUTickSample(user: 0, system: 0, idle: 0, nice: 0),
            to: CPUTickSample(user: 2786, system: 1432, idle: 5780, nice: 0)
        )
        #expect(abs(tickUsage - 0.4218) < 0.001)
        #expect(tickUsage < 1.0)
    }

    @Test("host tick samples produce a fraction in [0, 1]")
    func liveHostSampleIsBounded() {
        let first = CPUTickSample.readHost()
        #expect(first != nil)
        Thread.sleep(forTimeInterval: 0.15)
        let second = CPUTickSample.readHost()
        #expect(second != nil)
        let usage = CPUTickSample.busyFraction(from: first!, to: second!)
        #expect(usage >= 0.0 && usage <= 1.0)
    }

    /// The nil-first contract `status`/`doctor` rely on: a fresh sampler has
    /// no window, so its first reading is nil (0.0 on the wire), and two
    /// live readings a short interval apart are finite fractions in [0, 1].
    @Test("first-ever sample reports nil; consecutive live samples are finite in [0, 1]")
    func firstSampleIsNilThenBounded() throws {
        let sampler = CPUTickSampler()
        let anchor = CPUTickSample.readHost()
        let first = sampler.nextUsage()
        #expect(first == nil, "a fresh sampler has no window")

        // ~1,600 aggregate ticks/s on a 16-core box; poll so a descheduled
        // test thread cannot turn a short sleep into a sub-minimum window.
        var second: Double?
        for _ in 0..<40 {
            Thread.sleep(forTimeInterval: 0.05)
            second = sampler.nextUsage()
            if second != nil { break }
        }
        let elapsedTicks = anchor.flatMap { a in CPUTickSample.readHost().map { $0.totalTicks(since: a) } }
        let fraction = try #require(second, "no fraction after 2 s (\(elapsedTicks ?? 0) ticks elapsed)")
        #expect(fraction >= 0.0 && fraction <= 1.0)
        #expect(fraction.isFinite)

        Thread.sleep(forTimeInterval: 0.1)
        let third = try #require(sampler.nextUsage())
        #expect(third >= 0.0 && third <= 1.0)
    }

    /// Two builds back to back (an event heartbeat right after the baseline)
    /// open a degenerate window: the sampler repeats the previous fraction
    /// and keeps its anchor, so the following reading spans the full window.
    @Test("a window shorter than the minimum repeats the last fraction and keeps the anchor")
    func minimumWindowGuard() {
        let sampler = CPUTickSampler()
        let t0 = CPUTickSample(user: 1_000, system: 500, idle: 8_000, nice: 0)
        #expect(sampler.nextUsage(reading: t0) == nil)

        // 5 ticks later: below the minimum window, still no fraction, anchor kept.
        let tiny = CPUTickSample(user: 1_003, system: 501, idle: 8_001, nice: 0)
        #expect(sampler.nextUsage(reading: tiny) == nil)

        // 200 ticks after t0 (not after `tiny`): 100 busy / 200 total = 0.5.
        let t1 = CPUTickSample(user: 1_080, system: 520, idle: 8_100, nice: 0)
        let first = sampler.nextUsage(reading: t1)
        #expect(abs((first ?? -1) - 0.5) < 0.0001)

        // Another degenerate window repeats 0.5 and keeps t1 as the anchor …
        let tiny2 = CPUTickSample(user: 1_082, system: 520, idle: 8_101, nice: 0)
        #expect(abs((sampler.nextUsage(reading: tiny2) ?? -1) - 0.5) < 0.0001)
        // … so the next real window is measured from t1: 40 busy / 200 = 0.2.
        let t2 = CPUTickSample(user: 1_110, system: 530, idle: 8_260, nice: 0)
        #expect(abs((sampler.nextUsage(reading: t2) ?? -1) - 0.2) < 0.0001)

        // A failed host read (nil) reports the last fraction, never 0.
        #expect(abs((sampler.nextUsage(reading: nil) ?? -1) - 0.2) < 0.0001)
        #expect(CPUTickSampler.minimumWindowTicks == 32)
    }

    @Test("collect() keeps the wire shape and range")
    func collectShape() {
        let metrics = SystemMetricsCollector.collect(cpuCores: 16)
        #expect(metrics.memoryPressure >= 0 && metrics.memoryPressure <= 1)
        #expect(metrics.cpuUsage >= 0 && metrics.cpuUsage <= 1)
    }
}
