import Foundation
import Darwin

public enum SystemMetricsCollector: Sendable {

    public static func collect(cpuCores: UInt32) -> SystemMetrics {
        SystemMetrics(
            memoryPressure: collectMemoryPressure() ?? 0.0,
            cpuUsage: collectCPUUsage(cpuCores: cpuCores) ?? 0.0,
            thermalState: mapThermalState(ProcessInfo.processInfo.thermalState)
        )
    }
}

// MARK: - Thermal State Mapping

private func mapThermalState(_ state: ProcessInfo.ThermalState) -> ThermalState {
    switch state {
    case .nominal:  return .nominal
    case .fair:     return .fair
    case .serious:  return .serious
    case .critical: return .critical
    @unknown default: return .nominal
    }
}

// MARK: - Memory Pressure

// pressure = (active + wired + compressed) / (active + wired + compressed + inactive + speculative + free)
private func collectMemoryPressure() -> Double? {
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(
        MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size
    )

    let result = withUnsafeMutablePointer(to: &stats) { ptr in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
            host_statistics64(
                mach_host_self(),
                HOST_VM_INFO64,
                intPtr,
                &count
            )
        }
    }

    guard result == KERN_SUCCESS else { return nil }

    let active = UInt64(stats.active_count)
    let wired = UInt64(stats.wire_count)
    let compressed = UInt64(stats.compressor_page_count)
    let inactive = UInt64(stats.inactive_count)
    let speculative = UInt64(stats.speculative_count)
    let free = UInt64(stats.free_count)

    let used = active + wired + compressed
    let total = used + inactive + speculative + free

    guard total > 0 else { return 0.0 }
    return min(max(Double(used) / Double(total), 0.0), 1.0)
}

// MARK: - CPU Usage

// 1-minute load average normalized by core count.
private func collectCPUUsage(cpuCores: UInt32) -> Double? {
    var loadavg = [Double](repeating: 0.0, count: 3)
    guard getloadavg(&loadavg, 3) != -1 else { return nil }

    let cores = cpuCores > 0 ? Double(cpuCores) : 1.0
    return min(max(loadavg[0] / cores, 0.0), 1.0)
}
