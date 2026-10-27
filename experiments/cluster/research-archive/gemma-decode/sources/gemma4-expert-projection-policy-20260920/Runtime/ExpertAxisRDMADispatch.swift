import Foundation
import MLX

/// Transfer adapter over the exact existing plan and weighted operator. It owns
/// no model/request lifetime, and never reduces rank-local weighted partials.
final class ExpertAxisRDMADispatch {
    let base: ExpertAxisPreparedDispatch
    let rank: Int
    private let originalOrder: MLXArray
    init(ownership: ExpertIDOwnership, selected: [[Int]], rank: Int, check: () throws -> Void) throws {
        guard ownership.rankCount == 2, (0...1).contains(rank) else { throw ExpertDispatchError.invalidRank }
        base = try .init(ownership: ownership, selectedGlobalIDs: selected, check: check)
        self.rank = rank
        originalOrder = MLXArray(try base.plan.reassemblyIndices(returnedByRank: base.plan.assignmentsByRank).map(UInt32.init))
        eval(originalOrder); try check()
    }
    func localUnweighted(_ input: MLXArray, bank: ExpertAxisBank) throws -> MLXArray? {
        guard bank.globalExpertIDs == base.ownership.globalIDsByRank[rank], bank.geometry.experts == 128,
              bank.geometry.hidden == 2816, bank.geometry.intermediate == 704, bank.geometry.metadataDType == .bfloat16,
              input.shape == [base.plan.tokenCount, 2816], input.dtype == .bfloat16 else {
            throw ProbeError("Expert RDMA local projection does not match its original assignment/bank")
        }
        return try base.localUnweighted(input, rank: rank, bank: bank)
    }
    func reassemble(_ outputs: [MLXArray?]) throws -> MLXArray {
        guard outputs.count == 2 else { throw ExpertDispatchError.invalidReturnedMapping }
        for rank in 0..<2 {
            let count = base.plan.assignmentCountsByRank[rank]
            if count == 0 {
                guard case .none = outputs[rank] else { throw ExpertDispatchError.invalidReturnedMapping }
            } else {
                guard let value = outputs[rank], value.shape == [count,2816], value.dtype == .bfloat16 else {
                    throw ExpertDispatchError.invalidReturnedMapping
                }
            }
        }
        let rows = outputs.compactMap { $0 }
        guard !rows.isEmpty else { throw ExpertDispatchError.invalidReturnedMapping }
        let joined = rows.count == 1 ? rows[0] : concatenated(rows, axis: 0)
        return joined.take(originalOrder, axis: 0).reshaped(base.plan.tokenCount, base.plan.topK, 2816)
    }
}
