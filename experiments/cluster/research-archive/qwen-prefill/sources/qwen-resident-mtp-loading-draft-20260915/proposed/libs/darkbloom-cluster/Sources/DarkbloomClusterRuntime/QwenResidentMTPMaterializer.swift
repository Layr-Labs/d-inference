import Foundation
import MLX

/// Ordered extra-payload reader. Current active arrays are observed through
/// MLX; only the not-yet-read bounds remain in this additional load reserve.
final class QwenResidentMTPMaterializer {
    let source: PreparedQwenResidentMTPSource
    private var progress: QwenResidentMTPReadProgress
    private(set) var loadedBytes = 0
    private(set) var accounting = CheckpointAlignedReadAccounting()
    init(source: PreparedQwenResidentMTPSource) {
        self.source = source
        progress = .init(placement: source.placement, resources: source.resources)
    }

    private func observe() throws {
        let pending = try progress.pending()
        try QwenResidentResourceEnvironment.require()
        let remaining = pending.tensorBytes, host = pending.hostBytes
        let scratch = host == 0 ? 0 : CheckpointAlignedReadPlan.maximumScratchAllocationBytes
        let required = max(QwenDenseStageLoadPolicy.minimumActualFreeBytes,
            try QwenLongPrefillCheckedBytes.sum([remaining, host, host, scratch, QwenDenseStageLoadPolicy.loadingHeadroomBytes]))
        let allocator = try QwenLongPrefillCheckedBytes.sum([Memory.activeMemory, Memory.cacheMemory,
            remaining, host, QwenDenseStageLoadPolicy.allocatorHeadroomBytes])
        let os = try QwenDenseStageLoadResources.requireInitial()
        guard os.actualFreeBytes >= required, Memory.memoryLimit >= allocator else {
            throw ProbeError("MTP storage exceeds actual-free or allocator policy")
        }
    }

    func read(_ name: String, shape: [Int], packed: Bool, check: () throws -> Void) throws -> MLXArray {
        do {
            let entry = try progress.entry(name: name, shape: shape, packed: packed)
            guard let descriptor = source.descriptors[name] else { throw ProbeError("MTP descriptor disappeared") }
            try check(); try observe()
            let value = try descriptor.read(.all)
            eval(value.array); Stream.gpu.synchronize(); try check()
            guard value.array.shape == shape, value.array.dtype == descriptor.dtype,
                  value.array.nbytes == entry.byteCount, value.copiedBytes == entry.byteCount,
                  let info = try value.array.evaluatedBufferInfo(), info.isUnique,
                  info.dataOffset == 0, info.isRowContiguous, info.dataElements == value.array.size,
                  info.allocatedBytes >= value.array.nbytes,
                  info.allocatedBytes <= source.resources.tensorBounds[progress.completed],
                  let read = value.readAccounting, read.selectedBytes == value.copiedBytes else {
                throw ProbeError("MTP tensor is not an exact independently owned selected allocation")
            }
            try accounting.merge(read)
            loadedBytes = try QwenLongPrefillCheckedBytes.sum([loadedBytes, value.copiedBytes])
            try progress.accept(copiedBytes: value.copiedBytes)
            try observe(); try check()
            return value.array
        } catch { progress.poison(); throw error }
    }

    func finish() throws {
        do {
            try progress.requireComplete()
            guard loadedBytes == source.placement.additionalTensorBytes,
                  accounting.selectedBytes == loadedBytes else {
                throw ProbeError("MTP selected loading did not complete")
            }
            try source.target.source.prepared.checkpoint.checkUnchanged()
            try observe()
        } catch {
            progress.poison(); throw error
        }
    }
}
