import Foundation
import Testing

@testable import DarkbloomHardwareLoad

/// Reads this Mac's real counters. Assertions are structural because CI
/// runners can be virtual machines without an ANE or IOReport channels.
struct LiveHardwareTests {
    @Test func topologyCoversEveryLogicalCPU() {
        let topology = TopologyProbe.read()
        let cpus = topology.cpu.clusters.flatMap(\.cpus).sorted()
        #expect(cpus == Array(0..<ProcessInfo.processInfo.processorCount))
        #expect(topology.cpu.tiers.map(\.cores).reduce(0, +) == cpus.count)
        #expect(topology.memoryTotalBytes == ProcessInfo.processInfo.physicalMemory)
    }

    @Test func engineProducesAWholeMachineSample() async throws {
        let monitor = HardwareLoadMonitor(
            topology: TopologyProbe.read(), engine: ThreadSamplingEngine(providerPID: { nil }),
            grace: .milliseconds(10))
        let sample = try #require(await monitor.currentSample(waitingUpTo: .seconds(3)))
        #expect(sample.cpuLoad.count == ProcessInfo.processInfo.processorCount)
        #expect(sample.cpuLoad.allSatisfy { (0...1).contains($0) })
        #expect(sample.interval > .milliseconds(900) && sample.interval < .milliseconds(1500))
        #expect(sample.providerRunning == false)
        #expect(sample.gpu.providerShare == nil || sample.gpu.providerShare == 0)
        #expect(Set(sample.capabilities.keys) == Set(SoCCounter.allCases.map(\.rawValue) + ["gpu_provider_share"]))
        for counter in SoCCounter.allCases where sample.capabilities[counter.rawValue] != .measured
            && sample.capabilities[counter.rawValue] != .estimated
        {
            #expect(value(of: counter, in: sample) == nil)
        }
    }

    private func value(of counter: SoCCounter, in sample: HardwareSample) -> Double? {
        switch counter {
        case .gpuPower: return sample.gpu.powerW
        case .gpuFrequency: return sample.gpu.frequencyMHz
        case .memoryBandwidth: return sample.memory.bandwidthGBps
        case .aneBandwidth: return sample.ane.bandwidthGBps
        case .anePower: return sample.ane.powerW
        }
    }
}
