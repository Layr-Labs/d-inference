import Foundation
import MLX

/// Local one-layer qualification checks, not a serving capacity policy or a
/// replacement model owner. Root's process/lease/resource supervisor is required.
final class ExpertAxisCheckResources {
    let reservedNativeBytes: Int, hostReserveBytes: Int
    let deadline: UInt64
    private(set) var observations = 0, minimumFreeBytes = Int.max, maximumActiveBytes = 0

    init(geometry: ExpertAxisGeometry, ownership: ExpertIDOwnership, deadline: UInt64) throws {
        self.deadline = deadline
        var banks = 0, largestHost = 0
        for count in [geometry.experts] + ownership.globalIDsByRank.map(\.count) {
            for name in ExpertAxisGeometry.names {
                var shape = try geometry.shape(name); shape[0] = count
                let bytes = try QwenLongPrefillCheckedBytes.product(shape + [geometry.dtype(name).size])
                largestHost = max(largestHost, bytes)
                banks = try QwenLongPrefillCheckedBytes.sum([banks,
                    QwenResidentResourceEnvironment.allocationBound(bytes)])
            }
        }
        let assignments = 33 * 8
        let shapes = [
            [6, assignments, geometry.intermediate, 4], // both projection paths' GLU intermediates
            [8, assignments, geometry.hidden, 4], // inputs, outputs, reassembly and comparison copies
            [6, 33, geometry.hidden, 4], // residual, normalized, weighted and postnorm values
            [4, 33, geometry.experts, 4], // router logits/selection/normalization temporaries
        ]
        let arrays = try shapes.map { try QwenResidentResourceEnvironment.allocationBound(
            QwenLongPrefillCheckedBytes.product($0)) }
        // Each nonempty selected rank executes <= global assignments <=264.
        // Reserve an additional FULL padded local graph for every rank, even
        // when no padding is needed; do not subtract any original allowance.
        // Round each input/sorted-input/down/unsort, gate/up/activation and
        // token/index/sort tensor separately rather than rounding their sum.
        var paddingArrays: [Int] = []
        for _ in ownership.globalIDsByRank {
            let paddingShapes = Array(repeating: [assignments, geometry.hidden, 4], count: 4)
                + Array(repeating: [assignments, geometry.intermediate, 4], count: 3)
                + Array(repeating: [assignments, 4], count: 6)
            paddingArrays += try paddingShapes.map { try QwenResidentResourceEnvironment.allocationBound(
                QwenLongPrefillCheckedBytes.product($0)) }
        }
        // CPU padded records (six Int fields, plus concatenation temporary),
        // two UInt32 index-construction arrays and bounded policy bookkeeping.
        let paddingHost = try QwenLongPrefillCheckedBytes.sum([65_536,
            QwenLongPrefillCheckedBytes.product([ownership.rankCount, assignments,
                2 * MemoryLayout<ExpertAssignment>.stride + 2 * MemoryLayout<UInt32>.stride])])
        // Router/norm weights, index tensors and packet/reference structures are
        // small in this closed scope. These fixed diagnostic reserves do not
        // replace the unchanged 4 GiB graph/workspace and 2 GiB allocator guards.
        reservedNativeBytes = try QwenLongPrefillCheckedBytes.sum([banks, 16 * 1024 * 1024] + arrays + paddingArrays)
        hostReserveBytes = try QwenLongPrefillCheckedBytes.sum([largestHost, largestHost,
            CheckpointAlignedReadPlan.maximumScratchAllocationBytes, 16 * 1024 * 1024, paddingHost])
    }

    func check(native: () throws -> Void) throws {
        try native()
        guard DispatchTime.now().uptimeNanoseconds < deadline else { throw ProbeError("Expert check deadline expired") }
        try QwenResidentResourceEnvironment.require()
        let os = try QwenDenseStageLoadResources.requireInitial()
        guard os.pressureLevel == 1 else { throw ProbeError("Expert check requires normal pressure level1") }
        let freeRequired = max(QwenDenseStageLoadPolicy.minimumActualFreeBytes,
            try QwenLongPrefillCheckedBytes.sum([reservedNativeBytes, hostReserveBytes,
                QwenDenseStageLoadPolicy.loadingHeadroomBytes]))
        let allocatorRequired = try QwenLongPrefillCheckedBytes.sum([Memory.activeMemory, Memory.cacheMemory,
            reservedNativeBytes, QwenDenseStageLoadPolicy.allocatorHeadroomBytes])
        guard os.actualFreeBytes >= freeRequired, Memory.memoryLimit >= allocatorRequired else {
            throw ProbeError("Expert one-layer check exceeds current actual-free/allocator allowance")
        }
        observations += 1; minimumFreeBytes = min(minimumFreeBytes, os.actualFreeBytes)
        maximumActiveBytes = max(maximumActiveBytes, Memory.activeMemory)
        try native()
    }
}
