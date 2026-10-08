import Foundation

enum Gemma4StageAttentionKind: String, Codable {
    case sliding = "sliding_attention"
    case full = "full_attention"
}

struct Gemma4AffineQuantization: Encodable, Equatable {
    let bits: Int
    let groupSize: Int
    let mode: String
    var jsonObject: [String: Any] { ["bits": bits, "group_size": groupSize, "mode": mode] }
}

/// Closed metadata for this artifact. It selects no native kernel or execution profile.
struct Gemma4TextMetadata: Encodable, Equatable {
    let layerKinds: [Gemma4StageAttentionKind]
    let hiddenSize = 2816
    let vocabularySize = 262144
    let sharedIntermediateSize = 2112
    let expertIntermediateSize = 704
    let expertCount = 128
    let expertsPerToken = 8
    let slidingWindow = 1024
    let queryHeads = 16
    let slidingKVHeads = 8
    let fullKVHeads = 2
    let slidingHeadDimension = 256
    let fullHeadDimension = 512
    let quantizationDefaults = Gemma4AffineQuantization(bits: 4, groupSize: 64, mode: "affine")
    let quantizationOverrides: [String: Gemma4AffineQuantization]
    var globalLayerCount: Int { layerKinds.count }

    private init(kinds: [Gemma4StageAttentionKind], overrides: [String: Gemma4AffineQuantization]) {
        layerKinds = kinds; quantizationOverrides = overrides
    }

    static func decode(_ configuration: Data) throws -> Self {
        guard (1...1_048_576).contains(configuration.count),
              let root = try JSONSerialization.jsonObject(with: configuration) as? [String: Any],
              root["model_type"] as? String == "gemma4",
              let text = root["text_config"] as? [String: Any],
              text["model_type"] as? String == "gemma4_text" else { throw ProbeError("Gemma stage metadata requires the original text wrapper") }
        let integers = ["num_hidden_layers": 30, "hidden_size": 2816, "vocab_size": 262144,
            "intermediate_size": 2112, "moe_intermediate_size": 704, "num_experts": 128,
            "top_k_experts": 8, "sliding_window": 1024, "num_attention_heads": 16,
            "num_key_value_heads": 8, "num_global_key_value_heads": 2, "head_dim": 256,
            "global_head_dim": 512, "num_kv_shared_layers": 0, "hidden_size_per_layer_input": 0,
            "max_position_embeddings": 262144]
        for (key, expected) in integers {
            guard BoundedProbeInput.integer(text[key]) == expected else {
                throw ProbeError("Unsupported Gemma stage geometry: \(key)")
            }
        }
        func boolean(_ value: Any?, _ expected: Bool) -> Bool {
            guard let number = value as? NSNumber, String(cString: number.objCType) == "c" else { return false }
            return number.boolValue == expected
        }
        guard boolean(root["tie_word_embeddings"], true), boolean(text["tie_word_embeddings"], true),
              boolean(text["attention_k_eq_v"], true), boolean(text["enable_moe_block"], true),
              boolean(text["use_double_wide_mlp"], false), boolean(text["attention_bias"], false),
              text["use_bidirectional_attention"] as? String == "vision",
              text["dtype"] as? String == "bfloat16",
              text["hidden_activation"] as? String == "gelu_pytorch_tanh",
              (text["final_logit_softcapping"] as? NSNumber)?.doubleValue == 30 else {
            throw ProbeError("Unsupported Gemma embedding, attention, dtype or activation policy")
        }
        let kinds = (0..<30).map { ($0 + 1) % 6 == 0 ? Gemma4StageAttentionKind.full : .sliding }
        guard text["layer_types"] as? [String] == kinds.map(\.rawValue),
              let rope = text["rope_parameters"] as? [String: Any],
              let sliding = rope["sliding_attention"] as? [String: Any],
              let full = rope["full_attention"] as? [String: Any],
              sliding["rope_type"] as? String == "default", (sliding["rope_theta"] as? NSNumber)?.doubleValue == 10000,
              full["rope_type"] as? String == "proportional", (full["rope_theta"] as? NSNumber)?.doubleValue == 1000000,
              (full["partial_rotary_factor"] as? NSNumber)?.doubleValue == 0.25 else {
            throw ProbeError("Gemma global layer or rotary policy differs")
        }
        var overrides: [String: Gemma4AffineQuantization] = [:]
        for index in 0..<30 {
            for module in ["mlp.gate_proj", "mlp.up_proj", "mlp.down_proj", "router.proj"] {
                overrides["language_model.model.layers.\(index).\(module)"] = .init(bits: 8, groupSize: 64, mode: "affine")
            }
        }
        for key in ["quantization", "quantization_config"] {
            guard let table = root[key] as? [String: Any], table.count == 123,
                  BoundedProbeInput.integer(table["bits"]) == 4,
                  BoundedProbeInput.integer(table["group_size"]) == 64,
                  table["mode"] as? String == "affine",
                  Set(table.keys) == Set(overrides.keys).union(["bits", "group_size", "mode"]) else {
                throw ProbeError("Gemma quantization defaults/override paths differ")
            }
            for path in overrides.keys {
                guard let entry = table[path] as? [String: Any], Set(entry.keys) == ["bits", "group_size"],
                      BoundedProbeInput.integer(entry["bits"]) == 8,
                      BoundedProbeInput.integer(entry["group_size"]) == 64 else {
                    throw ProbeError("Gemma explicit shared/router quantization differs")
                }
            }
        }
        return .init(kinds: kinds, overrides: overrides)
    }
}
