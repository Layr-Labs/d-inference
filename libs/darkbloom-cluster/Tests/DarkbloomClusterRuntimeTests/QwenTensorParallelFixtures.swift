import Foundation
import MLX
@testable import MLXLLM
import MLXLMCommon
import MLXNN
@testable import DarkbloomClusterRuntime

/// Synthetic Qwen 3.5-family checkpoints for the tensor-parallel suites.
enum QwenTensorParallelFixtures {
    /// A synthetic 4-bit Qwen 3.5 dense checkpoint (random weights; the
    /// tensor names and cuts of the real rows, `TensorParallelPlanCheck`).
    static func checkpoint(hidden h: Int, layers: Int, heads hq: Int, kvHeads hkv: Int, vocabulary: Int,
                           linearKeyHeads nk: Int = 2, linearValueHeads nv: Int = 4)
        -> (configuration: Data, tensors: [(String, MLXArray)]) {
        let hd = 256, lk = nk * 128, lv = nv * 128, inter = 2 * h
        let text: [String: Any] = ["model_type": "qwen3_5_text", "hidden_size": h, "num_hidden_layers": layers,
            "full_attention_interval": 4, "num_attention_heads": hq, "num_key_value_heads": hkv, "head_dim": hd,
            "linear_num_key_heads": nk, "linear_num_value_heads": nv, "linear_key_head_dim": 128,
            "linear_value_head_dim": 128, "intermediate_size": inter, "vocab_size": vocabulary,
            "tie_word_embeddings": false, "attn_output_gate": true, "linear_conv_kernel_dim": 4]
        let root: [String: Any] = ["model_type": "qwen3_5", "text_config": text,
                                   "quantization": ["group_size": 64, "bits": 4]]
        var key = MLXRandom.key(2026)
        func next() -> MLXArray { let (a, b) = MLXRandom.split(key: key); key = a; return b }
        func q(_ name: String, _ out: Int, _ input: Int) -> [(String, MLXArray)] {
            let scales = MLXRandom.uniform(low: Float(0.002), high: Float(0.02), [out, input / 64], key: next()).asType(.bfloat16)
            return [(name + ".weight", MLXRandom.randInt(low: 0, high: Int32.max, [out, input / 8], key: next())
                        .asType(.uint32)),
                    (name + ".scales", scales), (name + ".biases", (scales * -7.5).asType(.bfloat16))]
        }
        func norm(_ name: String, _ n: Int, _ dtype: DType = .bfloat16) -> (String, MLXArray) {
            (name, MLXRandom.uniform(low: Float(0.9), high: Float(1.1), [n], key: next()).asType(dtype))
        }
        var all = q("language_model.model.embed_tokens", vocabulary, h) + q("language_model.lm_head", vocabulary, h)
        all.append(norm("language_model.model.norm.weight", h))
        for layer in 0..<layers {
            let p = "language_model.model.layers.\(layer)."
            all += [norm(p + "input_layernorm.weight", h), norm(p + "post_attention_layernorm.weight", h)]
            all += q(p + "mlp.gate_proj", inter, h) + q(p + "mlp.up_proj", inter, h) + q(p + "mlp.down_proj", h, inter)
            if (layer + 1) % 4 != 0 {
                all += q(p + "linear_attn.in_proj_qkv", 2 * lk + lv, h) + q(p + "linear_attn.in_proj_z", lv, h)
                    + q(p + "linear_attn.in_proj_b", nv, h) + q(p + "linear_attn.in_proj_a", nv, h)
                    + q(p + "linear_attn.out_proj", h, lv)
                all += [(p + "linear_attn.conv1d.weight",
                         (MLXRandom.normal([2 * lk + lv, 4, 1], key: next()) * 0.2).asType(.bfloat16)),
                        (p + "linear_attn.A_log", MLXRandom.uniform(low: Float(-1), high: Float(0), [nv], key: next())),
                        (p + "linear_attn.dt_bias", MLXRandom.uniform(low: Float(-0.5), high: Float(0.5), [nv], key: next())
                            .asType(.bfloat16)),
                        norm(p + "linear_attn.norm.weight", 128, .float32)]
            } else {
                all += q(p + "self_attn.q_proj", 2 * hq * hd, h) + q(p + "self_attn.k_proj", hkv * hd, h)
                    + q(p + "self_attn.v_proj", hkv * hd, h) + q(p + "self_attn.o_proj", h, hq * hd)
                all += [norm(p + "self_attn.q_norm.weight", hd), norm(p + "self_attn.k_norm.weight", hd)]
            }
        }
        return (try! JSONSerialization.data(withJSONObject: root), all)
    }

    /// A synthetic routed-expert checkpoint (`qwen3_5_moe`, affine4/group64,
    /// deterministic weights): linear-attention layers and a full-attention
    /// layer every `fullAttentionInterval`, `experts` routed experts of which
    /// each token takes `topK`, and a shared expert, as the registered A3B
    /// rows lay them out (`QwenMoETensorParallelPackingTests` keeps its own).
    static func routedCheckpoint(layers: Int = 4, fullAttentionInterval: Int = 2, experts: Int = 8, topK: Int = 2)
        throws -> (configuration: Data, tensors: [(String, MLXArray)]) {
        let text: [String: Any] = [
            "model_type": "qwen3_5_moe_text", "hidden_size": 128, "num_hidden_layers": layers,
            "num_experts": experts, "num_experts_per_tok": topK, "moe_intermediate_size": 128,
            "shared_expert_intermediate_size": 128, "num_attention_heads": 4, "num_key_value_heads": 2,
            "head_dim": 64, "linear_num_key_heads": 2, "linear_num_value_heads": 4,
            "linear_key_head_dim": 64, "linear_value_head_dim": 64, "linear_conv_kernel_dim": 4,
            "rms_norm_eps": 1e-6, "vocab_size": 256, "rope_theta": 100000.0, "partial_rotary_factor": 0.25,
            "max_position_embeddings": 4096, "tie_word_embeddings": false, "attention_bias": false,
            "attn_output_gate": true, "full_attention_interval": fullAttentionInterval, "mtp_num_hidden_layers": 0,
        ]
        let root: [String: Any] = ["model_type": "qwen3_5_moe", "text_config": text,
                                   "quantization": ["group_size": 64, "bits": 4, "mode": "affine"]]
        let configuration = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        let model = Qwen35MoEModel(try JSONDecoder().decode(Qwen35Configuration.self, from: configuration))
        let values = model.parameters().flattened().map { name, array in
            let seed = name.utf8.reduce(0) { $0 + Int($1) }
            let norm = name.contains("norm.weight")
            var data = (0..<array.size).map { Float(($0 * 17 + seed) % 127 - 63) / 512 + (norm ? 1 : 0) }
            // Recurrent decay terms in a stable range, as the synthetic dense checkpoint keeps them.
            if name.hasSuffix("linear_attn.A_log") { data = data.map { -abs($0) - 0.25 } }
            return (name, MLXArray(data, array.shape).asType(.bfloat16))
        }
        model.update(parameters: ModuleParameters.unflattened(values))
        quantize(model: model) { _, _ in (64, 4, .affine) }
        eval(model)
        return (configuration, model.parameters().flattened().sorted { $0.0 < $1.0 })
    }
}
