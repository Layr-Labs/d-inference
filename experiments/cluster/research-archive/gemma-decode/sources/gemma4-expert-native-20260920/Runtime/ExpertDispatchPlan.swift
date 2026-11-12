import Foundation

/// Identifies one original router slot. No routing score is recomputed, cast,
/// normalized or included here; it remains in the original [token, topK] tensor.
struct ExpertAssignment: Equatable, Sendable {
    let originalIndex: Int
    let tokenIndex: Int
    let topKSlot: Int
    let globalExpertID: Int
    let rank: Int
    let localExpertID: Int
}

/// Reference/validation dispatch contract, not a GPU hot-path implementation.
/// Token-major slot order is retained within every rank queue. A future device
/// implementation must match this map without reading router tensors on the CPU.
struct ExpertDispatchPlan: Sendable {
    let tokenCount: Int
    let topK: Int
    let assignmentsByRank: [[ExpertAssignment]]
    let assignmentCountsByExpert: [Int]
    private let assignmentsInOriginalOrder: [ExpertAssignment]

    var assignmentCount: Int { assignmentsInOriginalOrder.count }
    var assignmentCountsByRank: [Int] { assignmentsByRank.map(\.count) }

    init(ownership: ExpertIDOwnership, selectedGlobalIDs: [[Int]], maxAssignments: Int) throws {
        guard maxAssignments > 0, let first = selectedGlobalIDs.first,
            !first.isEmpty, first.count <= ownership.expertCount
        else { throw ExpertDispatchError.invalidRoutes }
        let product = selectedGlobalIDs.count.multipliedReportingOverflow(by: first.count)
        guard !product.overflow, product.partialValue <= maxAssignments else {
            throw ExpertDispatchError.assignmentLimit
        }
        // Validate every row before constructing the dispatch arrays.
        for ids in selectedGlobalIDs {
            guard ids.count == first.count, Set(ids).count == ids.count,
                ids.allSatisfy({ $0 >= 0 && $0 < ownership.expertCount })
            else { throw ExpertDispatchError.invalidRoutes }
        }
        var byRank = [[ExpertAssignment]](repeating: [], count: ownership.rankCount)
        var original: [ExpertAssignment] = []
        original.reserveCapacity(product.partialValue)
        var counts = [Int](repeating: 0, count: ownership.expertCount)
        for (token, ids) in selectedGlobalIDs.enumerated() {
            for (slot, id) in ids.enumerated() {
                let address = try ownership.address(globalExpertID: id)
                let assignment = ExpertAssignment(originalIndex: original.count,
                    tokenIndex: token, topKSlot: slot, globalExpertID: id,
                    rank: address.rank, localExpertID: address.localExpertID)
                original.append(assignment)
                byRank[address.rank].append(assignment)
                counts[id] += 1
            }
        }
        self.tokenCount = selectedGlobalIDs.count
        self.topK = first.count
        self.assignmentsByRank = byRank
        self.assignmentCountsByExpert = counts
        self.assignmentsInOriginalOrder = original
    }

    /// Returns one gather index per original slot into rank-major concatenated
    /// returned outputs. Within-rank return order may change, but every slot
    /// must occur exactly once with its original expert/rank/local/token binding.
    /// Gather with this permutation before the existing weightedExpertSum; a
    /// reduction of rank partial sums is deliberately not represented here.
    func reassemblyIndices(returnedByRank: [[ExpertAssignment]]) throws -> [Int] {
        guard returnedByRank.count == assignmentsByRank.count else {
            throw ExpertDispatchError.invalidReturnedMapping
        }
        var count = 0
        for returned in returnedByRank {
            let next = count.addingReportingOverflow(returned.count)
            guard !next.overflow, next.partialValue <= assignmentCount else {
                throw ExpertDispatchError.invalidReturnedMapping
            }
            count = next.partialValue
        }
        guard count == assignmentCount else { throw ExpertDispatchError.invalidReturnedMapping }
        var permutation = [Int](repeating: -1, count: assignmentCount)
        var returnedIndex = 0
        for (rank, returned) in returnedByRank.enumerated() {
            for assignment in returned {
                guard assignment.rank == rank,
                    assignmentsInOriginalOrder.indices.contains(assignment.originalIndex),
                    assignmentsInOriginalOrder[assignment.originalIndex] == assignment,
                    permutation[assignment.originalIndex] == -1 else {
                    throw ExpertDispatchError.invalidReturnedMapping
                }
                permutation[assignment.originalIndex] = returnedIndex
                returnedIndex += 1
            }
        }
        guard permutation.allSatisfy({ $0 >= 0 }) else {
            throw ExpertDispatchError.invalidReturnedMapping
        }
        return permutation
    }
}
