import Foundation
import MLX

typealias QwenResidentMemoryObserver = (QwenDenseStageLoadOSObservation, QwenResidentMemoryPages,
    Int, Int) throws -> Void

extension QwenResidentMemoryRecorder {
    /// The caller supplies the actual OS/requirements used by its existing
    /// successful gate. Snapshot is atomic under the allocator lock, but does
    /// not synchronize streams; OS and allocator reads are interval-bracketed.
    func observer(_ point: QwenResidentMemoryPoint, authorizedTensorCount: Int? = nil,
                  selectedTensorCount: Int? = nil) throws -> QwenResidentMemoryObserver? {
        let start = DispatchTime.now().uptimeNanoseconds
        guard try wants(point, now: start) else { return nil }
        return { os, pages, requiredFree, requiredAllocator in
            let native = Memory.snapshot()
            let limit = Memory.memoryLimit
            let end = DispatchTime.now().uptimeNanoseconds
            try self.append(.init(point: point, startedNanoseconds: start, completedNanoseconds: end,
                osStartedNanoseconds: os.startedNanoseconds, osCompletedNanoseconds: os.completedNanoseconds,
                physicalMemoryBytes: os.physicalMemoryBytes, pageSizeBytes: os.pageSizeBytes,
                kernelFreePages: os.kernelFreePages, freePages: os.freePages,
                inactivePages: os.inactivePages, speculativePages: os.speculativePages,
                actualFreeBytes: os.actualFreeBytes, estimatedReclaimableBytes: os.estimatedReclaimableBytes,
                pressureLevel: os.pressureLevel, swapUsedBytes: os.swapUsedBytes, pages: pages,
                activeBytes: native.activeMemory, cacheBytes: native.cacheMemory, peakBytes: native.peakMemory,
                allocatorLimitBytes: limit, requiredActualFreeBytes: requiredFree,
                requiredAllocatorBytes: requiredAllocator, authorizedTensorCount: authorizedTensorCount, selectedTensorCount: selectedTensorCount))
        }
    }
}
