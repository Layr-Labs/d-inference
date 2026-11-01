import Foundation

/// One counter's value over a sampling window, and whether the counter
/// advanced at all. A counter that never advances is indistinguishable from
/// one the hardware does not drive, so its value is withheld (`CounterLiveness`).
struct CounterReading: Equatable {
    let value: Double
    let moved: Bool
}

enum IOReportMath {
    private static let inactiveStates: Set<String> = ["IDLE", "DOWN", "OFF"]

    static func watts(energy: Int64, unit: String, seconds: Double) -> Double? {
        guard seconds > 0 else { return nil }
        let joulesPerUnit: Double
        switch unit {
        case "mJ": joulesPerUnit = 1e-3
        case "uJ", "µJ": joulesPerUnit = 1e-6
        case "nJ": joulesPerUnit = 1e-9
        case "pJ": joulesPerUnit = 1e-12
        default: return nil
        }
        return Double(max(energy, 0)) * joulesPerUnit / seconds
    }

    /// Residency-weighted mean frequency over active GPU states. GPUPH states
    /// after OFF ("P1"…"P15") index the DVFS table by position. An idle window
    /// reads 0 MHz.
    static func gpuFrequency(_ states: [IOReportState], tableMHz: [Double]) -> CounterReading? {
        guard !states.isEmpty, !tableMHz.isEmpty else { return nil }
        var weighted = 0.0
        var active = 0.0
        for (position, state) in states.filter({ !inactiveStates.contains($0.name) }).enumerated()
        where state.residency > 0 && position < tableMHz.count {
            weighted += tableMHz[position] * Double(state.residency)
            active += Double(state.residency)
        }
        return CounterReading(value: active > 0 ? weighted / active : 0, moved: active > 0)
    }

    /// Residency-weighted bandwidth estimate (GB/s) from a PMP DCS histogram
    /// whose states are labelled with their upper bounds ("32GB/s", "64GB/s", …).
    /// The first bucket is the underflow bin and counts as zero, so the result
    /// is an estimate bounded by the bucket width.
    static func histogramBandwidth(_ states: [IOReportState]) -> CounterReading? {
        guard !states.isEmpty else { return nil }
        var weighted = 0.0
        var total = 0.0
        for (index, state) in states.enumerated() where state.residency > 0 {
            total += Double(state.residency)
            if index > 0 { weighted += bucketLabel(state.name) * Double(state.residency) }
        }
        return CounterReading(value: total > 0 ? weighted / total : 0, moved: total > 0)
    }

    static func bucketLabel(_ name: String) -> Double {
        Double(name.trimmingCharacters(in: .whitespaces).prefix { "0123456789.".contains($0) }) ?? 0
    }
}
