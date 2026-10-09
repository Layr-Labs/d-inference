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
            pressureLevel: Int(pressure), swapUsedBytes: Int(swap.xsu_used),
            activePages: Int(statistics.active_count), fileBackedPages: Int(statistics.external_page_count),
            anonymousPages: Int(statistics.internal_page_count), wiredPages: Int(statistics.wire_count),
            purgeablePages: Int(statistics.purgeable_count), compressorPages: Int(statistics.compressor_page_count),
            kernelFileCacheMinimumPages: kernelFileCacheMinimumPages())
    }

    /// `vm.vm_page_filecache_min`, in pages. The kernel recomputes it only when
    /// its pageout scan runs, so it can lag; the policy uses it only when it is
    /// larger than the same formula applied to the current snapshot. Nil when
    /// this macOS does not publish it.
    private static func kernelFileCacheMinimumPages() -> Int? {
        var size = 0
        guard sysctlbyname("vm.vm_page_filecache_min", nil, &size, nil, 0) == 0 else { return nil }
        if size == MemoryLayout<UInt32>.size {
            var value: UInt32 = 0
            guard sysctlbyname("vm.vm_page_filecache_min", &value, &size, nil, 0) == 0,
                  size == MemoryLayout<UInt32>.size else { return nil }
            return Int(value)
        }
        if size == MemoryLayout<UInt64>.size {
            var value: UInt64 = 0
            guard sysctlbyname("vm.vm_page_filecache_min", &value, &size, nil, 0) == 0,
                  size == MemoryLayout<UInt64>.size, value <= UInt64(Int.max) else { return nil }
            return Int(value)
        }
        return nil
    }

    static func observeNative() -> QwenDenseStageLoadNativeObservation {
        .init(activeBytes: Memory.activeMemory, cacheBytes: Memory.cacheMemory,
            peakBytes: Memory.peakMemory, allocatorLimitBytes: Memory.memoryLimit)
    }

    static func requireInitial() throws -> QwenDenseStageLoadOSObservation {
        let value = try observeOS()
        _ = try admits(value, bytes: QwenDenseStageLoadPolicy.minimumAdmissibleBytes, for: "Selected-stage loading")
        return value
    }

    /// The question the load, request and diagnostics gates ask about a fresh
    /// sample. A refusal is thrown as the policy's sentence, which names the
    /// requirement, the free pages and the file cache counted. Every decision
    /// is noted in this process's record.
    static func admits(_ os: QwenDenseStageLoadOSObservation, bytes: Int, for purpose: String) throws -> Bool {
        let decision = try QwenDenseStageLoadPolicy.decide(os, requiredBytes: bytes, purpose: purpose,
            now: DispatchTime.now().uptimeNanoseconds)
        QwenDenseStageLoadAdmissionRecord.shared.note(decision)
        if let refusal = decision.refusal { throw ProbeError(refusal) }
        return true
    }
}

/// What this process's host memory gate decided so far: how often, the first
/// decision, the one with the least room, the one taken at the fewest free
/// pages, and whether any admission needed file cache. A record for receipts
/// and operators; nothing reads it to make a decision.
public struct QwenDenseStageLoadAdmissionSummary: Encodable, Sendable {
    public let policy: String
    public let decisions: Int
    public let refusals: Int
    public let reclaimableUsedForAdmission: Bool
    public let first: QwenDenseStageLoadAdmission?
    /// The admitted decision with the smallest admissible minus required.
    public let tightest: QwenDenseStageLoadAdmission?
    public let fewestFreePages: QwenDenseStageLoadAdmission?
    public let lastRefusal: QwenDenseStageLoadAdmission?

    /// The record of the calling process at this moment.
    public static var current: QwenDenseStageLoadAdmissionSummary { QwenDenseStageLoadAdmissionRecord.shared.summary() }
}

final class QwenDenseStageLoadAdmissionRecord: @unchecked Sendable {
    static let shared = QwenDenseStageLoadAdmissionRecord()
    private let lock = NSLock()
    private var decisions = 0, refusals = 0, usedReclaimable = false
    private var first: QwenDenseStageLoadAdmission?, tightest: QwenDenseStageLoadAdmission?
    private var fewestFree: QwenDenseStageLoadAdmission?, lastRefusal: QwenDenseStageLoadAdmission?

    func note(_ decision: QwenDenseStageLoadAdmission) {
        lock.lock(); defer { lock.unlock() }
        decisions += 1
        if first == nil { first = decision }
        if decision.actualFreeBytes < (fewestFree?.actualFreeBytes ?? Int.max) { fewestFree = decision }
        guard decision.admitted else { refusals += 1; lastRefusal = decision; return }
        if decision.reclaimableUsedForAdmission { usedReclaimable = true }
        let room = decision.admissibleBytes - decision.requiredBytes
        if room < tightest.map({ $0.admissibleBytes - $0.requiredBytes }) ?? Int.max { tightest = decision }
    }

    func summary() -> QwenDenseStageLoadAdmissionSummary {
        lock.lock(); defer { lock.unlock() }
        return .init(policy: QwenDenseStageLoadPolicy.identifier, decisions: decisions, refusals: refusals,
            reclaimableUsedForAdmission: usedReclaimable, first: first, tightest: tightest,
            fewestFreePages: fewestFree, lastRefusal: lastRefusal)
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
