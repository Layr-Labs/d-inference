import Foundation
import Testing
@testable import DarkbloomClusterRuntime

// Version 3 of the host memory gate: free pages plus part of the file cache.
// Every observation is constructed; the policy is pure. Each test names the
// boundary of the rule it stands on. The suites beside this one cover the
// second kernel bound, the compression guard, the per-load record and the
// real sampler.

/// A constructed Mac: 16 KiB pages and, unless said otherwise, 128 GiB with
/// 108 GiB of non-compressed pageable memory, so the kernel's file-cache
/// reserve (10/27 of it) is exactly 40 GiB. Free pages are few and the rest
/// of pageable memory is active or inactive; `fileBacked` and `anonymous` say
/// what those pages are. Unless said otherwise as much of the file cache as
/// fits is on the inactive queue.
enum ConstructedMac {
    static let gib = QwenDenseStageLoadPolicy.gib
    static let mib = 1_048_576
    static let page = 16_384
    static let pageablePages = 27 * 262_144
    /// Lifetime counters of every constructed sample before any growth.
    static let compressionPages = 1_000_000, swapoutPages = 500, liveCompressionPages = 2_000_000
    static let now: UInt64 = 1_100

    static func observation(freeBytes: Int = 256 * mib, fileBackedGiB: Int = 80, anonymousGiB: Int = 27,
                            pressure: Int = 1, swapBytes: Int = 0, kernelMinimumGiB: Int? = nil,
                            speculativeBytes: Int = 0, inactiveFileBackedBytes: Int? = nil,
                            inactiveAnonymousPages: Int? = nil, reportsInactive: Bool = true,
                            compressedBytes: Int = 0, swappedOutBytes: Int = 0,
                            liveCompressedBytes: Int? = 0, physicalGiB: Int = 128,
                            pageablePages: Int = ConstructedMac.pageablePages, activeGiB: Int = 32,
                            fileBackedPages: Int? = nil) -> QwenDenseStageLoadOSObservation {
        let free = freeBytes / page, speculative = speculativeBytes / page
        let active = activeGiB * gib / page, inactive = pageablePages - active - free - speculative
        let fileBacked = fileBackedPages ?? fileBackedGiB * gib / page, anonymous = anonymousGiB * gib / page
        let inactiveFile = inactiveFileBackedBytes.map { $0 / page } ?? min(fileBacked, inactive)
        let inactiveAnonymous = inactiveAnonymousPages ?? min(anonymous, max(0, inactive - inactiveFile))
        return .init(startedNanoseconds: 900, completedNanoseconds: 1_000, timestampUTC: "2026-10-09T00:00:00Z",
            physicalMemoryBytes: physicalGiB * gib, pageSizeBytes: page, kernelFreePages: free + speculative,
            freePages: free, inactivePages: inactive, speculativePages: speculative, actualFreeBytes: free * page,
            estimatedReclaimableBytes: (free + inactive + speculative) * page, pressureLevel: pressure,
            swapUsedBytes: swapBytes, activePages: active, fileBackedPages: fileBacked,
            anonymousPages: anonymous, wiredPages: max(0, physicalGiB * gib / page - pageablePages),
            purgeablePages: gib / page, compressorPages: gib / page,
            kernelFileCacheMinimumPages: kernelMinimumGiB.map { $0 * gib / page },
            inactiveFileBackedPages: reportsInactive ? inactiveFile : nil,
            inactiveAnonymousPages: reportsInactive ? inactiveAnonymous : nil,
            compressionPages: compressionPages + compressedBytes / page,
            swapoutPages: swapoutPages + swappedOutBytes / page,
            liveCompressionPages: liveCompressedBytes.map { liveCompressionPages + $0 / page })
    }

    static func decide(_ value: QwenDenseStageLoadOSObservation, required: Int,
                       since first: QwenDenseStageLoadBaseline? = nil) throws -> QwenDenseStageLoadAdmission {
        try QwenDenseStageLoadPolicy.decide(value, requiredBytes: required, purpose: "Test load", now: now, since: first)
    }
}

@Suite("Stage load admission on file cache (constructed observations)")
struct StageLoadFileCacheAdmissionTests {
    private static let gib = ConstructedMac.gib
    private static let mib = ConstructedMac.mib
    private static let page = ConstructedMac.page

    private static func observation(freeBytes: Int = 256 * mib, fileBackedGiB: Int = 80, anonymousGiB: Int = 27,
                                    pressure: Int = 1, swapBytes: Int = 0, kernelMinimumGiB: Int? = nil,
                                    speculativeBytes: Int = 0) -> QwenDenseStageLoadOSObservation {
        ConstructedMac.observation(freeBytes: freeBytes, fileBackedGiB: fileBackedGiB, anonymousGiB: anonymousGiB,
            pressure: pressure, swapBytes: swapBytes, kernelMinimumGiB: kernelMinimumGiB, speculativeBytes: speculativeBytes)
    }

    private static func decide(_ value: QwenDenseStageLoadOSObservation, required: Int) throws -> QwenDenseStageLoadAdmission {
        try ConstructedMac.decide(value, required: required)
    }

    @Test func theCacheHeavyMacThatVersionTwoRefusedIsAdmitted() throws {
        // 0.25 GiB free, 80 GiB of file cache, pressure normal: the state a Mac
        // is in after a model download or a hash pass.
        let value = Self.observation()
        let decision = try Self.decide(value, required: 16 * Self.gib)
        #expect(decision.admitted && decision.refusal == nil)
        #expect(decision.policy == "registered_dense_selected_stage_load_resources_v3")
        #expect(decision.reclaimableUsedForAdmission)
        #expect(decision.actualFreeBytes == 256 * Self.mib)
        #expect(decision.fileCacheReserveBytes == 40 * Self.gib && decision.pageableBytes == 108 * Self.gib)
        #expect(decision.fileCacheAboveReserveBytes == 40 * Self.gib)
        // 75.75 GiB of the 80 is inactive: 71.5 GiB could go before half is active.
        #expect(decision.fileCacheBeforeAnonymousBytes == 71 * Self.gib + 512 * Self.mib)
        #expect(decision.countableFileCacheBytes == 40 * Self.gib && !decision.structural)
        #expect(decision.countedReclaimableBytes == 30 * Self.gib)
        #expect(decision.admissibleBytes == 30 * Self.gib + 256 * Self.mib)
        #expect(decision.fileBackedBytes == 80 * Self.gib && decision.anonymousBytes == 27 * Self.gib)
        // The entry check every gate starts with passes on the same state.
        try QwenDenseStageLoadPolicy.requireInitial(value, now: 1_100)
    }

    @Test func threeQuartersOfTheCacheAboveTheReserveIsTheExactLimit() throws {
        let value = Self.observation()
        let limit = 30 * Self.gib + 256 * Self.mib
        #expect(try Self.decide(value, required: limit).admitted)
        let over = try Self.decide(value, required: limit + 1)
        #expect(!over.admitted && !over.reclaimableUsedForAdmission)
        // All of the cache above the reserve would have covered this.
        #expect(over.fileCacheAboveReserveBytes + over.actualFreeBytes > limit + 1)
    }

    @Test func noDecisionCountsMoreThanTheCap() throws {
        // 100 GiB of cache is 60 GiB above the reserve; three quarters is 45.
        let value = Self.observation(fileBackedGiB: 100, anonymousGiB: 7)
        let decision = try Self.decide(value, required: 32 * Self.gib + 256 * Self.mib)
        #expect(decision.admitted && decision.countedReclaimableBytes == 32 * Self.gib)
        #expect(decision.fileCacheAboveReserveBytes == 60 * Self.gib)
        #expect(!(try Self.decide(value, required: 32 * Self.gib + 256 * Self.mib + 1).admitted))
    }

    @Test func fileCacheAtOrBelowTheKernelReserveCountsNothing() throws {
        // Exactly the reserve: nothing is above it.
        let atReserve = try Self.decide(Self.observation(fileBackedGiB: 40, anonymousGiB: 67), required: 0)
        #expect(!atReserve.admitted && atReserve.countedReclaimableBytes == 0)
        #expect(!(try Self.decide(Self.observation(fileBackedGiB: 20, anonymousGiB: 87), required: 0).admitted))
        // 8 GiB above it counts 6 GiB, which with 0.25 GiB free meets the 6 GiB floor.
        let above = try Self.decide(Self.observation(fileBackedGiB: 48, anonymousGiB: 59), required: 0)
        #expect(above.admitted && above.countedReclaimableBytes == 6 * Self.gib && above.requiredBytes == 6 * Self.gib)
        // 7 GiB above it counts 5.25 GiB: under the floor.
        #expect(!(try Self.decide(Self.observation(fileBackedGiB: 47, anonymousGiB: 60), required: 0).admitted))
    }

    @Test func anonymousInactivePagesDoNotCount() throws {
        // 75 GiB inactive, but only 10 GiB of it is file-backed: the rest is
        // anonymous memory that could only be taken through the compressor.
        let anonymous = Self.observation(fileBackedGiB: 10, anonymousGiB: 97)
        #expect(anonymous.estimatedReclaimableBytes > 75 * Self.gib)
        let refused = try Self.decide(anonymous, required: 16 * Self.gib)
        #expect(!refused.admitted && refused.countedReclaimableBytes == 0)
        // The same queues with that memory file-backed are admitted.
        #expect(try Self.decide(Self.observation(fileBackedGiB: 80, anonymousGiB: 27), required: 16 * Self.gib).admitted)
    }

    @Test func plentyOfCacheUnderWarningPressureIsRefused() throws {
        let warning = try Self.decide(Self.observation(pressure: 2), required: 16 * Self.gib)
        #expect(!warning.admitted && warning.countedReclaimableBytes == 0)
        #expect(warning.admissibleBytes == warning.actualFreeBytes)
        #expect(warning.refusal?.contains("counted only at normal memory pressure (level 2 now") == true)
        // Level 0 is not the level the kernel reports as normal either.
        #expect(try Self.decide(Self.observation(pressure: 0), required: 16 * Self.gib).countedReclaimableBytes == 0)
        // With enough free pages warning pressure is admitted as before, on free pages alone.
        let free = try Self.decide(Self.observation(freeBytes: 20 * Self.gib, pressure: 2), required: 16 * Self.gib)
        #expect(free.admitted && !free.reclaimableUsedForAdmission && free.countedReclaimableBytes == 0)
        // Swap in use under warning pressure is still not judged at all.
        #expect(throws: ProbeError.self) {
            _ = try Self.decide(Self.observation(freeBytes: 20 * Self.gib, pressure: 2, swapBytes: 1), required: 0)
        }
        #expect(throws: ProbeError.self) { _ = try Self.decide(Self.observation(pressure: 4), required: 0) }
    }

    @Test func theTrulyFreeFloorRefusesWhateverTheCache() throws {
        // 8 MiB free with 100 GiB of cache: the kernel is not keeping up.
        let starved = try Self.decide(Self.observation(freeBytes: 8 * Self.mib, fileBackedGiB: 100, anonymousGiB: 7),
                                      required: 0)
        #expect(!starved.admitted && starved.countedReclaimableBytes == 32 * Self.gib)
        #expect(starved.refusal == "Test load refused: 8 MiB truly free, below the 16 MiB floor; "
            + "the kernel is not freeing pages fast enough")
        let below = try Self.decide(Self.observation(freeBytes: 16 * Self.mib - Self.page), required: 0)
        #expect(!below.admitted)
        // Exactly the floor is admitted; speculative pages are not free pages.
        #expect(try Self.decide(Self.observation(freeBytes: 16 * Self.mib), required: 16 * Self.gib).admitted)
        #expect(!(try Self.decide(Self.observation(freeBytes: 8 * Self.mib, speculativeBytes: Self.gib), required: 0).admitted))
    }

    @Test func freePagesAloneAreAdmittedWithoutUsingTheCache() throws {
        let free = try Self.decide(Self.observation(freeBytes: 20 * Self.gib, fileBackedGiB: 60), required: 16 * Self.gib)
        #expect(free.admitted && !free.reclaimableUsedForAdmission)
        // The cache is still reported, so the receipt shows it was not needed.
        #expect(free.countedReclaimableBytes == 15 * Self.gib)
        // An observation without the new counters is judged exactly as version 2 judged it.
        let old = QwenDenseStageLoadOSObservation(startedNanoseconds: 900, completedNanoseconds: 1_000,
            timestampUTC: "2026-10-09T00:00:00Z", physicalMemoryBytes: 128 * Self.gib, pageSizeBytes: Self.page,
            kernelFreePages: 5 * Self.gib / Self.page, freePages: 5 * Self.gib / Self.page, inactivePages: 80 * Self.gib / Self.page,
            speculativePages: 0, actualFreeBytes: 5 * Self.gib, estimatedReclaimableBytes: 85 * Self.gib,
            pressureLevel: 1, swapUsedBytes: 0)
        #expect(!(try Self.decide(old, required: 0).admitted))
    }

    @Test func theLargerOfTheComputedAndTheKernelReportedReserveIsUsed() throws {
        // The kernel reports 60 GiB: 20 GiB is above it and 15 GiB is counted.
        let larger = try Self.decide(Self.observation(kernelMinimumGiB: 60), required: 0)
        #expect(larger.fileCacheReserveBytes == 60 * Self.gib && larger.countedReclaimableBytes == 15 * Self.gib)
        #expect(larger.kernelFileCacheMinimumBytes == 60 * Self.gib)
        // A stale, smaller kernel figure never lowers the reserve.
        let smaller = try Self.decide(Self.observation(kernelMinimumGiB: 30), required: 0)
        #expect(smaller.fileCacheReserveBytes == 40 * Self.gib && smaller.countedReclaimableBytes == 30 * Self.gib)
        #expect(try Self.decide(Self.observation(), required: 0).kernelFileCacheMinimumBytes == nil)
    }

    @Test func aRefusalNamesTheRequirementTheFreePagesAndTheCacheCounted() throws {
        let decision = try Self.decide(Self.observation(fileBackedGiB: 50, anonymousGiB: 57), required: 16 * Self.gib)
        #expect(decision.refusal == "Test load needs 16.00 GiB of admissible memory and has 7.75 GiB: 0.25 GiB free plus "
            + "7.50 GiB of file cache counted (three quarters of the 10.00 GiB the kernel can take before anonymous "
            + "memory: 10.00 GiB above the 40.00 GiB reserve, 50.00 GiB before half of the cache is active; "
            + "at most 32.00 GiB; 50.00 GiB file-backed). More file cache cannot change this: with 57.00 GiB of "
            + "anonymous memory in use this Mac can count at most 8.06 GiB, so 7.93 GiB of the requirement has to be free pages")
        #expect(throws: ProbeError.self) {
            try QwenDenseStageLoadPolicy.requireAdmissible(Self.observation(fileBackedGiB: 50, anonymousGiB: 57),
                requiredBytes: 16 * Self.gib, purpose: "Test load", now: 1_100)
        }
        // More than the Mac has is refused whatever is free.
        let huge = try Self.decide(Self.observation(freeBytes: 60 * Self.gib, fileBackedGiB: 40, anonymousGiB: 7),
                                   required: 129 * Self.gib)
        #expect(huge.refusal == "Test load needs 129.00 GiB, more than this Mac's 128.00 GiB")
        #expect(QwenDenseStageLoadPolicy.gibText(6 * Self.gib - 1) == "5.99 GiB")
        #expect(QwenDenseStageLoadPolicy.gibText(0) == "0.00 GiB")
    }

    @Test func arithmeticIsCheckedAndBadInputIsNotJudged() throws {
        #expect(throws: (any Error).self, "negative requirement") { _ = try Self.decide(Self.observation(), required: -1) }
        #expect(throws: (any Error).self, "empty purpose") {
            _ = try QwenDenseStageLoadPolicy.decide(Self.observation(), requiredBytes: 0, purpose: "", now: 1_100)
        }
        func with(fileBacked: Int = 80 * Self.gib / Self.page, active: Int = 32 * Self.gib / Self.page,
                  anonymous: Int = 27 * Self.gib / Self.page,
                  kernelMinimum: Int? = nil) -> QwenDenseStageLoadOSObservation {
            let base = Self.observation()
            return .init(startedNanoseconds: base.startedNanoseconds, completedNanoseconds: base.completedNanoseconds,
                timestampUTC: base.timestampUTC, physicalMemoryBytes: base.physicalMemoryBytes,
                pageSizeBytes: base.pageSizeBytes, kernelFreePages: base.kernelFreePages, freePages: base.freePages,
                inactivePages: base.inactivePages, speculativePages: base.speculativePages,
                actualFreeBytes: base.actualFreeBytes, estimatedReclaimableBytes: base.estimatedReclaimableBytes,
                pressureLevel: base.pressureLevel, swapUsedBytes: base.swapUsedBytes, activePages: active,
                fileBackedPages: fileBacked, anonymousPages: anonymous, wiredPages: base.wiredPages,
                purgeablePages: base.purgeablePages, compressorPages: base.compressorPages,
                kernelFileCacheMinimumPages: kernelMinimum, inactiveFileBackedPages: base.inactiveFileBackedPages,
                inactiveAnonymousPages: base.inactiveAnonymousPages, compressionPages: base.compressionPages,
                swapoutPages: base.swapoutPages, liveCompressionPages: base.liveCompressionPages)
        }
        _ = try Self.decide(with(), required: 0)
        // A count whose byte size overflows, or exceeds the Mac, is thrown out, not wrapped.
        #expect(throws: (any Error).self, "file-backed overflow") { _ = try Self.decide(with(fileBacked: Int.max / 2), required: 0) }
        #expect(throws: (any Error).self, "active overflow") { _ = try Self.decide(with(active: Int.max), required: 0) }
        #expect(throws: (any Error).self, "more file cache than memory") {
            _ = try Self.decide(with(fileBacked: 129 * Self.gib / Self.page), required: 0)
        }
        #expect(throws: (any Error).self, "negative counter") { _ = try Self.decide(with(anonymous: -1), required: 0) }
        #expect(throws: (any Error).self, "negative kernel minimum") { _ = try Self.decide(with(kernelMinimum: -1), required: 0) }
        #expect(throws: (any Error).self, "kernel minimum beyond memory") {
            _ = try Self.decide(with(kernelMinimum: 129 * Self.gib / Self.page), required: 0)
        }
        // A stale sample is not judged, however much cache it shows.
        #expect(throws: ProbeError.self) {
            _ = try QwenDenseStageLoadPolicy.decide(Self.observation(), requiredBytes: 0, purpose: "Test load",
                now: 1_000 + 1_000_000_001)
        }
    }
}
