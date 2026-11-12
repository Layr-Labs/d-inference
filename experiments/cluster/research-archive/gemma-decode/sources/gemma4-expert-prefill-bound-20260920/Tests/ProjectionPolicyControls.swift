import Foundation

@main enum ProjectionPolicyControls {
    static func require(_ value: Bool) throws {
        if !value { throw ProbeError("Projection policy control failed") }
    }
    static func refuse(_ body: () throws -> Void) throws {
        do { try body() } catch { return }
        throw ProbeError("Invalid projection policy was accepted")
    }
    static func main() throws {
        var groups = 0
        // Exact observed failed cases: force global sort AND the same RHS
        // route/alignment; merely sorting39 rows with10 experts is insufficient.
        for (global, owned, local, executed) in [(64,6,25,32), (64,10,39,64),
                                                (72,6,27,40), (72,10,45,72),
                                                (64,6,29,32), (64,10,35,64),
                                                (72,6,29,40), (72,10,43,72)] {
            let p = try ExpertAxisProjectionPolicy(globalAssignments: global, globalExperts: 16,
                ownedExperts: owned, localAssignments: local)
            try require(p.sortAssignments && p.sortedProjection && p.executedAssignments == executed
                        && executed / owned >= 4 && executed % 32 == global % 32)
        }; groups += 1
        for local in [0,1,21,35,56] {
            let p = try ExpertAxisProjectionPolicy(globalAssignments: 56, globalExperts: 16,
                ownedExperts: 6, localAssignments: local)
            try require(!p.sortAssignments && !p.sortedProjection && p.executedAssignments == local)
        }; groups += 1
        // Real Gemma <=33*8: sorted top-level rows must still retain the
        // full128-expert QMV route, even a local48-expert all-owned route.
        for global in [64,72,264] {
            let p = try ExpertAxisProjectionPolicy(globalAssignments: global, globalExperts: 128,
                ownedExperts: 48, localAssignments: global)
            try require(p.sortAssignments && !p.sortedProjection && p.paddedAssignments == 0)
        }; groups += 1
        let empty = try ExpertAxisProjectionPolicy(globalAssignments: 72, globalExperts: 16,
            ownedExperts: 10, localAssignments: 0)
        let emptyRows = try empty.padded([Int]())
        try require(empty.executedAssignments == 0 && emptyRows.isEmpty); groups += 1
        let p = try ExpertAxisProjectionPolicy(globalAssignments: 64, globalExperts: 16,
            ownedExperts: 6, localAssignments: 25)
        let original = Array(0..<25), padded = try p.padded(original)
        try require(padded.count == 32 && Array(padded.prefix(25)) == original
                    && padded.suffix(7).allSatisfy { $0 == 24 }); groups += 1
        try refuse { _ = try p.padded(Array(0..<24)) }; groups += 1
        try refuse { _ = try ExpertAxisProjectionPolicy(globalAssignments: 1025, globalExperts: 16,
            ownedExperts: 6, localAssignments: 25) }; groups += 1
        try refuse { _ = try ExpertAxisProjectionPolicy(globalAssignments: 64, globalExperts: 16,
            ownedExperts: 17, localAssignments: 25) }; groups += 1
        try refuse { _ = try ExpertAxisProjectionPolicy(globalAssignments: 64, globalExperts: 16,
            ownedExperts: 6, localAssignments: 65) }; groups += 1
        try refuse { _ = try ExpertAxisProjectionPolicy(globalAssignments: 128, globalExperts: 3,
            ownedExperts: 1, localAssignments: 100) }; groups += 1
        let dense = try ExpertAxisProjectionPolicy(globalAssignments: 264, globalExperts: 2,
            ownedExperts: 1, localAssignments: 1)
        try require(dense.executedAssignments == 72 && dense.sortedProjection); groups += 1
        let ownership = try ExpertIDOwnership(expertCount: 16,
            globalIDsByRank: [Array(0..<6), Array(6..<16)])
        let selected = (0..<8).map { row in (0..<8).map { (row*7+$0*3)%16 } }
        let plan = try ExpertDispatchPlan(ownership: ownership, selectedGlobalIDs: selected, maxAssignments: 264)
        let projected = try plan.assignmentsByRank.enumerated().map { rank, rows in
            try ExpertAxisProjectionPolicy(globalAssignments: 64, globalExperts: 16,
                ownedExperts: ownership.globalIDsByRank[rank].count, localAssignments: rows.count).padded(rows)
        }
        let restored = projected.enumerated().map { rank, rows in Array(rows.prefix(plan.assignmentCountsByRank[rank])) }
        let restoredOrder = try plan.reassemblyIndices(returnedByRank: restored)
        let originalOrder = try plan.reassemblyIndices(returnedByRank: plan.assignmentsByRank)
        try require(restoredOrder == originalOrder); groups += 1
        try refuse { _ = try plan.reassemblyIndices(returnedByRank: projected) }; groups += 1
        // Both admitted Gemma prefill widths cross the real E128 sorted-RHS
        // threshold. All-owned and empty cases keep the same kernel contract.
        for global in [512, 1024] {
            for owned in [43, 48, 80, 85] {
                for count in [0, 1, global / 3, global / 2, global] {
                    let policy = try ExpertAxisProjectionPolicy(globalAssignments: global, globalExperts: 128,
                        ownedExperts: owned, localAssignments: count)
                    try require(policy.sortAssignments && policy.sortedProjection)
                    let rows = Array(0..<count), expanded = try policy.padded(rows)
                    try require(Array(expanded.prefix(count)) == rows && expanded.count <= global)
                    if count == 0 { try require(expanded.isEmpty) }
                    else {
                        try require(expanded.count / owned >= 4 && expanded.count / owned < 64
                            && expanded.count % 32 == global % 32)
                        try require(expanded.dropFirst(count).allSatisfy { $0 == count - 1 })
                    }
                }
            }
        }; groups += 1
        for ids in [[Array(0..<48), Array(48..<128)],
                    [(0..<128).filter { $0 % 3 == 0 }, (0..<128).filter { $0 % 3 != 0 }]] {
            let ownership = try ExpertIDOwnership(expertCount: 128, globalIDsByRank: ids)
            for tokens in [64, 128] {
                let selected = (0..<tokens).map { row in (0..<8).map { (row * 7 + $0 * 3) % 128 } }
                let plan = try ExpertDispatchPlan(ownership: ownership, selectedGlobalIDs: selected,
                    maxAssignments: ExpertAxisQualificationLimits.maximumAssignments)
                let restored = try plan.assignmentsByRank.enumerated().map { rank, assignments in
                    let policy = try ExpertAxisProjectionPolicy(globalAssignments: tokens * 8, globalExperts: 128,
                        ownedExperts: ids[rank].count, localAssignments: assignments.count)
                    return Array(try policy.padded(assignments).prefix(assignments.count))
                }
                let order = try plan.reassemblyIndices(returnedByRank: restored)
                try require(order.map { restored.flatMap { $0 }[$0].globalExpertID } == selected.flatMap { $0 })
            }
        }; groups += 1
        try require(ExpertAxisQualificationLimits.cases(experts: 16) == [1,7,8,9,33]
            && ExpertAxisQualificationLimits.cases(experts: 128) == [1,7,8,9,33,64,128]
            && ExpertAxisQualificationLimits.maximumAssignments * 2816 * 2 == 5_767_168
            && 4 * 8_388_608 <= 32 * 1_048_576)
        groups += 1
        print("Expert projection policy: \(groups) Foundation groups passed; no native execution")
    }
}
