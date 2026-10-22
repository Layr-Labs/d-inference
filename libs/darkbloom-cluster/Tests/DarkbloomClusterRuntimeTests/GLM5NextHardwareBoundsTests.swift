import Foundation
import Testing
import DarkbloomClusterPlacement
@testable import DarkbloomClusterRuntime

/// Placement capacity is a property of the Mac, not of what other programs
/// or the file cache happen to hold when the snapshot is sampled.
@Suite("GLM placement bounds come from hardware, never cache or free memory")
struct GLM5NextHardwareBoundsTests {
    private let gib = 1 << 30

    private func profile(free: Int, fileBacked: Int, counted: Int, workingSet: Int) throws -> ClusterDeviceProfile {
        let physical = 128 * gib
        return try .init(chip: "synthetic", performanceCores: 1, efficiencyCores: 0, gpuCores: 1,
            osVersion: "test", osBuild: "test", physicalMemoryBytes: physical,
            gpuRecommendedWorkingSetBytes: workingSet, gpuMaximumBufferBytes: 1 << 30,
            allocatorLimitBytes: 120 * gib,
            memory: .init(gatePolicy: "synthetic", sampledUTC: "test", judged: true, unjudgedReason: nil,
                physicalMemoryBytes: physical, actualFreeBytes: free, countedFileCacheBytes: counted,
                admissibleNowBytes: free + counted, fileBackedBytes: fileBacked, fileCacheReserveBytes: 0,
                fileCacheAboveReserveBytes: fileBacked, anonymousBytes: 0, wiredBytes: 0, compressorBytes: 0,
                pageableBytes: physical / 2, pressureLevel: 0, swapUsedBytes: 0, minimumAdmissibleBytes: 1,
                minimumTrulyFreeBytes: 1, loadingHeadroomBytes: 4 * gib, allocatorHeadroomBytes: 2 * gib,
                loadScratchBytes: 1, pageSizeBytes: 16384),
            power: .init(onExternalPower: true, lowPowerMode: false, thermalState: "nominal"))
    }
    private func authorization() throws -> GLM5NextCalibration.Authorization {
        try .init(requestID: UUID(), nativeHardCapBytes: 200 * gib, hostBudgetBytes: 16 * gib,
            osHeadroomBytes: 8 * gib, workspaceNativeAllowanceBytes: 1 << 30, workspaceHostAllowanceBytes: 1 << 28,
            promptTokenIDs: [1, 2], outputCount: 2, chunkSize: 2)
    }

    @Test func freeAndFileCacheStateDoNotChangeBounds() throws {
        let busy = try GLM5NextAutomaticPlacement.currentDeviceBounds(
            profile: profile(free: 20 * gib, fileBacked: 60 * gib, counted: 4 * gib, workingSet: 107 * gib),
            authorization: authorization())
        let idle = try GLM5NextAutomaticPlacement.currentDeviceBounds(
            profile: profile(free: 110 * gib, fileBacked: 2 * gib, counted: 0, workingSet: 107 * gib),
            authorization: authorization())
        #expect(busy.native == idle.native && busy.host == idle.host && busy.combined == idle.combined)
        // Native is bounded by the GPU's resident capacity, not by the cap.
        #expect(busy.native <= 107 * gib && busy.native > 100 * gib)
        // Combined is physical memory less headroom.
        #expect(busy.combined == 120 * gib)
    }

    @Test func gpuResidentCapacityBoundsNative() throws {
        let small = try GLM5NextAutomaticPlacement.currentDeviceBounds(
            profile: profile(free: 110 * gib, fileBacked: 0, counted: 0, workingSet: 40 * gib),
            authorization: authorization())
        #expect(small.native <= 40 * gib)
    }
}
