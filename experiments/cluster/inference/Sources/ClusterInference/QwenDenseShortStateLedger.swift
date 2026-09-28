import Foundation

enum QwenDenseShortStateLedger {
    static func owner(geometry g: QwenLongPrefillBudgetGeometry, name: String,
                      lower: Int, upper: Int) throws -> QwenDenseShortStateOwner {
        guard lower >= 0, upper <= g.layers, upper > lower,
              lower % g.fullAttentionInterval == 0,
              upper % g.fullAttentionInterval == 0 else {
            throw QwenDenseProfileError("Short state owner must cover a complete aligned layer range")
        }
        let product = QwenLongPrefillCheckedBytes.product, sum = QwenLongPrefillCheckedBytes.sum
        let attention = (upper - lower) / g.fullAttentionInterval
        let recurrent = upper - lower - attention
        let channels = try sum([product([2, g.linearKeyHeads, g.linearKeyDimension]),
                                product([g.linearValueHeads, g.linearValueDimension])])
        let convShape = [1, g.convolutionKernel - 1, channels]
        let ssmShape = [1, g.linearValueHeads, g.linearValueDimension, g.linearKeyDimension]
        let conv = try product(convShape + [2]), ssm = try product(ssmShape + [4])
        let components = try sum([product([attention, 3]), product([recurrent, 2])])
        func snapshot(_ tokens: Int) throws -> QwenDenseShortStateSnapshot {
            let kvShape = [1, g.kvHeads, tokens, g.headDimension]
            let kv = try product(kvShape + [2])
            let logical = try sum([product([attention, sum([product([2, kv]), 4])]),
                                   product([recurrent, sum([conv, ssm])])])
            return .init(committedTokens: tokens, componentCount: components, kvShape: kvShape,
                convolutionShape: convShape, ssmShape: ssmShape, kvBytesPerTensor: kv,
                convolutionBytesPerTensor: conv, ssmBytesPerTensor: ssm, logicalBytes: logical)
        }
        return try .init(owner: name, lowerLayer: lower, upperLayer: upper,
            attentionLayers: attention, recurrentLayers: recurrent,
            nativeCapacityStateBytes: snapshot(5).logicalBytes,
            frontiers: [2, 3, 4].map(snapshot))
    }

    static func appendAllowances(owner: QwenDenseShortStateOwner,
                                 geometry g: QwenLongPrefillBudgetGeometry,
                                 builder: inout QwenDenseShortAllowanceBuilder,
                                 bound: (Int) throws -> Int) throws {
        let product = QwenLongPrefillCheckedBytes.product
        let state = owner.frontiers[0]
        // Preserve the established three-generation F32 named allowance. This
        // deliberately differs from logical BF16 conv/KV snapshots above.
        try builder.append(category: "state", owner: owner.owner, name: "conv_f32_three_generations",
            shape: state.convolutionShape, elementBytes: 4,
            instances: product([3, owner.recurrentLayers]), bound: bound)
        try builder.append(category: "state", owner: owner.owner, name: "ssm_f32_three_generations",
            shape: state.ssmShape, elementBytes: 4,
            instances: product([3, owner.recurrentLayers]), bound: bound)
        try builder.append(category: "state", owner: owner.owner, name: "kv_capacity_f32",
            shape: [1, g.kvHeads, 5, g.headDimension], elementBytes: 4,
            instances: product([2, owner.attentionLayers]), bound: bound)
        try builder.append(category: "state", owner: owner.owner, name: "offset_i32",
            shape: [1], elementBytes: 4, instances: owner.attentionLayers, bound: bound)
    }
}
