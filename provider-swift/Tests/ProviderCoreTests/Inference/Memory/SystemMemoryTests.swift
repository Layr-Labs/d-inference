import Foundation
import Testing
@testable import ProviderCore

private let cohostGiB: UInt64 = 1 << 30
private let machPageSize: UInt64 = 16_384

/// A Mach `HOST_VM_INFO64` sample from page counts. Pageable pages keep the
/// kernel's partition `active + inactive + speculative + throttled == internal
/// + external`, and `free_count` includes the speculative pages, as on macOS.
func machVMStatistics(
    freePages: UInt64, activePages: UInt64 = 0, inactivePages: UInt64 = 0,
    speculativePages: UInt64 = 0, wiredPages: UInt64 = 0, fileBackedPages: UInt64,
    purgeablePages: UInt64 = 0, compressorPages: UInt64 = 0
) -> vm_statistics64 {
    let pageable = activePages + inactivePages + speculativePages
    precondition(pageable >= fileBackedPages, "file-backed pages are pageable pages")
    var stats = vm_statistics64()
    stats.free_count = natural_t(freePages + speculativePages)
    stats.active_count = natural_t(activePages)
    stats.inactive_count = natural_t(inactivePages)
    stats.speculative_count = natural_t(speculativePages)
    stats.wire_count = natural_t(wiredPages)
    stats.external_page_count = natural_t(fileBackedPages)
    stats.internal_page_count = natural_t(pageable - fileBackedPages)
    stats.purgeable_count = natural_t(purgeablePages)
    stats.compressor_page_count = natural_t(compressorPages)
    return stats
}

/// `vm_stat` reports decimal gigabytes of 16 KiB pages.
private func pages(gb: Double) -> UInt64 { UInt64(gb * 1e9 / Double(machPageSize)) }

/// Host #1's refused GLM cold load: `vm_stat` free 2.4 GB, active 55.7 GB,
/// inactive 208.7 GB, wired 6.6 GB. `purge` left active 5.6 GB and inactive
/// 6.6 GB, so at most 12.2 GB was anonymous; everything else was page cache
/// from staging, verifying and hashing the downloaded weights.
private func hostOneSample(anonymousFileCache: Bool = false) -> vm_statistics64 {
    let active = pages(gb: 55.7), inactive = pages(gb: 208.7)
    return machVMStatistics(
        freePages: pages(gb: 2.4), activePages: active, inactivePages: inactive,
        wiredPages: pages(gb: 6.6),
        fileBackedPages: anonymousFileCache ? 0 : active + inactive - pages(gb: 12.2))
}

/// An M3 Ultra 256 GB shared with other agents' builds: much inactive
/// anonymous memory and little page cache. `darkbloom doctor` reported 93.0 GB
/// usable from the former measure and 77.6 GB from the page-cache measure
/// alone; these are the probe's counters at the former measure's sample.
private func busySharedMacSample() -> vm_statistics64 {
    machVMStatistics(
        freePages: 4_355_202 - 979_511, activePages: 3_998_965, inactivePages: 3_417_777,
        speculativePages: 979_511, wiredPages: 5_045_847, fileBackedPages: 3_171_130,
        purgeablePages: 215_327, compressorPages: 61_142)
}

/// `darkbloom status`: "178.9 GB model + 6.5 GB serving reserve = 185.4 GB
/// needed". The load reserve is the 256 GiB machine's 90 % cap hold-back.
private func usableGbOn256GiBMac(availablePages: UInt64) -> Double {
    let total = 256 * cohostGiB
    return ModelLoadAdmission.freeForLoadGb(
        totalBytes: total, systemAvailableBytes: availablePages * machPageSize,
        gpuActiveBytes: 0, gpuCacheBytes: 0,
        reserveBytes: UnifiedMemoryCap.loadReserveBytes(
            physicalBytes: total, configReserveBytes: 4 * cohostGiB))
}

private func admitsGLMColdLoad(availableBytes: UInt64) -> Bool {
    ModelLoadAdmission.canLoad(
        weightsGb: 178.9, headroomGb: 6.5, totalBytes: 256 * cohostGiB,
        systemAvailableBytes: availableBytes, gpuActiveBytes: 0, gpuCacheBytes: 0,
        reserveBytes: UnifiedMemoryCap.loadReserveBytes(
            physicalBytes: 256 * cohostGiB, configReserveBytes: 4 * cohostGiB))
}

private func reclaimableAvailablePages(_ stats: vm_statistics64) throws -> UInt64 {
    try #require(SystemMemory.availableBytes(
        stats: stats, pageSize: machPageSize, policy: .reclaimable)) / machPageSize
}

@Test func hostOnePageCacheNoLongerBlocksTheGLMColdLoad() throws {
    let sample = hostOneSample()
    // The former free + inactive measure reported 170.8 GB usable now against
    // 185.4 GB needed.
    let formerUsable = usableGbOn256GiBMac(availablePages: SystemMemory.freeAndInactivePages(sample))
    #expect(formerUsable > 170 && formerUsable < 172)
    #expect(formerUsable < 178.9 + 6.5)

    let pageCache = SystemMemory.freeAndPageCachePages(sample)
    #expect(pageCache == pages(gb: 2.4) + pages(gb: 55.7) + pages(gb: 208.7) - pages(gb: 12.2))
    let available = try reclaimableAvailablePages(sample)
    #expect(available == pageCache)
    #expect(usableGbOn256GiBMac(availablePages: available) >= 178.9 + 6.5)
    #expect(admitsGLMColdLoad(availableBytes: available * machPageSize))
}

@Test func busySharedMacIsNeverStricterThanBefore() throws {
    let sample = busySharedMacSample()
    let formerUsable = usableGbOn256GiBMac(availablePages: SystemMemory.freeAndInactivePages(sample))
    let pageCacheUsable = usableGbOn256GiBMac(
        availablePages: SystemMemory.freeAndPageCachePages(sample))
    #expect(abs(formerUsable - 93.0) < 0.05)
    #expect(abs(pageCacheUsable - 77.6) < 0.05)
    let available = try reclaimableAvailablePages(sample)
    #expect(usableGbOn256GiBMac(availablePages: available) == formerUsable)
}

@Test func anonymousMemoryStillRefusesTheGLMColdLoad() throws {
    // The same page counts held by process memory instead of page cache:
    // reclaiming it means compression or swap, so the page-cache measure gives
    // it no credit. Its inactive part still counts through the former measure,
    // exactly as before, and the load stays refused.
    let sample = hostOneSample(anonymousFileCache: true)
    #expect(SystemMemory.freeAndPageCachePages(sample) == pages(gb: 2.4))
    let available = try reclaimableAvailablePages(sample)
    #expect(available == SystemMemory.freeAndInactivePages(sample))
    #expect(!admitsGLMColdLoad(availableBytes: available * machPageSize))
}

@Test func compressedAndWiredMemoryEarnNoCredit() throws {
    let base = machVMStatistics(
        freePages: 1_000, activePages: 3_000, inactivePages: 6_000, fileBackedPages: 5_000)
    var pressured = base
    pressured.compressor_page_count = 400_000
    pressured.wire_count = 900_000
    pressured.total_uncompressed_pages_in_compressor = 1_200_000
    for stats in [base, pressured] {
        #expect(SystemMemory.freeAndPageCachePages(stats) == 1_000 + 5_000)
        #expect(SystemMemory.freeAndInactivePages(stats) == 1_000 + 6_000)
        let available = try reclaimableAvailablePages(stats)
        #expect(available == 1_000 + 6_000)
    }
}

@Test func reclaimableIsTheLargerMeasureAndNeverMore() throws {
    let samples = [
        hostOneSample(), hostOneSample(anonymousFileCache: true), busySharedMacSample(),
        machVMStatistics(freePages: 900, fileBackedPages: 0),
        machVMStatistics(freePages: 0, activePages: 700, inactivePages: 300, fileBackedPages: 0),
        machVMStatistics(freePages: 0, activePages: 700, inactivePages: 300, fileBackedPages: 1_000),
        machVMStatistics(
            freePages: 5, activePages: 20, inactivePages: 30, speculativePages: 9,
            fileBackedPages: 40, purgeablePages: 3, compressorPages: 70),
    ]
    for sample in samples {
        let former = SystemMemory.freeAndInactivePages(sample)
        let pageCache = SystemMemory.freeAndPageCachePages(sample)
        let available = try reclaimableAvailablePages(sample)
        #expect(available >= former && available >= pageCache)
        #expect(available == max(former, pageCache))
    }
}

@Test func reclaimableCountsPageCacheAndPurgeablePagesOnce() throws {
    // Speculative read-ahead pages are inside both free_count and the
    // file-backed count; they are counted once. Volatile purgeable pages are
    // anonymous but discarded without compression.
    let stats = machVMStatistics(
        freePages: 10, activePages: 40, inactivePages: 50, speculativePages: 7,
        fileBackedPages: 60, purgeablePages: 5)
    #expect(SystemMemory.freeAndPageCachePages(stats) == 10 + 60 + 5)
    #expect(SystemMemory.freeAndInactivePages(stats) == 10 + 7 + 50)
    for pageSize: UInt64 in [4096, 16384] {
        #expect(SystemMemory.availableBytes(stats: stats, pageSize: pageSize, policy: .reclaimable)
            == (10 + 60 + 5) * pageSize)
        #expect(SystemMemory.availableBytes(stats: stats, pageSize: pageSize, policy: .freeOnly)
            == (10 + 7) * pageSize)
    }
}

@Test func cohostReclaimablePagesCannotSatisfyFreeOnlyReserve() {
    let total = 512 * cohostGiB
    let reserve = UnifiedMemoryCap.loadReserveBytes(
        physicalBytes: total, configReserveBytes: 40 * cohostGiB)
    let stats = machVMStatistics(
        freePages: 11 * cohostGiB / machPageSize, inactivePages: 211 * cohostGiB / machPageSize,
        fileBackedPages: 211 * cohostGiB / machPageSize)
    for policy in [SystemMemory.AvailabilityPolicy.reclaimable, .freeOnly] {
        let available = SystemMemory.availableBytes(
            stats: stats, pageSize: machPageSize, policy: policy)!
        let admitted = ModelLoadAdmission.canLoad(
            weightsGb: 24, headroomGb: 6.5, totalBytes: total,
            systemAvailableBytes: available, gpuActiveBytes: 16 * cohostGiB,
            gpuCacheBytes: 0, reserveBytes: reserve)
        #expect(admitted == (policy == .reclaimable))
        if policy == .freeOnly {
            // Even potential eviction of our 16 GiB cannot spend the reserve.
            #expect(ModelLoadAdmission.maxLoadableWeightGb(
                totalBytes: total, systemAvailableBytes: available,
                mlxUsedBytes: 16 * cohostGiB, reserveBytes: reserve, headroomGb: 6.5) == 0)
            #expect(UnifiedMemoryCap.liveKVHeadroomBytes(
                physicalBytes: total, mlxUsedBytes: 16 * cohostGiB,
                systemAvailableBytes: available, configReserveBytes: reserve) < available)
        }
    }
}

@Test func freeOnlyAdmissionRecoversAfterActualRelease() {
    // A later sample sees real free memory after owned cache/model release.
    // No RSS estimate or reclaim credit is needed.
    let available = SystemMemory.availableBytes(
        stats: machVMStatistics(freePages: 100 * cohostGiB / 4096, fileBackedPages: 0),
        pageSize: 4096, policy: .freeOnly)!
    #expect(ModelLoadAdmission.canLoad(
        weightsGb: 24, headroomGb: 6.5, totalBytes: 512 * cohostGiB,
        systemAvailableBytes: available, gpuActiveBytes: 0, gpuCacheBytes: 0,
        reserveBytes: 52 * cohostGiB, outstandingReservationBytes: 10 * cohostGiB))
    #expect(!ModelLoadAdmission.canLoad(
        weightsGb: 24, headroomGb: 6.5, totalBytes: 512 * cohostGiB,
        systemAvailableBytes: available, gpuActiveBytes: 0, gpuCacheBytes: 0,
        reserveBytes: 52 * cohostGiB, outstandingReservationBytes: 20 * cohostGiB))
}

@Test func freeOnlySamplerFailsClosed() {
    let stats = machVMStatistics(freePages: 2, inactivePages: 100, fileBackedPages: 100)
    #expect(SystemMemory.availableBytes(stats: nil, pageSize: 4096, policy: .freeOnly) == 0)
    #expect(SystemMemory.availableBytes(stats: nil, pageSize: 4096, policy: .reclaimable) == nil)
    #expect(SystemMemory.availableBytes(stats: stats, pageSize: .max, policy: .freeOnly) == 0)
    #expect(SystemMemory.availableBytes(stats: stats, pageSize: .max, policy: .reclaimable) == .max)
    #expect(SystemMemory.availableBytes(stats: stats, pageSize: 0, policy: .freeOnly) == 0)
}

@Test func memoryAvailabilityPolicyDefaultsAndInvalidValues() {
    #expect(SystemMemory.AvailabilityPolicy.resolve(nil) == .reclaimable)
    #expect(SystemMemory.AvailabilityPolicy.resolve("reclaimable") == .reclaimable)
    #expect(SystemMemory.AvailabilityPolicy.resolve(" FREE-ONLY ") == .freeOnly)
    #expect(SystemMemory.AvailabilityPolicy.resolve("free-onyl") == .freeOnly)
    #expect(SystemMemory.AvailabilityPolicy.resolve("") == .freeOnly)
}

@Test func liveMemorySamplerUsesProcessStartPolicy() throws {
    let expected = SystemMemory.AvailabilityPolicy.resolve(
        ProcessInfo.processInfo.environment["DARKBLOOM_MEMORY_AVAILABILITY"])
    #expect(SystemMemory.availabilityPolicy == expected)
    let bytes = try #require(SystemMemory.availableBytes())
    #expect(bytes <= ProcessInfo.processInfo.physicalMemory)
}

@Test func livePageCountsKeepTheMachPartition() {
    // The sampler's double-count guard relies on this kernel invariant.
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &stats) { ptr in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
        }
    }
    #expect(result == KERN_SUCCESS)
    #expect(stats.free_count >= stats.speculative_count)
    let pageable = Int64(stats.active_count) + Int64(stats.inactive_count)
        + Int64(stats.speculative_count) + Int64(stats.throttled_count)
    let partition = Int64(stats.internal_page_count) + Int64(stats.external_page_count)
    // Counters are read without a global lock; allow in-flight transitions.
    #expect(abs(pageable - partition) <= 4_096)
}
