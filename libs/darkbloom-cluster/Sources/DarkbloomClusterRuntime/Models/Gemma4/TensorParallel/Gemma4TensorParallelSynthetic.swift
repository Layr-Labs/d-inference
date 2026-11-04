import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN

extension Gemma4TensorParallelModel {
    /// Writes a tiny random Gemma 4 MoE checkpoint into `directory`
    /// (`config.json`, `model.safetensors` and its index), seeded, with the
    /// 26B's structure scaled down: sliding and full layers (window 16), 16
    /// query heads with 8 sliding and 2 full KV heads (head dims 256 and 512,
    /// K=V on full layers), a dense GeGLU MLP in parallel with 16 routed
    /// experts (top-4), sandwich norms, a tied softcapped head, and affine
    /// group-64 quantization (`bits` by default, 8-bit dense MLP and router)
    /// whose dense (5) and expert (3) group counts are odd, so both overlap
    /// splits run. For model-free equality checks of tensor parallel; never a
    /// model pass.
    ///
    /// `dtype` is the weights' and so the activations' type: BF16 as the
    /// artifacts, or FP32, whose rounding is too small to flip a random
    /// router's near-tied top-k choice (a random router's scores sit closer
    /// together than a trained one's).
    /// `experts`/`topK` change the routed bank (with `topK == experts` every
    /// token takes every expert, and no rounding can change a route).
    public static func writeSyntheticCheckpoint(directory: URL, seed: UInt64 = 7, bits: Int = 4,
                                                dtype: DType = .bfloat16, experts: Int = 16, topK: Int = 4) throws {
        guard [4, 8].contains(bits) else { throw ProbeError("Gemma synthetic checkpoint: bits are 4 or 8") }
        guard (1 ... 64).contains(experts), (1 ... experts).contains(topK) else {
            throw ProbeError("Gemma synthetic checkpoint: 1 to 64 experts, top-k at most the experts")
        }
        guard [.bfloat16, .float32].contains(dtype) else {
            throw ProbeError("Gemma synthetic checkpoint: weights are bfloat16 or float32")
        }
        let layers = 6
        let kinds = (0 ..< layers).map { ($0 + 1) % 3 == 0 ? "full_attention" : "sliding_attention" }
        let text: [String: Any] = [
            "model_type": "gemma4_text", "hidden_size": 256, "num_hidden_layers": layers, "layer_types": kinds,
            "intermediate_size": 320, "moe_intermediate_size": 192, "num_experts": experts, "top_k_experts": topK,
            "num_attention_heads": 16, "num_key_value_heads": 8, "num_global_key_value_heads": 2,
            "head_dim": 256, "global_head_dim": 512, "sliding_window": 16, "vocab_size": 512,
            "vocab_size_per_layer_input": 0, "hidden_size_per_layer_input": 0, "num_kv_shared_layers": 0,
            "attention_k_eq_v": true, "enable_moe_block": true, "tie_word_embeddings": true,
            "use_double_wide_mlp": false, "attention_bias": false, "final_logit_softcapping": 30.0,
            "rms_norm_eps": 1e-6, "max_position_embeddings": 4096, "hidden_activation": "gelu_pytorch_tanh",
            "use_bidirectional_attention": "vision", "dtype": dtype == .float32 ? "float32" : "bfloat16",
            "rope_parameters": [
                "sliding_attention": ["rope_type": "default", "rope_theta": 10000.0],
                "full_attention": ["rope_type": "proportional", "rope_theta": 1_000_000.0, "partial_rotary_factor": 0.25],
            ],
        ]
        var quantization: [String: Any] = ["group_size": 64, "bits": bits, "mode": "affine"]
        for layer in 0 ..< layers {
            for module in ["mlp.gate_proj", "mlp.up_proj", "mlp.down_proj", "router.proj"] {
                quantization["language_model.model.layers.\(layer).\(module)"] = ["group_size": 64, "bits": 8]
            }
        }
        let root: [String: Any] = ["model_type": "gemma4", "text_config": text, "tie_word_embeddings": true,
                                   "vocab_size": 512, "quantization": quantization, "quantization_config": quantization]
        let configurationData = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .prettyPrinted])
        let plan = try Gemma4TensorParallelPlan(configuration: root)
        let configuration = try JSONDecoder().decode(Gemma4Configuration.self, from: configurationData)
        let arrays: [String: MLXArray] = withRandomState(MLXRandom.RandomState(seed: seed)) {
            let model = Gemma4Model(configuration)
            var values: [(String, MLXArray)] = []
            for (key, value) in model.parameters().flattened() {
                let shape = value.shape
                let generated: MLXArray
                if key.hasSuffix("embed_tokens.weight") {
                    generated = MLXRandom.normal(shape) * 0.1
                } else if key.hasSuffix("layer_scalar") {
                    generated = MLXRandom.uniform(low: 0.5, high: 1.0, shape)
                } else if key.hasSuffix("per_expert_scale") {
                    generated = MLXRandom.uniform(low: 0.5, high: 1.5, shape)
                } else if key.hasSuffix("q_norm.weight") || key.hasSuffix("k_norm.weight") {
                    // Gemma 4 attends at scale 1: small per-head norms keep
                    // scores near unit spread, as a trained model's do, so
                    // softmax is not an argmax that rounding can flip.
                    generated = MLXRandom.uniform(low: 0.2, high: 0.3, shape)
                } else if key.hasSuffix("norm.weight") || key.hasSuffix("router.scale") {
                    generated = MLXRandom.uniform(low: 0.6, high: 1.4, shape)
                } else {
                    let fanIn = Float(shape.last ?? 1)
                    generated = MLXRandom.normal(shape) * (1 / fanIn.squareRoot())
                }
                values.append((key, generated.asType(dtype)))
            }
            model.update(parameters: ModuleParameters.unflattened(values))
            quantize(model: model) { path, module in
                guard module is Linear || module is SwitchLinear || module is Embedding else { return nil }
                return (64, plan.bits(forModule: path), .affine)
            }
            let flat = Dictionary(uniqueKeysWithValues: model.parameters().flattened())
            eval(Array(flat.values))
            return flat
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try configurationData.write(to: directory.appendingPathComponent("config.json"))
        try save(arrays: arrays, url: directory.appendingPathComponent("model.safetensors"))
        let index: [String: Any] = ["metadata": [:] as [String: Any],
                                    "weight_map": Dictionary(uniqueKeysWithValues: arrays.keys.map { ($0, "model.safetensors") })]
        try JSONSerialization.data(withJSONObject: index, options: [.sortedKeys, .prettyPrinted])
            .write(to: directory.appendingPathComponent("model.safetensors.index.json"))
    }
}
