import Foundation
import MLX

/// Additive staging charge on the existing conservative full-reference+both-bank
/// diagnostic budget. Actual rank ownership is smaller; no discount is taken.
final class ExpertAxisRDMAResources {
    let base: ExpertAxisCheckResources
    static let extraNativeBytes = 16 * 1_048_576
    static let extraHostBytes = 16 * 1_048_576
    init(geometry: ExpertAxisGeometry, ownership: ExpertIDOwnership, deadline: UInt64) throws {
        base = try .init(geometry: geometry, ownership: ownership, deadline: deadline)
    }
    func check(native: () throws -> Void) throws {
        try base.check(native: native)
        let os = try QwenDenseStageLoadResources.requireInitial()
        let free = max(QwenDenseStageLoadPolicy.minimumActualFreeBytes,
            try QwenLongPrefillCheckedBytes.sum([base.reservedNativeBytes,base.hostReserveBytes,
                Self.extraNativeBytes,Self.extraHostBytes,QwenDenseStageLoadPolicy.loadingHeadroomBytes]))
        let nativeRequired = try QwenLongPrefillCheckedBytes.sum([Memory.activeMemory, Memory.cacheMemory,
            base.reservedNativeBytes, Self.extraNativeBytes, QwenDenseStageLoadPolicy.allocatorHeadroomBytes])
        guard os.actualFreeBytes >= free, os.pressureLevel == 1, Memory.cacheMemory == 0,
              Memory.memoryLimit >= nativeRequired else { throw ProbeError("Expert RDMA staging/free/cache bound refused") }
        try native()
    }
}
