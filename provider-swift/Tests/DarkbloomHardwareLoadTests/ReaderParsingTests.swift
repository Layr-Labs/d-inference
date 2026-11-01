import Foundation
import Testing

@testable import DarkbloomHardwareLoad

struct ReaderParsingTests {
    @Test func cpuLoadSurvivesTickCounterWraparound() {
        let before = [CPUTicks(busy: UInt32.max - 9, total: UInt32.max - 19)]
        let after = [CPUTicks(busy: 30, total: 80)]
        // busy advanced 40 ticks, total 100.
        #expect(CPULoadSampler.loads(from: before, to: after) == [0.4])
    }

    @Test func cpuLoadNeedsAMatchingBaseline() {
        let ticks = [CPUTicks(busy: 1, total: 2)]
        #expect(CPULoadSampler.loads(from: [], to: ticks) == nil)
        #expect(CPULoadSampler.loads(from: ticks, to: ticks) == [0])
    }

    @Test func memoryUsedMatchesActivityMonitor() {
        let reading = MemorySampler.reading(
            internalPages: 100, purgeablePages: 20, wiredPages: 30, compressedPages: 10,
            pageSize: 16_384, pressureLevel: 2)
        #expect(reading.usedBytes == 120 * 16_384)
        #expect(reading.wiredBytes == 30 * 16_384)
        #expect(reading.pressure == .warn)
        #expect(
            MemorySampler.reading(
                internalPages: 1, purgeablePages: 5, wiredPages: 0, compressedPages: 0,
                pageSize: 1, pressureLevel: 3
            ) == MemoryReading(usedBytes: 0, wiredBytes: 0, pressure: nil))
    }

    @Test func gpuStatisticsUseDeviceUtilization() {
        let statistics = GPUStatistics(performanceStatistics: [
            "Device Utilization %": NSNumber(value: 99), "Renderer Utilization %": NSNumber(value: 12),
            "In use system memory": NSNumber(value: 4_294_967_296),
        ])
        #expect(statistics == GPUStatistics(utilization: 0.99, memoryInUseBytes: 4_294_967_296))
        #expect(GPUStatistics(performanceStatistics: [:]) == GPUStatistics(utilization: nil, memoryInUseBytes: nil))
    }

    @Test func dvfsTablesDecodeHzAndKHz() {
        func table(_ words: [UInt32]) -> Data { words.withUnsafeBytes { Data($0) } }
        #expect(
            GPUFrequencyTable.frequenciesMHz(table([338_000_000, 700, 0, 0, 1_578_000_000, 900]))
                == [338, 1578])
        #expect(GPUFrequencyTable.frequenciesMHz(table([2_592_000, 800])) == [2592])
        #expect(GPUFrequencyTable.frequenciesMHz(Data([1, 2])) == [])
    }

    @Test func gpuCoreGroupsComeFromPartitionMasks() {
        #expect(TopologyProbe.gpuCoreGroups(masks: [1023, 1023, 1023, 1023], cores: 40) == [10, 10, 10, 10])
        #expect(TopologyProbe.gpuCoreGroups(masks: [0b1111_1110, 0b1111_1111], cores: 15) == [7, 8])
        #expect(TopologyProbe.gpuCoreGroups(masks: [1023], cores: 40) == [40])
        #expect(TopologyProbe.gpuCoreGroups(masks: [], cores: nil) == [])
    }

    @Test func anePowerStateAndDutyCycle() {
        #expect(ANEPowerProbe.powered(["CurrentPowerState": NSNumber(value: 1), "MaxPowerState": NSNumber(value: 1)]) == true)
        #expect(ANEPowerProbe.powered(["CurrentPowerState": NSNumber(value: 0)]) == false)
        #expect(ANEPowerProbe.powered([:]) == nil)
        var duty = DutyCycle()
        #expect(duty.drain() == nil)
        [true, true, false, nil, true].forEach { duty.record($0) }
        #expect(duty.drain() == 0.75)
        #expect(duty.drain() == nil)
    }
}
