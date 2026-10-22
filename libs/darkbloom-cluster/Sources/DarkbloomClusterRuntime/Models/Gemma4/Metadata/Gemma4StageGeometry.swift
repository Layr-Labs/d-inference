import Foundation

/// The one text geometry both registered Gemma 4 26B artifacts have. A
/// configuration is held to it field by field; nothing here is caller-supplied.
enum Gemma4StageGeometry {
    static let layerCount = 30
    static let hiddenSize = 2816
    static let vocabularySize = 262_144
    static let queryHeads = 16
    static let slidingWindow = 1024
    static let slidingKVHeads = 8, slidingHeadDimension = 256
    static let fullKVHeads = 2, fullHeadDimension = 512
    /// Five sliding-window layers, then one full-attention layer, five times.
    static let fullAttentionInterval = 6
    static let slidingKind = "sliding_attention", fullKind = "full_attention"

    /// By the layer's index in the whole model: a stage that starts anywhere
    /// keeps each layer's own kind.
    static func isFullAttention(globalLayerIndex index: Int) -> Bool {
        (index + 1) % fullAttentionInterval == 0
    }

    static func kind(globalLayerIndex index: Int) -> String {
        isFullAttention(globalLayerIndex: index) ? fullKind : slidingKind
    }

    /// The decoded text configuration and the root it came from, after every
    /// field a stage depends on has been compared with the constants above.
    struct Decoded {
        let root: [String: Any]
        let text: [String: Any]
        /// `bits`, `group_size` and `mode` of projections the table does not name.
        let quantizationDefaults: [String: Any]
        /// Named projections, by their path in the whole model.
        let quantizationOverrides: [String: [String: Any]]
    }

    static func decode(_ configuration: Data, defaultQuantizationBits: Int) throws -> Decoded {
        guard (1...1_048_576).contains(configuration.count),
              let root = try JSONSerialization.jsonObject(with: configuration) as? [String: Any],
              root["model_type"] as? String == "gemma4",
              let text = root["text_config"] as? [String: Any],
              text["model_type"] as? String == "gemma4_text" else {
            throw ProbeError("Gemma stage metadata requires the original text wrapper")
        }
        let integers = ["num_hidden_layers": layerCount, "hidden_size": hiddenSize, "vocab_size": vocabularySize,
            "intermediate_size": 2112, "moe_intermediate_size": 704, "num_experts": 128, "top_k_experts": 8,
            "sliding_window": slidingWindow, "num_attention_heads": queryHeads,
            "num_key_value_heads": slidingKVHeads, "num_global_key_value_heads": fullKVHeads,
            "head_dim": slidingHeadDimension, "global_head_dim": fullHeadDimension,
            "num_kv_shared_layers": 0, "hidden_size_per_layer_input": 0, "max_position_embeddings": 262_144]
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
              (text["final_logit_softcapping"] as? NSNumber)?.doubleValue == 30,
              text["layer_types"] as? [String] == (0..<layerCount).map(kind(globalLayerIndex:)) else {
            throw ProbeError("Unsupported Gemma embedding, attention, dtype, activation or layer policy")
        }
        var defaults: [String: Any] = [:]
        var overrides: [String: [String: Any]] = [:]
        let expectedOverrides = Set((0..<layerCount).flatMap { layer in
            ["mlp.gate_proj", "mlp.up_proj", "mlp.down_proj", "router.proj"].map {
                Gemma4LayerStagePlanning.layerRoot(layer) + "." + $0
            }
        })
        for key in ["quantization", "quantization_config"] {
            guard let table = root[key] as? [String: Any],
                  BoundedProbeInput.integer(table["bits"]) == defaultQuantizationBits,
                  BoundedProbeInput.integer(table["group_size"]) == 64, table["mode"] as? String == "affine",
                  Set(table.keys) == expectedOverrides.union(["bits", "group_size", "mode"]) else {
                throw ProbeError("Gemma quantization defaults or named projections differ")
            }
            defaults = ["bits": defaultQuantizationBits, "group_size": 64, "mode": "affine"]
            for path in expectedOverrides {
                guard let entry = table[path] as? [String: Any], Set(entry.keys) == ["bits", "group_size"],
                      BoundedProbeInput.integer(entry["bits"]) == 8,
                      BoundedProbeInput.integer(entry["group_size"]) == 64 else {
                    throw ProbeError("Gemma shared feed-forward or router quantization differs")
                }
                overrides[path] = ["bits": 8, "group_size": 64]
            }
        }
        return .init(root: root, text: text, quantizationDefaults: defaults, quantizationOverrides: overrides)
    }
}
