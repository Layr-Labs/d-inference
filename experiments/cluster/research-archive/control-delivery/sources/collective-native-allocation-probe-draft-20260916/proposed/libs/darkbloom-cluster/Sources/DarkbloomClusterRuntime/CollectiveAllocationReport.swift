#if COLLECTIVE_RECORD_ALLOCATION_CHECK
import Foundation
import MLX

struct CollectiveAllocationReport: Encodable {
    struct Geometry: Encodable { let id: String; let shape: [Int]; let dtype: String; let plaintextBytes: Int; let nativeArrayBoundBytes: Int; let nativeFrameBoundBytes: Int }
    let schema = "collective_native_allocation_probe_v1"
    let scope = "both codec endpoints plus native staging in one process; no RDMA/group/model"
    let profileQualified = false
    let caseID: String
    let failureMode: String
    let hardwareModel: String
    let osBuild: String
    let suite = "aes256GcmHkdfSha256V1"
    let allocatorPolicy = "disable_freed_buffer_cache"
    let maximumPlaintextBytes = CollectiveAllocationCase.maximumPlaintextBytes
    let maximumFrameBytes = CollectiveAllocationCase.maximumFrameBytes
    let maximumInFlightOperations = 1
    let rounds: Int
    let geometries: [Geometry]
    let elapsedNanoseconds: UInt64
    let baselineNativeActiveBytes: Int
    let observedPeakNativeActiveBytes: Int
    let maximumObservedNativeCacheBytes: Int
    let finalNativeActiveBytes: Int
    let finalNativeCacheBytes: Int
    let baselinePhysical: CollectiveAllocationFootprint
    let finalPhysical: CollectiveAllocationFootprint
    let conservativeObservedPhysicalIncrementBytes: UInt64
    let sentRecords: UInt64
    let openedRecords: UInt64
    let publishedArrays: Int
    let refusedRecords: Int
    let frameLengths: [Int]
    let plaintextByteCounts: [Int]
    let actualInputByteCounts: [Int]
    let attemptedNativeShapes: [[Int]]
    let attemptedNativeDTypes: [String]
    let primingOperations: Int
    let unauthenticatedArraysPublished = 0
    let verifiedPlaintextDigests: [String]
    let senderActiveBeforeCleanup: Bool
    let receiverActiveBeforeCleanup: Bool
    let allTrackedNativeArraysReleased = true
    let nativeAllocationsReturnedToBaseline = true

    init(test: CollectiveAllocationCase, result: CollectiveAllocationExecution, baselineNative: Memory.Snapshot,
         beforeCleanup: Memory.Snapshot, finalNative: Memory.Snapshot, baselinePhysical: CollectiveAllocationFootprint,
         finalPhysical: CollectiveAllocationFootprint, elapsedNanoseconds: UInt64, hardware: String, osBuild: String) throws {
        caseID = test.id; failureMode = test.failure.rawValue; hardwareModel = hardware; self.osBuild = osBuild
        rounds = test.rounds; primingOperations = test.priming.count
        geometries = try test.geometries.map { geometry in
            let actual = try CollectivePointToPointShape(shape: geometry.shape, dtype: geometry.dtype,
                maximumBytes: CollectiveAllocationCase.maximumPlaintextBytes)
            guard geometry.bytes == actual.byteCount else { throw ProbeError("Probe geometry byte derivation differs") }
            let bounds = try CollectiveProtectedOperationBounds(shape: geometry.shape, dtype: geometry.dtype,
                maximumPlaintextBytes: CollectiveAllocationCase.maximumPlaintextBytes,
                maximumFrameBytes: CollectiveAllocationCase.maximumFrameBytes)
            return Geometry(id: geometry.id, shape: geometry.shape, dtype: String(describing: geometry.dtype),
                plaintextBytes: actual.byteCount, nativeArrayBoundBytes: bounds.nativePlaintextAllocationBytes,
                nativeFrameBoundBytes: bounds.nativeFrameAllocationBytes)
        }
        self.elapsedNanoseconds = elapsedNanoseconds
        baselineNativeActiveBytes = baselineNative.activeMemory
        observedPeakNativeActiveBytes = max(beforeCleanup.peakMemory, finalNative.peakMemory)
        maximumObservedNativeCacheBytes = max(baselineNative.cacheMemory, beforeCleanup.cacheMemory, finalNative.cacheMemory)
        finalNativeActiveBytes = finalNative.activeMemory; finalNativeCacheBytes = finalNative.cacheMemory
        self.baselinePhysical = baselinePhysical; self.finalPhysical = finalPhysical
        conservativeObservedPhysicalIncrementBytes = finalPhysical.lifetimeMaximumBytes > baselinePhysical.currentBytes
            ? finalPhysical.lifetimeMaximumBytes - baselinePhysical.currentBytes : 0
        sentRecords = result.sentRecords; openedRecords = result.openedRecords
        publishedArrays = result.publishedArrays; refusedRecords = result.refusedRecords; frameLengths = result.frameLengths
        plaintextByteCounts = result.expectedPlaintextBytes; actualInputByteCounts = result.actualInputByteCounts
        attemptedNativeShapes = result.attemptedShapes; attemptedNativeDTypes = result.attemptedDTypes
        verifiedPlaintextDigests = result.verifiedPlaintextDigests
        senderActiveBeforeCleanup = result.senderActiveBeforeCleanup; receiverActiveBeforeCleanup = result.receiverActiveBeforeCleanup
    }
}
#endif
