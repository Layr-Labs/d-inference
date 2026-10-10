import Foundation
import Testing
@testable import DarkbloomClusterRuntime

// The parts of version 3 that a reviewer asked for after the first round: the
// kernel's second bound on file cache, the compression and swap-out guard, the
// refusal that waiting cannot cure, the consistency checks on a sample, the
// arithmetic boundaries, and the record each load and each request keeps.
// Every observation is constructed (see `ConstructedMac`).

@Suite("Stage load admission: second kernel bound, compression guard and record (constructed observations)")
struct StageLoadFileCacheGuardTests {
    private typealias Mac = ConstructedMac
    private static let gib = ConstructedMac.gib, mib = ConstructedMac.mib, page = ConstructedMac.page

    // MARK: the kernel's second bound

    @Test func cacheIsCountedOnlyUntilHalfOfItWouldBeActive() throws {
        // 80 GiB of cache, 40 GiB above the reserve. With 60 GiB inactive the
        // scan can take 2 x 60 - 80 = 40 GiB before it turns to anonymous
        // pages: the two bounds meet and nothing changes.
        let both = try Mac.decide(Mac.observation(inactiveFileBackedBytes: 60 * Self.gib), required: 0)
        #expect(both.fileCacheBeforeAnonymousBytes == 40 * Self.gib && both.countedReclaimableBytes == 30 * Self.gib)
        // With 50 GiB inactive only 20 GiB can go first, so 15 GiB is counted
        // although 40 GiB is above the reserve.
        let half = Mac.observation(inactiveFileBackedBytes: 50 * Self.gib)
        let limit = 15 * Self.gib + 256 * Self.mib
        let admitted = try Mac.decide(half, required: limit)
        #expect(admitted.admitted && admitted.countableFileCacheBytes == 20 * Self.gib)
        #expect(admitted.fileCacheAboveReserveBytes == 40 * Self.gib && admitted.inactiveFileBackedBytes == 50 * Self.gib)
        let over = try Mac.decide(half, required: limit + 1)
        #expect(!over.admitted && !over.structural)
        #expect(over.refusal?.contains("three quarters of the 20.00 GiB the kernel can take before anonymous memory: "
            + "40.00 GiB above the 40.00 GiB reserve, 20.00 GiB before half of the cache is active") == true)
        // Exactly half inactive, or less: the scan is already on anonymous pages.
        for inactive in [40, 30, 0] {
            let none = try Mac.decide(Mac.observation(inactiveFileBackedBytes: inactive * Self.gib), required: 0)
            #expect(!none.admitted && none.countedReclaimableBytes == 0 && none.fileCacheBeforeAnonymousBytes == 0)
        }
        // One page past half counts one page's three quarters.
        let one = try Mac.decide(Mac.observation(inactiveFileBackedBytes: 40 * Self.gib + Self.page), required: 0)
        #expect(one.countableFileCacheBytes == 2 * Self.page && one.countedReclaimableBytes == 2 * Self.page * 3 / 4)
        // The reserve still binds when it is the smaller bound.
        let reserve = try Mac.decide(Mac.observation(fileBackedGiB: 48, anonymousGiB: 59), required: 0)
        #expect(reserve.fileCacheBeforeAnonymousBytes == 48 * Self.gib && reserve.countableFileCacheBytes == 8 * Self.gib)
    }

    @Test func aKernelThatDoesNotSayHowMuchCacheIsInactiveCountsNone() throws {
        let unreported = try Mac.decide(Mac.observation(reportsInactive: false), required: 16 * Self.gib)
        #expect(!unreported.admitted && unreported.countedReclaimableBytes == 0)
        #expect(unreported.fileCacheBeforeAnonymousBytes == nil && unreported.inactiveFileBackedBytes == nil)
        #expect(unreported.fileCacheAboveReserveBytes == 40 * Self.gib)
        #expect(unreported.refusal?.contains("no file cache, because this kernel does not report how much of it is inactive") == true)
        // Free pages alone are judged as before.
        #expect(try Mac.decide(Mac.observation(freeBytes: 20 * Self.gib, fileBackedGiB: 60, reportsInactive: false),
                               required: 16 * Self.gib).admitted)
    }

    // MARK: the compression and swap-out guard

    @Test func compressionOrSwapOutSinceTheFirstSampleWithdrawsTheCache() throws {
        let first = QwenDenseStageLoadBaseline(Mac.observation())
        let limit = QwenDenseStageLoadPolicy.maximumCompressedSinceFirstSampleBytes
        #expect(limit == 512 * Self.mib && QwenDenseStageLoadPolicy.maximumSwappedOutSinceFirstSampleBytes == 64 * Self.mib)
        // Exactly the limit is still inside it, and the growth is reported.
        let at = try Mac.decide(Mac.observation(compressedBytes: limit), required: 16 * Self.gib, since: first)
        #expect(at.admitted && at.countedReclaimableBytes == 30 * Self.gib && !at.stoppedByCompressionOrSwap)
        #expect(at.compressedSinceFirstSampleBytes == limit && at.swappedOutSinceFirstSampleBytes == 0)
        // One page more: no cache is counted and the decision is a refusal.
        let over = try Mac.decide(Mac.observation(compressedBytes: limit + Self.page), required: 16 * Self.gib, since: first)
        #expect(!over.admitted && over.stoppedByCompressionOrSwap && over.countedReclaimableBytes == 0)
        #expect(over.admissibleBytes == over.actualFreeBytes && !over.structural)
        #expect(over.refusal == "Test load needs 16.00 GiB of admissible memory and has 0.25 GiB: 0.25 GiB free plus "
            + "no file cache: 512 MiB was compressed and 0 MiB swapped out since its first check (limits 512 and 64 MiB), "
            + "so the kernel is taking anonymous memory")
        // Swap-outs have their own, smaller limit.
        let swapLimit = QwenDenseStageLoadPolicy.maximumSwappedOutSinceFirstSampleBytes
        #expect(try Mac.decide(Mac.observation(swappedOutBytes: swapLimit), required: 16 * Self.gib, since: first).admitted)
        let swapped = try Mac.decide(Mac.observation(swappedOutBytes: swapLimit + Self.page), required: 16 * Self.gib, since: first)
        #expect(!swapped.admitted && swapped.stoppedByCompressionOrSwap)
        #expect(swapped.swappedOutSinceFirstSampleBytes == swapLimit + Self.page && swapped.compressedSinceFirstSampleBytes == 0)
        // A decision that free pages cover alone is not betting on the cache,
        // so it is admitted; the cache is still not counted.
        let free = try Mac.decide(Mac.observation(freeBytes: 20 * Self.gib, fileBackedGiB: 60, compressedBytes: 2 * Self.gib),
                                  required: 16 * Self.gib, since: first)
        #expect(free.admitted && !free.stoppedByCompressionOrSwap && free.countedReclaimableBytes == 0)
        #expect(!free.reclaimableUsedForAdmission && free.compressedSinceFirstSampleBytes == 2 * Self.gib)
        // Without a first sample nothing is compared.
        let alone = try Mac.decide(Mac.observation(compressedBytes: 2 * Self.gib), required: 16 * Self.gib)
        #expect(alone.admitted && alone.compressedSinceFirstSampleBytes == nil && alone.swappedOutSinceFirstSampleBytes == nil)
        // A lifetime counter that went down is not a sample to judge.
        let later = QwenDenseStageLoadBaseline(Mac.observation(compressedBytes: Self.gib))
        #expect(throws: ProbeError.self) { _ = try Mac.decide(Mac.observation(), required: 0, since: later) }
        let laterSwap = QwenDenseStageLoadBaseline(Mac.observation(swappedOutBytes: Self.gib))
        #expect(throws: ProbeError.self) { _ = try Mac.decide(Mac.observation(), required: 0, since: laterSwap) }
    }

    @Test func theCurrentCountersTripTheGuardWhenTheStatisticsAreACachedCopy() throws {
        // The kernel serves this binary cached statistics for most of each
        // second: `compressions` has not moved, the counter read by sysctl has.
        let first = QwenDenseStageLoadBaseline(Mac.observation())
        let limit = QwenDenseStageLoadPolicy.maximumCompressedSinceFirstSampleBytes
        let at = try Mac.decide(Mac.observation(liveCompressedBytes: limit), required: 16 * Self.gib, since: first)
        #expect(at.admitted && at.compressedSinceFirstSampleBytes == limit)
        let over = try Mac.decide(Mac.observation(liveCompressedBytes: limit + Self.page), required: 16 * Self.gib, since: first)
        #expect(!over.admitted && over.stoppedByCompressionOrSwap && over.countedReclaimableBytes == 0)
        #expect(over.compressedSinceFirstSampleBytes == limit + Self.page)
        // The larger of the two views is the one reported and judged.
        let both = try Mac.decide(Mac.observation(compressedBytes: 300 * Self.mib, liveCompressedBytes: 100 * Self.mib),
                                  required: 16 * Self.gib, since: first)
        #expect(both.admitted && both.compressedSinceFirstSampleBytes == 300 * Self.mib)
        // Swap in use that grew past the limit trips it with no swap-out counted yet.
        let swapLimit = QwenDenseStageLoadPolicy.maximumSwappedOutSinceFirstSampleBytes
        #expect(try Mac.decide(Mac.observation(swapBytes: swapLimit), required: 16 * Self.gib, since: first).admitted)
        let swapping = try Mac.decide(Mac.observation(swapBytes: swapLimit + 1), required: 16 * Self.gib, since: first)
        #expect(!swapping.admitted && swapping.stoppedByCompressionOrSwap)
        #expect(swapping.swappedOutSinceFirstSampleBytes == swapLimit + 1)
        // Swap in use that shrank is not growth.
        let swapped = QwenDenseStageLoadBaseline(Mac.observation(swapBytes: Self.gib))
        let shrunk = try Mac.decide(Mac.observation(), required: 16 * Self.gib, since: swapped)
        #expect(shrunk.admitted && shrunk.swappedOutSinceFirstSampleBytes == 0)
        // A kernel that does not publish the counter is judged on the statistics alone.
        let without = QwenDenseStageLoadBaseline(Mac.observation(liveCompressedBytes: nil))
        let old = try Mac.decide(Mac.observation(compressedBytes: limit + Self.page, liveCompressedBytes: nil),
                                 required: 16 * Self.gib, since: without)
        #expect(!old.admitted && old.stoppedByCompressionOrSwap)
        #expect(try Mac.decide(Mac.observation(liveCompressedBytes: 2 * Self.gib), required: 16 * Self.gib, since: without).admitted)
        // The current counter does not run backwards either, and is never negative.
        let later = QwenDenseStageLoadBaseline(Mac.observation(liveCompressedBytes: Self.gib))
        #expect(throws: ProbeError.self) { _ = try Mac.decide(Mac.observation(), required: 0, since: later) }
        #expect(throws: ProbeError.self) {
            _ = try Mac.decide(Mac.observation(liveCompressedBytes: -(Mac.liveCompressionPages + 1) * Self.page), required: 0)
        }
    }

    // MARK: the refusal that waiting cannot cure

    @Test func aRefusalThatNoAmountOfCacheCouldChangeSaysSo() throws {
        // 57 GiB of anonymous memory on the 128 GiB Mac leaves 10.75 GiB that
        // could ever be cache above the reserve: 8.06 GiB counted at best.
        let anonymous = try Mac.decide(Mac.observation(fileBackedGiB: 50, anonymousGiB: 57), required: 16 * Self.gib)
        #expect(!anonymous.admitted && anonymous.structural)
        #expect(anonymous.largestCountableOnThisMacBytes == (10 * Self.gib + 768 * Self.mib) * 3 / 4)
        #expect(anonymous.refusal?.contains("More file cache cannot change this") == true)
        // The same Mac with the cache merely active is told nothing of the kind.
        let active = try Mac.decide(Mac.observation(inactiveFileBackedBytes: 45 * Self.gib), required: 16 * Self.gib)
        #expect(!active.admitted && !active.structural && active.countedReclaimableBytes == 7 * Self.gib + 512 * Self.mib)
        #expect(active.refusal?.contains("More file cache cannot change this") == false)
        // An admitted decision is never structural.
        #expect(!(try Mac.decide(Mac.observation(), required: 16 * Self.gib).structural))

        // A 32 GiB Mac with 28 GiB pageable and 0.25 GiB free. A 4 GiB stage
        // (9 GiB required) is admitted with 5 GiB of anonymous memory and not
        // with 6; a 10 or 14 GiB stage is never admitted on cache, even with
        // no anonymous memory at all.
        let pageable = 28 * Self.gib / Self.page, free = 256 * Self.mib / Self.page
        func small(anonymousGiB: Int) -> QwenDenseStageLoadOSObservation {
            Mac.observation(anonymousGiB: anonymousGiB, physicalGiB: 32, pageablePages: pageable, activeGiB: 8,
                            fileBackedPages: pageable - free - anonymousGiB * Self.gib / Self.page)
        }
        #expect(try Mac.decide(small(anonymousGiB: 5), required: 9 * Self.gib).admitted)
        let six = try Mac.decide(small(anonymousGiB: 6), required: 9 * Self.gib)
        #expect(!six.admitted && six.structural)
        for required in [15, 19] {
            let never = try Mac.decide(small(anonymousGiB: 0), required: required * Self.gib)
            #expect(!never.admitted && never.structural && never.anonymousBytes == 0)
            #expect(never.refusal?.contains("More file cache cannot change this: with 0.00 GiB of anonymous memory in use") == true)
        }
    }

    // MARK: samples that are not judged

    @Test func aSampleWhoseFileBackedOrInactiveCountersDisagreeIsNotJudged() throws {
        // File-backed pages are on the active, inactive or speculative queue.
        let queued = Mac.pageablePages - 256 * Self.mib / Self.page
        _ = try Mac.decide(Mac.observation(fileBackedPages: queued), required: 0)
        #expect(throws: ProbeError.self) { _ = try Mac.decide(Mac.observation(fileBackedPages: queued + 1), required: 0) }
        // Speculative pages are one of those queues.
        _ = try Mac.decide(Mac.observation(speculativeBytes: Self.gib, fileBackedPages: queued), required: 0)
        // Inactive file-backed pages are among the file-backed and the inactive.
        let slack = QwenDenseStageLoadPolicy.counterSlackPages
        let inactive = queued - 32 * Self.gib / Self.page
        _ = try Mac.decide(Mac.observation(inactiveFileBackedBytes: (inactive + slack) * Self.page), required: 0)
        #expect(throws: ProbeError.self) {
            _ = try Mac.decide(Mac.observation(inactiveFileBackedBytes: (inactive + slack + 1) * Self.page), required: 0)
        }
        #expect(throws: ProbeError.self) {
            _ = try Mac.decide(Mac.observation(fileBackedGiB: 10, anonymousGiB: 97, inactiveFileBackedBytes: 11 * Self.gib), required: 0)
        }
        // Inactive anonymous pages are among the anonymous and the inactive.
        let anonymous = 27 * Self.gib / Self.page
        _ = try Mac.decide(Mac.observation(inactiveAnonymousPages: anonymous + slack), required: 0)
        #expect(throws: ProbeError.self) { _ = try Mac.decide(Mac.observation(inactiveAnonymousPages: anonymous + slack + 1), required: 0) }
        // Negative counters.
        #expect(throws: ProbeError.self) { _ = try Mac.decide(Mac.observation(inactiveFileBackedBytes: -Self.page), required: 0) }
        #expect(throws: ProbeError.self) { _ = try Mac.decide(Mac.observation(inactiveAnonymousPages: -1), required: 0) }
        #expect(throws: ProbeError.self) {
            _ = try Mac.decide(Mac.observation(compressedBytes: -(Mac.compressionPages + 1) * Self.page), required: 0)
        }
        #expect(throws: ProbeError.self) {
            _ = try Mac.decide(Mac.observation(swappedOutBytes: -(Mac.swapoutPages + 1) * Self.page), required: 0)
        }
    }

    // MARK: arithmetic boundaries

    @Test func speculativePagesBelongToThePageableSumAndAreNotFree() throws {
        // 27 GiB speculative: the kernel's sum is still 108 GiB and its
        // reserve 40 GiB. Dropping them from the sum would make it 30 GiB.
        let decision = try Mac.decide(Mac.observation(speculativeBytes: 27 * Self.gib), required: 0)
        #expect(decision.pageableBytes == 108 * Self.gib && decision.fileCacheReserveBytes == 40 * Self.gib)
        #expect(decision.speculativeBytes == 27 * Self.gib && decision.actualFreeBytes == 256 * Self.mib)
    }

    @Test func theReserveIsRoundedUpToAWholePage() throws {
        // 108 GiB is a multiple of 27 pages: no rounding.
        #expect(try Mac.decide(Mac.observation(), required: 0).fileCacheReserveBytes == 40 * Self.gib)
        // One page more makes the exact reserve 10/27 of a page larger.
        let pages = 40 * Self.gib / Self.page
        for extra in [1, 2, 3, 26] {
            let reserve = pages + (extra * 10 + 26) / 27
            let exactly = try Mac.decide(Mac.observation(pageablePages: Mac.pageablePages + extra, fileBackedPages: reserve), required: 0)
            #expect(exactly.fileCacheReserveBytes == reserve * Self.page && exactly.fileCacheAboveReserveBytes == 0)
            let above = try Mac.decide(Mac.observation(pageablePages: Mac.pageablePages + extra, fileBackedPages: reserve + 1), required: 0)
            #expect(above.fileCacheAboveReserveBytes == Self.page)
        }
        #expect(try Mac.decide(Mac.observation(pageablePages: Mac.pageablePages + 27), required: 0).fileCacheReserveBytes
            == 40 * Self.gib + 10 * Self.page)
    }

    @Test func aKernelMinimumEqualToTheComputedReserveChangesNothing() throws {
        let equal = try Mac.decide(Mac.observation(kernelMinimumGiB: 40), required: 0)
        #expect(equal.fileCacheReserveBytes == 40 * Self.gib && equal.kernelFileCacheMinimumBytes == 40 * Self.gib)
        #expect(equal.countedReclaimableBytes == 30 * Self.gib)
        // One GiB above the computed figure is used; one below is not.
        #expect(try Mac.decide(Mac.observation(kernelMinimumGiB: 41), required: 0).fileCacheReserveBytes == 41 * Self.gib)
        #expect(try Mac.decide(Mac.observation(kernelMinimumGiB: 39), required: 0).fileCacheReserveBytes == 40 * Self.gib)
    }

    @Test func aRequirementEqualToPhysicalMemoryIsJudgedNotDismissed() throws {
        let equal = try Mac.decide(Mac.observation(), required: 128 * Self.gib)
        #expect(!equal.admitted && equal.structural)
        #expect(equal.refusal?.hasPrefix("Test load needs 128.00 GiB of admissible memory and has 30.25 GiB") == true)
        let over = try Mac.decide(Mac.observation(), required: 128 * Self.gib + 1)
        #expect(over.refusal == "Test load needs 128.00 GiB, more than this Mac's 128.00 GiB")
        // A Mac whose every page is free admits a requirement equal to its memory.
        let empty = Mac.observation(freeBytes: 108 * Self.gib, fileBackedGiB: 0, anonymousGiB: 0, physicalGiB: 108, activeGiB: 0)
        #expect(try Mac.decide(empty, required: 108 * Self.gib).admitted)
        #expect(!(try Mac.decide(empty, required: 108 * Self.gib + 1).admitted))
    }

    // MARK: the record of one load or one request

    private static func refusal(_ body: () throws -> Bool) -> String? {
        do { _ = try body(); return nil } catch { return String(describing: error) }
    }

    @Test func aWatchCountsOneDecisionPerPassAndKeepsRefusalsAndSamplesItCouldNotJudge() throws {
        let list = QwenDenseStageLoadWatchList()
        let watch = QwenDenseStageLoadWatch("Test load", list: list)
        #expect(list.report().scopes.isEmpty && watch.summary.decisions == 0 && watch.summary.first == nil)
        #expect(try watch.admits(Mac.observation(freeBytes: 20 * Self.gib, fileBackedGiB: 60), bytes: 16 * Self.gib, now: Mac.now))
        #expect(list.report().scopes.count == 1 && !watch.summary.reclaimableUsedForAdmission)
        #expect(try watch.admits(Mac.observation(), bytes: 30 * Self.gib, now: Mac.now))
        #expect(try watch.admits(Mac.observation(freeBytes: 64 * Self.mib), bytes: 8 * Self.gib, now: Mac.now))
        // A refusal is thrown as the policy's sentence and kept.
        let refused = Self.refusal {
            try watch.admits(Mac.observation(fileBackedGiB: 50, anonymousGiB: 57), bytes: 16 * Self.gib, now: Mac.now)
        }
        #expect(refused?.hasPrefix("Test load needs 16.00 GiB of admissible memory and has 7.75 GiB") == true)
        // A sample the policy will not judge is thrown too, and noted apart.
        let unjudged = Self.refusal { try watch.admits(Mac.observation(pressure: 4), bytes: 0, now: Mac.now) }
        #expect(unjudged == "Invalid, stale or pressured selected-stage resource observation")
        let stale = Self.refusal { try watch.admits(Mac.observation(), bytes: 0, now: 1_000 + 1_000_000_001) }
        #expect(stale != nil)
        let summary = watch.summary
        #expect(summary.policy == QwenDenseStageLoadPolicy.identifier && summary.purpose == "Test load")
        #expect(summary.decisions == 4 && summary.refusals == 1 && summary.unjudged == 2)
        #expect(summary.lastUnjudged == "Invalid, stale or pressured selected-stage resource observation")
        #expect(summary.reclaimableUsedForAdmission && !summary.stoppedByCompressionOrSwap)
        #expect(summary.first?.actualFreeBytes == 20 * Self.gib)
        #expect(summary.tightest?.requiredBytes == 30 * Self.gib)
        #expect(summary.fewestFreePages?.actualFreeBytes == 64 * Self.mib)
        #expect(summary.lastRefusal?.admitted == false && summary.latest == summary.lastRefusal)
        #expect(summary.compressedSinceFirstSampleBytes == 0 && summary.swappedOutSinceFirstSampleBytes == 0)
        #expect(summary.line.hasPrefix("Test load: 4 decisions, 1 refused, 2 not judged, file cache counted, "
            + "compressed 0 MiB and swapped out 0 MiB since its first sample; last refusal: Test load needs 16.00 GiB"))
        // Still one entry in its list, and the record encodes with every counter.
        let report = list.report()
        #expect(report.scopes.count == 1 && report.troubled.count == 1 && report.lines == [summary.line])
        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        let scope = try #require((object["scopes"] as? [[String: Any]])?.first)
        #expect(object["entryChecks"] != nil && scope["decisions"] as? Int == 4 && scope["unjudged"] as? Int == 2)
        let tightest = try #require(scope["tightest"] as? [String: Any])
        for key in ["actualFreeBytes", "countedReclaimableBytes", "fileBackedBytes", "fileCacheReserveBytes",
                    "fileCacheBeforeAnonymousBytes", "countableFileCacheBytes", "inactiveFileBackedBytes",
                    "inactiveAnonymousBytes", "compressedSinceFirstSampleBytes", "swappedOutSinceFirstSampleBytes",
                    "stoppedByCompressionOrSwap", "structural", "largestCountableOnThisMacBytes",
                    "anonymousBytes", "inactiveBytes", "pressureLevel", "swapUsedBytes", "compressorBytes",
                    "reclaimableUsedForAdmission", "requiredBytes", "admissibleBytes"] {
            #expect(tightest[key] != nil, "missing \(key)")
        }
    }

    @Test func eachWatchComparesWithItsOwnFirstJudgedSample() throws {
        let watch = QwenDenseStageLoadWatch("Test load", list: nil)
        // A sample that could not be judged does not become the first sample.
        #expect(Self.refusal { try watch.admits(Mac.observation(pressure: 4), bytes: 0, now: Mac.now) } != nil)
        // The first judged sample: the lifetime counter already stands 1 GiB higher.
        #expect(try watch.admits(Mac.observation(compressedBytes: Self.gib), bytes: 16 * Self.gib, now: Mac.now))
        #expect(watch.summary.compressedSinceFirstSampleBytes == 0)
        // 512 MiB later it is at the limit; one page more and it stops.
        #expect(try watch.admits(Mac.observation(compressedBytes: Self.gib + 512 * Self.mib), bytes: 16 * Self.gib, now: Mac.now))
        #expect(watch.summary.compressedSinceFirstSampleBytes == 512 * Self.mib && !watch.summary.stoppedByCompressionOrSwap)
        let stopped = Self.refusal {
            try watch.admits(Mac.observation(compressedBytes: Self.gib + 512 * Self.mib + Self.page), bytes: 16 * Self.gib, now: Mac.now)
        }
        #expect(stopped?.contains("so the kernel is taking anonymous memory") == true)
        #expect(watch.summary.stoppedByCompressionOrSwap && watch.summary.refusals == 1 && watch.summary.decisions == 3)
        #expect(watch.summary.line.contains("stopped for that"))
        // It stays stopped: the growth is measured from the first sample.
        #expect(Self.refusal { try watch.admits(Mac.observation(compressedBytes: 3 * Self.gib), bytes: 16 * Self.gib, now: Mac.now) } != nil)
        // Another load that starts now has its own first sample and is admitted.
        let next = QwenDenseStageLoadWatch("Test load", list: nil)
        #expect(try next.admits(Mac.observation(compressedBytes: 3 * Self.gib), bytes: 16 * Self.gib, now: Mac.now))
        #expect(next.summary.compressedSinceFirstSampleBytes == 0 && !next.summary.stoppedByCompressionOrSwap)
        // An entry check compares with nothing.
        let entry = QwenDenseStageLoadWatch("Selected-stage loading", comparesWithFirstSample: false, list: nil)
        #expect(try entry.admits(Mac.observation(), bytes: 0, now: Mac.now))
        #expect(try entry.admits(Mac.observation(compressedBytes: 3 * Self.gib), bytes: 0, now: Mac.now))
        #expect(entry.summary.compressedSinceFirstSampleBytes == nil && entry.summary.decisions == 2)
    }

    @Test func theListKeepsOneRecordPerLoadOrRequestAndIsBounded() throws {
        let list = QwenDenseStageLoadWatchList()
        // A watch that never took a decision is not listed.
        _ = QwenDenseStageLoadWatch("Never asked", list: list)
        #expect(list.report().scopes.isEmpty)
        let capacity = QwenDenseStageLoadWatchList.capacity
        for index in 0..<(capacity + 6) {
            let watch = QwenDenseStageLoadWatch("Request \(index)", list: list)
            #expect(try watch.admits(Mac.observation(), bytes: 16 * Self.gib, now: Mac.now))
            #expect(try watch.admits(Mac.observation(), bytes: 16 * Self.gib, now: Mac.now))
        }
        let report = list.report()
        #expect(report.scopes.count == capacity && report.earlierScopesDropped == 6)
        #expect(report.scopes.first?.purpose == "Request 6" && report.scopes.last?.purpose == "Request \(capacity + 5)")
        #expect(report.scopes.allSatisfy { $0.decisions == 2 } && report.troubled.isEmpty)
        #expect(report.policy == QwenDenseStageLoadPolicy.identifier)
    }
}
