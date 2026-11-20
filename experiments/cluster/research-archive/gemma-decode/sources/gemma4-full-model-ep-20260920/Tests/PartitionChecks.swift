import Foundation

@main struct PartitionChecks {
    static func main() throws {
        var groups = 0
        func require(_ condition: @autoclosure () -> Bool) throws {
            guard condition() else { throw CheckFailure.failed }
        }
        func refuses(_ body: () throws -> Void) throws {
            do { try body() } catch { return }
            throw CheckFailure.failed
        }
        let contiguous = [Array(0..<48), Array(48..<128)]
        let interleaved = [(0..<128).filter { $0 % 3 == 0 }, (0..<128).filter { $0 % 3 != 0 }]
        for map in [contiguous, interleaved] {
            let rank0 = try Gemma4ExpertPartition(rank: 0, globalIDsByRank: map)
            let rank1 = try Gemma4ExpertPartition(rank: 1, globalIDsByRank: map)
            try require(rank0.ownedIDs.count + rank1.ownedIDs.count == 128)
            try require(rank0 != rank1 && rank0.bindingText != rank1.bindingText)
            let ownership = try rank0.ownership()
            for id in 0..<128 {
                let address = try ownership.address(globalExpertID: id)
                try require(map[address.rank][address.localExpertID] == id)
            }
            groups += 1
            for count in [1, 33, 64, 128] {
                let routes = (0..<count).map { token in (0..<8).map { (token * 13 + $0 * 7) % 128 } }
                let plan = try ExpertDispatchPlan(ownership: ownership, selectedGlobalIDs: routes, maxAssignments: 1024)
                let permutation = try plan.reassemblyIndices(returnedByRank: plan.assignmentsByRank)
                let rankMajor = plan.assignmentsByRank.flatMap { $0 }
                for index in 0..<(count * 8) {
                    let assignment = rankMajor[permutation[index]]
                    try require(assignment.tokenIndex == index / 8 && assignment.topKSlot == index % 8)
                    try require(assignment.globalExpertID == routes[index / 8][index % 8])
                }
            }
            groups += 1
        }
        try require(interleaved.map(\.count) == [43,85]); groups += 1
        for rank in [-1,2] { try refuses { _ = try Gemma4ExpertPartition(rank: rank, globalIDsByRank: contiguous) } }; groups += 1
        for invalid in [[[Int]](), [Array(0..<128)], [[], Array(0..<128)],
                        [Array(0..<48), Array(47..<127)], [Array(0..<48), Array(49..<128)],
                        [Array((0..<48).reversed()), Array(48..<128)],
                        [Array(0..<48), Array(48..<127) + [128]]] {
            try refuses { _ = try Gemma4ExpertPartition(rank: 0, globalIDsByRank: invalid) }
        }; groups += 1
        let ownership = try Gemma4ExpertPartition(rank: 0, globalIDsByRank: contiguous).ownership()
        try refuses { _ = try ExpertDispatchPlan(ownership: ownership,
            selectedGlobalIDs: [[0,0,2,3,4,5,6,7]], maxAssignments: 1024) }; groups += 1
        let routes = (0..<129).map { _ in Array(0..<8) }
        try refuses { _ = try ExpertDispatchPlan(ownership: ownership,
            selectedGlobalIDs: routes, maxAssignments: 1024) }; groups += 1
        let plan = try ExpertDispatchPlan(ownership: ownership,
            selectedGlobalIDs: [[49,0,100,1,127,2,50,3]], maxAssignments: 1024)
        var returned = plan.assignmentsByRank
        returned[1][0] = returned[1][1]
        try refuses { _ = try plan.reassemblyIndices(returnedByRank: returned) }; groups += 1
        print("PASS \(groups) Gemma expert partition/slot groups (Foundation only)")
    }
    enum CheckFailure: Error { case failed }
}
