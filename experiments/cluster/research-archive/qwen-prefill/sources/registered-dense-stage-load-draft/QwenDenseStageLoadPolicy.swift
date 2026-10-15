import Foundation

struct QwenDenseStageLoadOSObservation: Encodable {
    let startedNanoseconds: UInt64, completedNanoseconds: UInt64
    let timestampUTC: String
    let physicalMemoryBytes: Int, pageSizeBytes: Int
    let kernelFreePages: Int, freePages: Int, inactivePages: Int, speculativePages: Int
    let actualFreeBytes: Int, estimatedReclaimableBytes: Int
    let pressureLevel: Int, swapUsedBytes: Int
}

struct QwenDenseStageLoadNativeObservation: Encodable {
    let activeBytes: Int, cacheBytes: Int, peakBytes: Int, allocatorLimitBytes: Int
}

struct QwenDenseStageLoadResourceDecision: Encodable {
    let policy = "registered_dense_selected_stage_load_resources_v1"
    let ordinal: Int, remainingAllocationBytes: Int
    let requiredActualFreeBytes: Int, requiredAllocatorBytes: Int
    let os: QwenDenseStageLoadOSObservation
    let native: QwenDenseStageLoadNativeObservation
    let reclaimableUsedForAdmission = false, wholeProcessMemorySafetyEstablished = false
    let reserveTermsAreOperationalPolicy = true, forwardExecutionAuthorized = false
}

/// Pure decision checks. A passing caller-fabricated observation is not a grant;
/// only the private native gate samples current resources and permits reads.
enum QwenDenseStageLoadPolicy {
    static let gib = 1_073_741_824
    static let minimumActualFreeBytes = 6 * gib
    static let loadingHeadroomBytes = 4 * gib
    static let allocatorHeadroomBytes = 2 * gib
    static let maximumObservationAgeNanoseconds: UInt64 = 1_000_000_000

    static func requireInitial(_ os: QwenDenseStageLoadOSObservation, now: UInt64) throws {
        try validateOS(os, now: now)
        guard os.actualFreeBytes >= minimumActualFreeBytes else {
            throw ProbeError("Selected-stage loading requires at least 6 GiB actual free memory")
        }
    }

    static func evaluate(budget: QwenDenseStageLoadBudget, ordinal: Int,
        os: QwenDenseStageLoadOSObservation, native: QwenDenseStageLoadNativeObservation, now: UInt64
    ) throws -> QwenDenseStageLoadResourceDecision {
        try requireInitial(os, now: now)
        guard [native.activeBytes, native.cacheBytes, native.peakBytes].allSatisfy({ $0 >= 0 }),
              native.allocatorLimitBytes > 0, native.peakBytes >= native.activeBytes else {
            throw ProbeError("Invalid native allocator observation")
        }
        let remaining = try budget.remainingAllocationBytes(after: ordinal)
        let host = ordinal == budget.active.count ? 0 : budget.largestHostTensorBytes
        let sum = QwenLongPrefillCheckedBytes.sum
        let freeRequired = max(minimumActualFreeBytes, try sum([remaining, host, host, loadingHeadroomBytes]))
        let allocatorRequired = try sum([native.activeBytes, native.cacheBytes,
            remaining, host, allocatorHeadroomBytes])
        guard os.actualFreeBytes >= freeRequired, os.physicalMemoryBytes >= freeRequired,
              native.allocatorLimitBytes >= allocatorRequired else {
            throw ProbeError("Selected-stage loading exceeds current actual-free or allocator limits")
        }
        return .init(ordinal: ordinal, remainingAllocationBytes: remaining,
            requiredActualFreeBytes: freeRequired, requiredAllocatorBytes: allocatorRequired, os: os, native: native)
    }

    private static func validateOS(_ os: QwenDenseStageLoadOSObservation, now: UInt64) throws {
        guard os.startedNanoseconds <= os.completedNanoseconds, now >= os.completedNanoseconds,
              os.completedNanoseconds - os.startedNanoseconds <= maximumObservationAgeNanoseconds,
              now - os.completedNanoseconds <= maximumObservationAgeNanoseconds,
              os.physicalMemoryBytes > 0, os.pageSizeBytes > 0,
              [os.kernelFreePages, os.freePages, os.inactivePages, os.speculativePages, os.actualFreeBytes,
               os.estimatedReclaimableBytes, os.swapUsedBytes].allSatisfy({ $0 >= 0 }),
              (0...2).contains(os.pressureLevel), os.swapUsedBytes == 0 else {
            throw ProbeError("Invalid, stale, pressured or swapped selected-stage resource observation")
        }
        let free = try QwenLongPrefillCheckedBytes.product([os.freePages, os.pageSizeBytes])
        let pages = try QwenLongPrefillCheckedBytes.sum([os.freePages, os.inactivePages, os.speculativePages])
        let reclaimable = try QwenLongPrefillCheckedBytes.product([pages, os.pageSizeBytes])
        guard os.kernelFreePages == (try QwenLongPrefillCheckedBytes.sum([os.freePages, os.speculativePages])),
              os.actualFreeBytes == free, os.estimatedReclaimableBytes == reclaimable,
              free <= os.physicalMemoryBytes, reclaimable <= os.physicalMemoryBytes else {
            throw ProbeError("Selected-stage VM counter accounting differs")
        }
    }
}
