import DarkbloomClusterPlacement
import Foundation

extension ClusterDeviceMemory {
    /// The host memory gate's own decision on one observation, as a planner
    /// carries it. Every number is the gate's: the decision record's fields
    /// and the policy's constants. A sample the gate would not judge is
    /// recorded as such, with its raw counters and no file cache counted.
    static func gate(_ os: QwenDenseStageLoadOSObservation, now: UInt64) -> ClusterDeviceMemory {
        func record(judged: Bool, reason: String?, physical: Int, free: Int, counted: Int, fileBacked: Int,
                    reserve: Int, above: Int, anonymous: Int, wired: Int, compressor: Int, pageable: Int) -> ClusterDeviceMemory {
            .init(gatePolicy: QwenDenseStageLoadPolicy.identifier, sampledUTC: os.timestampUTC, judged: judged,
                unjudgedReason: reason, physicalMemoryBytes: physical, actualFreeBytes: free,
                countedFileCacheBytes: counted, admissibleNowBytes: free + counted, fileBackedBytes: fileBacked,
                fileCacheReserveBytes: reserve, fileCacheAboveReserveBytes: above, anonymousBytes: anonymous, wiredBytes: wired, compressorBytes: compressor, pageableBytes: pageable,
                pressureLevel: max(0, os.pressureLevel), swapUsedBytes: max(0, os.swapUsedBytes),
                minimumAdmissibleBytes: QwenDenseStageLoadPolicy.minimumAdmissibleBytes,
                minimumTrulyFreeBytes: QwenDenseStageLoadPolicy.minimumTrulyFreeBytes,
                loadingHeadroomBytes: QwenDenseStageLoadPolicy.loadingHeadroomBytes,
                allocatorHeadroomBytes: QwenDenseStageLoadPolicy.allocatorHeadroomBytes,
                loadScratchBytes: CheckpointAlignedReadPlan.maximumScratchAllocationBytes,
                pageSizeBytes: min(1_048_576, max(1, os.pageSizeBytes)))
        }
        do {
            // The requirement enters the decision only through comparisons, so
            // the record of a zero requirement carries every other number.
            let d = try QwenDenseStageLoadPolicy.decide(os, requiredBytes: 0, purpose: "Placement profile", now: now)
            return record(judged: true, reason: nil, physical: d.physicalMemoryBytes, free: d.actualFreeBytes,
                counted: d.countedReclaimableBytes, fileBacked: d.fileBackedBytes, reserve: d.fileCacheReserveBytes,
                above: d.fileCacheAboveReserveBytes, anonymous: d.anonymousBytes,
                wired: d.wiredBytes, compressor: d.compressorBytes, pageable: min(d.pageableBytes, d.physicalMemoryBytes))
        } catch {
            let physical = max(1, os.physicalMemoryBytes)
            func bytes(_ pages: Int) -> Int {
                let (value, overflow) = max(0, pages).multipliedReportingOverflow(by: max(1, os.pageSizeBytes))
                return overflow ? physical : min(physical, value)
            }
            return record(judged: false, reason: String(String(describing: error).prefix(500)), physical: physical,
                free: min(physical, max(0, os.actualFreeBytes)), counted: 0, fileBacked: bytes(os.fileBackedPages),
                // Nothing is known to be above the kernel's minimum on a sample nobody judged.
                reserve: bytes(os.fileBackedPages), above: 0, anonymous: bytes(os.anonymousPages), wired: bytes(os.wiredPages), compressor: bytes(os.compressorPages),
                pageable: bytes(max(0, os.activePages) &+ max(0, os.inactivePages) &+ max(0, os.kernelFreePages)))
        }
    }
}
