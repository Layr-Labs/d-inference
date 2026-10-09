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
        guard statistics.compressions <= UInt64(Int.max), statistics.swapouts <= UInt64(Int.max),
              statistics.inactive_external_count <= UInt64(Int.max),
              statistics.inactive_internal_count <= UInt64(Int.max) else {
            throw ProbeError("Invalid selected-stage compression, swap or inactive counters")
        }
        // Every read is done before the completion time is taken. The two
        // sysctl reads are current; the statistics above may be the kernel's
        // cached copy (see `liveCompressionPages`).
        let kernelMinimum = kernelCounter("vm.vm_page_filecache_min")
        let liveCompressions = kernelCounter("vm.pageout_inactive_dirty_internal")
        return .init(startedNanoseconds: start, completedNanoseconds: DispatchTime.now().uptimeNanoseconds,
            timestampUTC: ResourceObservationTimestamp.utc(), physicalMemoryBytes: Int(physical),
            pageSizeBytes: page, kernelFreePages: rawFree, freePages: free, inactivePages: inactive,
            speculativePages: speculative, actualFreeBytes: freeBytes, estimatedReclaimableBytes: reclaimable,
            pressureLevel: Int(pressure), swapUsedBytes: Int(swap.xsu_used),
            activePages: Int(statistics.active_count), fileBackedPages: Int(statistics.external_page_count),
            anonymousPages: Int(statistics.internal_page_count), wiredPages: Int(statistics.wire_count),
            purgeablePages: Int(statistics.purgeable_count), compressorPages: Int(statistics.compressor_page_count),
            kernelFileCacheMinimumPages: kernelMinimum,
            inactiveFileBackedPages: Int(statistics.inactive_external_count),
            inactiveAnonymousPages: Int(statistics.inactive_internal_count),
            compressionPages: Int(statistics.compressions), swapoutPages: Int(statistics.swapouts),
            liveCompressionPages: liveCompressions)
    }

    /// One of the kernel's page counters by sysctl, 32 or 64 bits wide; nil when
    /// this macOS does not publish it. `vm.vm_page_filecache_min` is recomputed
    /// only when the pageout scan runs, so it can lag; the policy uses it only
    /// when it is larger than the same formula applied to the current snapshot.
    static func kernelCounter(_ name: String) -> Int? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0 else { return nil }
        if size == MemoryLayout<UInt32>.size {
            var value: UInt32 = 0
            guard sysctlbyname(name, &value, &size, nil, 0) == 0,
                  size == MemoryLayout<UInt32>.size else { return nil }
            return Int(value)
        }
        if size == MemoryLayout<UInt64>.size {
            var value: UInt64 = 0
            guard sysctlbyname(name, &value, &size, nil, 0) == 0,
                  size == MemoryLayout<UInt64>.size, value <= UInt64(Int.max) else { return nil }
            return Int(value)
        }
        return nil
    }

    static func observeNative() -> QwenDenseStageLoadNativeObservation {
        .init(activeBytes: Memory.activeMemory, cacheBytes: Memory.cacheMemory,
            peakBytes: Memory.peakMemory, allocatorLimitBytes: Memory.memoryLimit)
    }

    /// The entry check: a fresh sample and the 6 GiB floor on admissible
    /// memory. It belongs to no load or request, so it is judged without a
    /// first sample and counted apart from their decisions.
    static func requireInitial() throws -> QwenDenseStageLoadOSObservation {
        let value = try observeOS()
        _ = try QwenDenseStageLoadWatch.entry.admits(value, bytes: QwenDenseStageLoadPolicy.minimumAdmissibleBytes)
        return value
    }
}

/// One load or one request as the host memory gate sees it. It keeps the
/// first sample's compression and swap-out counters, takes the policy's
/// decision on every later sample against them, and keeps a record of those
/// decisions. Each of the three gates owns one.
final class QwenDenseStageLoadWatch: @unchecked Sendable {
    /// Entry checks: no first sample, not listed among loads and requests.
    static let entry = QwenDenseStageLoadWatch("Selected-stage loading", comparesWithFirstSample: false, list: nil)

    let purpose: String
    private let comparesWithFirstSample: Bool
    private let list: QwenDenseStageLoadWatchList?
    private let lock = NSLock()
    private var registered = false
    private var baseline: QwenDenseStageLoadBaseline?
    private var decisions = 0, refusals = 0, unjudged = 0, usedReclaimable = false, stopped = false
    private var lastUnjudged: String?
    private var first: QwenDenseStageLoadAdmission?, tightest: QwenDenseStageLoadAdmission?
    private var fewestFree: QwenDenseStageLoadAdmission?, lastRefusal: QwenDenseStageLoadAdmission?
    private var latest: QwenDenseStageLoadAdmission?

    /// `list` is where this watch appears once it has taken a decision.
    init(_ purpose: String, comparesWithFirstSample: Bool = true, list: QwenDenseStageLoadWatchList? = .shared) {
        self.purpose = purpose; self.comparesWithFirstSample = comparesWithFirstSample; self.list = list
    }

    /// One gate pass: the policy's decision on a fresh sample. A refusal is
    /// thrown as the policy's sentence. A sample that cannot be judged
    /// (critical pressure, swap under pressure, stale or implausible
    /// counters) is thrown too, and noted.
    func admits(_ os: QwenDenseStageLoadOSObservation, bytes: Int,
                now: UInt64 = DispatchTime.now().uptimeNanoseconds) throws -> Bool {
        lock.lock()
        let register = !registered
        registered = true
        lock.unlock()
        if register { list?.add(self) }
        lock.lock(); defer { lock.unlock() }
        let since = comparesWithFirstSample ? (baseline ?? .init(os)) : nil
        let decision: QwenDenseStageLoadAdmission
        do {
            decision = try QwenDenseStageLoadPolicy.decide(os, requiredBytes: bytes, purpose: purpose,
                now: now, since: since)
        } catch {
            unjudged += 1; lastUnjudged = String(describing: error)
            throw error
        }
        if baseline == nil { baseline = since }
        decisions += 1; latest = decision
        if first == nil { first = decision }
        if decision.actualFreeBytes < (fewestFree?.actualFreeBytes ?? Int.max) { fewestFree = decision }
        guard decision.admitted else {
            refusals += 1; lastRefusal = decision
            if decision.stoppedByCompressionOrSwap { stopped = true }
            throw ProbeError(decision.refusal ?? "\(purpose) refused")
        }
        if decision.reclaimableUsedForAdmission { usedReclaimable = true }
        let room = decision.admissibleBytes - decision.requiredBytes
        if room < tightest.map({ $0.admissibleBytes - $0.requiredBytes }) ?? Int.max { tightest = decision }
        return true
    }

    var summary: QwenDenseStageLoadAdmissionSummary {
        lock.lock(); defer { lock.unlock() }
        return .init(policy: QwenDenseStageLoadPolicy.identifier, purpose: purpose, decisions: decisions,
            refusals: refusals, unjudged: unjudged, lastUnjudged: lastUnjudged,
            reclaimableUsedForAdmission: usedReclaimable, stoppedByCompressionOrSwap: stopped,
            compressedSinceFirstSampleBytes: latest?.compressedSinceFirstSampleBytes,
            swappedOutSinceFirstSampleBytes: latest?.swappedOutSinceFirstSampleBytes,
            first: first, tightest: tightest, fewestFreePages: fewestFree, lastRefusal: lastRefusal, latest: latest)
    }
}

/// The loads and requests of this process that took at least one decision,
/// oldest first. Bounded: a worker lives for at most sixteen requests.
final class QwenDenseStageLoadWatchList: @unchecked Sendable {
    static let shared = QwenDenseStageLoadWatchList()
    static let capacity = 64
    private let lock = NSLock()
    private var watches: [QwenDenseStageLoadWatch] = []
    private var dropped = 0

    func add(_ watch: QwenDenseStageLoadWatch) {
        lock.lock(); defer { lock.unlock() }
        watches.append(watch)
        if watches.count > Self.capacity { watches.removeFirst(); dropped += 1 }
    }

    func report() -> QwenResidentResourceAdmissionReport {
        lock.lock()
        let listed = watches, earlier = dropped
        lock.unlock()
        return .init(policy: QwenDenseStageLoadPolicy.identifier, entryChecks: QwenDenseStageLoadWatch.entry.summary,
            scopes: listed.map(\.summary), earlierScopesDropped: earlier)
    }
}

/// What the host memory gate decided for one load or one request: how many
/// gate passes, how many were refused or could not be judged, the first
/// decision, the one with the least room, the one at the fewest free pages,
/// the latest, whether any admission needed file cache, and how much was
/// compressed and swapped out since its first sample. A record for receipts
/// and operators; nothing reads it to make a decision.
public struct QwenDenseStageLoadAdmissionSummary: Encodable, Sendable {
    public let policy: String
    public let purpose: String
    /// One per gate pass that the policy judged.
    public let decisions: Int
    public let refusals: Int
    /// Samples the policy would not judge, and the last reason.
    public let unjudged: Int
    public let lastUnjudged: String?
    public let reclaimableUsedForAdmission: Bool
    public let stoppedByCompressionOrSwap: Bool
    public let compressedSinceFirstSampleBytes: Int?
    public let swappedOutSinceFirstSampleBytes: Int?
    public let first: QwenDenseStageLoadAdmission?
    /// The admitted decision with the smallest admissible minus required.
    public let tightest: QwenDenseStageLoadAdmission?
    public let fewestFreePages: QwenDenseStageLoadAdmission?
    public let lastRefusal: QwenDenseStageLoadAdmission?
    public let latest: QwenDenseStageLoadAdmission?

    /// The record as one line for a log.
    public var line: String {
        func mib(_ bytes: Int?) -> String { bytes.map { "\($0 / 1_048_576) MiB" } ?? "not compared" }
        return "\(purpose): \(decisions) decisions, \(refusals) refused, \(unjudged) not judged, "
            + (reclaimableUsedForAdmission ? "file cache counted" : "free pages alone") + ", compressed "
            + "\(mib(compressedSinceFirstSampleBytes)) and swapped out \(mib(swappedOutSinceFirstSampleBytes)) since its first sample"
            + (stoppedByCompressionOrSwap ? ", stopped for that" : "")
            + (lastRefusal?.refusal.map { "; last refusal: \($0)" } ?? "")
            + (lastUnjudged.map { "; last sample not judged: \($0)" } ?? "")
    }
}

/// The host memory gate's record for the calling process: its entry checks,
/// and one summary per load and per request. A caller on the serving path can
/// print `current` after a load or a request; nothing else emits it there.
public struct QwenResidentResourceAdmissionReport: Encodable, Sendable {
    public let policy: String
    public let entryChecks: QwenDenseStageLoadAdmissionSummary
    public let scopes: [QwenDenseStageLoadAdmissionSummary]
    public let earlierScopesDropped: Int

    public static var current: QwenResidentResourceAdmissionReport { QwenDenseStageLoadWatchList.shared.report() }

    /// One line per load and per request, oldest first, for a log.
    public var lines: [String] { scopes.map(\.line) }

    /// The scopes that refused, could not judge a sample, or were stopped.
    public var troubled: [QwenDenseStageLoadAdmissionSummary] {
        scopes.filter { $0.refusals > 0 || $0.unjudged > 0 || $0.stoppedByCompressionOrSwap }
    }
}
