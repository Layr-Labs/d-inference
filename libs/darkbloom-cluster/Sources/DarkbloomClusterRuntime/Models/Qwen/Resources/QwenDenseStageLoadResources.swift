import Darwin
import Foundation
import MLX

/// Direct local observations only: no subprocess, supplied receipt or permissive
/// parse fallback. A Mach host right is released before returning a snapshot.
enum QwenDenseStageLoadResources {
    static func observeOS() throws -> QwenDenseStageLoadOSObservation {
        let start = DispatchTime.now().uptimeNanoseconds
        let host = mach_host_self()
        var pageSize: vm_size_t = 0
        var statistics = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let expectedCount = count
        let pageStatus = host_page_size(host, &pageSize)
        let status = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(expectedCount)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        let released = mach_port_deallocate(mach_task_self_, host)
        guard pageStatus == KERN_SUCCESS, status == KERN_SUCCESS, released == KERN_SUCCESS,
              count == expectedCount, pageSize > 0, pageSize <= UInt(Int.max) else {
            throw ProbeError("Cannot observe current selected-stage VM counters")
        }
        var pressure: Int32 = -1
        var pressureSize = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &pressureSize, nil, 0) == 0,
              pressureSize == MemoryLayout<Int32>.size else {
            throw ProbeError("Cannot observe current selected-stage memory pressure")
        }
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0,
              swapSize == MemoryLayout<xsw_usage>.size, swap.xsu_used <= UInt64(Int.max) else {
            throw ProbeError("Cannot observe current selected-stage swap")
        }
        let physical = ProcessInfo.processInfo.physicalMemory
        guard physical <= UInt64(Int.max), statistics.free_count >= statistics.speculative_count else {
            throw ProbeError("Invalid selected-stage physical/free-page accounting")
        }
        // Darwin vm_statistics64: speculative pages are included in free_count.
        // Exclude them from actual free; include them once in diagnostic reclaimable.
        let rawFree = Int(statistics.free_count), speculative = Int(statistics.speculative_count)
        let free = rawFree - speculative, inactive = Int(statistics.inactive_count), page = Int(pageSize)
        let freeBytes = try QwenLongPrefillCheckedBytes.product([free, page])
        let reclaimablePages = try QwenLongPrefillCheckedBytes.sum([free, inactive, speculative])
        let reclaimable = try QwenLongPrefillCheckedBytes.product([reclaimablePages, page])
        return .init(startedNanoseconds: start, completedNanoseconds: DispatchTime.now().uptimeNanoseconds,
            timestampUTC: ResourceObservationTimestamp.utc(), physicalMemoryBytes: Int(physical),
            pageSizeBytes: page, kernelFreePages: rawFree, freePages: free, inactivePages: inactive,
            speculativePages: speculative, actualFreeBytes: freeBytes, estimatedReclaimableBytes: reclaimable,
            pressureLevel: Int(pressure), swapUsedBytes: Int(swap.xsu_used))
    }

    static func observeNative() -> QwenDenseStageLoadNativeObservation {
        .init(activeBytes: Memory.activeMemory, cacheBytes: Memory.cacheMemory,
            peakBytes: Memory.peakMemory, allocatorLimitBytes: Memory.memoryLimit)
    }

    static func requireInitial() throws -> QwenDenseStageLoadOSObservation {
        let value = try observeOS()
        try QwenDenseStageLoadPolicy.requireInitial(value, now: DispatchTime.now().uptimeNanoseconds)
        return value
    }
}

struct QwenDenseStageLoadRuntimeObservation: Encodable {
    let executableName: String?, mainBundleName: String, bundleIdentifier: String?
    let executablePath: String?, mainBundlePath: String, mainBundleResourcePath: String?
    let processID: Int32, operatingSystemVersion: String
    let deviceArchitecture: String, deviceMemoryBytes: Int, maximumBufferBytes: Int
    let recommendedWorkingSetBytes: UInt64
    let binaryOrBundleHashVerifiedByNative = false, providerEligibilityEstablished = false
    let recommendedWorkingSetUsedForAdmission = false

    init() {
        let device = GPU.deviceInfo()
        executableName = Bundle.main.executableURL?.lastPathComponent
        mainBundleName = Bundle.main.bundleURL.lastPathComponent; bundleIdentifier = Bundle.main.bundleIdentifier
        executablePath = Bundle.main.executableURL?.path; mainBundlePath = Bundle.main.bundleURL.path
        mainBundleResourcePath = Bundle.main.resourceURL?.path
        processID = ProcessInfo.processInfo.processIdentifier
        operatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersionString
        deviceArchitecture = device.architecture; deviceMemoryBytes = device.memorySize
        maximumBufferBytes = device.maxBufferSize; recommendedWorkingSetBytes = device.maxRecommendedWorkingSetSize
    }
}
