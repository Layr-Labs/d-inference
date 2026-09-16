import Foundation
import Darwin

public enum SystemMetricsCollector: Sendable {

    public static func collect(cpuCores _: UInt32) -> SystemMetrics {
        SystemMetrics(
            memoryPressure: collectMemoryPressure() ?? 0.0,
            cpuUsage: collectCPUUsage() ?? 0.0,
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

/// Cumulative `HOST_CPU_LOAD_INFO` ticks. `cpu_ticks` is indexed by
/// `CPU_STATE_USER/SYSTEM/IDLE/NICE` (0...3).
struct CPUTickSample: Equatable, Sendable {
    var user: UInt32
    var system: UInt32
    var idle: UInt32
    var nice: UInt32

    static func readHost() -> CPUTickSample? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics(
                    mach_host_self(),
                    HOST_CPU_LOAD_INFO,
                    intPtr,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return CPUTickSample(
            user: info.cpu_ticks.0,
            system: info.cpu_ticks.1,
            idle: info.cpu_ticks.2,
            nice: info.cpu_ticks.3
        )
    }

    /// Busy fraction in [0, 1] from a pair of cumulative tick samples.
    ///
    /// Load average / core count is **not** CPU utilization: macOS load
    /// counts runnable + uninterruptible threads, which Metal/MLX work
    /// inflates far past core count. That saturates the old 0...1 clamp at
    /// 100% even when `top` shows the CPU mostly idle.
    static func busyFraction(from previous: CPUTickSample, to current: CPUTickSample) -> Double {
        let user = UInt64(current.user &- previous.user)
        let system = UInt64(current.system &- previous.system)
        let idle = UInt64(current.idle &- previous.idle)
        let nice = UInt64(current.nice &- previous.nice)
        let total = user + system + idle + nice
        guard total > 0 else { return 0.0 }
        let busy = user + system + nice
        return min(max(Double(busy) / Double(total), 0.0), 1.0)
    }
}

/// Heartbeats are 5s apart, so a previous sample is almost always available.
/// The first reading after process start returns nil (reported as 0.0).
private final class CPUTickSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var previous: CPUTickSample?

    func nextUsage() -> Double? {
        guard let current = CPUTickSample.readHost() else { return nil }
        lock.lock()
        let previous = self.previous
        self.previous = current
        lock.unlock()
        guard let previous else { return nil }
        return CPUTickSample.busyFraction(from: previous, to: current)
    }
}

private let cpuTickSampler = CPUTickSampler()

private func collectCPUUsage() -> Double? {
    cpuTickSampler.nextUsage()
}
