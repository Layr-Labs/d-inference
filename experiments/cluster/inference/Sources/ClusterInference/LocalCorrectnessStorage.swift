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

    static func validate(storage: PartitionStorageCommitment,
                         tensors: [String: QwenCheckpointTensor], plan: QwenPartitionPlan) throws {
        guard !plan.isMoE, !tensors.isEmpty, storage.schemaVersion == 1,
              storage.ranks.map(\.rank) == [0, 1] else {
            throw ProbeError("Local correctness storage requires dense Qwen and an ordered two-rank commitment")
        }
        var sourceBytes = 0, selectedBytes = [0, 0], largest = [0, 0]
        for (name, tensor) in tensors {
            // Dense tensors have one source allocation. Expert fusion requires
            // a separate host-piece accounting contract and is excluded here.
            guard tensor.parts.count == 1, tensor.byteCount > 0 else {
                throw ProbeError("Local correctness does not support composed expert tensors")
            }
            try add(&sourceBytes, tensor.byteCount)
            for rank in 0..<2 {
                let shape = try plan.selection(name: name, shape: tensor.shape, rank: rank).resultShape(tensor.shape)
                var bytes = tensor.dtype.size
                for dimension in shape {
                    let product = bytes.multipliedReportingOverflow(by: dimension)
                    guard dimension > 0, !product.overflow else {
                        throw ProbeError("Local correctness selected tensor byte count overflow")
                    }
                    bytes = product.partialValue
                }
                try add(&selectedBytes[rank], bytes)
                largest[rank] = max(largest[rank], bytes)
            }
        }
        guard sourceBytes == storage.sourceModelTensorBytes,
              selectedBytes == storage.ranks.map(\.loadedTensorBytes) else {
            throw ProbeError("Local correctness descriptor bytes differ from the storage commitment")
        }
        try validateByteCounts(sourceModelTensorBytes: sourceBytes, rankLoadedTensorBytes: selectedBytes,
                               rankLargestHostTensorBytes: largest)
    }

    private static func add(_ total: inout Int, _ value: Int) throws {
        let sum = total.addingReportingOverflow(value)
        guard value >= 0, !sum.overflow else { throw ProbeError("Local correctness storage byte count overflow") }
        total = sum.partialValue
    }
}

