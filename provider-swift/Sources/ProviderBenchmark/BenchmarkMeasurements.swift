import Foundation

/// Shared conversions for benchmark measurements.
enum BenchmarkMeasurements {
    /// Convert the complete quotient/remainder `Duration`, not only its
    /// sub-second attoseconds component.
    static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000
            + Double(duration.components.attoseconds) / 1e15
    }
}
