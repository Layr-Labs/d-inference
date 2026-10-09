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
    /// `inactive_external_count`: file-backed pages on the inactive queue. Nil
    /// when the kernel does not report it; no file cache is counted then.
    let inactiveFileBackedPages: Int?
    /// `inactive_internal_count`: anonymous pages on the inactive queue, the
    /// ones the pageout scan compresses. Reported, never counted.
    let inactiveAnonymousPages: Int?
    /// Lifetime counters `compressions` and `swapouts`, in pages. A load or a
    /// request compares them with its first sample: growth is the kernel
    /// taking anonymous memory, which is the harm this gate exists to avoid.
    let compressionPages: Int, swapoutPages: Int
    /// `vm.pageout_inactive_dirty_internal`: anonymous pages the pageout scan
    /// has handed to the compressor, read by sysctl. The kernel answers
    /// `host_statistics64` from a cache once a binary that is not Apple's has
    /// asked a few times within a second, so every counter above can be up
    /// to a second old; this one and the swap figure are not. Nil when this
    /// macOS does not publish it.
    let liveCompressionPages: Int?

    init(startedNanoseconds: UInt64, completedNanoseconds: UInt64, timestampUTC: String,
         physicalMemoryBytes: Int, pageSizeBytes: Int, kernelFreePages: Int, freePages: Int,
         inactivePages: Int, speculativePages: Int, actualFreeBytes: Int, estimatedReclaimableBytes: Int,
         pressureLevel: Int, swapUsedBytes: Int, activePages: Int = 0, fileBackedPages: Int = 0,
         anonymousPages: Int = 0, wiredPages: Int = 0, purgeablePages: Int = 0, compressorPages: Int = 0,
         kernelFileCacheMinimumPages: Int? = nil, inactiveFileBackedPages: Int? = nil,
         inactiveAnonymousPages: Int? = nil, compressionPages: Int = 0, swapoutPages: Int = 0,
         liveCompressionPages: Int? = nil) {
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
        self.inactiveFileBackedPages = inactiveFileBackedPages
        self.inactiveAnonymousPages = inactiveAnonymousPages
        self.compressionPages = compressionPages; self.swapoutPages = swapoutPages
        self.liveCompressionPages = liveCompressionPages
    }
}

/// The lifetime compression and swap-out counters, and the swap in use, at the
/// first sample of one load or one request. Later decisions of that load or
/// request are judged against it.
struct QwenDenseStageLoadBaseline: Equatable {
    let compressionPages: Int, swapoutPages: Int
    let liveCompressionPages: Int?, swapUsedBytes: Int
    init(_ os: QwenDenseStageLoadOSObservation) {
        compressionPages = os.compressionPages; swapoutPages = os.swapoutPages
        liveCompressionPages = os.liveCompressionPages; swapUsedBytes = os.swapUsedBytes
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
    /// `2 x inactive file-backed - file-backed`: how many file pages the
    /// kernel's pageout scan takes before fewer than half of the file cache is
    /// inactive and it turns to anonymous pages. Nil when not reported.
    public let fileCacheBeforeAnonymousBytes: Int?
    /// The smaller of the two kernel bounds; three quarters of it is counted.
    public let countableFileCacheBytes: Int
    /// The most file cache this Mac could ever have counted with its
    /// anonymous memory as it is now, if everything else were file cache.
    public let largestCountableOnThisMacBytes: Int
    /// A refusal that no amount of file cache could change on this Mac with
    /// its anonymous memory as it is: waiting for cache will not help.
    public let structural: Bool
    /// Pages compressed and swapped out since the first sample of this load
    /// or request, in bytes. Nil for a decision taken without a first sample.
    public let compressedSinceFirstSampleBytes: Int?
    public let swappedOutSinceFirstSampleBytes: Int?
    /// True when that growth exceeded its limit and the cache was not counted.
    public let stoppedByCompressionOrSwap: Bool
    public let inactiveFileBackedBytes: Int?
    public let inactiveAnonymousBytes: Int?
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

/// Pure decision checks. A passing caller-fabricated observation is not a grant;
/// only the private native gate samples current resources and permits reads.
///
/// Version 3 admits on free pages plus part of the file cache, because macOS
/// keeps almost nothing free once files have been read: after a download or a
/// hash pass a Mac has a few hundred MiB free and tens of GiB of cache.
///
/// Counted is three quarters of the file-backed memory inside both of the
/// kernel's own bounds (above its file-cache minimum, and before fewer than
/// half of the file cache is inactive), at most 32 GiB. Those bounds say
/// where the pageout scan is forced onto anonymous pages; inside them it may
/// still compress, so counting cache is a bet that the kernel can evict
/// closed files, and it is withdrawn the moment the bet is seen to fail: a
/// load or a request stops counting cache once more than a small amount has
/// been compressed or swapped out since its first sample. Anonymous pages are
/// never counted. Memory pressure is a last-resort condition only: on a Mac
/// with this much memory "warning" comes long after the harm.
///
/// Only the pressure level, the swap in use, the kernel's file-cache minimum
/// and the live compression counter are current at every decision. The queue
/// counters come from `host_statistics64`, which the kernel refreshes for a
/// binary that is not Apple's only a few times a second: between refreshes a
/// decision sees the same figures again, so the bounds describe the Mac up to
/// a second ago and the compression guard is what reacts in between.
/// The measurements and what was rejected are in
/// `handoff/DESIGN-resource-gate-v3.md`.
enum QwenDenseStageLoadPolicy {
    static let identifier = "registered_dense_selected_stage_load_resources_v3"
    static let gib = 1_073_741_824
    /// Floor on admissible memory for any decision.
    static let minimumAdmissibleBytes = 6 * gib
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
    /// The pageout scan takes anonymous pages once fewer than this share of
    /// the file cache is inactive (`VM_PAGE_INACTIVE_TARGET(avail)` is
    /// `avail * 1 / 2` in `vps_choose_victim_page`).
    static let inactiveFileCacheTargetDenominator = 2
    /// Pages compressed since the first sample of a load or request, beyond
    /// which no file cache is counted for it. 39 of 42 recorded runs
    /// compressed nothing at all in 1,384 s; the three that did compressed
    /// 51, 92 and 255 MiB in single bursts and finished normally. The limit
    /// is twice the largest of those.
    static let maximumCompressedSinceFirstSampleBytes = 512 * 1024 * 1024
    /// The same for pages swapped out and for growth of the swap in use,
    /// neither of which moved in any recorded run.
    static let maximumSwappedOutSinceFirstSampleBytes = 64 * 1024 * 1024
    /// Pages by which two counters of one sample may disagree before the
    /// sample is thrown out as inconsistent.
    static let counterSlackPages = 1024
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
    /// pressure); a judged refusal is returned with its sentence. `baseline`
    /// is the first sample of the load or request this decision belongs to.
    static func decide(_ os: QwenDenseStageLoadOSObservation, requiredBytes: Int, purpose: String,
                       now: UInt64, since baseline: QwenDenseStageLoadBaseline? = nil) throws -> QwenDenseStageLoadAdmission {
        try validateOS(os, now: now)
        guard requiredBytes >= 0, !purpose.isEmpty else { throw ProbeError("Invalid resource requirement") }
        let sum = QwenLongPrefillCheckedBytes.sum, product = QwenLongPrefillCheckedBytes.product
        let page = os.pageSizeBytes
        let required = max(minimumAdmissibleBytes, requiredBytes)
        // First kernel bound: its file-cache minimum. The kernel's formula on
        // this snapshot, rounded up, and the kernel's own figure when that is
        // larger. The sysctl alone can be stale.
        let pageablePages = try sum([os.activePages, os.inactivePages, os.kernelFreePages])
        let scaled = try sum([try product([pageablePages, fileCacheReserveNumerator]), fileCacheReserveDenominator - 1])
        let reservePages = max(scaled / fileCacheReserveDenominator, os.kernelFileCacheMinimumPages ?? 0)
        let abovePages = max(0, os.fileBackedPages - reservePages)
        // Second kernel bound: taking x inactive file pages leaves fewer than
        // half of the file cache inactive once x exceeds 2 * inactive - total.
        let beforeAnonymousPages = try os.inactiveFileBackedPages.map {
            max(0, try product([$0, inactiveFileCacheTargetDenominator]) - os.fileBackedPages)
        }
        let countablePages = min(abovePages, beforeAnonymousPages ?? 0)
        let aboveBytes = try product([abovePages, page]), countableBytes = try product([countablePages, page])
        // Harm seen since this load or request began withdraws the cache.
        var compressed: Int?, swappedOut: Int?
        if let baseline {
            let live = os.liveCompressionPages.flatMap { now in baseline.liveCompressionPages.map { now - $0 } }
            guard os.compressionPages >= baseline.compressionPages, os.swapoutPages >= baseline.swapoutPages,
                  (live ?? 0) >= 0 else {
                throw ProbeError("Compression or swap-out counter ran backwards since the first sample")
            }
            // The larger of the two views of each: the kernel's statistics,
            // which it may have served from a cache up to a second old, and
            // the figures read by sysctl, which are current.
            compressed = try product([max(os.compressionPages - baseline.compressionPages, live ?? 0), page])
            swappedOut = max(try product([os.swapoutPages - baseline.swapoutPages, page]),
                             os.swapUsedBytes - baseline.swapUsedBytes)
        }
        let harmed = (compressed ?? 0) > maximumCompressedSinceFirstSampleBytes
            || (swappedOut ?? 0) > maximumSwappedOutSinceFirstSampleBytes
        let pressureNormal = os.pressureLevel == normalPressureLevel
        func threeQuarters(_ bytes: Int) throws -> Int {
            min(maximumCountedReclaimableBytes,
                try product([bytes, countedFileCacheNumerator]) / countedFileCacheDenominator)
        }
        let counted = pressureNormal && !harmed ? try threeQuarters(countableBytes) : 0
        let admissible = try sum([os.actualFreeBytes, counted])
        let fileBacked = try product([os.fileBackedPages, page]), reserve = try product([reservePages, page])
        // The best this Mac could do with its anonymous memory as it is: every
        // other pageable page file cache, all of it inactive.
        let otherPages = max(0, pageablePages - os.anonymousPages - os.freePages - reservePages)
        let largest = try threeQuarters(try product([otherPages, page]))
        let structural = required > (try sum([os.actualFreeBytes, largest]))
        var refusal: String?
        if os.actualFreeBytes < minimumTrulyFreeBytes {
            refusal = "\(purpose) refused: \(os.actualFreeBytes / 1_048_576) MiB truly free, below the "
                + "\(minimumTrulyFreeBytes / 1_048_576) MiB floor; the kernel is not freeing pages fast enough"
        } else if required > os.physicalMemoryBytes {
            refusal = "\(purpose) needs \(gibText(required)), more than this Mac's \(gibText(os.physicalMemoryBytes))"
        } else if admissible < required {
            let cache: String
            if harmed {
                cache = "no file cache: \((compressed ?? 0) / 1_048_576) MiB was compressed and "
                    + "\((swappedOut ?? 0) / 1_048_576) MiB swapped out since its first check (limits "
                    + "\(maximumCompressedSinceFirstSampleBytes / 1_048_576) and "
                    + "\(maximumSwappedOutSinceFirstSampleBytes / 1_048_576) MiB), so the kernel is taking anonymous memory"
            } else if !pressureNormal {
                cache = "no file cache, which is counted only at normal memory pressure (level \(os.pressureLevel) now; "
                    + "\(gibText(fileBacked)) file-backed)"
            } else if beforeAnonymousPages == nil {
                cache = "no file cache, because this kernel does not report how much of it is inactive "
                    + "(\(gibText(fileBacked)) file-backed)"
            } else {
                cache = "\(gibText(counted)) of file cache counted (three quarters of the \(gibText(countableBytes)) "
                    + "the kernel can take before anonymous memory: \(gibText(aboveBytes)) above the "
                    + "\(gibText(reserve)) reserve, \(gibText(try product([beforeAnonymousPages ?? 0, page]))) before half "
                    + "of the cache is active; at most \(gibText(maximumCountedReclaimableBytes)); "
                    + "\(gibText(fileBacked)) file-backed)"
            }
            refusal = "\(purpose) needs \(gibText(required)) of admissible memory and has \(gibText(admissible)): "
                + "\(gibText(os.actualFreeBytes)) free plus \(cache)"
            if structural {
                refusal! += ". More file cache cannot change this: with "
                    + "\(gibText(try product([os.anonymousPages, page]))) of anonymous memory in use this Mac can count at most "
                    + "\(gibText(largest)), so \(gibText(required - largest)) of the requirement has to be free pages"
            }
        }
        return .init(policy: identifier, purpose: purpose, admitted: refusal == nil, refusal: refusal,
            requiredBytes: required, admissibleBytes: admissible, actualFreeBytes: os.actualFreeBytes,
            countedReclaimableBytes: counted,
            reclaimableUsedForAdmission: refusal == nil && os.actualFreeBytes < required,
            fileBackedBytes: fileBacked, fileCacheReserveBytes: reserve, fileCacheAboveReserveBytes: aboveBytes,
            fileCacheBeforeAnonymousBytes: try beforeAnonymousPages.map { try product([$0, page]) },
            countableFileCacheBytes: countableBytes, largestCountableOnThisMacBytes: largest,
            structural: refusal != nil && structural,
            compressedSinceFirstSampleBytes: compressed, swappedOutSinceFirstSampleBytes: swappedOut,
            stoppedByCompressionOrSwap: refusal != nil && harmed,
            inactiveFileBackedBytes: try os.inactiveFileBackedPages.map { try product([$0, page]) },
            inactiveAnonymousBytes: try os.inactiveAnonymousPages.map { try product([$0, page]) },
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
                                  now: UInt64, since baseline: QwenDenseStageLoadBaseline? = nil) throws -> QwenDenseStageLoadAdmission {
        let decision = try decide(os, requiredBytes: requiredBytes, purpose: purpose, now: now, since: baseline)
        if let refusal = decision.refusal { throw ProbeError(refusal) }
        return decision
    }

    /// Two decimals of GiB, rounded down, so a printed figure never overstates.
    static func gibText(_ bytes: Int) -> String {
        let whole = bytes / gib, hundredths = (bytes % gib) * 100 / gib
        return "\(whole).\(hundredths < 10 ? "0" : "")\(hundredths) GiB"
    }

    private static func validateOS(_ os: QwenDenseStageLoadOSObservation, now: UInt64) throws {
        guard os.startedNanoseconds <= os.completedNanoseconds, now >= os.completedNanoseconds,
              os.completedNanoseconds - os.startedNanoseconds <= maximumObservationAgeNanoseconds,
              now - os.completedNanoseconds <= maximumObservationAgeNanoseconds,
              os.physicalMemoryBytes > 0, os.pageSizeBytes > 0,
              [os.kernelFreePages, os.freePages, os.inactivePages, os.speculativePages, os.actualFreeBytes,
               os.estimatedReclaimableBytes, os.swapUsedBytes, os.activePages, os.fileBackedPages,
               os.anonymousPages, os.wiredPages, os.purgeablePages, os.compressorPages,
               os.kernelFileCacheMinimumPages ?? 0, os.inactiveFileBackedPages ?? 0,
               os.inactiveAnonymousPages ?? 0, os.compressionPages, os.swapoutPages,
               os.liveCompressionPages ?? 0].allSatisfy({ $0 >= 0 }),
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
        // File-backed pages are on the active, inactive or speculative queue,
        // and the inactive ones are among both. A sample that says otherwise
        // is not one to count cache from. The kernel fills these counters one
        // after another while pages move, so the inactive ones get a little
        // slack; the first comparison has gigabytes of margin on any real Mac.
        let queued = try QwenLongPrefillCheckedBytes.sum([os.activePages, os.inactivePages, os.speculativePages])
        let slack = counterSlackPages
        guard os.fileBackedPages <= queued,
              (os.inactiveFileBackedPages ?? 0) <= (try QwenLongPrefillCheckedBytes.sum([min(os.fileBackedPages, os.inactivePages), slack])),
              (os.inactiveAnonymousPages ?? 0) <= (try QwenLongPrefillCheckedBytes.sum([min(os.anonymousPages, os.inactivePages), slack])) else {
            throw ProbeError("Selected-stage file-backed or inactive counters are inconsistent")
        }
    }
}
