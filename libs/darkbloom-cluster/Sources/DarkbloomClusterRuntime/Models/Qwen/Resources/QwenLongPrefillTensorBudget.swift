import Foundation

enum QwenLongPrefillBudgetError: Error, CustomStringConvertible {
    case invalid(String)
    var description: String { switch self { case .invalid(let value): return value } }
}

enum QwenLongPrefillCheckedBytes {
    static func product(_ values: [Int]) throws -> Int {
        var result = 1
        for value in values {
            guard value >= 0 else { throw QwenLongPrefillBudgetError.invalid("Negative byte-count factor") }
            let next = result.multipliedReportingOverflow(by: value)
            guard !next.overflow else { throw QwenLongPrefillBudgetError.invalid("Byte-count product overflow") }
            result = next.partialValue
        }
        return result
    }

    static func sum(_ values: [Int]) throws -> Int {
        var result = 0
        for value in values {
            guard value >= 0 else { throw QwenLongPrefillBudgetError.invalid("Negative byte-count term") }
            let next = result.addingReportingOverflow(value)
            guard !next.overflow else { throw QwenLongPrefillBudgetError.invalid("Byte-count sum overflow") }
            result = next.partialValue
        }
        return result
    }
}

/// Dimension-only input, independent of CLI, model constructors or wire formats.
/// These are existing dense-Qwen metadata maxima, not execution authorization.
struct QwenLongPrefillBudgetGeometry: Encodable, Equatable {
    let layers: Int, fullAttentionInterval: Int, hiddenSize: Int
    let queryHeads: Int, kvHeads: Int, headDimension: Int
    let linearKeyHeads: Int, linearValueHeads: Int
    let linearKeyDimension: Int, linearValueDimension: Int, convolutionKernel: Int

    init(layers: Int, fullAttentionInterval: Int, hiddenSize: Int,
         queryHeads: Int, kvHeads: Int, headDimension: Int,
         linearKeyHeads: Int, linearValueHeads: Int,
         linearKeyDimension: Int, linearValueDimension: Int, convolutionKernel: Int) throws {
        guard (1...128).contains(layers), (2...128).contains(fullAttentionInterval),
              layers >= fullAttentionInterval, layers % fullAttentionInterval == 0,
              (1...8192).contains(hiddenSize), (1...128).contains(queryHeads),
              (1...128).contains(kvHeads), queryHeads % kvHeads == 0,
              (1...512).contains(headDimension), (1...128).contains(linearKeyHeads),
              (1...128).contains(linearValueHeads), linearValueHeads % linearKeyHeads == 0,
              (1...512).contains(linearKeyDimension), linearKeyDimension % 32 == 0,
              (1...512).contains(linearValueDimension), (1...16).contains(convolutionKernel) else {
            throw QwenLongPrefillBudgetError.invalid("Invalid bounded dense-Qwen budget geometry")
        }
        self.layers = layers; self.fullAttentionInterval = fullAttentionInterval; self.hiddenSize = hiddenSize
        self.queryHeads = queryHeads; self.kvHeads = kvHeads; self.headDimension = headDimension
        self.linearKeyHeads = linearKeyHeads; self.linearValueHeads = linearValueHeads
        self.linearKeyDimension = linearKeyDimension; self.linearValueDimension = linearValueDimension
        self.convolutionKernel = convolutionKernel
    }
}

/// Same named tensors as the legacy comparison formula, calculated with checked
/// arithmetic. No threshold is applied here and no allocator/RSS bound is claimed.
struct QwenLongPrefillTensorBudget: Encodable, Equatable {
    let formula = "qwen_state_snapshot_two_boundaries_f32_three_recurrent_v1"
    let maximumTokens: Int, chunkSize: Int
    let attentionLayers: Int, recurrentLayers: Int
    let convolutionBytesPerLayer: Int, ssmBytesPerLayer: Int
    let kvCapacityBytesPerAttentionLayer: Int, boundaryBytes: Int
    let threeRecurrentGenerationsBytes: Int, allKVCapacityAndOffsetsBytes: Int
    let largestSingleHostStateComponentBytes: Int, twoBoundaryArraysBytes: Int
    let conservativeStateAndBoundaryBytes: Int
    let isWholeProcessMemoryBound = false
    let includesWeightsOrNativeWorkspaces = false

    static func estimate(geometry g: QwenLongPrefillBudgetGeometry,
                         maximumTokens: Int, chunkSize: Int) throws -> Self {
        guard (1...32768).contains(maximumTokens), (1...512).contains(chunkSize), chunkSize <= maximumTokens else {
            throw QwenLongPrefillBudgetError.invalid("Budget token/chunk geometry is outside explicit bounds")
        }
        let product = QwenLongPrefillCheckedBytes.product, sum = QwenLongPrefillCheckedBytes.sum
        let channels = try sum([product([2, g.linearKeyHeads, g.linearKeyDimension]),
                                product([g.linearValueHeads, g.linearValueDimension])])
        let conv = try product([4, g.convolutionKernel - 1, channels])
        let ssm = try product([4, g.linearValueHeads, g.linearValueDimension, g.linearKeyDimension])
        let attention = g.layers / g.fullAttentionInterval, recurrent = g.layers - attention
        let kv = try product([2, 4, maximumTokens, g.kvHeads, g.headDimension])
        let boundary = try product([chunkSize, g.hiddenSize, 4])
        let recurrentBytes = try product([3, recurrent, sum([conv, ssm])])
        let kvBytes = try product([attention, sum([kv, 4])])
        let snapshot = max(conv, ssm, kv / 2)
        let boundaries = try product([2, boundary])
        let total = try sum([recurrentBytes, kvBytes, snapshot, boundaries])
        return .init(maximumTokens: maximumTokens, chunkSize: chunkSize,
            attentionLayers: attention, recurrentLayers: recurrent,
            convolutionBytesPerLayer: conv, ssmBytesPerLayer: ssm,
            kvCapacityBytesPerAttentionLayer: kv, boundaryBytes: boundary,
            threeRecurrentGenerationsBytes: recurrentBytes, allKVCapacityAndOffsetsBytes: kvBytes,
            largestSingleHostStateComponentBytes: snapshot, twoBoundaryArraysBytes: boundaries,
            conservativeStateAndBoundaryBytes: total)
    }
}
