import Darwin
import Foundation
import MLX

struct LabRecordFootprint: Codable {
    let currentBytes: UInt64, lifetimeMaximumBytes: UInt64
    static func read() throws -> Self {
        var value = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), Int32(RUSAGE_INFO_V4), $0)
            }
        }
        guard status == 0, value.ri_phys_footprint > 0,
              value.ri_lifetime_max_phys_footprint >= value.ri_phys_footprint else { throw ProbeError("Lab process footprint unavailable") }
        return .init(currentBytes: value.ri_phys_footprint, lifetimeMaximumBytes: value.ri_lifetime_max_phys_footprint)
    }
    static func system(_ name: String) throws -> String {
        var count = 0
        guard sysctlbyname(name, nil, &count, nil, 0) == 0, (1...256).contains(count) else { throw ProbeError("Lab system identity unavailable") }
        var bytes = [UInt8](repeating: 0, count: count)
        guard bytes.withUnsafeMutableBytes({ sysctlbyname(name, $0.baseAddress, &count, nil, 0) }) == 0,
              bytes.last == 0, let result = String(bytes: bytes.dropLast(), encoding: .utf8) else { throw ProbeError("Lab system identity malformed") }
        return result
    }
}

final class LabRecordResources {
    static let nativeAllowance = 256 * 1_048_576
    static let hostAllowance = 512 * 1_048_576
    static let minimumFree = 6 * 1_073_741_824
    let baselineNative: Int, baselinePhysical: LabRecordFootprint, deadline: UInt64
    private(set) var minimumObservedFree = Int.max, maximumObservedNative = 0, observations = 0
    private var nextObservation: UInt64 = 0
    init(job: LabRecordJob) throws {
        guard try LabRecordFootprint.system("hw.model") == job.expectedHardware[job.rank],
              try LabRecordFootprint.system("kern.osversion") == job.expectedOSBuild[job.rank] else { throw ProbeError("Lab actual hardware/OS differs") }
        baselineNative = Memory.activeMemory; baselinePhysical = try .read()
        let (end, overflow) = DispatchTime.now().uptimeNanoseconds.addingReportingOverflow(115_000_000_000)
        guard !overflow else { throw ProbeError("Lab deadline overflow") }; deadline = end
        try check()
    }
    func check() throws {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline, Memory.cacheMemory == 0,
              Memory.activeMemory <= baselineNative + Self.nativeAllowance,
              Memory.peakMemory <= baselineNative + Self.nativeAllowance,
              Memory.memoryLimit >= baselineNative + Self.nativeAllowance else { throw ProbeError("Lab native/cache/lifetime ceiling refused") }
        maximumObservedNative = max(maximumObservedNative, Memory.activeMemory)
        if now >= nextObservation {
            try QwenResidentResourceEnvironment.require()
            let os = try QwenDenseStageLoadResources.requireInitial(), footprint = try LabRecordFootprint.read()
            // Full process allowance is retained, never replaced with a sampled
            // current heap or used as a new serving profile.
            guard os.pressureLevel == 1, os.actualFreeBytes >= Self.minimumFree + Self.hostAllowance,
                  footprint.lifetimeMaximumBytes <= baselinePhysical.currentBytes + UInt64(Self.hostAllowance) else {
                throw ProbeError("Lab actual-free/pressure/process high-water ceiling refused")
            }
            minimumObservedFree = min(minimumObservedFree, os.actualFreeBytes); observations += 1
            nextObservation = now + 100_000_000
        }
    }
    func finalCheck() throws { nextObservation = 0; try check() }
}
