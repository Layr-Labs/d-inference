import Foundation

enum ExpertDispatchError: Error, Equatable {
    case invalidOwnership
    case invalidRank
    case invalidExpert
    case invalidStoredShape
    case invalidRoutes
    case assignmentLimit
    case invalidReturnedMapping
}

struct ExpertAddress: Equatable, Sendable {
    let rank: Int
    let localExpertID: Int
}

/// Pure ownership metadata, independent of MLX, model activation or admission.
/// Local expert IDs follow increasing global IDs so axis-0 materialization and
/// dispatch agree. The caller supplies an already bounded metadata packet.
struct ExpertIDOwnership: Sendable {
    let expertCount: Int
    let globalIDsByRank: [[Int]]
    private let addressByGlobalID: [ExpertAddress]

    var rankCount: Int { globalIDsByRank.count }

    init(expertCount: Int, globalIDsByRank: [[Int]]) throws {
        guard expertCount > 0, UInt64(expertCount) <= UInt64(UInt32.max),
            globalIDsByRank.count >= 2, globalIDsByRank.count <= expertCount
        else { throw ExpertDispatchError.invalidOwnership }

        // Check supplied sizes before allocating by the declared expert count.
        var supplied = 0
        for ids in globalIDsByRank {
            let total = supplied.addingReportingOverflow(ids.count)
            guard !ids.isEmpty, !total.overflow, total.partialValue <= expertCount
            else { throw ExpertDispatchError.invalidOwnership }
            supplied = total.partialValue
            var previous = -1
            for id in ids {
                guard id > previous, id < expertCount
                else { throw ExpertDispatchError.invalidOwnership }
                previous = id
            }
        }
        guard supplied == expertCount else { throw ExpertDispatchError.invalidOwnership }

        var addresses = [ExpertAddress?](repeating: nil, count: expertCount)
        for (rank, ids) in globalIDsByRank.enumerated() {
            for (localID, globalID) in ids.enumerated() {
                guard addresses[globalID] == nil else {
                    throw ExpertDispatchError.invalidOwnership
                }
                addresses[globalID] = ExpertAddress(rank: rank, localExpertID: localID)
            }
        }
        guard addresses.allSatisfy({ $0 != nil }) else {
            throw ExpertDispatchError.invalidOwnership
        }
        self.expertCount = expertCount
        self.globalIDsByRank = globalIDsByRank
        self.addressByGlobalID = addresses.compactMap { $0 }
    }

    func address(globalExpertID: Int) throws -> ExpertAddress {
        guard addressByGlobalID.indices.contains(globalExpertID) else {
            throw ExpertDispatchError.invalidExpert
        }
        return addressByGlobalID[globalExpertID]
    }

    /// Direct adapter: TensorSelection.axis(0, try ownership.expertRanges(rank:)).
    /// Ranges are ordered/disjoint, so the existing selected reader packs local
    /// experts in the exact order used by address(globalExpertID:).
    func expertRanges(rank: Int) throws -> [Range<Int>] {
        guard globalIDsByRank.indices.contains(rank) else { throw ExpertDispatchError.invalidRank }
        let ids = globalIDsByRank[rank]
        var ranges: [Range<Int>] = []
        var lower = ids[0]
        var upper = lower + 1
        for id in ids.dropFirst() {
            if id == upper { upper += 1 }
            else { ranges.append(lower..<upper); lower = id; upper = id + 1 }
        }
        ranges.append(lower..<upper)
        return ranges
    }

    /// A structural check for each rank-3 expert weight/scale/bias tensor. The
    /// model adapter must additionally verify names, dtypes, packed dimensions,
    /// quantization and source bytes through its existing layout/storage checks.
    func selectedStoredShape(_ shape: [Int], rank: Int) throws -> [Int] {
        guard globalIDsByRank.indices.contains(rank) else { throw ExpertDispatchError.invalidRank }
        guard shape.count == 3, shape[0] == expertCount, shape.allSatisfy({ $0 > 0 })
        else { throw ExpertDispatchError.invalidStoredShape }
        return [globalIDsByRank[rank].count, shape[1], shape[2]]
    }
}
