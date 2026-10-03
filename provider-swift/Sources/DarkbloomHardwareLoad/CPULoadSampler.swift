import Darwin

/// Scheduler tick counters for one logical CPU. They are 32-bit and wrap.
struct CPUTicks: Equatable {
    let busy: UInt32
    let total: UInt32
}

/// Per-logical-CPU busy fraction from `host_processor_info` tick deltas.
final class CPULoadSampler {
    private var previous: [CPUTicks] = []

    /// Busy fraction (0…1) per logical CPU since the previous call; nil on the
    /// first call and whenever the CPU count changes.
    func sample() -> [Double]? {
        guard let current = Self.readTicks() else { return nil }
        defer { previous = current }
        return Self.loads(from: previous, to: current)
    }

    static func loads(from previous: [CPUTicks], to current: [CPUTicks]) -> [Double]? {
        guard !current.isEmpty, previous.count == current.count else { return nil }
        return zip(previous, current).map { before, now in
            let total = now.total &- before.total
            guard total > 0 else { return 0 }
            return min(1, Double(now.busy &- before.busy) / Double(total))
        }
    }

    private static func readTicks() -> [CPUTicks]? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard
            host_processor_info(
                mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
            let info
        else { return nil }
        defer {
            vm_deallocate(
                mach_task_self_, vm_address_t(bitPattern: info),
                vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }
        let states = Int(CPU_STATE_MAX)
        return (0..<Int(cpuCount)).map { cpu in
            func ticks(_ state: Int32) -> UInt32 {
                UInt32(bitPattern: info[cpu * states + Int(state)])
            }
            let busy = ticks(CPU_STATE_USER) &+ ticks(CPU_STATE_SYSTEM) &+ ticks(CPU_STATE_NICE)
            return CPUTicks(busy: busy, total: busy &+ ticks(CPU_STATE_IDLE))
        }
    }
}
