import Foundation

/// The IOReport channels behind `SoCCounter`, one subscription per group so a
/// group the kernel refuses cannot take the others down. Not thread-safe; the
/// PMP read blocks on the power-management coprocessor for several
/// milliseconds, so this runs only on the sampling thread.
final class SoCCounters {
    let available: Set<SoCCounter>
    private let gpuStates: IOReportSubscription?
    private let energy: IOReportSubscription?
    private let fabric: IOReportSubscription?
    private let gpuTableMHz: [Double]

    init(library: IOReportLibrary? = .shared, gpuTableMHz: [Double]) {
        self.gpuTableMHz = gpuTableMHz
        guard let library else {
            available = []
            gpuStates = nil
            energy = nil
            fabric = nil
            return
        }
        func subscribe(
            _ group: String, _ subgroup: String?, _ include: (String) -> Bool
        ) -> (IOReportSubscription, Set<String>)? {
            var names: Set<String> = []
            guard
                let channels = library.channels(
                    group: group, subgroup: subgroup,
                    include: { channel in
                        guard include(channel.name) else { return false }
                        names.insert(channel.name)
                        return true
                    }),
                let subscription = IOReportSubscription(library: library, channels: channels)
            else { return nil }
            return (subscription, names)
        }
        let states = subscribe("GPU Stats", "GPU Performance States") { $0 == "GPUPH" }
        let energy = subscribe("Energy Model", nil) { $0 == "GPU Energy" || $0.hasPrefix("ANE") }
        let fabric = subscribe("PMP", "DCS BW") { $0 == "AMCC RD+WR" || Self.isANELane($0) }
        var available: Set<SoCCounter> = []
        if states != nil, !gpuTableMHz.isEmpty { available.insert(.gpuFrequency) }
        if energy?.1.contains("GPU Energy") == true { available.insert(.gpuPower) }
        if energy?.1.contains(where: { $0.hasPrefix("ANE") }) == true { available.insert(.anePower) }
        if fabric?.1.contains("AMCC RD+WR") == true { available.insert(.memoryBandwidth) }
        if fabric?.1.contains(where: Self.isANELane) == true { available.insert(.aneBandwidth) }
        self.available = available
        gpuStates = states?.0
        self.energy = energy?.0
        self.fabric = fabric?.0
    }

    /// ANE fabric lanes ("ANE0 L0 RD+WR", "ANE0 L1 RD+WR") tick only while the ANE is powered.
    private static func isANELane(_ name: String) -> Bool {
        name.hasPrefix("ANE") && name.hasSuffix("RD+WR")
    }

    /// Readings since the previous call; empty on the first call.
    func read() -> [SoCCounter: CounterReading] {
        var readings: [SoCCounter: CounterReading] = [:]
        _ = gpuStates?.nextDelta { channel in
            guard channel.name == "GPUPH" else { return }
            readings[.gpuFrequency] = IOReportMath.gpuFrequency(
                channel.states, tableMHz: gpuTableMHz)
        }
        var gpuEnergy: [(Int64, String)] = []
        var aneEnergy: [(Int64, String)] = []
        if let seconds = energy?.nextDelta({ channel in
            guard let value = channel.simpleValue else { return }
            if channel.name == "GPU Energy" { gpuEnergy.append((value, channel.unit)) }
            if channel.name.hasPrefix("ANE") { aneEnergy.append((value, channel.unit)) }
        }) {
            readings[.gpuPower] = Self.power(gpuEnergy, seconds: seconds)
            readings[.anePower] = Self.power(aneEnergy, seconds: seconds)
        }
        var lanes: [CounterReading] = []
        _ = fabric?.nextDelta { channel in
            if channel.name == "AMCC RD+WR" {
                readings[.memoryBandwidth] = IOReportMath.histogramBandwidth(channel.states)
            } else if Self.isANELane(channel.name),
                let lane = IOReportMath.histogramBandwidth(channel.states)
            {
                lanes.append(lane)
            }
        }
        if !lanes.isEmpty {
            readings[.aneBandwidth] = CounterReading(
                value: lanes.map(\.value).reduce(0, +), moved: lanes.contains(where: \.moved))
        }
        return readings
    }

    private static func power(_ energies: [(Int64, String)], seconds: Double) -> CounterReading? {
        let watts = energies.compactMap { IOReportMath.watts(energy: $0.0, unit: $0.1, seconds: seconds) }
        guard !watts.isEmpty else { return nil }
        return CounterReading(value: watts.reduce(0, +), moved: energies.contains { $0.0 > 0 })
    }
}
