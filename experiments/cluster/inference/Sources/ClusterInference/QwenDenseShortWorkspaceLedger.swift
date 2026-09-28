import Foundation

/// Source-shaped allowance for named intermediates. Counts charge all covered
/// layers, without claiming actual overlap, kernel dispatch or complete scratch.
enum QwenDenseShortWorkspaceLedger {
    static func append(profile: QwenRegisteredDenseModelProfile,
                       owners: [QwenDenseShortStateOwner], scope: QwenDenseShortLedgerScope,
                       builder: inout QwenDenseShortAllowanceBuilder,
                       bound: (Int) throws -> Int) throws {
        let g = profile.geometry, product = QwenLongPrefillCheckedBytes.product
        let sum = QwenLongPrefillCheckedBytes.sum
        guard let root = try JSONSerialization.jsonObject(with: profile.configuration) as? [String: Any] else {
            throw QwenDenseProfileError("Registered short workspace configuration is not an object")
        }
        let text = root["text_config"] as? [String: Any] ?? root
        let intermediate = try QwenStageMetadata.integer(text, "intermediate_size", limit: 32768)
        let channels = try sum([product([2, g.linearKeyHeads, g.linearKeyDimension]),
                                product([g.linearValueHeads, g.linearValueDimension])])
        let projection = try sum([channels, product([g.linearValueHeads, g.linearValueDimension]),
                                  product([2, g.linearValueHeads])])
        for owner in owners {
            let layers = owner.upperLayer - owner.lowerLayer
            // input norm, attention/recurrent output, first residual, post norm,
            // feed-forward output, final residual: widened to F32 individually.
            try builder.append(category: "workspace", owner: owner.owner, name: "hidden_intermediates_f32",
                shape: [1, 2, g.hiddenSize], elementBytes: 4, instances: product([6, layers]), bound: bound)
            // gate projection, SiLU, up projection, product in Qwen3NextMLP.
            try builder.append(category: "workspace", owner: owner.owner, name: "mlp_intermediates_f32",
                shape: [1, 2, intermediate], elementBytes: 4, instances: product([4, layers]), bound: bound)
            try builder.append(category: "workspace", owner: owner.owner, name: "q_and_gate_projection_f32",
                shape: [1, 2, g.queryHeads, 2, g.headDimension], elementBytes: 4,
                instances: owner.attentionLayers, bound: bound)
            try builder.append(category: "workspace", owner: owner.owner, name: "key_value_projection_f32",
                shape: [1, 2, g.kvHeads, g.headDimension], elementBytes: 4,
                instances: product([2, owner.attentionLayers]), bound: bound)
            // Dense score/softmax matrices are an allowance for an operations
            // fallback; this does not assert that a fused kernel allocates them.
            try builder.append(category: "workspace", owner: owner.owner, name: "score_softmax_f32",
                shape: [1, g.queryHeads, 2, 5], elementBytes: 4,
                instances: product([2, owner.attentionLayers]), bound: bound)
            try builder.append(category: "workspace", owner: owner.owner, name: "gdn_fused_projection_f32",
                shape: [1, 2, projection], elementBytes: 4, instances: owner.recurrentLayers, bound: bound)
            try builder.append(category: "workspace", owner: owner.owner, name: "gdn_conv_input_f32",
                shape: [1, g.convolutionKernel - 1 + 2, channels], elementBytes: 4,
                instances: owner.recurrentLayers, bound: bound)
        }
        try builder.append(category: "output", owner: "request", name: "native_logits_bf16",
            shape: [1, profile.vocabularySize], elementBytes: 2, instances: 1, bound: bound)
        try builder.append(category: "output", owner: "request", name: "diagnostic_logits_f32",
            shape: [1, profile.vocabularySize], elementBytes: 4, instances: 1, bound: bound)
        try builder.append(category: "input", owner: "request", name: "token_input_i32",
            shape: [1, 2], elementBytes: 4, instances: 1, bound: bound)
        if scope == .sequentialStagePair {
            try builder.append(category: "boundary", owner: "pair", name: "residual_and_owned_copy_f32",
                shape: [1, 2, g.hiddenSize], elementBytes: 4, instances: 2, bound: bound)
        }
    }
}
