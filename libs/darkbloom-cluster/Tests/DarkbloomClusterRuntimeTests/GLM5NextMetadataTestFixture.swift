import Foundation
import MLXLLM
@testable import DarkbloomClusterRuntime

/// Tiny complete SDK metadata, without weights, native arrays or file payloads.
struct GLM5NextMetadataTestFixture {
    let configuration: GLM5NextConfiguration
    let inventory: GLM5NextWeightInventory
    let index: Data
    let shards: [String: GLM5NextHeaderInventory.Shard]

    init(layers: Int = 45, textDType: String = "float32") throws {
        let kinds = (0..<layers).map { $0 % 4 == 3 ? "deepseek_sparse_attention" : "linear_attention" }
        let dense = min(3, layers)
        let text: [String: Any] = [
            "model_type": "glm5_next_text", "vocab_size": 32, "hidden_size": 4,
            "intermediate_size": 8, "moe_intermediate_size": 4, "num_hidden_layers": layers,
            "num_attention_heads": 1, "num_key_value_heads": 1, "head_dim": 0,
            "qk_head_dim": 2, "qk_nope_head_dim": 2, "qk_rope_head_dim": 0,
            "v_head_dim": 2, "q_lora_rank": 4, "kv_lora_rank": 2, "mla_use_nope": true,
            "layer_types": kinds,
            "mlp_layer_types": (0..<layers).map { $0 < dense ? "dense" : "sparse" },
            "indexer_types": Array(repeating: "full", count: layers),
            "linear_attn_config": [
                "num_heads": 1, "head_dim": 2, "gate_lower_bound": -5,
                "short_conv_kernel_size": 4,
                "kda_layers": kinds.indices.filter { kinds[$0] == "linear_attention" },
                "full_attn_layers": kinds.indices.filter { kinds[$0] == "deepseek_sparse_attention" },
            ],
            "index_head_dim": 2, "index_n_heads": 1, "index_topk": 4, "index_kpool": 4,
            "index_kpool_compress": true, "index_kpool_always_select_tail": true,
            "indexer_rope_interleave": true, "index_share_for_mtp_iteration": true,
            "mhc": true, "hc_mult": 4, "hc_eps": 1e-6, "hc_sinkhorn_iters": 20,
            "first_k_dense_replace": dense, "n_routed_experts": 2, "n_shared_experts": 1,
            "num_experts_per_tok": 1, "n_group": 1, "topk_group": 1, "norm_topk_prob": true,
            "routed_scaling_factor": 2.5, "scoring_func": "sigmoid", "topk_method": "noaux_tc",
            "moe_router_dtype": "float32", "output_router_logits": false, "router_aux_loss_coef": 0.001,
            "num_nextn_predict_layers": 1, "hidden_act": "silu", "swiglu_limit": 10, "rms_norm_eps": 1e-5,
            "attention_bias": false, "attention_dropout": 0, "max_position_embeddings": 256,
            "initializer_range": 0.02, "use_cache": true, "tie_word_embeddings": false,
            "dtype": textDType, "pad_token_id": 0, "eos_token_id": [1, 2, 3],
        ]
        let root: [String: Any] = [
            "model_type": "glm5_next", "architectures": ["Glm5NextForConditionalGeneration"],
            "tie_word_embeddings": false, "text_config": text,
            "image_token_id": 10, "video_token_id": 11, "image_start_token_id": 12,
            "image_end_token_id": 13, "video_start_token_id": 14, "video_end_token_id": 15,
            "vision_config": [
                "model_type": "glm5_next_vision", "depth": 1, "hidden_size": 8,
                "intermediate_size": 12, "num_heads": 2, "image_size": 8, "patch_size": 2,
                "temporal_patch_size": 2, "spatial_merge_size": 2, "in_channels": 3,
                "out_hidden_size": 4, "projection_intermediate_size": 8, "hidden_act": "silu",
                "swiglu_limit": 10, "rms_norm_eps": 1e-5, "attention_bias": true,
                "attention_dropout": 0, "initializer_range": 0.02,
            ],
        ]
        let configuration = try JSONDecoder().decode(GLM5NextConfiguration.self,
            from: JSONSerialization.data(withJSONObject: root))
        self.configuration = configuration
        let headers = try GLM5NextWeightInventory.expectedTensors(
            configuration: configuration, storage: .float32, shard: "a.safetensors")
        let located = headers.enumerated().map { index, tensor in
            GLM5NextWeightInventory.Tensor(name: tensor.name, shape: tensor.shape, dtype: tensor.dtype,
                shard: index % 2 == 0 ? "a.safetensors" : "b.safetensors")
        }
        let inventory = try GLM5NextWeightInventory.validate(
            configuration: configuration, tensors: located, storage: .float32)
        self.inventory = inventory
        var shards: [String: GLM5NextHeaderInventory.Shard] = [:]
        for shard in ["a.safetensors", "b.safetensors"] {
            var header: [String: Any] = [:], offset = 0
            for entry in inventory.entries.values.sorted(by: { $0.tensor.name < $1.tensor.name })
            where entry.tensor.shard == shard {
                header[entry.tensor.name] = ["shape": entry.tensor.shape, "dtype": entry.tensor.dtype,
                    "data_offsets": [offset, offset + entry.bytes]]
                offset += entry.bytes
            }
            let data = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
            shards[shard] = .init(data: data, fileBytes: 8 + data.count + offset)
        }
        self.shards = shards
        index = try JSONSerialization.data(withJSONObject: [
            "metadata": ["total_size": inventory.entries.values.reduce(0) { $0 + $1.bytes }],
            "weight_map": Dictionary(uniqueKeysWithValues: located.map { ($0.name, $0.shard) }),
        ], options: [.sortedKeys])
    }

    func validate(index: Data? = nil, shards: [String: GLM5NextHeaderInventory.Shard]? = nil) throws
        -> GLM5NextWeightInventory {
        try GLM5NextHeaderInventory.validate(configuration: configuration,
            index: index ?? self.index, storage: .float32) { name in
                guard let shard = (shards ?? self.shards)[name] else { throw ProbeError("Missing test shard") }
                return shard
            }
    }
}
