import Foundation

enum QwenDenseShortLedgerScope: String, Encodable {
    case fullReference, sequentialStagePair
}

/// One named array shape, independently passed to the allocator-bound closure.
/// `instances` is an operational allowance, not an observed allocation count.
struct QwenDenseShortBufferAllowance: Encodable, Equatable {
    let category: String, owner: String, name: String
    let shape: [Int], elementBytes: Int, instances: Int
    let logicalBytesPerArray: Int, allocationBoundPerArray: Int
    let logicalBytes: Int, allocationBoundBytes: Int
}

struct QwenDenseShortStateSnapshot: Encodable, Equatable {
    let committedTokens: Int, componentCount: Int
    let kvShape: [Int], convolutionShape: [Int], ssmShape: [Int]
    let kvBytesPerTensor: Int, convolutionBytesPerTensor: Int, ssmBytesPerTensor: Int
    let logicalBytes: Int
    let kvDType = "bfloat16", convolutionDType = "bfloat16", ssmDType = "float32"
    let offsetDType = "int32", offsetBytesPerAttentionLayer = 4
}

struct QwenDenseShortStateOwner: Encodable, Equatable {
    let owner: String, lowerLayer: Int, upperLayer: Int
    let attentionLayers: Int, recurrentLayers: Int
    let nativeCapacityStateBytes: Int
    let frontiers: [QwenDenseShortStateSnapshot]
}

struct QwenDenseShortCPUEvidenceAllowance: Encodable, Equatable {
    let baselineNativeRowBytes: Int, baselineFloatRowBytes: Int
    let candidateFloatRowBytes: Int, transientCandidateNativeRowBytes: Int
    let largestSingleStateCopyBytes: Int, boundaryCopyBytes: Int
    let logicalBytes: Int
    let outputRows = 2, retainedRawStateHistoryBytes = 0
    let objectAndSerializationOverheadIncluded = false
}

/// Never retains the closure. Each distinct named shape is bounded before it is
/// multiplied by its instance allowance; rounding the aggregate is forbidden.
struct QwenDenseShortAllowanceBuilder {
    private(set) var buffers: [QwenDenseShortBufferAllowance] = []

    mutating func append(category: String, owner: String, name: String,
                         shape: [Int], elementBytes: Int, instances: Int,
                         bound: (Int) throws -> Int) throws {
        guard !category.isEmpty, !owner.isEmpty, !name.isEmpty,
              (1...5).contains(shape.count), shape.allSatisfy({ $0 > 0 }),
              [2, 4].contains(elementBytes), (1...1024).contains(instances),
              buffers.count < 256,
              !buffers.contains(where: { $0.owner == owner && $0.name == name }) else {
            throw QwenDenseProfileError("Invalid or repeated short-ledger array allowance")
        }
        let product = QwenLongPrefillCheckedBytes.product
        let logical = try product(shape + [elementBytes])
        let allocation = try bound(logical)
        guard allocation >= logical else {
            throw QwenDenseProfileError("Short-ledger allocator bound is below its logical array")
        }
        buffers.append(.init(category: category, owner: owner, name: name, shape: shape,
            elementBytes: elementBytes, instances: instances, logicalBytesPerArray: logical,
            allocationBoundPerArray: allocation, logicalBytes: try product([logical, instances]),
            allocationBoundBytes: try product([allocation, instances])))
    }
}
