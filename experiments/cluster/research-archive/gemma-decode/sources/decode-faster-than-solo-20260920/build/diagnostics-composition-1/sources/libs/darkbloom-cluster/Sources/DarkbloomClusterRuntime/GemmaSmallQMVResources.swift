import Foundation
import MLX

/// Same fresh AC/low-power/thermal/pressure/zero-swap and 10 GiB floor as
/// the existing tiny MTP qualifier. The private primitive adds explicit native
/// and host 64 MiB bounds; it creates no model/request/transport owner.
final class GemmaSmallQMVResources {
    static let reserve = 64 * 1024 * 1024
    let baseline: Int, deadline: UInt64
    private(set) var observations = 0, minimumFree = Int.max, peakExtraActive = 0
    init(deadline: UInt64) { baseline = Memory.activeMemory; self.deadline = deadline }
    func admit(experts: Int, k: Int, n: Int, bits: Int, dtype: DType) throws {
        let sum = QwenLongPrefillCheckedBytes.sum
        let bound = QwenResidentResourceEnvironment.allocationBound
        let matrix = [experts*n*k*bits/8,experts*n*(k/64)*dtype.size,experts*n*(k/64)*dtype.size]
        // Two copies of EVERY matrix root cover initialization/contiguity.
        // Two input roots and eight output/conversion/host-readback worksets
        // cover both implementations without relying on last-use collection.
        let arrays = matrix + matrix + [24*k*4,24*k*4]
            + Array(repeating:24*n*4,count:8) + [24*4,4*1024*1024]
        let native = try sum(arrays.map { try bound($0) })
        let host = try sum(matrix + [24*k*4,8*24*n*4,4*1024*1024])
        guard native <= Self.reserve, host <= Self.reserve else {
            throw ProbeError("Small QMV fixture exceeds its explicit 64 MiB live bounds")
        }
    }
    func check(native: () throws -> Void) throws {
        try native()
        guard DispatchTime.now().uptimeNanoseconds < deadline else { throw ProbeError("Small QMV deadline expired") }
        let os = try QwenResidentResourceEnvironment.observe()
        let allocation = QwenDenseStageLoadResources.observeNative()
        guard os.pressureLevel == 1,
              os.actualFreeBytes >= 10*1024*1024*1024 + 2*Self.reserve,
              allocation.activeBytes >= baseline, allocation.activeBytes <= baseline+Self.reserve,
              allocation.cacheBytes == 0,
              try QwenLongPrefillCheckedBytes.sum([allocation.activeBytes,Self.reserve,2*1024*1024*1024])
                <= allocation.allocatorLimitBytes else {
            throw ProbeError("Small QMV actual-free/allocator/pressure admission refused")
        }
        observations += 1; minimumFree = min(minimumFree,os.actualFreeBytes)
        peakExtraActive = max(peakExtraActive,allocation.activeBytes-baseline)
        try native()
    }
}
