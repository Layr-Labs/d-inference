import Foundation
import Testing
@testable import ProviderCore

private let cohostGiB: UInt64 = 1 << 30

@Test func cohostInactivePagesCannotSatisfyFreeOnlyReserve() {
    let pageSize: UInt64 = 16_384
    let total = 512 * cohostGiB
    let reserve = UnifiedMemoryCap.loadReserveBytes(
        physicalBytes: total, configReserveBytes: 40 * cohostGiB)
    for policy in [SystemMemory.AvailabilityPolicy.reclaimable, .freeOnly] {
        let available = SystemMemory.availableBytes(
            freePages: 11 * cohostGiB / pageSize,
            inactivePages: 211 * cohostGiB / pageSize,
            pageSize: pageSize, policy: policy)!
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
    // No RSS estimate or inactive-page credit is needed.
    let available = SystemMemory.availableBytes(
        freePages: 100 * cohostGiB / 4096, inactivePages: 0,
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
    #expect(SystemMemory.availableBytes(freePages: nil, inactivePages: 100,
        pageSize: 4096, policy: .freeOnly) == 0)
    #expect(SystemMemory.availableBytes(freePages: nil, inactivePages: 100,
        pageSize: 4096, policy: .reclaimable) == nil)
    #expect(SystemMemory.availableBytes(freePages: .max, inactivePages: 100,
        pageSize: 4096, policy: .freeOnly) == 0)
    #expect(SystemMemory.availableBytes(freePages: 1, inactivePages: 100,
        pageSize: 0, policy: .freeOnly) == 0)
}

@Test func freeOnlyCountsMachFreePagesOnce() {
    // Mach free_count already includes speculative pages: no extra credit.
    for pageSize: UInt64 in [4096, 16384] {
        #expect(SystemMemory.availableBytes(freePages: 10, inactivePages: 90,
            pageSize: pageSize, policy: .freeOnly) == 10 * pageSize)
        #expect(SystemMemory.availableBytes(freePages: 10, inactivePages: 90,
            pageSize: pageSize, policy: .reclaimable) == 100 * pageSize)
    }
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
