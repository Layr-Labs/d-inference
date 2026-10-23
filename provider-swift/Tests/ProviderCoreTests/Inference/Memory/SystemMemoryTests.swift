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

/// `darkbloom status`: "178.9 GB model + 6.5 GB serving reserve = 185.4 GB
/// needed". The load reserve is the 256 GiB machine's 90 % cap hold-back.
private func hostOneLoadUsableGb(systemAvailableBytes: UInt64) -> Double {
    let total = 256 * cohostGiB
    return ModelLoadAdmission.freeForLoadGb(
        totalBytes: total, systemAvailableBytes: systemAvailableBytes,
        gpuActiveBytes: 0, gpuCacheBytes: 0,
        reserveBytes: UnifiedMemoryCap.loadReserveBytes(
            physicalBytes: total, configReserveBytes: 4 * cohostGiB))
}

@Test func hostOnePageCacheNoLongerBlocksTheGLMColdLoad() throws {
    let sample = hostOneSample()
    // The former policy counted free + inactive pages only: 170.8 GB was
    // reported usable now against 185.4 GB needed.
    let freeAndInactive = (UInt64(sample.free_count) + UInt64(sample.inactive_count)) * machPageSize
    let formerUsable = hostOneLoadUsableGb(systemAvailableBytes: freeAndInactive)
    #expect(formerUsable > 170 && formerUsable < 172)
    #expect(formerUsable < 178.9 + 6.5)

    let available = try #require(SystemMemory.availableBytes(
        stats: sample, pageSize: machPageSize, policy: .reclaimable))
    #expect(available == (pages(gb: 2.4) + pages(gb: 55.7) + pages(gb: 208.7) - pages(gb: 12.2))
        * machPageSize)
    let usable = hostOneLoadUsableGb(systemAvailableBytes: available)
    #expect(usable >= 178.9 + 6.5)
    #expect(ModelLoadAdmission.canLoad(
        weightsGb: 178.9, headroomGb: 6.5, totalBytes: 256 * cohostGiB,
        systemAvailableBytes: available, gpuActiveBytes: 0, gpuCacheBytes: 0,
        reserveBytes: UnifiedMemoryCap.loadReserveBytes(
            physicalBytes: 256 * cohostGiB, configReserveBytes: 4 * cohostGiB)))
}

@Test func anonymousMemoryStillRefusesTheGLMColdLoad() throws {
    // The same page counts held by process memory instead of page cache:
    // reclaiming it means compression or swap, so it earns no credit even
    // though most of it is inactive.
    let sample = hostOneSample(anonymousFileCache: true)
    let available = try #require(SystemMemory.availableBytes(
        stats: sample, pageSize: machPageSize, policy: .reclaimable))
    #expect(available == pages(gb: 2.4) * machPageSize)
    #expect(!ModelLoadAdmission.canLoad(
        weightsGb: 178.9, headroomGb: 6.5, totalBytes: 256 * cohostGiB,
        systemAvailableBytes: available, gpuActiveBytes: 0, gpuCacheBytes: 0,
        reserveBytes: UnifiedMemoryCap.loadReserveBytes(
            physicalBytes: 256 * cohostGiB, configReserveBytes: 4 * cohostGiB)))
}

@Test func compressedAndWiredMemoryEarnNoCredit() throws {
    let base = machVMStatistics(
        freePages: 1_000, activePages: 3_000, inactivePages: 6_000, fileBackedPages: 5_000)
    var pressured = base
    pressured.compressor_page_count = 400_000
    pressured.wire_count = 900_000
    pressured.total_uncompressed_pages_in_compressor = 1_200_000
    let expected = (1_000 + 5_000) * machPageSize
    #expect(SystemMemory.availableBytes(stats: base, pageSize: machPageSize, policy: .reclaimable)
        == expected)
    #expect(SystemMemory.availableBytes(stats: pressured, pageSize: machPageSize, policy: .reclaimable)
        == expected)
}

@Test func reclaimableCountsPageCacheAndPurgeablePagesOnce() {
    // Speculative read-ahead pages are inside both free_count and the
    // file-backed count; they are counted once. Volatile purgeable pages are
    // anonymous but discarded without compression.
    let stats = machVMStatistics(
        freePages: 10, activePages: 40, inactivePages: 50, speculativePages: 7,
        fileBackedPages: 60, purgeablePages: 5)
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
