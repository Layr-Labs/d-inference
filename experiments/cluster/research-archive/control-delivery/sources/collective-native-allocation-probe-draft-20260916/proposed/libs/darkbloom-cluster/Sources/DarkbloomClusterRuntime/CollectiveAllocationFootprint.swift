#if COLLECTIVE_RECORD_ALLOCATION_CHECK
import Darwin
import Foundation

struct CollectiveAllocationFootprint: Encodable {
    let currentBytes: UInt64
    let lifetimeMaximumBytes: UInt64

    static func read() throws -> Self {
        var value = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), Int32(RUSAGE_INFO_V4), $0)
            }
        }
        guard status == 0, value.ri_phys_footprint > 0,
              value.ri_lifetime_max_phys_footprint >= value.ri_phys_footprint else {
            throw ProbeError("OS lifetime physical high-water is unavailable")
        }
        return .init(currentBytes: value.ri_phys_footprint, lifetimeMaximumBytes: value.ri_lifetime_max_phys_footprint)
    }

    static func systemString(_ name: String) throws -> String {
        var count = 0
        guard sysctlbyname(name, nil, &count, nil, 0) == 0, (1...256).contains(count) else {
            throw ProbeError("Allocation probe system identity unavailable")
        }
        var bytes = [UInt8](repeating: 0, count: count)
        let status = bytes.withUnsafeMutableBytes { sysctlbyname(name, $0.baseAddress, &count, nil, 0) }
        guard status == 0, count == bytes.count, bytes.last == 0,
              let value = String(bytes: bytes.dropLast(), encoding: .utf8), !value.isEmpty else {
            throw ProbeError("Allocation probe system identity malformed")
        }
        return value
    }
}
#endif
