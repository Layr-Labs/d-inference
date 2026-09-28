import Foundation

struct QwenDenseShortReferenceResourceDecision: Encodable {
    let policy = "registered_dense_short_full_reference_resources_v1", role = "fullReference"
    let ordinal: Int, remainingAllocationBytes: Int, forwardReserveBytes: Int
    let requiredActualFreeBytes: Int, requiredAllocatorBytes: Int
    let os: QwenDenseStageLoadOSObservation, native: QwenDenseStageLoadNativeObservation
    let reclaimableUsedForAdmission = false, wholeProcessMemorySafetyEstablished = false
    let forwardExecuted = false, reserveTermsAreOperationalPolicy = true
}

/// Pure predicates, never a load grant. The private full owner supplies live
/// observations and its exact actual-descriptor/short-request bound budget.
enum QwenDenseShortReferenceResourcePolicy {
    static func evaluate(budget: QwenDenseShortReferenceLoadBudget, ordinal: Int,
        os: QwenDenseStageLoadOSObservation, native: QwenDenseStageLoadNativeObservation, now: UInt64
    ) throws -> QwenDenseShortReferenceResourceDecision {
        try QwenDenseStageLoadPolicy.requireInitial(os, now: now)
        guard [native.activeBytes, native.cacheBytes, native.peakBytes].allSatisfy({ $0 >= 0 }),
              native.allocatorLimitBytes > 0, native.peakBytes >= native.activeBytes else {
            throw ProbeError("Invalid short full-reference native allocator observation")
        }
        let remaining = try budget.remainingAllocationBytes(after: ordinal)
        let host = ordinal == budget.tensors.count ? 0 : budget.largestHostTensorBytes
        let sum = QwenLongPrefillCheckedBytes.sum
        let freeRequired = max(QwenDenseStageLoadPolicy.minimumActualFreeBytes,
            try sum([remaining, host, host, budget.forwardReserveBytes, QwenDenseStageLoadPolicy.loadingHeadroomBytes]))
        let allocatorRequired = try sum([native.activeBytes, native.cacheBytes,
            remaining, host, budget.forwardReserveBytes, QwenDenseStageLoadPolicy.allocatorHeadroomBytes])
        guard os.actualFreeBytes >= freeRequired, os.physicalMemoryBytes >= freeRequired,
              native.allocatorLimitBytes >= allocatorRequired else {
            throw ProbeError("Short full-reference exceeds current actual-free or allocator limits")
        }
        return .init(ordinal: ordinal, remainingAllocationBytes: remaining,
            forwardReserveBytes: budget.forwardReserveBytes, requiredActualFreeBytes: freeRequired,
            requiredAllocatorBytes: allocatorRequired, os: os, native: native)
    }
}
