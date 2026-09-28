import Foundation
import MLXLLM
import MLXLMCommon

/// Stored shapes of the pinned text-only Gemma constructor. This is metadata
/// only: no model or MLXArray is allocated when a partition is planned.
struct GemmaPartitionLayout {
    private(set) var shapes: [String: [Int]] = [:]
    private(set) var policies: [String: BaseConfiguration.Quantization] = [:]

    init(config: Gemma4TextConfiguration, vocabulary: Int, prefix: String,
         policy: BaseConfiguration.PerLayerQuantization) throws {
        let trunk = prefix + "model"
        let h = config.hiddenSize
        try projection(trunk + ".embed_tokens", rows: vocabulary, columns: h, policy: policy)
        shapes[trunk + ".norm.weight"] = [h]
        if !config.tieWordEmbeddings {
            try projection(prefix + "lm_head", rows: vocabulary, columns: h, policy: policy)
        }
        let ple = config.hiddenSizePerLayerInput
        if ple > 0 {
            let total = config.numHiddenLayers * ple
            try projection(trunk + ".embed_tokens_per_layer", rows: config.vocabSizePerLayerInput,
                           columns: total, policy: policy)
            // The pinned ScaledLinear is not Quantizable. Keep its ordinary
            // floating weight and scaling scalar exactly as the model does.
            shapes[trunk + ".per_layer_model_projection.weight"] = [total, h]
            shapes[trunk + ".per_layer_projection_norm.weight"] = [ple]
        }
        for layer in 0..<config.numHiddenLayers {
            let path = trunk + ".layers.\(layer)"
            let shared = config.layerUsesSharedKV(layerIdx: layer)
            let full = config.layerTypes[layer] == "full_attention"
            let dimension = full ? config.globalHeadDim : config.headDim
            let kv = full ? (config.numGlobalKeyValueHeads ?? config.numKeyValueHeads) : config.numKeyValueHeads
            let queryWidth = config.numAttentionHeads * dimension
            try projection(path + ".self_attn.q_proj", rows: queryWidth, columns: h, policy: policy)
            try projection(path + ".self_attn.o_proj", rows: h, columns: queryWidth, policy: policy)
            shapes[path + ".self_attn.q_norm.weight"] = [dimension]
            if !shared {
                try projection(path + ".self_attn.k_proj", rows: kv * dimension, columns: h, policy: policy)
                if !(full && config.attentionKeqV) {
                    try projection(path + ".self_attn.v_proj", rows: kv * dimension, columns: h, policy: policy)
                }
                shapes[path + ".self_attn.k_norm.weight"] = [dimension]
                // v_norm is RMSNormNoScale and has no checkpoint parameters.
            }
            let denseWidth = config.intermediateSize * (config.useDoubleWideMlp && shared ? 2 : 1)
            try projection(path + ".mlp.gate_proj", rows: denseWidth, columns: h, policy: policy)
            try projection(path + ".mlp.up_proj", rows: denseWidth, columns: h, policy: policy)
            try projection(path + ".mlp.down_proj", rows: h, columns: denseWidth, policy: policy)
            var norms = ["input_layernorm", "post_attention_layernorm",
                         "pre_feedforward_layernorm", "post_feedforward_layernorm"]
            if config.enableMoeBlock {
                guard let experts = config.numExperts, let width = config.moeIntermediateSize else {
                    throw ProbeError("Gemma MoE requires explicit expert count and intermediate width")
                }
                try projection(path + ".router.proj", rows: experts, columns: h, policy: policy)
                shapes[path + ".router.scale"] = [h]
                shapes[path + ".router.per_expert_scale"] = [experts]
                let bank = path + ".experts.switch_glu"
                try projection(bank + ".gate_proj", rows: width, columns: h, experts: experts, policy: policy)
                try projection(bank + ".up_proj", rows: width, columns: h, experts: experts, policy: policy)
                try projection(bank + ".down_proj", rows: h, columns: width, experts: experts, policy: policy)
                norms += ["post_feedforward_layernorm_1", "pre_feedforward_layernorm_2",
                          "post_feedforward_layernorm_2"]
            }
            if ple > 0 {
                try projection(path + ".per_layer_input_gate", rows: ple, columns: h, policy: policy)
                try projection(path + ".per_layer_projection", rows: h, columns: ple, policy: policy)
                norms.append("post_per_layer_input_norm")
            }
            for norm in norms { shapes[path + "." + norm + ".weight"] = [h] }
            shapes[path + ".layer_scalar"] = [1]
        }
        // Unsupported aliases, overrides on a non-quantizable module and skip
        // policies must not quietly fall back to a differently packed weight.
        for path in policy.perLayerQuantization.keys where policies[path] == nil {
            throw ProbeError("Gemma quantization override does not name a supported text projection: \(path)")
        }
    }

    private mutating func projection(_ path: String, rows: Int, columns: Int,
                                    experts: Int? = nil,
                                    policy: BaseConfiguration.PerLayerQuantization) throws {
        guard rows > 0, columns > 0, columns % 64 == 0,
              let quantization = policy.quantization(layer: path),
              [4, 8].contains(quantization.bits), quantization.groupSize == 64,
              quantization.mode == .affine else {
            throw ProbeError("Gemma requires affine W4/W8 G64 at \(path)")
        }
        policies[path] = quantization
        let leading = experts.map { [$0] } ?? []
        shapes[path + ".weight"] = leading + [rows, columns / (32 / quantization.bits)]
        shapes[path + ".scales"] = leading + [rows, columns / 64]
        shapes[path + ".biases"] = leading + [rows, columns / 64]
    }
}
