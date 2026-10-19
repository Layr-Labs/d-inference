import Foundation
@testable import MLXLLM

enum GLM5NextInventoryFixture {
    static func configuration(layers: Int = 4, q4: Bool = false) throws -> GLM5NextConfiguration {
        let d = q4 ? 64 : 4
        let a = q4 ? 64 : 2
        let types = (0 ..< layers).map {
            $0 % 4 == 3 ? "deepseek_sparse_attention" : "linear_attention"
        }
        let linear = types.indices.filter { types[$0] == "linear_attention" }
        let sparse = types.indices.filter { types[$0] == "deepseek_sparse_attention" }
        let dense = min(layers, 3)
        let text: [String: Any] = [
            "model_type": "glm5_next_text", "vocab_size": 32, "hidden_size": d,
            "intermediate_size": q4 ? 64 : 8, "moe_intermediate_size": q4 ? 64 : 4,
            "num_hidden_layers": layers, "num_attention_heads": 1, "num_key_value_heads": 1,
            "head_dim": 0, "qk_head_dim": a, "qk_nope_head_dim": a, "qk_rope_head_dim": 0,
            "v_head_dim": a, "q_lora_rank": d, "kv_lora_rank": q4 ? 64 : 2,
            "mla_use_nope": true, "layer_types": types,
            "mlp_layer_types": (0 ..< layers).map { $0 < dense ? "dense" : "sparse" },
            "indexer_types": Array(repeating: "full", count: layers),
            "linear_attn_config": [
                "num_heads": 1, "head_dim": a, "gate_lower_bound": -5,
                "short_conv_kernel_size": 4, "kda_layers": linear, "full_attn_layers": sparse,
            ],
            "index_head_dim": a, "index_n_heads": 1, "index_topk": 4, "index_kpool": 4,
            "index_kpool_compress": true, "index_kpool_always_select_tail": true,
            "indexer_rope_interleave": true, "index_share_for_mtp_iteration": true,
            "mhc": true, "hc_mult": 4, "hc_eps": 1e-6, "hc_sinkhorn_iters": 20,
            "first_k_dense_replace": dense, "n_routed_experts": 2, "n_shared_experts": 1,
            "num_experts_per_tok": 1, "n_group": 1, "topk_group": 1,
            "norm_topk_prob": true, "routed_scaling_factor": 2.5,
            "scoring_func": "sigmoid", "topk_method": "noaux_tc", "moe_router_dtype": "float32",
            "output_router_logits": false, "router_aux_loss_coef": 0.001,
            "num_nextn_predict_layers": 1, "hidden_act": "silu", "swiglu_limit": 10,
            "rms_norm_eps": 1e-5, "attention_bias": false, "attention_dropout": 0,
            "max_position_embeddings": 256, "initializer_range": 0.02, "use_cache": true,
            "tie_word_embeddings": false, "dtype": "float32", "pad_token_id": 0,
            "eos_token_id": [1, 2, 3],
        ]
        var root: [String: Any] = [
            "model_type": "glm5_next", "architectures": ["Glm5NextForConditionalGeneration"],
            "tie_word_embeddings": false, "text_config": text,
            "image_token_id": 10, "video_token_id": 11, "image_start_token_id": 12,
            "image_end_token_id": 13, "video_start_token_id": 14, "video_end_token_id": 15,
            "vision_config": [
                "model_type": "glm5_next_vision", "depth": 1, "hidden_size": 8,
                "intermediate_size": 12, "num_heads": 2, "image_size": 8, "patch_size": 2,
                "temporal_patch_size": 2, "spatial_merge_size": 2, "in_channels": 3,
                "out_hidden_size": d, "projection_intermediate_size": 8, "hidden_act": "silu",
                "swiglu_limit": 10, "rms_norm_eps": 1e-5, "attention_bias": true,
                "attention_dropout": 0, "initializer_range": 0.02,
            ],
        ]
        if q4 { root["quantization"] = ["bits": 4, "group_size": 64, "mode": "affine"] }
        return try JSONDecoder().decode(
            GLM5NextConfiguration.self, from: JSONSerialization.data(withJSONObject: root))
    }
}
