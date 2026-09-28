import Foundation

struct QwenDenseShortPairResourceDecision: Encodable {
    let policy = "registered_dense_short_pair_resources_v1", role = "sequentialStagePair"
    let progress: QwenDenseShortPairLoadProgress
    let remainingAllocationBytes: Int, hostAllowanceBytes: Int, forwardReserveBytes: Int
    let requiredActualFreeBytes: Int, requiredAllocatorBytes: Int
    let os: QwenDenseStageLoadOSObservation, native: QwenDenseStageLoadNativeObservation
    let reclaimableUsedForAdmission = false, wholeProcessMemorySafetyEstablished = false
    let forwardExecuted = false, reserveTermsAreOperationalPolicy = true
}

enum QwenDenseShortPairResourcePolicy {
    static func evaluate(budget: QwenDenseShortPairLoadBudget, progress: QwenDenseShortPairLoadProgress,
        os: QwenDenseStageLoadOSObservation, native: QwenDenseStageLoadNativeObservation, now: UInt64
    ) throws -> QwenDenseShortPairResourceDecision {
        try QwenDenseStageLoadPolicy.requireInitial(os, now: now)
        guard [native.activeBytes, native.cacheBytes, native.peakBytes].allSatisfy({ $0 >= 0 }),
              native.allocatorLimitBytes > 0, native.peakBytes >= native.activeBytes else {
            throw ProbeError("Invalid short pair allocator observation")
        }
        let r = try budget.remainingAllocationBytes(progress), h = try budget.hostAllowanceBytes(progress)
        let q = budget.forwardReserveBytes, sum = QwenLongPrefillCheckedBytes.sum
        let scratch = h == 0 ? 0 : CheckpointAlignedReadPlan.maximumScratchAllocationBytes
        let free = max(QwenDenseStageLoadPolicy.minimumActualFreeBytes,
            try sum([r, h, h, scratch, q, QwenDenseStageLoadPolicy.loadingHeadroomBytes]))
        let allocator = try sum([native.activeBytes, native.cacheBytes, r, h, q,
            QwenDenseStageLoadPolicy.allocatorHeadroomBytes])
        guard os.actualFreeBytes >= free, os.physicalMemoryBytes >= free,
              native.allocatorLimitBytes >= allocator else {
            throw ProbeError("Short pair exceeds current actual-free or allocator limits")
        }
        return .init(progress: progress, remainingAllocationBytes: r, hostAllowanceBytes: h,
            forwardReserveBytes: q, requiredActualFreeBytes: free, requiredAllocatorBytes: allocator,
            os: os, native: native)
    }
}
