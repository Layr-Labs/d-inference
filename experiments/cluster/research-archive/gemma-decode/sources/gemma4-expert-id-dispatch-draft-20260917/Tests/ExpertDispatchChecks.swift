import Foundation

private struct CheckFailure: Error { let message: String }
private func require(_ value: Bool, _ message: String) throws {
    guard value else { throw CheckFailure(message: message) }
}
private func refuses(_ error: ExpertDispatchError, _ body: () throws -> Void) throws {
    do { try body() } catch let actual as ExpertDispatchError {
        try require(actual == error, "wrong refusal: \(actual), expected \(error)")
        return
    }
    throw CheckFailure(message: "missing refusal: \(error)")
}

@main
enum ExpertDispatchChecks {
    static func main() throws {
        var groups: [String] = []
        func check(_ name: String, _ body: () throws -> Void) throws {
            try body(); groups.append(name)
        }
        let unequal = try ExpertIDOwnership(expertCount: 8,
            globalIDsByRank: [[0, 2, 3], [1, 4, 5, 6, 7]])
        try check("unequal_noncontiguous_axis_zero") {
            try require(unequal.expertRanges(rank: 0) == [0..<1, 2..<4], "rank0 ranges")
            try require(unequal.expertRanges(rank: 1) == [1..<2, 4..<8], "rank1 ranges")
            try require(unequal.address(globalExpertID: 3) == ExpertAddress(rank: 0, localExpertID: 2), "local ID")
            try require(unequal.address(globalExpertID: 4) == ExpertAddress(rank: 1, localExpertID: 1), "local ID")
        }
        try check("gemma_48_80_full_projection_shapes") {
            let plan = try ExpertIDOwnership(expertCount: 128,
                globalIDsByRank: [Array(0..<48), Array(48..<128)])
            for shape in [[128, 704, 352], [128, 704, 44], [128, 2816, 88], [128, 2816, 11]] {
                let a = try plan.selectedStoredShape(shape, rank: 0)
                let b = try plan.selectedStoredShape(shape, rank: 1)
                try require(a[0] + b[0] == shape[0], "expert-axis conservation")
                try require(Array(a.dropFirst()) == Array(shape.dropFirst()), "whole dot product")
                try require(Array(b.dropFirst()) == Array(shape.dropFirst()), "whole dot product")
            }
        }
        try check("ownership_gap_and_overlap_refused") {
            try refuses(.invalidOwnership) { _ = try ExpertIDOwnership(expertCount: 4, globalIDsByRank: [[0], [2, 3]]) }
            try refuses(.invalidOwnership) { _ = try ExpertIDOwnership(expertCount: 4, globalIDsByRank: [[0, 1], [1, 3]]) }
        }
        try check("ownership_empty_unsorted_duplicate_range_refused") {
            for ids in [[[0, 1, 2, 3], []], [[1, 0], [2, 3]], [[0, 0], [2, 3]], [[-1, 0], [2, 3]], [[0, 1], [2, 4]]] {
                try refuses(.invalidOwnership) { _ = try ExpertIDOwnership(expertCount: 4, globalIDsByRank: ids) }
            }
            try refuses(.invalidOwnership) { _ = try ExpertIDOwnership(expertCount: 0, globalIDsByRank: [[], []]) }
            try refuses(.invalidOwnership) { _ = try ExpertIDOwnership(expertCount: 4, globalIDsByRank: [[0, 1, 2, 3]]) }
        }
        try check("metadata_and_lookup_refusals") {
            try refuses(.invalidRank) { _ = try unequal.expertRanges(rank: 2) }
            try refuses(.invalidExpert) { _ = try unequal.address(globalExpertID: 8) }
            try refuses(.invalidExpert) { _ = try unequal.address(globalExpertID: -1) }
            for shape in [[8, 4], [7, 4, 8], [8, 0, 8], [8, 4, -1]] {
                try refuses(.invalidStoredShape) { _ = try unequal.selectedStoredShape(shape, rank: 0) }
            }
        }
        let routes = [[7, 0, 4, 2], [3, 1, 6, 5]]
        let dispatch = try ExpertDispatchPlan(ownership: unequal, selectedGlobalIDs: routes, maxAssignments: 8)
        try check("original_slot_mapping_and_histograms") {
            try require(dispatch.assignmentCountsByRank == [3, 5], "unequal actual work")
            try require(dispatch.assignmentCountsByExpert == Array(repeating: 1, count: 8), "histogram")
            try require(dispatch.assignmentsByRank[0].map(\.originalIndex) == [1, 3, 4], "stable local order")
            let item = dispatch.assignmentsByRank[0][2]
            try require(item.tokenIndex == 1 && item.topKSlot == 0 && item.globalExpertID == 3 && item.localExpertID == 2,
                "exact token/slot/global/local join")
        }
        try check("global_slot_reassembly_preserves_raw_weight_bits") {
            let returned = dispatch.assignmentsByRank.map { Array($0.reversed()) }
            let permutation = try dispatch.reassemblyIndices(returnedByRank: returned)
            let flattened = returned.flatMap { $0 }
            let originalSlots = permutation.map { flattened[$0].originalIndex }
            try require(originalSlots == Array(0..<8), "restored top-k order")
            // Bit payloads are opaque: no normalization, conversion or multiply.
            let weightBits: [UInt32] = [0x80000000, 0x3e000001, 0x3f000001, 0x3f800001,
                0x3a010203, 0x3b112233, 0x3c556677, 0x3d123456]
            let returnedBits = flattened.map { weightBits[$0.originalIndex] }
            try require(permutation.map { returnedBits[$0] } == weightBits, "weights unchanged")
        }
        try check("empty_local_work_is_valid") {
            let one = try ExpertDispatchPlan(ownership: unequal, selectedGlobalIDs: [[7, 1], [6, 4]], maxAssignments: 4)
            try require(one.assignmentCountsByRank == [0, 4], "all assignments can select one rank")
            try require(one.reassemblyIndices(returnedByRank: one.assignmentsByRank) == Array(0..<4), "empty rank return")
        }
        try check("same_expert_across_tokens_is_valid") {
            let repeated = try ExpertDispatchPlan(ownership: unequal, selectedGlobalIDs: [[0, 7], [0, 7]], maxAssignments: 4)
            try require(repeated.assignmentCountsByExpert[0] == 2 && repeated.assignmentCountsByExpert[7] == 2, "cross-token reuse")
        }
        try check("invalid_router_rows_refused") {
            for rows in [[], [[]], [[0, 0]], [[0, 8]], [[-1, 0]], [[0, 1], [2]]] {
                try refuses(.invalidRoutes) { _ = try ExpertDispatchPlan(ownership: unequal, selectedGlobalIDs: rows, maxAssignments: 16) }
            }
        }
        try check("explicit_assignment_bound") {
            try refuses(.assignmentLimit) { _ = try ExpertDispatchPlan(ownership: unequal, selectedGlobalIDs: routes, maxAssignments: 7) }
            try refuses(.invalidRoutes) { _ = try ExpertDispatchPlan(ownership: unequal, selectedGlobalIDs: routes, maxAssignments: 0) }
        }
        try check("missing_extra_duplicate_returns_refused") {
            var missing = dispatch.assignmentsByRank; missing[0].removeLast()
            try refuses(.invalidReturnedMapping) { _ = try dispatch.reassemblyIndices(returnedByRank: missing) }
            var extra = dispatch.assignmentsByRank; extra[0].append(extra[0][0])
            try refuses(.invalidReturnedMapping) { _ = try dispatch.reassemblyIndices(returnedByRank: extra) }
            var duplicate = dispatch.assignmentsByRank; duplicate[0][1] = duplicate[0][0]
            try refuses(.invalidReturnedMapping) { _ = try dispatch.reassemblyIndices(returnedByRank: duplicate) }
        }
        try check("wrong_rank_and_rank_count_refused") {
            var swapped = dispatch.assignmentsByRank
            let a = swapped[0][0]; swapped[0][0] = swapped[1][0]; swapped[1][0] = a
            try refuses(.invalidReturnedMapping) { _ = try dispatch.reassemblyIndices(returnedByRank: swapped) }
            try refuses(.invalidReturnedMapping) { _ = try dispatch.reassemblyIndices(returnedByRank: [dispatch.assignmentsByRank[0]]) }
        }
        try check("forged_local_global_token_slot_and_index_refused") {
            let a = dispatch.assignmentsByRank[0][0]
            let forged = [
                ExpertAssignment(originalIndex: a.originalIndex, tokenIndex: a.tokenIndex, topKSlot: a.topKSlot, globalExpertID: a.globalExpertID, rank: a.rank, localExpertID: a.localExpertID + 1),
                ExpertAssignment(originalIndex: a.originalIndex, tokenIndex: a.tokenIndex, topKSlot: a.topKSlot, globalExpertID: 3, rank: a.rank, localExpertID: a.localExpertID),
                ExpertAssignment(originalIndex: a.originalIndex, tokenIndex: 1, topKSlot: a.topKSlot, globalExpertID: a.globalExpertID, rank: a.rank, localExpertID: a.localExpertID),
                ExpertAssignment(originalIndex: a.originalIndex, tokenIndex: a.tokenIndex, topKSlot: 0, globalExpertID: a.globalExpertID, rank: a.rank, localExpertID: a.localExpertID),
                ExpertAssignment(originalIndex: -1, tokenIndex: a.tokenIndex, topKSlot: a.topKSlot, globalExpertID: a.globalExpertID, rank: a.rank, localExpertID: a.localExpertID),
                ExpertAssignment(originalIndex: 8, tokenIndex: a.tokenIndex, topKSlot: a.topKSlot, globalExpertID: a.globalExpertID, rank: a.rank, localExpertID: a.localExpertID)]
            for item in forged {
                var returned = dispatch.assignmentsByRank; returned[0][0] = item
                try refuses(.invalidReturnedMapping) { _ = try dispatch.reassemblyIndices(returnedByRank: returned) }
            }
        }
        try check("gemma_top8_noncontiguous_unequal_ownership") {
            let rank0 = (0..<128).filter { $0 % 3 == 0 }
            let rank1 = (0..<128).filter { $0 % 3 != 0 }
            let plan = try ExpertIDOwnership(expertCount: 128, globalIDsByRank: [rank0, rank1])
            let selected = [[127, 0, 63, 64, 3, 91, 18, 44], [1, 2, 4, 5, 7, 8, 10, 11]]
            let work = try ExpertDispatchPlan(ownership: plan, selectedGlobalIDs: selected, maxAssignments: 16)
            try require(work.assignmentCountsByRank == [4, 12], "actual skew is not expert-count ratio")
            let received = work.assignmentsByRank.map { $0.sorted { $0.localExpertID < $1.localExpertID } }
            let flat = received.flatMap { $0 }
            let permutation = try work.reassemblyIndices(returnedByRank: received)
            try require(permutation.map { flat[$0].globalExpertID } == selected.flatMap { $0 }, "top8 order")
        }
        try check("three_rank_contract_has_no_two_rank_assumption") {
            let plan = try ExpertIDOwnership(expertCount: 6, globalIDsByRank: [[0], [1, 3], [2, 4, 5]])
            let work = try ExpertDispatchPlan(ownership: plan, selectedGlobalIDs: [[5, 0, 3]], maxAssignments: 3)
            let flat = work.assignmentsByRank.flatMap { $0 }
            try require(work.reassemblyIndices(returnedByRank: work.assignmentsByRank).map { flat[$0].globalExpertID } == [5, 0, 3], "generic map")
        }
        let report: [String: Any] = ["schema": "expert_id_dispatch_foundation_checks_v1", "groups": groups,
            "passed": groups.count, "mlxExecuted": false, "nativeModelExecuted": false,
            "numericalQualification": false, "hardwareQualification": false]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
    }
}
