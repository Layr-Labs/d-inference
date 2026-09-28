import Foundation
import MLX
import MLXLMCommon

/// Native execution of an already authoritative, bounded assignment packet.
/// Dynamic router-to-packet production is intentionally outside this primitive.
final class ExpertAxisPreparedDispatch {
    let ownership: ExpertIDOwnership
    let plan: ExpertDispatchPlan
    let globalIDs: MLXArray
    private let tokenRows: [MLXArray?]
    private let localIDs: [MLXArray?]
    private let originalOrder: MLXArray

    init(ownership: ExpertIDOwnership, selectedGlobalIDs: [[Int]], check: () throws -> Void) throws {
        guard selectedGlobalIDs.count <= 33, (selectedGlobalIDs.first?.count ?? 0) <= 8 else {
            throw ProbeError("Expert-axis primitive requires at most33 tokens and top8")
        }
        let plan = try ExpertDispatchPlan(ownership: ownership, selectedGlobalIDs: selectedGlobalIDs,
            maxAssignments: 33 * 8)
        let permutation = try plan.reassemblyIndices(returnedByRank: plan.assignmentsByRank)
        self.ownership = ownership; self.plan = plan
        self.globalIDs = MLXArray(selectedGlobalIDs.flatMap { $0 }.map(UInt32.init))
            .reshaped(plan.tokenCount, plan.topK)
        self.tokenRows = plan.assignmentsByRank.map { rows in
            rows.isEmpty ? nil : MLXArray(rows.map { UInt32($0.tokenIndex) })
        }
        self.localIDs = plan.assignmentsByRank.map { rows in
            rows.isEmpty ? nil : MLXArray(rows.map { UInt32($0.localExpertID) }).reshaped(rows.count, 1)
        }
        self.originalOrder = MLXArray(permutation.map(UInt32.init))
        try check()
        eval([globalIDs, originalOrder] + tokenRows.compactMap { $0 } + localIDs.compactMap { $0 })
        try check()
    }

    /// Empty ranks perform no expert projection; all returned rows are unweighted.
    func unweighted(_ input: MLXArray, banks: [ExpertAxisBank]) throws -> MLXArray {
        guard banks.count == ownership.rankCount, input.ndim == 2, input.dim(0) == plan.tokenCount,
              banks.indices.allSatisfy({ banks[$0].globalExpertIDs == ownership.globalIDsByRank[$0]
                && banks[$0].geometry.experts == ownership.expertCount
                && banks[$0].geometry.hidden == input.dim(1)
                && banks[$0].geometry.intermediate == banks[0].geometry.intermediate
                && banks[$0].geometry.metadataDType == banks[0].geometry.metadataDType }) else {
            throw ProbeError("Expert-axis dispatch differs from its owned banks")
        }
        var outputs: [MLXArray] = []
        for rank in banks.indices {
            guard let rows = tokenRows[rank], let ids = localIDs[rank] else { continue }
            outputs.append(try banks[rank].project(input.take(rows, axis: 0), localIDs: ids))
        }
        guard !outputs.isEmpty else { throw ProbeError("Expert-axis dispatch has no output") }
        let joined = outputs.count == 1 ? outputs[0] : concatenated(outputs, axis: 0)
        return joined.take(originalOrder, axis: 0).reshaped(plan.tokenCount, plan.topK, input.dim(1))
    }

    func weighted(_ outputs: MLXArray, weights: MLXArray) throws -> MLXArray {
        guard outputs.ndim == 3, outputs.dim(0) == plan.tokenCount, outputs.dim(1) == plan.topK,
              weights.shape == [plan.tokenCount, plan.topK], weights.dtype == outputs.dtype else {
            throw ProbeError("Expert-axis weighted reduction geometry/dtype differs")
        }
        // Exactly the stock compiled operator; do not replace with rank sums.
        return weightedExpertSum(outputs, weights)
    }
}
