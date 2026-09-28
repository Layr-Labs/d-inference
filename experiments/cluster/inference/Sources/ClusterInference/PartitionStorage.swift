import Foundation
import MLX

struct PartitionStorageTensor {
    let name: String
    let shape: [Int]
    let sourceDType: DType
    let loadedDType: DType
    let byteCount: Int
    let isFeedForward: Bool
}

struct RankPartitionStorage: Codable {
    let rank: Int
    let parameterLayoutSHA256: String
    let loadedTensorBytes: Int
    let selectedShardedTensorBytes: Int
}

/// A shared, ordered commitment; unequal ranks never relax exact local checks.
struct PartitionStorageCommitment: Codable {
    let schemaVersion: Int
    let sourceTensorManifestSHA256: String
    let sourceModelTensorBytes: Int
    let sourceFFNTensorBytes: Int
    let sourceShardedFFNTensorBytes: Int
    let sourceShardedTensorBytes: Int
    let ranks: [RankPartitionStorage]

    var fingerprint: String { get throws { sha256(try canonicalJSONData(self)) } }
}

private struct StorageSelection: Encodable {
    let kind: String
    let axis: Int?
    let intervals: [[Int]]
    init(_ value: TensorSelection) {
        switch value {
        case .all: kind = "all"; axis = nil; intervals = []
        case .axis(let dimension, let ranges):
            kind = "axis"; axis = dimension
            intervals = ranges.map { [$0.lowerBound, $0.upperBound] }
        }
    }
}

private struct StorageSource: Encodable {
    let name: String
    let shape: [Int]
    let sourceDType: String
    let loadedDType: String
    let byteCount: Int
    let isFeedForward: Bool
    let rankSelections: [StorageSelection]
}

/// Check disjoint coverage, not only byte totals (which could hide duplicated
/// ranges). Replicated tensors must be explicitly all/all; mixed ownership fails.
private func validateStorageCoverage(_ choices: [TensorSelection], shape: [Int]) throws -> Bool {
    if choices == [.all, .all] { return false }
    guard case .axis(let a, let first) = choices[0],
        case .axis(let b, let second) = choices[1], a == b else {
        throw ProbeError("Partition ownership must be replicated or a disjoint two-rank axis cover")
    }
    var cursor = 0
    for range in (first + second).sorted(by: { $0.lowerBound < $1.lowerBound }) {
        guard range.lowerBound == cursor else { throw ProbeError("Partition ownership overlaps or leaves a gap") }
        cursor = range.upperBound
    }
    guard cursor == shape[a] else { throw ProbeError("Partition ownership does not cover the source tensor") }
    return true
}

private func storageBytes(_ shape: [Int], dtype: DType) throws -> Int {
    var result = dtype.size
    for dimension in shape {
        let product = result.multipliedReportingOverflow(by: dimension)
        guard dimension > 0, !product.overflow else { throw ProbeError("Invalid storage shape or byte overflow") }
        result = product.partialValue
    }
    return result
}

private func storageAdd(_ current: inout Int, _ amount: Int) throws {
    let total = current.addingReportingOverflow(amount)
    guard amount >= 0, !total.overflow else { throw ProbeError("Partition storage byte count overflow") }
    current = total.partialValue
}

func makePartitionStorage(
    tensors: [PartitionStorageTensor],
    selection: (String, [Int], Int) throws -> TensorSelection
) throws -> PartitionStorageCommitment {
    guard !tensors.isEmpty, Set(tensors.map(\.name)).count == tensors.count else {
        throw ProbeError("Partition source metadata is empty or contains duplicate names")
    }
    var sources: [StorageSource] = []
    var layouts = [[String](), [String]()]
    var loaded = [0, 0], selected = [0, 0]
    var total = 0, ffn = 0, shardedFFN = 0, sharded = 0
    for tensor in tensors.sorted(by: { $0.name < $1.name }) {
        guard !tensor.name.isEmpty,
            try storageBytes(tensor.shape, dtype: tensor.sourceDType) == tensor.byteCount,
            tensor.loadedDType.size == tensor.sourceDType.size else {
            throw ProbeError("Partition storage metadata has an invalid source/loaded byte width")
        }
        let choices = try (0..<2).map { try selection(tensor.name, tensor.shape, $0) }
        let shapes = try choices.map { try $0.resultShape(tensor.shape) }
        let isSharded = try validateStorageCoverage(choices, shape: tensor.shape)
        try storageAdd(&total, tensor.byteCount)
        if tensor.isFeedForward { try storageAdd(&ffn, tensor.byteCount) }
        if isSharded {
            try storageAdd(&sharded, tensor.byteCount)
            if tensor.isFeedForward { try storageAdd(&shardedFFN, tensor.byteCount) }
        }
        for rank in 0..<2 {
            let count = try storageBytes(shapes[rank], dtype: tensor.loadedDType)
            try storageAdd(&loaded[rank], count)
            if isSharded { try storageAdd(&selected[rank], count) }
            layouts[rank].append("\(tensor.name):\(tensor.loadedDType):\(shapes[rank])")
        }
        sources.append(StorageSource(name: tensor.name, shape: tensor.shape,
            sourceDType: String(describing: tensor.sourceDType), loadedDType: String(describing: tensor.loadedDType),
            byteCount: tensor.byteCount, isFeedForward: tensor.isFeedForward,
            rankSelections: choices.map(StorageSelection.init)))
    }
    guard sharded > 0, selected[0] + selected[1] == sharded,
        loaded[0] == total - sharded + selected[0], loaded[1] == total - sharded + selected[1] else {
        throw ProbeError("Partition storage conservation failed")
    }
    return PartitionStorageCommitment(schemaVersion: 1,
        sourceTensorManifestSHA256: sha256(try canonicalJSONData(sources)),
        sourceModelTensorBytes: total, sourceFFNTensorBytes: ffn,
        sourceShardedFFNTensorBytes: shardedFFN, sourceShardedTensorBytes: sharded,
        ranks: (0..<2).map { RankPartitionStorage(rank: $0,
            parameterLayoutSHA256: sha256(Data(layouts[$0].joined(separator: "\n").utf8)),
            loadedTensorBytes: loaded[$0], selectedShardedTensorBytes: selected[$0]) })
}
