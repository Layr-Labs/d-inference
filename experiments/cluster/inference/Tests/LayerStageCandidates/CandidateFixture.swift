import Foundation

/// Public synthetic metadata. No checkpoint, tensors, descriptor bytes or model
/// factory. Geometry follows the existing small QwenLayerStagePlanCheck fixture.
struct CandidateFixture {
    enum Form: CaseIterable, Equatable { case text, flatWrapper, nestedWrapper }
    let layerCount: Int
    let form: Form
    let object: [String: Any]
    let canonicalNames: [String]
    var namespace: String { form == .text ? "" : "language_model." }
    var isNested: Bool { form == .nestedWrapper }

    init(layers: Int, form: Form) {
        self.layerCount = layers
        self.form = form
        let namespace = form == .text ? "" : "language_model."
        let text: [String: Any] = [
            "model_type": "qwen3_5_text", "hidden_size": 128, "intermediate_size": 256,
            "num_hidden_layers": layers, "num_attention_heads": 4, "num_key_value_heads": 2,
            "head_dim": 64, "linear_num_key_heads": 2, "linear_num_value_heads": 2,
            "linear_key_head_dim": 128, "linear_value_head_dim": 128, "linear_conv_kernel_dim": 4,
            "vocab_size": 512, "max_position_embeddings": 8192, "full_attention_interval": 4,
            "tie_word_embeddings": false, "attention_bias": false, "mtp_num_hidden_layers": 1,
            "dtype": "bfloat16", "rms_norm_eps": 0.000001,
            "layer_types": (0..<layers).map { ($0 + 1) % 4 == 0 ? "full_attention" : "linear_attention" },
            "rope_parameters": ["rope_type": "default", "rope_theta": 10000000,
                "partial_rotary_factor": 0.25, "mrope_section": [11, 11, 10]],
        ]
        var root: [String: Any] = form == .nestedWrapper ? ["model_type": "qwen3_5", "text_config": text] : text
        if form == .flatWrapper { root["model_type"] = "qwen3_5" }
        var policy: [String: Any] = ["bits": 4, "group_size": 64, "mode": "affine",
            "quant_method": "synthetic-retained-metadata", "linear_class": "QuantizedLinear"]
        if layers > 8 {
            policy[namespace + "model.layers.8.mlp.down_proj"] = ["bits": 8, "group_size": 128, "mode": "affine"]
        }
        policy["mtp.layers.0.mlp.down_proj"] = false
        root["quantization"] = policy
        root["quantization_config"] = policy
        root["mtplx_mtp"] = ["included": true, "prefix": "mtp."]
        self.object = root

        // Explicit canonical suffix tables form the synthetic input; do not ask
        // production moduleInventory for its expected names and test it against itself.
        var names = [namespace + "model.norm.weight"]
        func projection(_ path: String) {
            names += ["weight", "scales", "biases"].map { path + "." + $0 }
        }
        projection(namespace + "model.embed_tokens")
        projection(namespace + "lm_head")
        for layer in 0..<layers {
            let path = namespace + "model.layers.\(layer)."
            names += ["input_layernorm.weight", "post_attention_layernorm.weight"].map { path + $0 }
            for leaf in ["gate_proj", "up_proj", "down_proj"] { projection(path + "mlp." + leaf) }
            if (layer + 1) % 4 == 0 {
                for leaf in ["q_proj", "k_proj", "v_proj", "o_proj"] { projection(path + "self_attn." + leaf) }
                names += ["q_norm.weight", "k_norm.weight"].map { path + "self_attn." + $0 }
            } else {
                for leaf in ["in_proj_qkv", "in_proj_z", "in_proj_b", "in_proj_a", "out_proj"] {
                    projection(path + "linear_attn." + leaf)
                }
                names += ["A_log", "dt_bias", "norm.weight", "conv1d.weight"].map { path + "linear_attn." + $0 }
            }
        }
        self.canonicalNames = names
    }

    func text(in root: [String: Any]) throws -> [String: Any] {
        guard isNested else { return root }
        guard let text = root["text_config"] as? [String: Any] else { throw ProbeError("Missing fixture text_config") }
        return text
    }

    func changingText(_ key: String, to value: Any) throws -> Data {
        var root = object, text = try self.text(in: object)
        text[key] = value
        if isNested { root["text_config"] = text } else { root = text }
        return try candidateJSON(root)
    }
}
