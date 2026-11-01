import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN

extension MiMoTensorParallelModel {
    /// Synthetic MiMo V2.6 geometries for model-free tensor-parallel checks.
    /// Random weights: never a model pass.
    public enum SyntheticVariant: String, CaseIterable, Sendable {
        /// Hidden 1,024; 16 experts, top-8, expert width 1,024 (512 per rank,
        /// MXFP4 group 32); 16 query heads with 2 full and 4 sliding KV heads
        /// at the registered head dims 192/128, sinks on sliding layers; 8-bit
        /// attention, dense layer and head. Every per-rank decode shape stays
        /// inside the production MiMo decode kernels' gates (experts, router
        /// GEMV, fused norms), as the whole model's do.
        case kernel
        /// Hidden 256; 8 experts, top-2; below those gates, so the generic
        /// expert, router and attention paths run.
        case tiny
    }

    /// The variant's whole `config.json` object. `experts`/`topK` replace the
    /// variant's routed bank (with `topK == experts` every token takes every
    /// expert, so no rounding can change a route).
    public static func syntheticConfiguration(_ variant: SyntheticVariant, dtype: DType = .bfloat16,
                                              experts: Int? = nil, topK: Int? = nil) -> [String: Any] {
        let kernel = variant == .kernel
        let layers = kernel ? 6 : 4
        let dtypeName = dtype == .float32 ? "float32" : "bfloat16"
        var quantization: [String: Any] = ["group_size": 64, "bits": 8, "mode": "affine"]
        let pattern = kernel ? [0, 1, 1, 0, 1, 1] : [0, 1, 1, 0]
        let routed = (0 ..< layers).map { $0 == 0 ? 0 : 1 }
        for layer in 0 ..< layers where routed[layer] == 1 {
            for module in ["gate_proj", "up_proj", "down_proj"] {
                quantization["language_model.model.layers.\(layer).mlp.switch_mlp.\(module)"] =
                    ["group_size": 32, "bits": 4, "mode": "mxfp4"]
            }
        }
        return [
            "model_type": "mimo_v2", "architectures": ["MiMoV2ForCausalLM"],
            "hidden_size": kernel ? 1024 : 256, "intermediate_size": kernel ? 2048 : 512,
            "moe_intermediate_size": kernel ? 1024 : 256, "vocab_size": kernel ? 4096 : 512,
            "num_hidden_layers": layers, "max_position_embeddings": 4096,
            "sliding_window": 8, "sliding_window_size": 8, "num_nextn_predict_layers": 0,
            "hybrid_layer_pattern": pattern, "moe_layer_freq": routed,
            "partial_rotary_factor": 0.334, "attention_value_scale": 0.707, "layernorm_epsilon": 1e-5,
            "attention_projection_layout": "fused_qkv", "moe_router_dtype": dtypeName, "hidden_act": "silu",
            "dtype": dtypeName, "attention_bias": false, "tie_word_embeddings": false, "attention_dropout": 0.0,
            "scoring_func": "sigmoid", "topk_method": "noaux_tc", "n_routed_experts": experts ?? (kernel ? 16 : 8),
            "num_experts_per_tok": topK ?? (kernel ? 8 : 2), "n_group": 1, "topk_group": 1, "norm_topk_prob": true,
            "num_attention_heads": kernel ? 16 : 4, "num_key_value_heads": 2,
            "head_dim": kernel ? 192 : 48, "v_head_dim": kernel ? 128 : 32, "rope_theta": 10_000_000.0,
            "add_full_attention_sink_bias": false,
            "swa_num_attention_heads": kernel ? 16 : 4, "swa_num_key_value_heads": kernel ? 4 : 2,
            "swa_head_dim": kernel ? 192 : 48, "swa_v_head_dim": kernel ? 128 : 32, "swa_rope_theta": 10_000.0,
            "add_swa_attention_sink_bias": true, "eos_token_id": [1, 2], "pad_token_id": 0,
            "quantization": quantization, "quantization_config": quantization,
        ]
    }

    /// Writes a seeded random checkpoint of `variant` into `directory`
    /// (`config.json`, `model.safetensors` and its index), quantized as the
    /// registered artifact is (MXFP4 experts, affine 8-bit group 64
    /// elsewhere; BF16 router, norms and sinks; FP32 score correction), with
    /// one MTP and one vision tensor that every loader must skip by name.
    public static func writeSyntheticCheckpoint(directory: URL, variant: SyntheticVariant, seed: UInt64 = 7,
                                                dtype: DType = .bfloat16, experts: Int? = nil, topK: Int? = nil) throws {
        guard [.bfloat16, .float32].contains(dtype) else {
            throw ProbeError("MiMo synthetic checkpoint: weights are bfloat16 or float32")
        }
        if experts != nil || topK != nil {
            guard let experts, let topK, (2 ... 64).contains(experts), (1 ... experts).contains(topK) else {
                throw ProbeError("MiMo synthetic checkpoint: 2 to 64 experts, top-k at most the experts")
            }
        }
        let configurationData = try JSONSerialization.data(
            withJSONObject: syntheticConfiguration(variant, dtype: dtype, experts: experts, topK: topK),
            options: [.sortedKeys, .prettyPrinted])
        let plan = try MiMoTensorParallelPlan(configuration: configurationData)
        let configuration = try JSONDecoder().decode(MiMoV26Configuration.self, from: configurationData)
        var arrays = try withRandomState(MLXRandom.RandomState(seed: seed)) { () throws -> [String: MLXArray] in
            let model = try MiMoV26TextModel(configuration)
            var values: [(String, MLXArray)] = []
            for (key, value) in model.parameters().flattened() {
                let shape = value.shape
                if key.hasSuffix("e_score_correction_bias") {
                    values.append((key, MLXRandom.normal(shape) * 0.05))
                    continue
                }
                let generated: MLXArray
                if key.hasSuffix("attention_sink_bias") {
                    generated = MLXRandom.uniform(low: -1.0, high: 1.0, shape)
                } else if key.hasSuffix("norm.weight") || key.hasSuffix("layernorm.weight") {
                    generated = MLXRandom.uniform(low: 0.6, high: 1.4, shape)
                } else if key.hasSuffix("embed_tokens.weight") {
                    generated = MLXRandom.normal(shape)
                } else {
                    generated = MLXRandom.normal(shape) * (1 / Float(shape.last ?? 1).squareRoot())
                }
                values.append((key, generated.asType(dtype)))
            }
            try model.update(parameters: ModuleParameters.unflattened(values), verify: [.noUnusedKeys, .shapeMismatch])
            quantize(model: model) { path, module in
                guard module is Linear || module is SwitchLinear || module is Embedding,
                      let policy = plan.policy(module: MiMoTensorParallelPlan.textNamespace + path) else { return nil }
                return (policy.groupSize, policy.bits, policy.mode == "mxfp4" ? .mxfp4 : .affine)
            }
            let flat = Dictionary(uniqueKeysWithValues: model.parameters().flattened().map {
                (MiMoTensorParallelPlan.textNamespace + $0.0, $0.1)
            })
            eval(Array(flat.values))
            return flat
        }
        arrays["language_model.model.mtp.layers.0.enorm.weight"] = MLXArray.ones([plan.hiddenSize], dtype: dtype)
        arrays["vision_tower.patch_embed.proj.weight"] = MLXArray.zeros([8, 8], dtype: dtype)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try configurationData.write(to: directory.appendingPathComponent("config.json"))
        try save(arrays: arrays, url: directory.appendingPathComponent("model.safetensors"))
        let index: [String: Any] = ["metadata": [:] as [String: Any],
                                    "weight_map": Dictionary(uniqueKeysWithValues: arrays.keys.map { ($0, "model.safetensors") })]
        try JSONSerialization.data(withJSONObject: index, options: [.sortedKeys, .prettyPrinted])
            .write(to: directory.appendingPathComponent("model.safetensors.index.json"))
    }
}
