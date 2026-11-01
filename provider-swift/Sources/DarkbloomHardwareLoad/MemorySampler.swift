import Darwin

public enum MemoryPressure: String, Sendable, Equatable {
    case normal
    case warn
    case critical

    /// `kern.memorystatus_vm_pressure_level`: 1 normal, 2 warn, 4 critical.
    init?(level: Int) {
        switch level {
        case 1: self = .normal
        case 2: self = .warn
        case 4: self = .critical
        default: return nil
        }
    }
}

struct MemoryReading: Equatable {
    /// Activity Monitor "Memory Used": app (internal − purgeable) + wired + compressed.
    let usedBytes: UInt64
    let wiredBytes: UInt64
    let pressure: MemoryPressure?
}

enum MemorySampler {
    static func read() -> MemoryReading? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        var pageSize: vm_size_t = 0
        guard result == KERN_SUCCESS, host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS
        else { return nil }
        return reading(
            internalPages: UInt64(stats.internal_page_count),
            purgeablePages: UInt64(stats.purgeable_count), wiredPages: UInt64(stats.wire_count),
            compressedPages: UInt64(stats.compressor_page_count),
            pageSize: UInt64(pageSize),
            pressureLevel: SystemControl.integer("kern.memorystatus_vm_pressure_level"))
    }

    static func reading(
        internalPages: UInt64, purgeablePages: UInt64, wiredPages: UInt64, compressedPages: UInt64,
        pageSize: UInt64, pressureLevel: Int?
    ) -> MemoryReading {
        let app = internalPages > purgeablePages ? internalPages - purgeablePages : 0
        return MemoryReading(
            usedBytes: (app + wiredPages + compressedPages) * pageSize,
            wiredBytes: wiredPages * pageSize,
            pressure: pressureLevel.flatMap(MemoryPressure.init(level:)))
    }
}
