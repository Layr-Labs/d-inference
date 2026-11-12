import Foundation

/// Bounded global ownership, separate from any measured placement/capacity claim.
/// Arbitrary increasing IDs support contiguous48/80 and interleaved43/85 alike.
struct Gemma4ExpertPartition: Equatable, Sendable {
    let rank: Int
    let globalIDsByRank: [[Int]]
    var ownedIDs: [Int] { globalIDsByRank[rank] }
    var bindingText: String {
        "gemma4_expert_axis0_v1|128|8|30|\(rank)|" + globalIDsByRank.map {
            $0.map(String.init).joined(separator: ",")
        }.joined(separator: "|")
    }
    init(rank: Int, globalIDsByRank: [[Int]]) throws {
        guard globalIDsByRank.count == 2, (0...1).contains(rank),
              globalIDsByRank.allSatisfy({ (1...127).contains($0.count) }) else {
            throw ExpertDispatchError.invalidOwnership
        }
        _ = try ExpertIDOwnership(expertCount: 128, globalIDsByRank: globalIDsByRank)
        self.rank = rank; self.globalIDsByRank = globalIDsByRank
    }
    func ownership() throws -> ExpertIDOwnership {
        try .init(expertCount: 128, globalIDsByRank: globalIDsByRank)
    }
}
