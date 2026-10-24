import Foundation
import MLX
import MLXLLM
import MLXNN
import Testing
@testable import DarkbloomClusterRuntime

@Suite("Qwen3.6 mixed routing-gate tensor-parallel loading (CPU)", .serialized)
struct QwenMixedRouterTensorParallelTests {
    // Construction only: a shard must not call its reduction while loading.
    private final class LoadReduction: QwenTensorParallelReduction {
        let rank: Int
        let size = 2
        var calls = 0
        init(rank: Int) { self.rank = rank }
        func allSum(_ value: MLXArray) -> MLXArray { calls += 1; return value }
    }

    private func fixture() throws -> (root: [String: Any], model: Qwen35MoEModel, weights: [String: MLXArray]) {
        let text: [String: Any] = [
            "model_type": "qwen3_5_moe_text", "hidden_size": 128, "num_hidden_layers": 2,
            "num_experts": 4, "num_experts_per_tok": 2, "moe_intermediate_size": 128,
            "shared_expert_intermediate_size": 128, "num_attention_heads": 4, "num_key_value_heads": 2,
            "head_dim": 64, "linear_num_key_heads": 2, "linear_num_value_heads": 4,
            "linear_key_head_dim": 64, "linear_value_head_dim": 64, "linear_conv_kernel_dim": 4,
            "rms_norm_eps": 1e-6, "vocab_size": 256, "rope_theta": 100000.0, "partial_rotary_factor": 0.25,
            "max_position_embeddings": 4096, "tie_word_embeddings": false, "attention_bias": false,
            "attn_output_gate": true, "full_attention_interval": 1, "mtp_num_hidden_layers": 0,
        ]
        var quantization: [String: Any] = ["group_size": 64, "bits": 4, "mode": "affine"]
        let gates = Set((0..<2).flatMap { layer in
            ["language_model.model.layers.\(layer).mlp.gate",
             "language_model.model.layers.\(layer).mlp.shared_expert_gate"]
        })
        for path in gates { quantization[path] = ["group_size": 64, "bits": 8] }
        let root: [String: Any] = ["model_type": "qwen3_5_moe", "text_config": text, "quantization": quantization]
        let config = try JSONDecoder().decode(Qwen35Configuration.self,
            from: JSONSerialization.data(withJSONObject: root))
        let model = Qwen35MoEModel(config)
        let values = model.parameters().flattened().map { name, array in
            let seed = name.utf8.reduce(0) { $0 + Int($1) }
            let norm = name.contains("norm.weight")
            let data = (0..<array.size).map { Float(($0 * 17 + seed) % 127 - 63) / 512 + (norm ? 1 : 0) }
            return (name, MLXArray(data, array.shape).asType(.bfloat16))
        }
        model.update(parameters: ModuleParameters.unflattened(values))
        // Independent fixture policy: do not derive expected packing from the
        // plan under test. The SDK model and bytes are the reference.
        quantize(model: model) { path, _ in (64, gates.contains(path) ? 8 : 4, .affine) }
        eval(model)
        return (root, model, Dictionary(uniqueKeysWithValues: model.parameters().flattened()))
    }

    @Test func canonicalAndStoredBanksLoadWithExactMixedPacking() throws {
        try Device.withDefaultDevice(.cpu) {
            let fixture = try fixture()
            let config = try JSONSerialization.data(withJSONObject: fixture.root, options: [.sortedKeys])
            var split: [String: MLXArray] = [:]
            for (name, value) in fixture.weights {
                if name.contains(".switch_mlp.gate_up_proj.") {
                    let half = value.dim(1) / 2
                    split[name.replacingOccurrences(of: ".gate_up_proj.", with: ".gate_proj.")] = value[0..., 0..<half, 0...]
                    split[name.replacingOccurrences(of: ".gate_up_proj.", with: ".up_proj.")] = value[0..., half..., 0...]
                } else { split[name] = value }
            }
            for weights in [fixture.weights, split] {
                let loaded = try QwenTensorParallelModel.assemble(configurationData: config, role: .full, reduction: nil) { _, keep in
                    for name in weights.keys.sorted() { try keep(name, weights[name]!) }
                }
                let referenceCache = fixture.model.newCache(parameters: nil), loadedCache = loaded.newCache()
                for tokens: [Int32] in [[1, 7, 19], [31], [43, 59]] {
                    let input = MLXArray(tokens).reshaped([1, tokens.count])
                    let expected = fixture.model(input, cache: referenceCache)
                    let actual = loaded.forwardForRuntime(input, cache: loadedCache)
                    eval(expected, actual)
                    #expect(actual.dtype == .bfloat16 && actual.shape == expected.shape)
                    #expect(actual.asData().data == expected.asData().data)
                    #expect(actual.asArray(Float.self).allSatisfy { $0.isFinite })
                }
                for rank in 0..<2 {
                    let reduction = LoadReduction(rank: rank)
                    let shard = try QwenTensorParallelModel.assemble(configurationData: config,
                        role: .shard(rank: rank, size: 2), reduction: reduction) { _, keep in
                        for name in weights.keys.sorted() { try keep(name, weights[name]!) }
                    }
                    #expect(reduction.calls == 0)
                    #expect(shard.loadedParameterBytes < loaded.loadedParameterBytes)
                    #expect(2 * shard.loadedParameterBytes > loaded.loadedParameterBytes)
                    #expect(shard.plan.affineQuantization(forModule: "language_model.model.layers.0.mlp.gate").bits == 8)
                }
            }
        }
    }

    @Test func aDividedOverrideIsRefusedBeforeAnyTensorRead() throws {
        try Device.withDefaultDevice(.cpu) {
            var root = try fixture().root
            var quantization = try #require(root["quantization"] as? [String: Any])
            quantization["language_model.model.layers.0.mlp.switch_mlp.down_proj"] = ["group_size": 64, "bits": 8]
            root["quantization"] = quantization
            let config = try JSONSerialization.data(withJSONObject: root)
            var read = false
            #expect(throws: ProbeError.self) {
                _ = try QwenTensorParallelModel.assemble(configurationData: config, role: .full, reduction: nil) { _, _ in
                    read = true
                }
            }
            #expect(!read)
        }
    }
}
