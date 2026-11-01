import Foundation
import MLX

/// Stored payload/host-copy bounds, not a promise about whole-process memory.
/// Validation uses verified descriptors and never materializes selected tensors.
enum LocalCorrectnessStorage {
    static let maximumManifestPayloadBytes = 8 * 1024 * 1024 * 1024
    static let maximumSourceModelTensorBytes = QwenDenseLegacySourceBounds.maximumSourceModelTensorBytes
    static let maximumRankLoadedTensorBytes = 4 * 1024 * 1024 * 1024
    static let maximumCombinedLoadedTensorBytes = 8 * 1024 * 1024 * 1024
    static let maximumHostTensorBytes = QwenDenseLegacySourceBounds.maximumHostTensorBytes

    static func validateByteCounts(sourceModelTensorBytes: Int, rankLoadedTensorBytes: [Int],
                                   rankLargestHostTensorBytes: [Int]) throws {
        guard sourceModelTensorBytes > 0, sourceModelTensorBytes <= maximumSourceModelTensorBytes,
              rankLoadedTensorBytes.count == 2, rankLargestHostTensorBytes.count == 2,
              rankLoadedTensorBytes.allSatisfy({ $0 > 0 && $0 <= maximumRankLoadedTensorBytes }),
              rankLargestHostTensorBytes.allSatisfy({ $0 > 0 && $0 <= maximumHostTensorBytes }) else {
            throw ProbeError("Local correctness source, rank, or host tensor byte budget exceeded")
        }
        let combined = rankLoadedTensorBytes[0].addingReportingOverflow(rankLoadedTensorBytes[1])
        guard !combined.overflow, combined.partialValue <= maximumCombinedLoadedTensorBytes,
              zip(rankLargestHostTensorBytes, rankLoadedTensorBytes).allSatisfy({ $0.0 <= $0.1 }) else {
            throw ProbeError("Local correctness combined storage byte budget exceeded or inconsistent")
        }
    }


}

