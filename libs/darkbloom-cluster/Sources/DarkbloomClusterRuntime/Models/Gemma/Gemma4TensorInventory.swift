import Foundation

enum Gemma4TensorInventory {
    static let prefix = "language_model.model."

    static func expectedText(_ metadata: Gemma4TextMetadata) throws -> [String: LayerStageTensorLayout] {
        var result: [String: LayerStageTensorLayout] = [:]
        func tensor(_ name: String, _ dtype: String, _ shape: [Int]) throws {
            let width = dtype == "U32" ? 4 : 2
            guard result[name] == nil else { throw ProbeError("Duplicate expected Gemma tensor") }
            result[name] = try LayerStageTensorLayout(canonicalName: name, shape: shape,
                sourceDType: dtype, byteCount: QwenLongPrefillCheckedBytes.product(shape + [width]))
        }
        func quantized(_ module: String, _ shape: [Int], bits: Int = 4) throws {
            guard let width = shape.last, width % 64 == 0, [4, 8].contains(bits) else {
                throw ProbeError("Gemma packed projection width/policy differs")
            }
            try tensor(module + ".weight", "U32", Array(shape.dropLast()) + [width / (32 / bits)])
            for suffix in ["scales", "biases"] {
                try tensor(module + "." + suffix, "BF16", Array(shape.dropLast()) + [width / 64])
            }
        }
        let h = metadata.hiddenSize, experts = metadata.expertCount
        let shared = metadata.sharedIntermediateSize, expertWidth = metadata.expertIntermediateSize
        try quantized(prefix + "embed_tokens", [metadata.vocabularySize, h])
        try tensor(prefix + "norm.weight", "BF16", [h])
        for (index, kind) in metadata.layerKinds.enumerated() {
            let base = prefix + "layers.\(index)."
            for name in ["input_layernorm", "post_attention_layernorm", "pre_feedforward_layernorm",
                "post_feedforward_layernorm", "post_feedforward_layernorm_1",
                "pre_feedforward_layernorm_2", "post_feedforward_layernorm_2"] {
                try tensor(base + name + ".weight", "BF16", [h])
            }
            try tensor(base + "layer_scalar", "BF16", [1])
            try tensor(base + "router.scale", "BF16", [h])
            try tensor(base + "router.per_expert_scale", "BF16", [experts])
            try quantized(base + "router.proj", [experts, h], bits: 8)
            for (name, output, input) in [("gate_proj", shared, h), ("up_proj", shared, h), ("down_proj", h, shared)] {
                try quantized(base + "mlp." + name, [output, input], bits: 8)
            }
            for (name, output, input) in [("gate_proj", expertWidth, h), ("up_proj", expertWidth, h), ("down_proj", h, expertWidth)] {
                try quantized(base + "experts.switch_glu." + name, [experts, output, input])
            }
            let head = kind == .sliding ? metadata.slidingHeadDimension : metadata.fullHeadDimension
            let kv = kind == .sliding ? metadata.slidingKVHeads : metadata.fullKVHeads
            for (name, output, input) in [("q_proj", metadata.queryHeads * head, h),
                ("k_proj", kv * head, h), ("o_proj", h, metadata.queryHeads * head)] {
                try quantized(base + "self_attn." + name, [output, input])
            }
            if kind == .sliding { try quantized(base + "self_attn.v_proj", [kv * head, h]) }
            for name in ["q_norm", "k_norm"] { try tensor(base + "self_attn." + name + ".weight", "BF16", [head]) }
        }
        return result
    }
}
