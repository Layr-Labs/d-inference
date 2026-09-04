import Foundation
import Darwin

public enum SystemMetricsCollector: Sendable {

    /// One heartbeat's system metrics.
    ///
    /// SINGLE CALLER BY TIME: `cpuUsage` is a delta between this call's
    /// `HOST_CPU_LOAD_INFO` ticks and the previous call's (a process-wide
    /// sampler), so every `collect()` consumes the window the previous one
    /// opened. The only production caller is `buildHeartbeatJSON`; anything
    /// else that needs the figure (`status`/`doctor` via the daemon-state
    /// file) must read the stored `ProviderState.lastSystemMetrics`, never
    /// call this again. `cpuCores` is kept for source compatibility; the tick
    /// fraction is already normalized across cores.
    public static func collect(cpuCores _: UInt32) -> SystemMetrics {
        SystemMetrics(
            memoryPressure: collectMemoryPressure() ?? 0.0,
            cpuUsage: cpuTickSampler.nextUsage() ?? 0.0,
            thermalState: mapThermalState(ProcessInfo.processInfo.thermalState)
        )
    }
}

// MARK: - Host port

/// `mach_host_self()` returns a new send right on every call and the old
/// code never deallocated it — one leaked uref per heartbeat and per
/// availability probe, for the life of the daemon. The host port is
/// process-constant; take it once.
private let cachedHostPort: mach_port_t = mach_host_self()

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
                cachedHostPort,
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
                    cachedHostPort,
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

    /// Total ticks elapsed since `previous`, wrapping-safe (the kernel's
    /// counters are UInt32 and roll over).
    func totalTicks(since previous: CPUTickSample) -> UInt64 {
        UInt64(user &- previous.user) + UInt64(system &- previous.system)
            + UInt64(idle &- previous.idle) + UInt64(nice &- previous.nice)
    }

    /// Busy fraction in [0, 1] from a pair of cumulative tick samples.
    ///
    /// Load average / core count is **not** CPU utilization: macOS load
    /// counts runnable + uninterruptible threads, which Metal/MLX work,
    /// model loads (parallel weight hashing + compile) and prefix-cache
    /// sweeps inflate far past core count and which decays over ~60 s. That
    /// saturated the old `min(loadavg[0] / cores, 1)` at 100 % even when
    /// `top` showed the CPU mostly idle — and the coordinator charges
    /// cpu_usage × 1500 ms of routing cost and −100 × in the warm-pool score.
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

/// Stateful delta sampler: each reading is the busy fraction over the window
/// since the previous reading. The window is however far apart the heartbeat
/// builds are — 5 s for the baseline, as little as 500 ms when event
/// heartbeats fire (they reuse the same builder, rate-capped at 2/s) — so it
/// is 0.5–5 s in practice, hundreds of ticks on a 16-core box at 100 Hz.
///
/// The first reading after process start has no window and returns nil
/// (reported as 0.0). A window shorter than `minimumWindowTicks` — two
/// builds back to back — is not a meaningful fraction: the previous fraction
/// is reported again and the anchor is KEPT, so the next reading spans a
/// longer window instead of a degenerate one.
final class CPUTickSampler: @unchecked Sendable {
    /// ≈ 20 ms of aggregate ticks on 16 cores at 100 Hz.
    static let minimumWindowTicks: UInt64 = 32

    private let lock = NSLock()
    private var previous: CPUTickSample?
    private var lastFraction: Double?

    init() {}

    /// Advance the sampler with `reading` (the live host counters by
    /// default; injectable for tests) and return the busy fraction, or nil
    /// when no fraction can be reported yet.
    func nextUsage(reading: CPUTickSample? = CPUTickSample.readHost()) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        guard let current = reading else { return lastFraction }
        guard let previous else {
            self.previous = current
            return nil
        }
        guard current.totalTicks(since: previous) >= Self.minimumWindowTicks else {
            return lastFraction
        }
        let fraction = CPUTickSample.busyFraction(from: previous, to: current)
        self.previous = current
        lastFraction = fraction
        return fraction
    }
}

/// Process-wide: the delta is only meaningful with one consumer (see
/// `SystemMetricsCollector.collect`).
private let cpuTickSampler = CPUTickSampler()
