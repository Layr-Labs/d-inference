import Foundation

/// Admission and complete name ownership only: no files, MLX or model execution.
func checkQwenLayerStagePlan() throws {
    func json(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }
    func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw ProbeError("Layer-stage check: " + message) }
    }
    func fixture(layers: Int, nested: Bool) -> [String: Any] {
        let realGeometry = layers == 32
        let text: [String: Any] = ["model_type": "qwen3_5_text",
            "hidden_size": realGeometry ? 4096 : 128, "intermediate_size": realGeometry ? 12288 : 256,
            "num_hidden_layers": layers, "num_attention_heads": realGeometry ? 16 : 4,
            "num_key_value_heads": realGeometry ? 4 : 2, "head_dim": realGeometry ? 256 : 64,
            "linear_num_key_heads": realGeometry ? 16 : 2, "linear_num_value_heads": realGeometry ? 32 : 2,
            "linear_key_head_dim": 128, "linear_value_head_dim": 128, "linear_conv_kernel_dim": 4,
            "vocab_size": realGeometry ? 248320 : 512, "max_position_embeddings": 262144,
            "full_attention_interval": 4, "tie_word_embeddings": false, "attention_bias": false,
            "mtp_num_hidden_layers": 1, "dtype": "bfloat16", "rms_norm_eps": 0.000001,
            "layer_types": (0..<layers).map { ($0 + 1) % 4 == 0 ? "full_attention" : "linear_attention" },
            "rope_parameters": ["rope_type": "default", "rope_theta": 10000000,
                "partial_rotary_factor": 0.25, "mrope_section": [11, 11, 10]]]
        var root: [String: Any] = nested ? ["model_type": "qwen3_5", "text_config": text] : text
        root["quantization"] = ["bits": 4, "group_size": 64, "mode": "affine"]
        root["mtplx_mtp"] = ["included": true, "prefix": "mtp."]
        return root
    }
    // Independently enumerate the converted affine checkpoint names, including
    // all stored scales/biases. These are name fixtures, not fabricated tensors.
    func names(layers: Int, wrapped: Bool) -> [String] {
        let prefix = wrapped ? "language_model." : ""
        var result = [prefix + "model.norm.weight"]
        func projection(_ path: String) { result += ["weight", "scales", "biases"].map { path + "." + $0 } }
        projection(prefix + "model.embed_tokens"); projection(prefix + "lm_head")
        for layer in 0..<layers {
            let path = prefix + "model.layers.\(layer)."
            result += [path + "input_layernorm.weight", path + "post_attention_layernorm.weight"]
            for name in ["gate_proj", "up_proj", "down_proj"] { projection(path + "mlp." + name) }
            if (layer + 1) % 4 == 0 {
                for name in ["q_proj", "k_proj", "v_proj", "o_proj"] { projection(path + "self_attn." + name) }
                result += [path + "self_attn.q_norm.weight", path + "self_attn.k_norm.weight"]
            } else {
                for name in ["in_proj_qkv", "in_proj_z", "in_proj_b", "in_proj_a", "out_proj"] {
                    projection(path + "linear_attn." + name)
                }
                result += ["A_log", "dt_bias", "norm.weight", "conv1d.weight"].map { path + "linear_attn." + $0 }
            }
        }
        return result
    }
    var accepted = 0, rejected = 0, mapped = 0
    func reject(_ label: String, _ action: () throws -> Void) throws {
        do { try action() } catch { rejected += 1; return }
        throw ProbeError("Layer-stage check accepted " + label)
    }
    for (count, nested, wrapped) in [(8, false, false), (32, true, true), (8, false, true)] {
        var object = fixture(layers: count, nested: nested)
        if wrapped { object["model_type"] = "qwen3_5" }
        let original = try json(object)
        let ranges = [0..<(count / 2), (count / 2)..<count]
        let plan = try QwenLayerStagePlan(configuration: original, ranges: ranges)
        let repeatPlan = try QwenLayerStagePlan(configuration: original, ranges: ranges)
        try require(plan.fingerprint == repeatPlan.fingerprint && plan.originalConfiguration == original,
            "original identity or deterministic fingerprint differs")
        try require(plan.stages.flatMap(\.layers).map(\.globalIndex) == Array(0..<count), "global layer coverage differs")
        let sourceNames = names(layers: count, wrapped: wrapped)
        let mappings = try plan.parameters(canonicalSourceNames: sourceNames + ["mtp.layers.0.weight"])
        try require(mappings.count == (count == 8 ? 237 : 927), "complete affine name inventory differs")
        for stage in plan.stages {
            let construction = try JSONSerialization.jsonObject(with: stage.constructionConfiguration) as! [String: Any]
            var text = nested ? construction["text_config"] as! [String: Any] : construction
            var originalText = nested ? object["text_config"] as! [String: Any] : object
            try require(text["num_hidden_layers"] as? Int == count / 2
                && text["mtp_num_hidden_layers"] as? Int == 0, "stage count or MTP disable differs")
            try require((construction["mtplx_mtp"] as? [String: Any])?["included"] as? Bool == false,
                "stage artifact MTP flag remains active")
            for key in ["num_hidden_layers", "layer_types", "mtp_num_hidden_layers", "quantization", "mtplx_mtp"] {
                text.removeValue(forKey: key); originalText.removeValue(forKey: key)
            }
            try require(try json(text) == json(originalText), "stage changed original widths/types/other text metadata")
            try require(stage.layers.map(\.localIndex) == Array(0..<(count / 2)), "local layer indexing differs")
            try require(stage.inertModules.count == (stage.index == 0 ? 2 : 1), "inert ownership differs")
        }
        let prefix = wrapped ? "language_model." : ""
        try require(try plan.parameter(canonicalSourceName: prefix + "model.layers.\(count / 2).mlp.down_proj.weight")
            == .init(sourceName: prefix + "model.layers.\(count / 2).mlp.down_proj.weight",
                stage: 1, localName: prefix + "model.layers.0.mlp.down_proj.weight"), "global-to-local tensor mapping differs")
        try require(try plan.parameter(canonicalSourceName: prefix + "model.embed_tokens.weight")?.stage == 0
            && plan.parameter(canonicalSourceName: prefix + "lm_head.weight")?.stage == 1
            && plan.parameter(canonicalSourceName: prefix + "model.norm.weight")?.stage == 1, "embedding/head/norm ownership differs")
        try reject("duplicate source name") { _ = try plan.parameters(canonicalSourceNames: sourceNames + [sourceNames[0]]) }
        try reject("missing required tensor") { _ = try plan.parameters(canonicalSourceNames: Array(sourceNames.dropFirst())) }
        for name in [prefix + "model.layers.00.mlp.down_proj.weight", prefix + "model.layers.\(count).mlp.down_proj.weight",
            prefix + "model.layers.0.self_attn.q_proj.weight", prefix + "model.layers.3.linear_attn.A_log",
            prefix + "model.layers.0.mlp.mystery.weight", prefix + "model.norm.scales"] {
            try reject("unknown parameter") { _ = try plan.parameter(canonicalSourceName: name) }
        }
        accepted += 1; mapped += mappings.count
    }
    let base = fixture(layers: 32, nested: true)
    var overridden = base
    var policy = base["quantization"] as! [String: Any]
    policy["quant_method"] = "retained-loader-metadata"
    policy["linear_class"] = "QuantizedLinear"
    policy["quantization_mode"] = "retained-loader-metadata"
    let sourcePath = "language_model.model.layers.20.mlp.down_proj"
    policy[sourcePath] = ["bits": 8, "group_size": 128, "mode": "affine"]
    policy["language_model.model.layers.19.self_attn.q_proj"] = false
    policy["language_model.model.embed_tokens"] = false
    policy["mtp.layers.0.mlp.down_proj"] = ["bits": 8, "group_size": 64]
    overridden["quantization"] = policy; overridden["quantization_config"] = policy
    let mixed = try QwenLayerStagePlan(configuration: json(overridden), ranges: [0..<16, 16..<32])
    let mappedPolicy = mixed.stages[1].quantizationMappings.first { $0.sourcePath == sourcePath }
    try require(mappedPolicy?.localPath == "language_model.model.layers.4.mlp.down_proj"
        && mixed.stages[0].excludedQuantizationPaths.contains(sourcePath), "per-path policy was not reindexed/excluded")
    let stageRoot = try JSONSerialization.jsonObject(with: mixed.stages[1].constructionConfiguration) as! [String: Any]
    let stagePolicy = stageRoot["quantization"] as! [String: Any]
    try require(try json(stagePolicy) == json(stageRoot["quantization_config"]!), "policy container aliases diverged")
    try require(stagePolicy["language_model.model.embed_tokens"] as? Bool == false
        && (stagePolicy["language_model.model.layers.4.mlp.down_proj"] as? [String: Any])?["bits"] as? Int == 8,
        "stage policy lost native precision or inert exclusion")
    try require(stagePolicy["quant_method"] as? String == policy["quant_method"] as? String
        && stagePolicy["linear_class"] as? String == policy["linear_class"] as? String
        && stagePolicy["quantization_mode"] as? String == policy["quantization_mode"] as? String,
        "recognized ignored quantization metadata was lost")
    var fallback = base
    fallback["quantization_config"] = fallback.removeValue(forKey: "quantization")
    _ = try QwenLayerStagePlan(configuration: json(fallback), ranges: [0..<16, 16..<32])
    var unquantized = base; unquantized.removeValue(forKey: "quantization")
    _ = try QwenLayerStagePlan(configuration: json(unquantized), ranges: [0..<16, 16..<32])
    accepted += 3
    // The pinned MLXLLM text decoder supplies false when this field is absent.
    // Exercise all three supported construction forms, not a VLM decoder.
    for nested in [false, true] {
        var noTie = fixture(layers: 8, nested: nested)
        if nested {
            var text = noTie["text_config"] as! [String: Any]
            text.removeValue(forKey: "tie_word_embeddings"); noTie["text_config"] = text
        } else { noTie.removeValue(forKey: "tie_word_embeddings") }
        _ = try QwenLayerStagePlan(configuration: json(noTie), ranges: [0..<4, 4..<8])
        accepted += 1
        if !nested {
            noTie["model_type"] = "qwen3_5"
            _ = try QwenLayerStagePlan(configuration: json(noTie), ranges: [0..<4, 4..<8])
            accepted += 1
        }
    }
    var groupMismatch = base, groupText = base["text_config"] as! [String: Any]
    groupText["intermediate_size"] = 12224; groupMismatch["text_config"] = groupText
    var groupPolicy = base["quantization"] as! [String: Any]
    groupPolicy[sourcePath] = ["bits": 8, "group_size": 128]; groupMismatch["quantization"] = groupPolicy
    try reject("per-module group mismatch") {
        _ = try QwenLayerStagePlan(configuration: json(groupMismatch), ranges: [0..<16, 16..<32])
    }
    groupPolicy[sourcePath] = false; groupMismatch["quantization"] = groupPolicy
    _ = try QwenLayerStagePlan(configuration: json(groupMismatch), ranges: [0..<16, 16..<32])
    accepted += 1
    for ranges in [[0..<12, 16..<32], [0..<20, 16..<32], [0..<15, 15..<32], [0..<0, 0..<32], [0..<16], [4..<16, 16..<32]] {
        try reject("invalid ranges") { _ = try QwenLayerStagePlan(configuration: json(base), ranges: ranges) }
    }
    try reject("active MTP") { _ = try QwenLayerStagePlan(configuration: json(base), ranges: [0..<16, 16..<32], activeMTP: true) }
    for (key, value) in [("tie_word_embeddings", true as Any), ("attention_bias", true), ("num_experts", 8),
        ("num_hidden_layers", false), ("num_hidden_layers", 32.5), ("full_attention_interval", 3),
        ("layer_types", Array(repeating: "full_attention", count: 32)), ("mlp_only_layers", [3]),
        ("decoder_sparse_step", 2), ("head_dim", 0), ("linear_num_value_heads", 31),
        ("layer_pattern", "alternate"), ("attn_output_gate", 1), ("attention_dropout", false),
        ("dtype", "int8"), ("rms_norm_eps", -1), ("rope_parameters", "default"),
        ("hidden_size", 4095),
        ("quantization", ["bits": 4, "group_size": 64])] {
        var invalid = base, text = base["text_config"] as! [String: Any]; text[key] = value; invalid["text_config"] = text
        try reject("invalid text metadata " + key) { _ = try QwenLayerStagePlan(configuration: json(invalid), ranges: [0..<16, 16..<32]) }
    }
    for (path, value) in [("model.layers.20.mlp.down_proj", ["bits": 8, "group_size": 64] as Any),
        ("model.language_model.layers.20.mlp.down_proj", false),
        (sourcePath, true), (sourcePath, ["bits": 4, "group_size": 63]),
        (sourcePath, ["bits": 7, "group_size": 64]), (sourcePath, ["bits": 4, "group_size": 64, "mode": "mxfp4"]),
        ("language_model.model.layers.32.mlp.down_proj", false),
        ("language_model.model.norm", ["bits": 4, "group_size": 64])] {
        var invalid = base, policy = base["quantization"] as! [String: Any]; policy[path] = value; invalid["quantization"] = policy
        try reject("unknown/aliased policy") { _ = try QwenLayerStagePlan(configuration: json(invalid), ranges: [0..<16, 16..<32]) }
    }
    var conflict = base; conflict["quantization_config"] = ["bits": 8, "group_size": 64]
    try reject("conflicting policy containers") { _ = try QwenLayerStagePlan(configuration: json(conflict), ranges: [0..<16, 16..<32]) }
    for flag in [true as Any, "false", NSNull()] {
        var rootTie = base; rootTie["tie_word_embeddings"] = flag
        try reject("invalid wrapper tie flag") { _ = try QwenLayerStagePlan(configuration: json(rootTie), ranges: [0..<16, 16..<32]) }
    }
    var invalidWrapper = base; invalidWrapper["model_type"] = "qwen3_5_text"
    try reject("nested data in a direct text constructor") {
        _ = try QwenLayerStagePlan(configuration: json(invalidWrapper), ranges: [0..<16, 16..<32])
    }
    struct Result: Encodable {
        let kind = "qwen_layer_stage_plan_check"
        let cpuOnly = true
        let pipelineExecutionValidated = false
        let acceptedFixtures: Int
        let rejectedFixtures: Int
        let mappedParameterNames: Int
    }
    try emitJSON(Result(acceptedFixtures: accepted, rejectedFixtures: rejected, mappedParameterNames: mapped))
}
