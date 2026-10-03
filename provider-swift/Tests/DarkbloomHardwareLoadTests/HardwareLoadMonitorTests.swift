import Foundation
import Testing

@testable import DarkbloomHardwareLoad

/// Emits a sample every `period` while started, like `ThreadSamplingEngine` at test speed.
final class TickingEngine: HardwareSamplingEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var ticker: Task<Void, Never>?
    private(set) var starts = 0
    private(set) var stops = 0
    let period: Duration

    init(period: Duration = .milliseconds(20)) { self.period = period }

    var counts: (starts: Int, stops: Int) { lock.withLock { (starts, stops) } }

    func start(emit: @escaping @Sendable (HardwareSample) -> Void) {
        lock.withLock {
            guard ticker == nil else { return }
            starts += 1
            let period = period
            ticker = Task {
                var index = 0
                while !Task.isCancelled {
                    try? await Task.sleep(for: period)
                    index += 1
                    emit(HardwareSample(sampledAt: Date(), interval: period, cpuLoad: [Double(index)]))
                }
            }
        }
    }

    func stop() {
        lock.withLock {
            ticker?.cancel()
            ticker = nil
            stops += 1
        }
    }
}

extension HardwareTopology {
    static let fixture = HardwareTopology(
        chip: "Apple M4 Max", model: "Mac16,5",
        cpu: CPUTopologyResolver.resolve(
            levels: [
                PerfLevel(index: 0, name: "Performance", logicalCPUs: 12, cpusPerL2: 6),
                PerfLevel(index: 1, name: "Efficiency", logicalCPUs: 4, cpusPerL2: 4),
            ], nodes: []),
        gpu: HardwareTopology.GPU(cores: 40, groups: [10, 10, 10, 10], maxMHz: 1578),
        anePresent: true, memoryTotalBytes: 128 << 30)
}

struct HardwareLoadMonitorTests {
    @Test func samplingRunsOnlyWhileSubscribedPlusGrace() async throws {
        let engine = TickingEngine()
        let monitor = HardwareLoadMonitor(
            topology: .fixture, engine: engine, grace: .milliseconds(150))
        #expect(await monitor.isSampling == false)

        let reader = Task {
            var seen = 0
            for await _ in await monitor.samples() {
                seen += 1
                if seen == 3 { break }
            }
            return seen
        }
        #expect(await reader.value == 3)
        #expect(engine.counts == (1, 0))

        // Still sampling inside the grace window, stopped after it.
        try await Task.sleep(for: .milliseconds(50))
        #expect(await monitor.isSampling)
        try await Task.sleep(for: .milliseconds(300))
        #expect(await monitor.isSampling == false)
        #expect(engine.counts == (1, 1))
        #expect(await monitor.subscriberCount == 0)
    }

    @Test func resubscribingInsideGraceKeepsTheEngineRunning() async throws {
        let engine = TickingEngine()
        let monitor = HardwareLoadMonitor(
            topology: .fixture, engine: engine, grace: .milliseconds(200))
        for _ in 0..<3 {
            for await _ in await monitor.samples() { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(engine.counts == (1, 0))
        #expect(await monitor.isSampling)
    }

    @Test func eachSubscriberReceivesTheSameSamples() async throws {
        let monitor = HardwareLoadMonitor(topology: .fixture, engine: TickingEngine())
        let first = await monitor.samples()
        let second = await monitor.samples()
        #expect(await monitor.subscriberCount == 2)
        var a = first.makeAsyncIterator()
        var b = second.makeAsyncIterator()
        let x = await a.next()
        let y = await b.next()
        #expect(x != nil && x == y)
    }

    @Test func currentSampleWaitsForTheFirstWindowThenServesTheLatest() async throws {
        let engine = TickingEngine()
        let monitor = HardwareLoadMonitor(topology: .fixture, engine: engine)
        let sample = try #require(await monitor.currentSample(waitingUpTo: .seconds(2)))
        #expect(sample.cpuLoad == [1])
        let again = await monitor.currentSample(waitingUpTo: .seconds(2))
        #expect(again != nil)
        #expect(engine.counts.starts == 1)
    }

    @Test func currentSampleTimesOutWithoutSamples() async {
        let monitor = HardwareLoadMonitor(
            topology: .fixture, engine: TickingEngine(period: .seconds(60)))
        #expect(await monitor.currentSample(waitingUpTo: .milliseconds(50)) == nil)
    }
}
