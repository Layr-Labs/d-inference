import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
import Testing
@testable import DarkbloomClusterRuntime

/// Small deterministic packed GPT-OSS models; no catalog payload or GPU.
enum GPTOSSNativeTestFixture {
    static func model(layers: Range<Int>, dtype: DType) throws -> GPTOSSModel {
        let json: [String: Any] = [
            "model_type": "gpt_oss", "num_hidden_layers": layers.count,
            "num_local_experts": 4, "num_experts_per_tok": 2, "vocab_size": 64,
            "rms_norm_eps": 1e-5, "hidden_size": 64, "intermediate_size": 64,
            "head_dim": 16, "num_attention_heads": 4, "num_key_value_heads": 2,
            "sliding_window": 8,
            "layer_types": layers.map { $0.isMultiple(of: 2) ? "sliding_attention" : "full_attention" },
        ]
        let value = GPTOSSModel(try JSONDecoder().decode(GPTOSSConfiguration.self,
            from: JSONSerialization.data(withJSONObject: json)))
        // Deterministic, nonzero parameters (including learned sinks). Only
        // fixture initialization converts dtype; no forward result is cast.
        let parameters = value.parameters().flattened().map { name, array in
            let seed = name.utf8.reduce(0) { $0 + Int($1) }
            let norm = name.contains("norm.weight")
            let values = (0..<array.size).map { Float(($0 * 13 + seed) % 101 - 50) / 256 + (norm ? 1 : 0) }
            return (name, MLXArray(values, array.shape).asType(dtype))
        }
        value.update(parameters: ModuleParameters.unflattened(parameters))
        quantize(model: value, groupSize: 32, bits: 4, mode: .mxfp4,
            filter: { path, _ in path.contains(".experts.") })
        // The registered checkpoint uses affine 8-bit non-expert projections.
        quantize(model: value, groupSize: 64, bits: 8,
            filter: { path, _ in !path.contains(".experts.") })
        eval(value)
        return value
    }

    static func stage(from whole: GPTOSSModel, layers: Range<Int>, first: Bool, dtype: DType) throws -> GPTOSSModel {
        let value = try model(layers: layers, dtype: dtype)
        let replacements: [(String, Module)] = first
            ? [("model.norm", GPTOSSStageIdentityNorm()), ("lm_head", GPTOSSStageDiscardedHead(hiddenSize: 64, dtype: dtype))]
            : [("model.embed_tokens", GPTOSSStageResidualEmbedding(hiddenSize: 64, dtype: dtype))]
        try value.update(modules: ModuleChildren.unflattened(replacements), verify: [.noUnusedKeys])
        let source = Dictionary(uniqueKeysWithValues: whole.parameters().flattened())
        let parameters = try value.parameters().flattened().compactMap { name, _ -> (String, MLXArray)? in
            if replacements.contains(where: { name.hasPrefix($0.0 + ".") }) { return nil }
            var sourceName = name
            if name.hasPrefix("model.layers.") {
                var parts = name.split(separator: ".").map(String.init)
                parts[2] = String(try #require(Int(parts[2])) + layers.lowerBound)
                sourceName = parts.joined(separator: ".")
            }
            return (name, try #require(source[sourceName]))
        }
        try value.update(parameters: ModuleParameters.unflattened(parameters), verify: [.noUnusedKeys, .shapeMismatch])
        value.freeze()
        return value
    }

}
