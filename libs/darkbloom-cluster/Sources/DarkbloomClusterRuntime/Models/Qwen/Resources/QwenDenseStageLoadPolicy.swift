import Foundation

struct QwenDenseStageLoadOSObservation: Encodable {
    let startedNanoseconds: UInt64, completedNanoseconds: UInt64
    let timestampUTC: String
    let physicalMemoryBytes: Int, pageSizeBytes: Int
    let kernelFreePages: Int, freePages: Int, inactivePages: Int, speculativePages: Int
    let actualFreeBytes: Int, estimatedReclaimableBytes: Int
    let pressureLevel: Int, swapUsedBytes: Int
    /// Counters the v3 rule reads, in pages. An observation built without them
    /// (all zero) counts no file cache and is judged on free pages alone.
    let activePages: Int
    /// `external_page_count`: pageable pages backed by a file.
    let fileBackedPages: Int
    /// `internal_page_count`: pageable anonymous pages. Reported, never counted.
    let anonymousPages: Int
    let wiredPages: Int, purgeablePages: Int, compressorPages: Int
    /// `vm.vm_page_filecache_min` as the kernel last computed it; nil if unreadable.
    let kernelFileCacheMinimumPages: Int?

    init(startedNanoseconds: UInt64, completedNanoseconds: UInt64, timestampUTC: String,
         physicalMemoryBytes: Int, pageSizeBytes: Int, kernelFreePages: Int, freePages: Int,
         inactivePages: Int, speculativePages: Int, actualFreeBytes: Int, estimatedReclaimableBytes: Int,
         pressureLevel: Int, swapUsedBytes: Int, activePages: Int = 0, fileBackedPages: Int = 0,
         anonymousPages: Int = 0, wiredPages: Int = 0, purgeablePages: Int = 0, compressorPages: Int = 0,
         kernelFileCacheMinimumPages: Int? = nil) {
        self.startedNanoseconds = startedNanoseconds; self.completedNanoseconds = completedNanoseconds
        self.timestampUTC = timestampUTC; self.physicalMemoryBytes = physicalMemoryBytes
        self.pageSizeBytes = pageSizeBytes; self.kernelFreePages = kernelFreePages; self.freePages = freePages
        self.inactivePages = inactivePages; self.speculativePages = speculativePages
        self.actualFreeBytes = actualFreeBytes; self.estimatedReclaimableBytes = estimatedReclaimableBytes
        self.pressureLevel = pressureLevel; self.swapUsedBytes = swapUsedBytes
        self.activePages = activePages; self.fileBackedPages = fileBackedPages
        self.anonymousPages = anonymousPages; self.wiredPages = wiredPages
        self.purgeablePages = purgeablePages; self.compressorPages = compressorPages
        self.kernelFileCacheMinimumPages = kernelFileCacheMinimumPages
    }
}

/// One decision of the host memory gate with every number it used. A refused
/// decision carries the sentence the operator sees. This is a record of a
/// policy decision, not a measurement of what a load will consume.
public struct QwenDenseStageLoadAdmission: Encodable, Equatable, Sendable {
    public let policy: String
    public let purpose: String
    public let admitted: Bool
    public let refusal: String?
    /// The caller's requirement after the 6 GiB floor.
    public let requiredBytes: Int
    /// Actual free plus the file cache counted for this decision.
    public let admissibleBytes: Int
    public let actualFreeBytes: Int
    public let countedReclaimableBytes: Int
    /// True when the decision was admitted and free pages alone would not have been enough.
    public let reclaimableUsedForAdmission: Bool
    public let fileBackedBytes: Int
    public let fileCacheReserveBytes: Int
    public let fileCacheAboveReserveBytes: Int
    public let kernelFileCacheMinimumBytes: Int?
    public let pageableBytes: Int
    public let anonymousBytes: Int, activeBytes: Int, inactiveBytes: Int, speculativeBytes: Int
    public let wiredBytes: Int, purgeableBytes: Int, compressorBytes: Int
    public let pressureLevel: Int, swapUsedBytes: Int
    public let physicalMemoryBytes: Int, pageSizeBytes: Int
    public let timestampUTC: String
}

struct QwenDenseStageLoadNativeObservation: Encodable {
    let activeBytes: Int, cacheBytes: Int, peakBytes: Int, allocatorLimitBytes: Int
}

struct QwenDenseStageLoadResourceDecision: Encodable {
    let policy = QwenDenseStageLoadPolicy.identifier
    let ordinal: Int, remainingAllocationBytes: Int
    let requiredAdmissibleBytes: Int, requiredAllocatorBytes: Int
    let os: QwenDenseStageLoadOSObservation
    let native: QwenDenseStageLoadNativeObservation
    let admission: QwenDenseStageLoadAdmission
    let reclaimableUsedForAdmission: Bool
    let wholeProcessMemorySafetyEstablished = false
    let reserveTermsAreOperationalPolicy = true, forwardExecutionAuthorized = false
}

/// Pure decision checks. A passing caller-fabricated observation is not a grant;
/// only the private native gate samples current resources and permits reads.
///
/// Version 3 admits on free pages plus part of the file cache, because macOS
/// keeps almost nothing free once files have been read: after a download or a
/// hash pass a Mac has a few hundred MiB free and tens of GiB of cache. Counted
/// is three quarters of the file-backed memory above the kernel's own
/// file-cache minimum, at most 32 GiB, and only while memory pressure is
/// normal. Anonymous pages are never counted: taking them means compressing
/// them. The measurements and what was rejected are in
/// `handoff/DESIGN-resource-gate-v3.md`.
enum QwenDenseStageLoadPolicy {
    static let identifier = "registered_dense_selected_stage_load_resources_v3"
    static let gib = 1_073_741_824
    /// Floor on admissible memory for any decision.
    static let minimumAdmissibleBytes = 6 * gib
    /// The same floor under the name its three callers use. Since version 3 it
    /// is a floor on admissible memory, not on free pages.
    static let minimumActualFreeBytes = minimumAdmissibleBytes
    /// Floor on pages that are free right now, about the kernel's reserved
    /// pool. The kernel runs loads from cache at 0.1 GiB free, so this is a
    /// tripwire for a kernel that is not keeping up, not a budget.
    static let minimumTrulyFreeBytes = 16 * 1024 * 1024
    /// XNU keeps this share of non-compressed pageable memory as file cache
    /// before it turns to anonymous pages (`vps_calculate_filecache_min`).
    static let fileCacheReserveNumerator = 10, fileCacheReserveDenominator = 27
    /// Share of the file cache above the reserve that one decision may count.
    static let countedFileCacheNumerator = 3, countedFileCacheDenominator = 4
    /// No decision counts more file cache than this, whatever the Mac holds.
    static let maximumCountedReclaimableBytes = 32 * gib
    static let loadingHeadroomBytes = 4 * gib
    static let allocatorHeadroomBytes = 2 * gib
    static let maximumObservationAgeNanoseconds: UInt64 = 1_000_000_000
    /// `kern.memorystatus_vm_pressure_level`: 1 normal, 2 warning, 4 critical.
    static let normalPressureLevel = 1
    static let warningPressureLevel = 2

    /// Swap occupancy is history: pages written out earlier stay counted until
    /// they are touched or the Mac restarts. It says the Mac is short of memory
    /// now only together with pressure, so it is refused under warning pressure
    /// and admitted while the kernel reports normal. Swapped pages are never
    /// counted as available.
    static func swapIsAcceptable(swapUsedBytes: Int, pressureLevel: Int) -> Bool {
        swapUsedBytes == 0 || pressureLevel <= normalPressureLevel
    }

    static func requireInitial(_ os: QwenDenseStageLoadOSObservation, now: UInt64) throws {
        _ = try requireAdmissible(os, requiredBytes: minimumAdmissibleBytes, purpose: "Selected-stage loading", now: now)
    }

    /// The decision for one requirement. Throws only for an observation that
    /// cannot be judged (invalid, stale, critical pressure, swap under
    /// pressure); a judged refusal is returned with its sentence.
    static func decide(_ os: QwenDenseStageLoadOSObservation, requiredBytes: Int, purpose: String,
                       now: UInt64) throws -> QwenDenseStageLoadAdmission {
        try validateOS(os, now: now)
        guard requiredBytes >= 0, !purpose.isEmpty else { throw ProbeError("Invalid resource requirement") }
        let sum = QwenLongPrefillCheckedBytes.sum, product = QwenLongPrefillCheckedBytes.product
        let page = os.pageSizeBytes
        let required = max(minimumAdmissibleBytes, requiredBytes)
        // The kernel's formula on this snapshot, rounded up, and the kernel's
        // own figure when that is larger. The sysctl alone can be stale.
        let pageablePages = try sum([os.activePages, os.inactivePages, os.kernelFreePages])
        let scaled = try sum([try product([pageablePages, fileCacheReserveNumerator]), fileCacheReserveDenominator - 1])
        let reservePages = max(scaled / fileCacheReserveDenominator, os.kernelFileCacheMinimumPages ?? 0)
        let abovePages = max(0, os.fileBackedPages - reservePages)
        let aboveBytes = try product([abovePages, page])
        let pressureNormal = os.pressureLevel == normalPressureLevel
        let counted = pressureNormal
            ? min(maximumCountedReclaimableBytes,
                  try product([aboveBytes, countedFileCacheNumerator]) / countedFileCacheDenominator)
            : 0
        let admissible = try sum([os.actualFreeBytes, counted])
        let fileBacked = try product([os.fileBackedPages, page]), reserve = try product([reservePages, page])
        let cache = pressureNormal
            ? "\(gibText(counted)) of file cache counted (three quarters of the \(gibText(aboveBytes)) above the "
                + "\(gibText(reserve)) reserve, at most \(gibText(maximumCountedReclaimableBytes)); \(gibText(fileBacked)) file-backed)"
            : "no file cache, which is counted only at normal memory pressure (level \(os.pressureLevel) now; "
                + "\(gibText(fileBacked)) file-backed)"
        var refusal: String?
        if os.actualFreeBytes < minimumTrulyFreeBytes {
            refusal = "\(purpose) refused: \(os.actualFreeBytes / 1_048_576) MiB truly free, below the "
                + "\(minimumTrulyFreeBytes / 1_048_576) MiB floor; the kernel is not freeing pages fast enough"
        } else if required > os.physicalMemoryBytes {
            refusal = "\(purpose) needs \(gibText(required)), more than this Mac's \(gibText(os.physicalMemoryBytes))"
        } else if admissible < required {
            refusal = "\(purpose) needs \(gibText(required)) of admissible memory and has \(gibText(admissible)): "
                + "\(gibText(os.actualFreeBytes)) free plus \(cache)"
        }
        return .init(policy: identifier, purpose: purpose, admitted: refusal == nil, refusal: refusal,
            requiredBytes: required, admissibleBytes: admissible, actualFreeBytes: os.actualFreeBytes,
            countedReclaimableBytes: counted,
            reclaimableUsedForAdmission: refusal == nil && os.actualFreeBytes < required,
            fileBackedBytes: fileBacked, fileCacheReserveBytes: reserve, fileCacheAboveReserveBytes: aboveBytes,
            kernelFileCacheMinimumBytes: try os.kernelFileCacheMinimumPages.map { try product([$0, page]) },
            pageableBytes: try product([pageablePages, page]),
            anonymousBytes: try product([os.anonymousPages, page]), activeBytes: try product([os.activePages, page]),
            inactiveBytes: try product([os.inactivePages, page]), speculativeBytes: try product([os.speculativePages, page]),
            wiredBytes: try product([os.wiredPages, page]), purgeableBytes: try product([os.purgeablePages, page]),
            compressorBytes: try product([os.compressorPages, page]),
            pressureLevel: os.pressureLevel, swapUsedBytes: os.swapUsedBytes,
            physicalMemoryBytes: os.physicalMemoryBytes, pageSizeBytes: page, timestampUTC: os.timestampUTC)
    }

    /// `decide`, with a refusal thrown as the sentence that names its numbers.
    @discardableResult
    static func requireAdmissible(_ os: QwenDenseStageLoadOSObservation, requiredBytes: Int, purpose: String,
                                  now: UInt64) throws -> QwenDenseStageLoadAdmission {
        let decision = try decide(os, requiredBytes: requiredBytes, purpose: purpose, now: now)
        if let refusal = decision.refusal { throw ProbeError(refusal) }
        return decision
    }

    /// Two decimals of GiB, rounded down, so a printed figure never overstates.
    static func gibText(_ bytes: Int) -> String {
        let whole = bytes / gib, hundredths = (bytes % gib) * 100 / gib
        return "\(whole).\(hundredths < 10 ? "0" : "")\(hundredths) GiB"
    }

    static func evaluate(budget: QwenDenseStageLoadBudget, ordinal: Int,
        os: QwenDenseStageLoadOSObservation, native: QwenDenseStageLoadNativeObservation, now: UInt64
    ) throws -> QwenDenseStageLoadResourceDecision {
        try requireInitial(os, now: now)
        guard [native.activeBytes, native.cacheBytes, native.peakBytes].allSatisfy({ $0 >= 0 }),
              native.allocatorLimitBytes > 0, native.peakBytes >= native.activeBytes else {
            throw ProbeError("Invalid native allocator observation")
        }
        let remaining = try budget.remainingAllocationBytes(after: ordinal)
        let host = ordinal == budget.active.count ? 0 : budget.largestHostTensorBytes
        let sum = QwenLongPrefillCheckedBytes.sum
        let scratch = ordinal == budget.active.count ? 0 : CheckpointAlignedReadPlan.maximumScratchAllocationBytes
        let required = max(minimumAdmissibleBytes, try sum([remaining, host, host, scratch, loadingHeadroomBytes]))
        let allocatorRequired = try sum([native.activeBytes, native.cacheBytes,
            remaining, host, allocatorHeadroomBytes])
        let admission = try requireAdmissible(os, requiredBytes: required, purpose: "Selected-stage loading", now: now)
        guard native.allocatorLimitBytes >= allocatorRequired else {
            throw ProbeError("Selected-stage loading exceeds the allocator limit")
        }
        return .init(ordinal: ordinal, remainingAllocationBytes: remaining,
            requiredAdmissibleBytes: required, requiredAllocatorBytes: allocatorRequired, os: os, native: native,
            admission: admission, reclaimableUsedForAdmission: admission.reclaimableUsedForAdmission)
    }

    private static func validateOS(_ os: QwenDenseStageLoadOSObservation, now: UInt64) throws {
        guard os.startedNanoseconds <= os.completedNanoseconds, now >= os.completedNanoseconds,
              os.completedNanoseconds - os.startedNanoseconds <= maximumObservationAgeNanoseconds,
              now - os.completedNanoseconds <= maximumObservationAgeNanoseconds,
              os.physicalMemoryBytes > 0, os.pageSizeBytes > 0,
              [os.kernelFreePages, os.freePages, os.inactivePages, os.speculativePages, os.actualFreeBytes,
               os.estimatedReclaimableBytes, os.swapUsedBytes, os.activePages, os.fileBackedPages,
               os.anonymousPages, os.wiredPages, os.purgeablePages, os.compressorPages,
               os.kernelFileCacheMinimumPages ?? 0].allSatisfy({ $0 >= 0 }),
              (0...warningPressureLevel).contains(os.pressureLevel) else {
            throw ProbeError("Invalid, stale or pressured selected-stage resource observation")
        }
        guard swapIsAcceptable(swapUsedBytes: os.swapUsedBytes, pressureLevel: os.pressureLevel) else {
            throw ProbeError("Selected-stage loading refuses swap in use under memory pressure")
        }
        let free = try QwenLongPrefillCheckedBytes.product([os.freePages, os.pageSizeBytes])
        let pages = try QwenLongPrefillCheckedBytes.sum([os.freePages, os.inactivePages, os.speculativePages])
        let reclaimable = try QwenLongPrefillCheckedBytes.product([pages, os.pageSizeBytes])
        guard os.kernelFreePages == (try QwenLongPrefillCheckedBytes.sum([os.freePages, os.speculativePages])),
              os.actualFreeBytes == free, os.estimatedReclaimableBytes == reclaimable,
              free <= os.physicalMemoryBytes, reclaimable <= os.physicalMemoryBytes else {
            throw ProbeError("Selected-stage VM counter accounting differs")
        }
        // No counter may claim more memory than the Mac has; a product that
        // overflows throws before any comparison is made.
        for pages in [os.activePages, os.fileBackedPages, os.anonymousPages, os.wiredPages, os.purgeablePages,
                      os.compressorPages, os.kernelFileCacheMinimumPages ?? 0] {
            guard try QwenLongPrefillCheckedBytes.product([pages, os.pageSizeBytes]) <= os.physicalMemoryBytes else {
                throw ProbeError("Selected-stage VM counter exceeds physical memory")
            }
        }
    }
}
