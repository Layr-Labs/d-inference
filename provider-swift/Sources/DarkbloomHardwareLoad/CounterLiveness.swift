/// Best-effort SoC counters read through IOReport.
public enum SoCCounter: String, Sendable, CaseIterable {
    case gpuPower = "gpu_power"
    case gpuFrequency = "gpu_frequency"
    case memoryBandwidth = "memory_bandwidth"
    case aneBandwidth = "ane_bandwidth"
    case anePower = "ane_power"

    /// Bandwidth comes from bucketed histograms, so it is an estimate.
    var liveStatus: CapabilityStatus {
        switch self {
        case .memoryBandwidth, .aneBandwidth: return .estimated
        case .gpuPower, .gpuFrequency, .anePower: return .measured
        }
    }
}

public enum CapabilityStatus: String, Sendable, Equatable {
    case measured
    case estimated
    /// The channel exists but has not advanced yet, so its values are null.
    case pending
    case unavailable
}

/// Withholds a counter's values until the counter has advanced once.
///
/// Several channels exist on chips that never drive them (they read 0
/// forever), so a 0 is only trustworthy after the counter has been seen moving.
struct CounterLiveness {
    let available: Set<SoCCounter>
    private(set) var live: Set<SoCCounter> = []

    init(available: Set<SoCCounter>) {
        self.available = available
    }

    mutating func gate(_ counter: SoCCounter, _ reading: CounterReading?) -> Double? {
        guard available.contains(counter), let reading else { return nil }
        if reading.moved { live.insert(counter) }
        return live.contains(counter) ? reading.value : nil
    }

    func status(_ counter: SoCCounter) -> CapabilityStatus {
        guard available.contains(counter) else { return .unavailable }
        return live.contains(counter) ? counter.liveStatus : .pending
    }
}
