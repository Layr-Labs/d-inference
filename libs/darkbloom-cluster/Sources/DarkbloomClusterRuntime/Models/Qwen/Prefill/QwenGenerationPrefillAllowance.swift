import Foundation

/// Added named storage, never taken from the existing two-boundary reserve.
/// The CPU bookkeeping allowance covers one bounded packet/token/summary slot;
/// it is not a claim about the entire Swift heap or native workspace peak.
struct QwenGenerationPrefillAllowance: Encodable, Equatable {
    static let bookkeepingBytes = 65_536
    let rank: Int
    let extraNativeBytes: Int
    let extraHostBytes: Int
    var reservedBytes: Int { get throws { try QwenLongPrefillCheckedBytes.sum([extraNativeBytes, extraHostBytes]) } }

    static func derive(rank: Int, promptCount: Int, chunkSize: Int, hiddenSize: Int,
                       elementBytes: Int, bound: (Int) throws -> Int) throws -> Self {
        guard (0...1).contains(rank), (1...32_768).contains(promptCount), (1...512).contains(chunkSize),
              (1...8192).contains(hiddenSize), [2, 4].contains(elementBytes) else {
            throw ProbeError("Invalid lookahead allowance geometry")
        }
        // No next prompt frame exists for a one-chunk request. Both ranks still
        // reserve the fixed CPU summary/policy slot, and rank1 never prefetches.
        guard rank == 0 && promptCount > chunkSize else {
            return .init(rank: rank, extraNativeBytes: 0, extraHostBytes: bookkeepingBytes)
        }
        let bytes = try QwenLongPrefillCheckedBytes.product([chunkSize, hiddenSize, elementBytes])
        let rounded = try bound(bytes)
        guard rounded >= bytes else { throw ProbeError("Lookahead allocator bound is too small") }
        return .init(rank: rank, extraNativeBytes: rounded,
            extraHostBytes: try QwenLongPrefillCheckedBytes.sum([bytes, bookkeepingBytes]))
    }
    func requireCapacity(baseBytes: Int, ownerLimit: Int, readinessLimit: Int) throws {
        let total = try QwenLongPrefillCheckedBytes.sum([baseBytes, reservedBytes])
        guard baseBytes > 0, ownerLimit > 0, readinessLimit > 0,
              total <= ownerLimit, total <= readinessLimit else {
            throw ProbeError("Lookahead exceeds its additionally reserved owner/readiness capacity")
        }
    }
}
