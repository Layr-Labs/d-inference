import Foundation

/// Pure admission, module inventory and quantization metadata for layer stages.
enum QwenStageMetadata {
    static func json(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed])
    }
    static func integer(_ object: [String: Any], _ key: String, limit: Int) throws -> Int {
        guard let value = BoundedProbeInput.integer(object[key]), (1...limit).contains(value) else {
            throw ProbeError("Layer-stage metadata requires a bounded positive integer: \(key)")
        }
        return value
    }
    static func validate(text: [String: Any], root: [String: Any], nested: Bool) throws {
        guard text["model_type"] == nil || text["model_type"] as? String == "qwen3_5_text"
            || (!nested && text["model_type"] as? String == "qwen3_5") else {
            throw ProbeError("Unknown dense Qwen text configuration type")
        }
        // Fail closed on future text-layer policies rather than treating a new
        // layer selection/geometry field as irrelevant to stage reindexing.
        let knownKeys: Set<String> = ["model_type", "hidden_size", "num_hidden_layers", "intermediate_size",
            "num_attention_heads", "num_key_value_heads", "linear_num_value_heads", "linear_num_key_heads",
            "linear_key_head_dim", "linear_value_head_dim", "linear_conv_kernel_dim", "rms_norm_eps",
            "vocab_size", "rope_theta", "partial_rotary_factor", "max_position_embeddings", "tie_word_embeddings",
            "attention_bias", "head_dim", "rope_scaling", "rope_parameters", "full_attention_interval",
            "num_experts", "num_experts_per_tok", "decoder_sparse_step", "shared_expert_intermediate_size",
            "moe_intermediate_size", "norm_topk_prob", "mtp_num_hidden_layers", "mtp_use_dedicated_embeddings",
            "layer_types", "mlp_only_layers", "hidden_act", "attn_output_gate", "attention_dropout",
            "output_gate_type",
            "mamba_ssm_dtype", "dtype", "torch_dtype", "initializer_range", "use_cache", "eos_token_id",
            "bos_token_id", "pad_token_id", "quantization", "quantization_config", "architectures",
            "transformers_version", "cluster_fixture_profile", "cluster_fixture_dtype", "mtplx_mtp", "mtplx_mtp_quantization"]
        guard Set(text.keys).isSubset(of: knownKeys),
            root["mtplx_mtp"] == nil || root["mtplx_mtp"] is [String: Any] else {
            throw ProbeError("Unqualified Qwen text metadata or malformed optional MTP declaration")
        }
        // The current Qwen35 decoder ignores this optional key; its GDN
        // RMSNorm gate already applies SiLU. Admit only compatible declarations.
        // Validate without normalizing/removing the original source spelling.
        // This selects no new operator and grants no execution capability.
        if let outputGate = text["output_gate_type"] {
            guard let value = outputGate as? String, ["swish", "silu"].contains(value) else {
                throw ProbeError("Unsupported GDN output gate; layer stages require swish or silu")
            }
        }
        func boolean(_ value: Any?, expected: Bool) -> Bool {
            guard let number = value as? NSNumber, String(cString: number.objCType) == "c" else { return false }
            return number.boolValue == expected
        }
        // Missing tie_word_embeddings is provably false on this exact path:
        // MLXLLM/Qwen35.swift:120–121 supplies false, and the MLXLLM wrapper
        // selects text_config without propagating root tie metadata. Explicit
        // true at either level is rejected, including contradictory metadata.
        for object in nested ? [root, text] : [text] {
            for key in ["tie_word_embeddings", "attention_bias"] where object[key] != nil {
                guard boolean(object[key], expected: false) else {
                    throw ProbeError("Layer stages currently require untied embeddings and unbiased attention")
                }
            }
        }
        for key in ["num_experts", "num_experts_per_tok", "moe_intermediate_size", "shared_expert_intermediate_size"] {
            guard text[key] == nil || BoundedProbeInput.integer(text[key]) == 0 else {
                throw ProbeError("Layer stages do not support MoE metadata")
            }
        }
        if let mtp = text["mtp_num_hidden_layers"] {
            guard let value = BoundedProbeInput.integer(mtp), (0...128).contains(value) else {
                throw ProbeError("Malformed optional MTP layer metadata")
            }
        }
        guard text["mlp_only_layers"] == nil || (text["mlp_only_layers"] as? [Int]) == [],
            text["decoder_sparse_step"] == nil || BoundedProbeInput.integer(text["decoder_sparse_step"]) == 1,
            text["hidden_act"] == nil || text["hidden_act"] as? String == "silu",
            text["attn_output_gate"] == nil || boolean(text["attn_output_gate"], expected: true),
            text["attention_dropout"] == nil || (!boolean(text["attention_dropout"], expected: false)
                && (text["attention_dropout"] as? Double) == 0),
            text["mamba_ssm_dtype"] == nil || text["mamba_ssm_dtype"] as? String == "float32",
            !nested || (text["quantization"] == nil && text["quantization_config"] == nil) else {
            throw ProbeError("Unknown layer policy or nested quantization configuration")
        }
        for key in ["dtype", "torch_dtype"] where text[key] != nil {
            guard let value = text[key] as? String, ["bfloat16", "float16", "float32"].contains(value) else {
                throw ProbeError("Unsupported activation dtype metadata")
            }
        }
        for key in ["rope_parameters", "rope_scaling"] where text[key] != nil {
            guard text[key] is [String: Any] else { throw ProbeError("RoPE metadata must retain an object") }
        }
        if let epsilon = text["rms_norm_eps"] {
            guard let value = epsilon as? NSNumber, String(cString: value.objCType) != "c",
                value.doubleValue.isFinite, value.doubleValue > 0 else { throw ProbeError("Invalid RMSNorm epsilon") }
        }
        let bounds = ["hidden_size": 8192, "intermediate_size": 32768, "num_attention_heads": 128,
            "num_key_value_heads": 128, "head_dim": 512, "linear_num_key_heads": 128,
            "linear_num_value_heads": 128, "linear_key_head_dim": 512, "linear_value_head_dim": 512,
            "linear_conv_kernel_dim": 16, "vocab_size": 262144, "max_position_embeddings": 1048576]
        var dimensions: [String: Int] = [:]
        for (key, bound) in bounds { dimensions[key] = try integer(text, key, limit: bound) }
        guard dimensions["num_attention_heads"]! % dimensions["num_key_value_heads"]! == 0,
            dimensions["linear_num_value_heads"]! % dimensions["linear_num_key_heads"]! == 0,
            dimensions["linear_key_head_dim"]! % 32 == 0 else {
            throw ProbeError("Invalid dense Qwen attention or recurrent grouping")
        }
    }
    static func moduleInventory(namespace: String, layerTypes: [String], text: [String: Any])
        -> (modules: Set<String>, inputWidths: [String: Int], required: Set<String>) {
        // Called only after validate established bounded positive dimensions.
        let hidden = BoundedProbeInput.integer(text["hidden_size"])!
        let intermediate = BoundedProbeInput.integer(text["intermediate_size"])!
        let attentionWidth = BoundedProbeInput.integer(text["num_attention_heads"])!
            * BoundedProbeInput.integer(text["head_dim"])!
        let recurrentWidth = BoundedProbeInput.integer(text["linear_num_value_heads"])!
            * BoundedProbeInput.integer(text["linear_value_head_dim"])!
        var modules: Set<String> = [namespace + "model.norm"]
        var inputWidths = [namespace + "model.embed_tokens": hidden, namespace + "lm_head": hidden]
        var direct = Set<String>()
        for (layer, kind) in layerTypes.enumerated() {
            let base = namespace + "model.layers.\(layer)."
            modules.formUnion([base + "input_layernorm", base + "post_attention_layernorm"])
            for name in ["gate_proj", "up_proj"] { inputWidths[base + "mlp." + name] = hidden }
            inputWidths[base + "mlp.down_proj"] = intermediate
            if kind == "full_attention" {
                for name in ["q_proj", "k_proj", "v_proj"] { inputWidths[base + "self_attn." + name] = hidden }
                inputWidths[base + "self_attn.o_proj"] = attentionWidth
                modules.formUnion([base + "self_attn.q_norm", base + "self_attn.k_norm"])
            } else {
                for name in ["in_proj_qkv", "in_proj_z", "in_proj_b", "in_proj_a"] {
                    inputWidths[base + "linear_attn." + name] = hidden
                }
                inputWidths[base + "linear_attn.out_proj"] = recurrentWidth
                modules.formUnion([base + "linear_attn.norm", base + "linear_attn.conv1d"])
                direct.formUnion([base + "linear_attn.A_log", base + "linear_attn.dt_bias"])
            }
        }
        modules.formUnion(inputWidths.keys)
        return (modules, inputWidths, Set(modules.map { $0 + ".weight" }).union(direct))
    }
    static func excluded(_ path: String, namespace: String) -> Bool {
        path.hasPrefix(namespace + "mtp.") || path.hasPrefix("mtp.")
            || path.hasPrefix("vision_tower.") || path.hasPrefix("model.visual.")
    }
    static func localModule(_ path: String, namespace: String, range: Range<Int>, index: Int) -> String? {
        let prefix = namespace + "model.layers."
        if path.hasPrefix(prefix) {
            let pieces = path.dropFirst(prefix.count).split(separator: ".", omittingEmptySubsequences: false)
            guard let first = pieces.first, let layer = Int(first), String(layer) == String(first),
                range.contains(layer), pieces.count > 1 else { return nil }
            return prefix + "\(layer - range.lowerBound)." + pieces.dropFirst().joined(separator: ".")
        }
        if (index == 0 && path == namespace + "model.embed_tokens")
            || (index == 1 && [namespace + "model.norm", namespace + "lm_head"].contains(path)) { return path }
        return nil
    }
    static func policy(root: [String: Any], modules: Set<String>, inputWidths: [String: Int], namespace: String)
        throws -> (present: Bool, containerKeys: [String], defaults: [String: Any], overrides: [String: Any]) {
        let keys = ["quantization", "quantization_config"].filter { root[$0] != nil }
        guard let first = keys.first else { return (false, [], [:], [:]) }
        guard let object = root[first] as? [String: Any] else { throw ProbeError("Quantization must be an object") }
        for key in keys.dropFirst() {
            guard try json(root[key]!) == json(object) else { throw ProbeError("Conflicting quantization container aliases") }
        }
        func validateOption(_ value: Any, skipAllowed: Bool) throws {
            if let number = value as? NSNumber, String(cString: number.objCType) == "c", !number.boolValue,
                skipAllowed { return }
            guard let option = value as? [String: Any],
                Set(option.keys).isSubset(of: ["bits", "group_size", "mode"]),
                let bits = BoundedProbeInput.integer(option["bits"]), [2, 3, 4, 5, 6, 8].contains(bits),
                let group = BoundedProbeInput.integer(option["group_size"]), [32, 64, 128].contains(group),
                option["mode"] == nil || option["mode"] as? String == "affine" else {
                throw ProbeError("Unsupported quantization instruction; only explicit affine policies or false are admitted")
            }
        }
        // Match BaseConfiguration.QuantizationContainer's recognized metadata
        // keys (BaseConfiguration.swift:159–165). The latter three are retained
        // but ignored by that decoder; they must not become module overrides.
        let metadataKeys: Set<String> = ["bits", "group_size", "mode", "quant_method", "linear_class", "quantization_mode"]
        let defaults = object.filter { metadataKeys.contains($0.key) }
        try validateOption(defaults.filter { ["bits", "group_size", "mode"].contains($0.key) }, skipAllowed: false)
        var overrides: [String: Any] = [:]
        for path in object.keys.sorted() where !metadataKeys.contains(path) {
            guard modules.contains(path) || excluded(path, namespace: namespace) else {
                // The pinned alias helper does NOT alias ordinary dense module paths.
                throw ProbeError("Unknown or noncanonical dense quantization path: \(path)")
            }
            try validateOption(object[path]!, skipAllowed: true)
            if modules.contains(path), inputWidths[path] == nil, object[path] is [String: Any] {
                throw ProbeError("Quantization of a nonquantizable dense module is unsupported")
            }
            overrides[path] = object[path]!
        }
        // Affine quantize accepts these bits/groups and requires complete input
        // groups (pinned mlx/ops.cpp affine_quantize). A stage never truncates a
        // column. Explicit false skips this check. This admits a conservative
        // declared policy; actual presence of stored triplets is loader-owned.
        for (path, width) in inputWidths {
            guard let option = (overrides[path] ?? defaults) as? [String: Any] else { continue }
            let group = BoundedProbeInput.integer(option["group_size"])!
            guard width % group == 0 else {
                throw ProbeError("Dense module input width does not retain complete declared quantization groups: \(path)")
            }
        }
        return (true, keys, defaults, overrides)
    }
}
