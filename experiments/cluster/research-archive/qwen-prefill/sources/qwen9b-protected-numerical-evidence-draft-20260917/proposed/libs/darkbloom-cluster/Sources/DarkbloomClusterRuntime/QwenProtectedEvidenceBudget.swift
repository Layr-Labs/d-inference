import Foundation

/// Incremental host storage for this private correctness export only. The
/// existing recorder separately charges native/logical/F32 row storage and the
/// request's largest state-copy component. This is not a whole-process peak.
enum QwenProtectedEvidenceBudget {
    static let maximumEncodedBytes = 8 * 1_048_576
    static let maximumOutputAllocationBytes = 9 * 1_048_576
    static let scratchAndMetadataBytes = 1_048_576
    static let additionalHostBytes = maximumOutputAllocationBytes + scratchAndMetadataBytes
    static let vocabularySize = 248_320
    static let stateEntriesPerRank = 36

    static func requireAllocation(_ bytes: Int) throws {
        guard bytes >= maximumEncodedBytes, bytes <= maximumOutputAllocationBytes else {
            throw ProbeError("Protected evidence host allocation exceeds its charged bound")
        }
    }
}
