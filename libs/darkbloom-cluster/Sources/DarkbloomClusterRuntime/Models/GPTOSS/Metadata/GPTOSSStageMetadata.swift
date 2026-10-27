import Foundation

/// Pure admission of the registered GPT-OSS configuration: a closed key set,
/// the registered geometry, the two quantization policies the artifact uses
/// and the stored tensor inventory that follows from them.
///
/// The routed experts are MXFP4 (4 bits, groups of 32, one unsigned byte of
/// exponent per group); every other projection, the embedding and the head are
/// affine 8-bit in groups of 64 with scales and biases in the activation dtype.
/// Anything else is refused rather than approximated.
enum GPTOSSStageMetadata {
    struct Policy: Equatable {
        let mode: String, bits: Int, groupSize: Int
        static let experts = Policy(mode: "mxfp4", bits: 4, groupSize: 32)
        static let affine = Policy(mode: "affine", bits: 8, groupSize: 64)
    }

    /// Bytes per element of a safetensors dtype this family stores.
    static func elementBytes(_ dtype: String) -> Int? {
        switch dtype {
        case "U32": 4
        case "BF16": 2
        case "U8": 1
        default: nil
        }
    }
    /// The MLX spelling of a stored dtype, as loader records and receipts use it.
    static func nativeName(_ dtype: String) -> String? {
        switch dtype {
        case "U32": "uint32"
        case "BF16": "bfloat16"
        case "U8": "uint8"
        default: nil
        }
    }

    private static let knownKeys: Set<String> = ["architectures", "attention_bias", "attention_dropout",
        "eos_token_id", "experts_per_token", "head_dim", "hidden_act", "hidden_size", "initial_context_length",
        "initializer_range", "intermediate_size", "layer_types", "max_position_embeddings", "model_type",
        "num_attention_heads", "num_experts_per_tok", "num_hidden_layers", "num_key_value_heads",
        "num_local_experts", "output_router_logits", "pad_token_id", "quantization", "quantization_config",
        "rms_norm_eps", "rope_scaling", "rope_theta", "router_aux_loss_coef", "sliding_window", "swiglu_limit",
        "tie_word_embeddings", "transformers_version", "use_cache", "vocab_size"]

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, String(cString: number.objCType) == "c" else { return nil }
        return number.boolValue
    }

    /// Returns the per-layer attention types. Fails closed on any key this
    /// adapter has not been taught: a new layer policy must not be treated as
    /// irrelevant to stage reindexing.
    static func validate(_ root: [String: Any], specification spec: GPTOSSRegisteredSpecification) throws -> [String] {
        guard Set(root.keys).isSubset(of: knownKeys), root["model_type"] as? String == "gpt_oss" else {
            throw ProbeError("Unqualified GPT-OSS configuration key or model type")
        }
        let expected: [String: Int] = ["num_hidden_layers": spec.layers, "hidden_size": spec.hidden,
            "intermediate_size": spec.intermediate, "vocab_size": spec.vocabulary,
            "num_local_experts": spec.experts, "num_experts_per_tok": spec.expertsPerToken,
            "head_dim": spec.headDimension, "num_attention_heads": spec.queryHeads,
            "num_key_value_heads": spec.keyValueHeads, "sliding_window": spec.slidingWindow,
            "max_position_embeddings": spec.maximumPositions]
        for (key, value) in expected {
            guard BoundedProbeInput.integer(root[key]) == value else {
                throw ProbeError("GPT-OSS configuration differs from the registered geometry: \(key)")
            }
        }
        guard root["experts_per_token"] == nil || BoundedProbeInput.integer(root["experts_per_token"]) == spec.expertsPerToken,
              root["attention_bias"] == nil || boolean(root["attention_bias"]) == true,
              root["tie_word_embeddings"] == nil || boolean(root["tie_word_embeddings"]) == false,
              root["hidden_act"] == nil || root["hidden_act"] as? String == "silu",
              root["attention_dropout"] == nil || (root["attention_dropout"] as? NSNumber)?.doubleValue == 0,
              // The product class clips the gated activation at exactly this value.
              root["swiglu_limit"] == nil || (root["swiglu_limit"] as? NSNumber)?.doubleValue == 7,
              root["rope_scaling"] == nil || root["rope_scaling"] is [String: Any],
              let epsilon = root["rms_norm_eps"] as? NSNumber, boolean(epsilon) == nil,
              epsilon.doubleValue.isFinite, epsilon.doubleValue > 0,
              let theta = root["rope_theta"] as? NSNumber, boolean(theta) == nil, theta.doubleValue > 0 else {
            throw ProbeError("GPT-OSS configuration declares an unsupported layer policy")
        }
        guard let types = root["layer_types"] as? [String], types.count == spec.layers,
              types.allSatisfy({ $0 == GPTOSSRegisteredSpecification.slidingAttention
                  || $0 == GPTOSSRegisteredSpecification.fullAttention }) else {
            throw ProbeError("GPT-OSS layer stages require an explicit attention type for every layer")
        }
        return types
    }

    /// The quantized module paths of a model with the registered geometry.
    static func modules(specification spec: GPTOSSRegisteredSpecification) -> [String: Policy] {
        var result = [GPTOSSLayerStagePlan.embedding: Policy.affine, GPTOSSLayerStagePlan.head: Policy.affine]
        for layer in 0..<spec.layers {
            let base = GPTOSSLayerStagePlan.layerPrefix + "\(layer)."
            for name in ["q_proj", "k_proj", "v_proj", "o_proj"] { result[base + "self_attn." + name] = .affine }
            result[base + "mlp.router"] = .affine
            for name in ["gate_proj", "up_proj", "down_proj"] { result[base + "mlp.experts." + name] = .experts }
        }
        return result
    }

    static func policy(_ root: [String: Any], specification spec: GPTOSSRegisteredSpecification)
        throws -> (containerKeys: [String], defaults: [String: Any], overrides: [String: Any], modules: [String: Policy]) {
        let keys = ["quantization", "quantization_config"].filter { root[$0] != nil }
        guard let first = keys.first, let object = root[first] as? [String: Any] else {
            throw ProbeError("GPT-OSS layer stages require the artifact's quantization container")
        }
        for key in keys.dropFirst() {
            guard try QwenStageMetadata.json(root[key]!) == QwenStageMetadata.json(object) else {
                throw ProbeError("Conflicting quantization container aliases")
            }
        }
        func declared(_ value: Any?) -> Policy? {
            guard let option = value as? [String: Any], Set(option.keys).isSubset(of: ["bits", "group_size", "mode"]),
                  let bits = BoundedProbeInput.integer(option["bits"]),
                  let group = BoundedProbeInput.integer(option["group_size"]),
                  option["mode"] == nil || option["mode"] is String else { return nil }
            // The product's decoder reads an absent mode as affine.
            return Policy(mode: option["mode"] as? String ?? "affine", bits: bits, groupSize: group)
        }
        let metadataKeys: Set<String> = ["bits", "group_size", "mode"]
        let defaults = object.filter { metadataKeys.contains($0.key) }
        let modules = Self.modules(specification: spec)
        let overrides = object.filter { !metadataKeys.contains($0.key) }
        // The container's default is the experts' policy; every affine module is named.
        guard declared(defaults) == .experts,
              Set(overrides.keys) == Set(modules.filter { $0.value == .affine }.keys),
              overrides.values.allSatisfy({ declared($0) == .affine }) else {
            throw ProbeError("GPT-OSS quantization container differs from MXFP4 experts with named affine 8-bit modules")
        }
        return (keys, defaults, overrides, modules)
    }

    /// Every tensor the registered artifact stores, from geometry alone, in name order.
    static func tensors(specification spec: GPTOSSRegisteredSpecification) -> [GPTOSSLayerStagePlan.Tensor] {
        typealias Tensor = GPTOSSLayerStagePlan.Tensor
        var result: [Tensor] = []
        /// An affine 8-bit projection `[output, input]`: packed words, then one
        /// scale and one bias per group of 64 inputs.
        func affine(_ path: String, output: Int, input: Int, bias: Bool) {
            result.append(Tensor(name: path + ".weight", sourceDType: "U32", shape: [output, input * Policy.affine.bits / 32]))
            for suffix in ["scales", "biases"] {
                result.append(Tensor(name: path + "." + suffix, sourceDType: "BF16", shape: [output, input / Policy.affine.groupSize]))
            }
            if bias { result.append(Tensor(name: path + ".bias", sourceDType: "BF16", shape: [output])) }
        }
        /// One MXFP4 expert bank `[experts, output, input]`: packed words and
        /// one exponent byte per group of 32 inputs. MXFP4 has no stored bias term.
        func experts(_ path: String, output: Int, input: Int) {
            result.append(Tensor(name: path + ".weight", sourceDType: "U32",
                                 shape: [spec.experts, output, input * Policy.experts.bits / 32]))
            result.append(Tensor(name: path + ".scales", sourceDType: "U8",
                                 shape: [spec.experts, output, input / Policy.experts.groupSize]))
            result.append(Tensor(name: path + ".bias", sourceDType: "BF16", shape: [spec.experts, output]))
        }
        let attention = spec.queryHeads * spec.headDimension, keyValue = spec.keyValueHeads * spec.headDimension
        affine(GPTOSSLayerStagePlan.embedding, output: spec.vocabulary, input: spec.hidden, bias: false)
        affine(GPTOSSLayerStagePlan.head, output: spec.vocabulary, input: spec.hidden, bias: false)
        result.append(Tensor(name: GPTOSSLayerStagePlan.norm + ".weight", sourceDType: "BF16", shape: [spec.hidden]))
        for layer in 0..<spec.layers {
            let base = GPTOSSLayerStagePlan.layerPrefix + "\(layer)."
            for name in ["input_layernorm", "post_attention_layernorm"] {
                result.append(Tensor(name: base + name + ".weight", sourceDType: "BF16", shape: [spec.hidden]))
            }
            result.append(Tensor(name: base + "self_attn.sinks", sourceDType: "BF16", shape: [spec.queryHeads]))
            affine(base + "self_attn.q_proj", output: attention, input: spec.hidden, bias: true)
            affine(base + "self_attn.k_proj", output: keyValue, input: spec.hidden, bias: true)
            affine(base + "self_attn.v_proj", output: keyValue, input: spec.hidden, bias: true)
            affine(base + "self_attn.o_proj", output: spec.hidden, input: attention, bias: true)
            affine(base + "mlp.router", output: spec.experts, input: spec.hidden, bias: true)
            experts(base + "mlp.experts.gate_proj", output: spec.intermediate, input: spec.hidden)
            experts(base + "mlp.experts.up_proj", output: spec.intermediate, input: spec.hidden)
            experts(base + "mlp.experts.down_proj", output: spec.hidden, input: spec.intermediate)
        }
        return result.sorted { $0.name < $1.name }
    }
}
