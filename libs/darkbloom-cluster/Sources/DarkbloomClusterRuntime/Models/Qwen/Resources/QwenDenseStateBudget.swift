import Foundation

enum QwenDenseStateBudget {
    static func geometry(_ g: QwenLongPrefillBudgetGeometry, layers: Int) throws -> QwenLongPrefillBudgetGeometry {
        try .init(layers: layers, fullAttentionInterval: g.fullAttentionInterval, hiddenSize: g.hiddenSize,
            queryHeads: g.queryHeads, kvHeads: g.kvHeads, headDimension: g.headDimension,
            linearKeyHeads: g.linearKeyHeads, linearValueHeads: g.linearValueHeads,
            linearKeyDimension: g.linearKeyDimension, linearValueDimension: g.linearValueDimension,
            convolutionKernel: g.convolutionKernel)
    }

    /// Logical final state differs deliberately from the conservative capacity/
    /// transient formula. No state tensor is constructed, captured or read here.
    static func finalState(_ g: QwenLongPrefillBudgetGeometry) throws -> QwenDenseFinalStateGeometry {
        let product = QwenLongPrefillCheckedBytes.product, sum = QwenLongPrefillCheckedBytes.sum
        let full = g.layers / g.fullAttentionInterval, recurrent = g.layers - full
        let channels = try sum([product([2, g.linearKeyHeads, g.linearKeyDimension]),
                                product([g.linearValueHeads, g.linearValueDimension])])
        let kvShape = [1, g.kvHeads, 8192, g.headDimension]
        let convShape = [1, g.convolutionKernel - 1, channels]
        let ssmShape = [1, g.linearValueHeads, g.linearValueDimension, g.linearKeyDimension]
        let kv = try product(kvShape + [2]), conv = try product(convShape + [2]), ssm = try product(ssmShape + [4])
        let bytes = try sum([product([full, sum([product([2, kv]), 4])]), product([recurrent, sum([conv, ssm])])])
        return .init(committedTokens: 8192, attentionLayers: full, recurrentLayers: recurrent,
            componentCount: try sum([product([full, 3]), product([recurrent, 2])]),
            kvShape: kvShape, convolutionShape: convShape, ssmShape: ssmShape,
            kvBytesPerTensor: kv, convolutionBytesPerTensor: conv, ssmBytesPerTensor: ssm, logicalBytes: bytes)
    }
}
