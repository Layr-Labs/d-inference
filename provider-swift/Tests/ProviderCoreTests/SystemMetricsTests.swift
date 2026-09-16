import Testing
@testable import ProviderCore

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

        let mixed = CPUTickSample.busyFraction(
            from: origin,
            to: CPUTickSample(user: 60, system: 25, idle: 70, nice: 1)
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
}
