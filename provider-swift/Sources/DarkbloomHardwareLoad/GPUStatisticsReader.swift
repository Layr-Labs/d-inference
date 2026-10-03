import Foundation
import IOKit

struct GPUStatistics: Equatable {
    /// "Device Utilization %" as 0…1. The driver can report 0 under very light load.
    let utilization: Double?
    let memoryInUseBytes: UInt64?

    init(utilization: Double?, memoryInUseBytes: UInt64?) {
        self.utilization = utilization
        self.memoryInUseBytes = memoryInUseBytes
    }

    init(performanceStatistics: [String: Any]) {
        let percent = (performanceStatistics["Device Utilization %"] as? NSNumber)?.doubleValue
        utilization = percent.map { min(max($0 / 100, 0), 1) }
        memoryInUseBytes = (performanceStatistics["In use system memory"] as? NSNumber)?.uint64Value
    }
}

/// The GPU driver's own counters (`IOAccelerator` → `PerformanceStatistics`).
final class GPUStatisticsReader {
    private let accelerator: io_service_t

    init?() {
        guard let service = RegistryProperty.matchingService("IOAccelerator") else { return nil }
        accelerator = service
    }

    deinit { IOObjectRelease(accelerator) }

    /// Reads only `PerformanceStatistics`; copying the accelerator's whole
    /// property table costs roughly 17× more.
    func read() -> GPUStatistics? {
        (RegistryProperty.value(accelerator, "PerformanceStatistics") as? [String: Any])
            .map(GPUStatistics.init(performanceStatistics:))
    }
}
