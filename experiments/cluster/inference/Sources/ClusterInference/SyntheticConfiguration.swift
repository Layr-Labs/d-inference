import Foundation

/// Bounded fixtures retain small hidden/vocabulary sizes while exercising
/// checkpoint head geometry. They are not replicas of registered model weights.
func syntheticConfiguration(options: Options) throws -> Data {
    if options.syntheticProfile.hasPrefix("gemma-") { return try syntheticGemmaConfiguration(options) }
    var configuration: [String: Any] = [
        "model_type": "qwen3_5_text", "hidden_size": 128,
        "num_hidden_layers": 4, "intermediate_size": 256,
        "num_attention_heads": 4, "num_key_value_heads": 2, "head_dim": 64,
        "linear_num_key_heads": 2, "linear_num_value_heads": 2,
        "linear_key_head_dim": 128, "linear_value_head_dim": 128,
        "linear_conv_kernel_dim": 4, "full_attention_interval": 2,
        "vocab_size": 512, "tie_word_embeddings": false,
        "max_position_embeddings": 8192, "mtp_num_hidden_layers": 0,
        "quantization": ["bits": 4, "group_size": 64, "mode": "affine"],
        "cluster_fixture_dtype": options.syntheticDType,
    ]
    switch options.syntheticProfile {
    case "tiny":
        // Preserve the original tiny fixture's configuration bytes and hash.
        break
    case "qwen9-heads", "qwen27-heads":
        let is27 = options.syntheticProfile == "qwen27-heads"
        configuration["num_attention_heads"] = is27 ? 24 : 16
        configuration["num_key_value_heads"] = 4
        configuration["head_dim"] = 256
        configuration["linear_num_key_heads"] = 16
        configuration["linear_num_value_heads"] = is27 ? 48 : 32
        configuration["full_attention_interval"] = 4
    case "qwen-moe":
        configuration["model_type"] = "qwen3_5_moe_text"
        configuration["num_experts"] = 16
        configuration["num_experts_per_tok"] = 4
        configuration["moe_intermediate_size"] = 512
        configuration["shared_expert_intermediate_size"] = 256
        configuration["decoder_sparse_step"] = 1
        configuration["norm_topk_prob"] = true
    default:
        throw ProbeError("Unsupported synthetic profile")
    }
    if options.syntheticProfile != "tiny" {
        configuration["cluster_fixture_profile"] = options.syntheticProfile
    }
    return try JSONSerialization.data(withJSONObject: configuration, options: [.sortedKeys])
}

private func syntheticGemmaConfiguration(_ options: Options) throws -> Data {
    guard ["gemma-moe", "gemma-moe-w8"].contains(options.syntheticProfile) else {
        throw ProbeError("Unsupported Gemma fixture")
    }
    let allW8 = options.syntheticProfile == "gemma-moe-w8"
    var policy: [String: Any] = ["bits": allW8 ? 8 : 4, "group_size": 64, "mode": "affine"]
    if !allW8 {
        for layer in 0..<4 {
            for projection in ["mlp.gate_proj", "mlp.up_proj", "mlp.down_proj", "router.proj"] {
                policy["language_model.model.layers.\(layer).\(projection)"] = ["bits": 8, "group_size": 64, "mode": "affine"]
            }
        }
    }
    let text: [String: Any] = [
        "model_type": "gemma4_text", "hidden_size": 128, "num_hidden_layers": 4,
        "intermediate_size": 704, "num_attention_heads": 4, "num_key_value_heads": 2,
        "num_global_key_value_heads": 1, "head_dim": 64, "global_head_dim": 64,
        "attention_k_eq_v": true, "num_kv_shared_layers": 2, "hidden_size_per_layer_input": 64,
        "vocab_size": 512, "vocab_size_per_layer_input": 512, "tie_word_embeddings": true,
        "layer_types": ["sliding_attention", "full_attention", "sliding_attention", "full_attention"],
        "sliding_window": 32, "max_position_embeddings": 8192, "enable_moe_block": true,
        "num_experts": 4, "top_k_experts": 2, "moe_intermediate_size": 704,
        "use_double_wide_mlp": true, "hidden_activation": "gelu_pytorch_tanh",
        "final_logit_softcapping": 30.0,
    ]
    return try JSONSerialization.data(withJSONObject: [
        "model_type": "gemma4", "vocab_size": 512, "text_config": text, "quantization": policy,
        "cluster_fixture_profile": options.syntheticProfile, "cluster_fixture_dtype": options.syntheticDType,
    ], options: [.sortedKeys])
}
