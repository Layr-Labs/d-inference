import Darwin
import Foundation

/// Combines every reader into one sample per window. Owns IOKit and IOReport
/// handles that are not thread-safe, so an instance stays on one thread.
final class HardwareSampler {
    private let cpu = CPULoadSampler()
    private let gpu = GPUStatisticsReader()
    private let ane = ANEPowerProbe()
    private let soc: SoCCounters
    private var liveness: CounterLiveness
    private var share = ProviderGPUShare()
    private var aneDuty = DutyCycle()
    private var windowStart = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    private let providerPID: @Sendable () -> Int32?

    /// Takes the baseline every delta-based reader needs.
    init(providerPID: @escaping @Sendable () -> Int32?) {
        self.providerPID = providerPID
        soc = SoCCounters(gpuTableMHz: GPUFrequencyTable.read())
        liveness = CounterLiveness(available: soc.available)
        _ = cpu.sample()
        _ = soc.read()
        if let clients = GPUClientScanner.scan() {
            _ = share.update(clients: clients, providerPID: providerPID())
        }
        windowStart = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }

    func pollANE() {
        aneDuty.record(ane?.isPowered())
    }

    func sample() -> HardwareSample {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        defer { windowStart = now }
        let pid = providerPID()
        let statistics = gpu?.read()
        let memory = MemorySampler.read()
        let counters = soc.read()
        let clients = GPUClientScanner.scan()
        var sample = HardwareSample(
            sampledAt: Date(),
            interval: .nanoseconds(Int64(now - windowStart)),
            cpuLoad: cpu.sample() ?? [],
            gpu: HardwareSample.GPU(
                utilization: statistics?.utilization,
                frequencyMHz: liveness.gate(.gpuFrequency, counters[.gpuFrequency]),
                powerW: liveness.gate(.gpuPower, counters[.gpuPower]),
                providerShare: clients.flatMap { share.update(clients: $0, providerPID: pid) },
                memoryInUseBytes: statistics?.memoryInUseBytes),
            ane: HardwareSample.ANE(
                active: aneDuty.drain(),
                bandwidthGBps: liveness.gate(.aneBandwidth, counters[.aneBandwidth]),
                powerW: liveness.gate(.anePower, counters[.anePower])),
            memory: HardwareSample.Memory(
                usedBytes: memory?.usedBytes, wiredBytes: memory?.wiredBytes,
                pressure: memory?.pressure,
                bandwidthGBps: liveness.gate(.memoryBandwidth, counters[.memoryBandwidth])),
            thermal: ThermalState(ProcessInfo.processInfo.thermalState),
            providerRunning: pid != nil)
        sample.capabilities = capabilities(providerShareReadable: clients != nil)
        return sample
    }

    private func capabilities(providerShareReadable: Bool) -> [String: CapabilityStatus] {
        var result = Dictionary(
            uniqueKeysWithValues: SoCCounter.allCases.map { ($0.rawValue, liveness.status($0)) })
        result["gpu_provider_share"] = providerShareReadable ? .measured : .unavailable
        return result
    }
}
