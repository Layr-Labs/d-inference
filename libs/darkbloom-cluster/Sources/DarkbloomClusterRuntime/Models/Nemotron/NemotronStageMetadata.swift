import Foundation

/// What a Nemotron 3.5 Lightning (`nemotron_h`) configuration declares, as far
/// as two layer stages depend on it. Every block is `x + mixer(norm(x))` with
/// one mixer: a Mamba2 block keeps a convolution history and an SSM state, an
/// attention block keeps keys and values (no RoPE, so no position input), and
/// a mixture-of-experts block keeps nothing. Nothing but the residual crosses
/// a cut between two blocks.
struct NemotronStageGeometry: Equatable {
    let kinds: [NemotronStageMetadata.BlockKind]
    let hiddenSize: Int, vocabularySize: Int
    let attentionHeads: Int, keyValueHeads: Int, headDimension: Int
    let mambaHeads: Int, mambaHeadDimension: Int, stateSize: Int, groups: Int, convolutionKernel: Int
    let experts: Int, expertsPerToken: Int, expertIntermediate: Int, sharedIntermediate: Int

    var layers: Int { kinds.count }
    /// Width of a Mamba block's inner stream and of its output projection's input.
    var mambaWidth: Int { mambaHeads * mambaHeadDimension }
    /// Channels of a Mamba block's convolution: the inner stream plus B and C.
    var convolutionWidth: Int { mambaWidth + 2 * groups * stateSize }
    var attentionWidth: Int { attentionHeads * headDimension }
}

/// Pure admission, module inventory and name mapping for Nemotron layer
/// stages. CPU metadata only: no model constructor, no payload, no permit.
enum NemotronStageMetadata {
    enum BlockKind: String, Equatable {
        case mamba, moe, attention
        /// The request state a block of this kind owns, in snapshot spelling.
        var stateComponents: [String] {
            switch self {
            case .mamba: ["conv", "ssm"]
            case .attention: ["kv.keys", "kv.values", "kv.position_offsets"]
            case .moe: []
            }
        }
    }

    static let rootModelType = "nemotron_h"
    static let stageAdapter = "nemotron-h-layer-stage-v1"
    static let planAdapter = "nemotron-h-two-layer-stages-v1"
    static let embeddingPath = "backbone.embeddings"
    static let finalNormPath = "backbone.norm_f"
    static let headPath = "lm_head"
    static let layerPrefix = "backbone.layers."
    /// The artifact's own speculative head. It is never part of a stage.
    static let excludedPrefix = "mtp."

    /// Fail closed on a key this adapter has not read: a new key could select
    /// a block policy that a stage's re-indexed configuration would then lose.
    private static let knownKeys: Set<String> = [
        "architectures", "attention_bias", "attention_dropout", "bos_token_id", "chunk_size", "conv_kernel",
        "darkbloom_embedded_mtp", "darkbloom_local_experiment", "dtype", "eos_token_id", "expand", "head_dim",
        "hidden_dropout", "hidden_size", "initializer_range", "intermediate_size", "layer_norm_epsilon",
        "layers_block_type", "mamba_head_dim", "mamba_hidden_act", "mamba_num_heads", "mamba_proj_bias",
        "mamba_ssm_cache_dtype", "max_position_embeddings", "mlp_bias", "mlp_hidden_act", "model_type",
        "moe_intermediate_size", "moe_latent_size", "moe_shared_expert_intermediate_size",
        "moe_shared_expert_overlap", "mtp_layers_block_type", "n_group", "n_groups", "n_routed_experts",
        "n_shared_experts", "norm_eps", "norm_topk_prob", "num_attention_heads", "num_experts_per_tok",
        "num_hidden_layers", "num_key_value_heads", "num_logits_to_keep", "num_nextn_predict_layers",
        "pad_token_id", "partial_rotary_factor", "quantization", "quantization_config",
        "rescale_prenorm_residual", "residual_in_fp32", "rope_theta", "routed_scaling_factor", "sliding_window",
        "ssm_state_size", "tie_word_embeddings", "time_step_floor", "time_step_max", "time_step_min",
        "topk_group", "transformers_version", "use_bias", "use_cache", "use_conv_bias", "use_mamba_kernels",
        "vocab_size",
    ]

    /// Keys that would make the pinned constructor build something a stage
    /// does not describe: the compact pattern spelling takes precedence over
    /// `layers_block_type`, and explicit step limits change the SSM equations.
    private static let refusedKeys = ["hybrid_override_pattern", "time_step_limit", "time_step_limit_min",
                                      "time_step_limit_max"]

    static func accepts(_ root: [String: Any]) -> Bool { root["model_type"] as? String == rootModelType }

    static func geometry(root: [String: Any]) throws -> NemotronStageGeometry {
        guard accepts(root), Set(root.keys).isSubset(of: knownKeys),
              refusedKeys.allSatisfy({ root[$0] == nil }) else {
            throw ProbeError("Unqualified Nemotron configuration key or model type")
        }
        func integer(_ key: String, _ limit: Int) throws -> Int {
            guard let value = BoundedProbeInput.integer(root[key]), (1...limit).contains(value) else {
                throw ProbeError("Nemotron layer stages require a bounded positive integer: \(key)")
            }
            return value
        }
        func boolean(_ key: String, _ expected: Bool, absent: Bool) -> Bool {
            guard let value = root[key] else { return absent }
            guard let number = value as? NSNumber, String(cString: number.objCType) == "c" else { return false }
            return number.boolValue == expected
        }
        func absentOrNull(_ key: String) -> Bool { root[key] == nil || root[key] is NSNull }
        guard let names = root["layers_block_type"] as? [String], (2...128).contains(names.count),
              names.count == (try integer("num_hidden_layers", 128)) else {
            throw ProbeError("Nemotron layer stages require one explicit block type per layer")
        }
        // A plain `mlp` block has no registered artifact; it is not admitted.
        let kinds = try names.map { name -> BlockKind in
            guard let kind = BlockKind(rawValue: name) else {
                throw ProbeError("Unsupported Nemotron block type: \(name)")
            }
            return kind
        }
        // Each of these selects the equations the pinned mixers run. A value
        // the registered artifact does not use is refused, not interpreted.
        guard boolean("tie_word_embeddings", false, absent: true), boolean("attention_bias", false, absent: true),
              boolean("mamba_proj_bias", false, absent: true), boolean("mlp_bias", false, absent: true),
              boolean("use_bias", false, absent: true), boolean("use_conv_bias", true, absent: true),
              boolean("norm_topk_prob", true, absent: true), boolean("residual_in_fp32", false, absent: true),
              absentOrNull("moe_latent_size"), absentOrNull("sliding_window"),
              root["mamba_ssm_cache_dtype"] == nil || root["mamba_ssm_cache_dtype"] as? String == "float32",
              root["dtype"] == nil || root["dtype"] as? String == "bfloat16",
              root["mlp_hidden_act"] == nil || root["mlp_hidden_act"] as? String == "relu2",
              root["mamba_hidden_act"] == nil || root["mamba_hidden_act"] as? String == "silu",
              root["n_group"] == nil || BoundedProbeInput.integer(root["n_group"]) == 1,
              root["topk_group"] == nil || BoundedProbeInput.integer(root["topk_group"]) == 1,
              BoundedProbeInput.integer(root["n_shared_experts"]) == 1 else {
            throw ProbeError("Unsupported Nemotron mixer, router or dtype policy")
        }
        if let layers = root["num_nextn_predict_layers"] {
            guard let value = BoundedProbeInput.integer(layers), (0...1).contains(value),
                  root["mtp_layers_block_type"] == nil || root["mtp_layers_block_type"] is [String] else {
                throw ProbeError("Malformed optional Nemotron MTP declaration")
            }
        }
        let geometry = NemotronStageGeometry(kinds: kinds,
            hiddenSize: try integer("hidden_size", 8192), vocabularySize: try integer("vocab_size", 262_144),
            attentionHeads: try integer("num_attention_heads", 128), keyValueHeads: try integer("num_key_value_heads", 128),
            headDimension: try integer("head_dim", 512),
            mambaHeads: try integer("mamba_num_heads", 128), mambaHeadDimension: try integer("mamba_head_dim", 512),
            stateSize: try integer("ssm_state_size", 512), groups: try integer("n_groups", 128),
            convolutionKernel: try integer("conv_kernel", 16),
            experts: try integer("n_routed_experts", 1024), expertsPerToken: try integer("num_experts_per_tok", 64),
            expertIntermediate: try integer("moe_intermediate_size", 32_768),
            sharedIntermediate: try integer("moe_shared_expert_intermediate_size", 32_768))
        guard geometry.attentionHeads % geometry.keyValueHeads == 0, geometry.mambaHeads % geometry.groups == 0,
              geometry.expertsPerToken <= geometry.experts,
              try integer("max_position_embeddings", 1_048_576) >= 8320 else {
            throw ProbeError("Invalid Nemotron attention, recurrent or expert grouping")
        }
        return geometry
    }

    /// Every module that holds parameters, the input width of each
    /// quantizable one, and the parameter names a complete artifact must
    /// carry (a quantized module adds `scales` and `biases` to its `weight`).
    static func moduleInventory(_ geometry: NemotronStageGeometry)
        -> (modules: Set<String>, inputWidths: [String: Int], required: Set<String>) {
        let hidden = geometry.hiddenSize
        var inputWidths = [embeddingPath: hidden, headPath: hidden]
        var required: Set<String> = [finalNormPath + ".weight"]
        var modules: Set<String> = [finalNormPath]
        for (layer, kind) in geometry.kinds.enumerated() {
            let base = layerPrefix + "\(layer)."
            modules.insert(base + "norm"); required.insert(base + "norm.weight")
            switch kind {
            case .mamba:
                inputWidths[base + "mixer.in_proj"] = hidden
                inputWidths[base + "mixer.out_proj"] = geometry.mambaWidth
                modules.formUnion([base + "mixer", base + "mixer.conv1d", base + "mixer.norm"])
                required.formUnion(["A_log", "D", "dt_bias", "conv1d.weight", "conv1d.bias", "norm.weight"]
                    .map { base + "mixer." + $0 })
            case .attention:
                for name in ["q_proj", "k_proj", "v_proj"] { inputWidths[base + "mixer." + name] = hidden }
                inputWidths[base + "mixer.o_proj"] = geometry.attentionWidth
            case .moe:
                inputWidths[base + "mixer.switch_mlp.fc1"] = hidden
                inputWidths[base + "mixer.switch_mlp.fc2"] = geometry.expertIntermediate
                inputWidths[base + "mixer.shared_experts.up_proj"] = hidden
                inputWidths[base + "mixer.shared_experts.down_proj"] = geometry.sharedIntermediate
                modules.insert(base + "mixer.gate")
                required.formUnion(["weight", "e_score_correction_bias"].map { base + "mixer.gate." + $0 })
            }
        }
        modules.formUnion(inputWidths.keys)
        required.formUnion(inputWidths.keys.map { $0 + ".weight" })
        return (modules, inputWidths, required)
    }

    static func excluded(_ name: String) -> Bool { name.hasPrefix(excludedPrefix) }

    /// A module or parameter path of the complete model as one stage names
    /// it, or nil when that stage does not own it. Only the layer index of a
    /// block changes; the embedding belongs to stage 0 and the final norm and
    /// head to stage 1.
    static func localPath(_ path: String, range: Range<Int>, index: Int) -> String? {
        if path.hasPrefix(layerPrefix) {
            let pieces = path.dropFirst(layerPrefix.count).split(separator: ".", omittingEmptySubsequences: false)
            guard let first = pieces.first, let layer = Int(first), String(layer) == String(first),
                  range.contains(layer), pieces.count > 1 else { return nil }
            return layerPrefix + "\(layer - range.lowerBound)." + pieces.dropFirst().joined(separator: ".")
        }
        let owner = [embeddingPath, finalNormPath, headPath].first { path == $0 || path.hasPrefix($0 + ".") }
        guard let owner, (index == 0) == (owner == embeddingPath) else { return nil }
        return path
    }

    /// Stage 0 layer counts a pair may be cut at, as far as the layer kinds
    /// decide it: each stage keeps at least one attention block (the loader
    /// proves a stage's native KV dtype from one), and the cut is beside a
    /// mixture-of-experts block. A structural cut is not a memory or speed claim.
    static func structuralCuts(_ kinds: [BlockKind]) -> [Int] {
        guard kinds.count >= 2 else { return [] }
        return (1..<kinds.count).filter { cut in
            kinds[..<cut].contains(.attention) && kinds[cut...].contains(.attention)
                && (kinds[cut - 1] == .moe || kinds[cut] == .moe)
        }
    }
}

/// The registered Nemotron 3.5 Lightning artifact's own numbers, pinned
/// independently of its configuration bytes: admission requires both to agree.
enum NemotronRegisteredLightning {
    static let profileID = "registered_nemotron35_lightning_greedy_generation_v1"
    static let vocabularySize = 131_072
    /// `MEMEM*EMEMEM*EMEMEM*EMEMEM*EMEMEM*EMEMEMEM*EMEMEMEME`
    static let pattern = "MEMEM*EMEMEM*EMEMEM*EMEMEM*EMEMEM*EMEMEMEM*EMEMEMEME"
    static var kinds: [NemotronStageMetadata.BlockKind] {
        pattern.map { $0 == "M" ? .mamba : $0 == "E" ? .moe : .attention }
    }
    static var geometry: NemotronStageGeometry {
        .init(kinds: kinds, hiddenSize: 2688, vocabularySize: vocabularySize,
            attentionHeads: 32, keyValueHeads: 2, headDimension: 128,
            mambaHeads: 64, mambaHeadDimension: 64, stateSize: 128, groups: 8, convolutionKernel: 4,
            experts: 128, expertsPerToken: 6, expertIntermediate: 1856, sharedIntermediate: 3712)
    }
    /// The resident row's cuts: the structural cuts that directly follow a
    /// mixture-of-experts block, so stage 1 starts at a Mamba or an attention
    /// block. There are exactly sixteen, which is also the most partitions a
    /// capability record carries.
    static let supportedCuts = [7, 9, 11, 14, 16, 18, 21, 23, 25, 28, 30, 32, 35, 37, 39, 41]
    /// The cut metadata admission plans at when a caller names none.
    static let planningCut = 25

    /// Named request state in the terms the shared budget is written in. A
    /// Mamba2 block's state has the shapes the budget derives for a recurrent
    /// layer: `n_groups` and `ssm_state_size` are its key heads and key
    /// width, the Mamba heads and head width its value heads and value width.
    static func stateGeometry(_ geometry: NemotronStageGeometry,
                              kinds: [NemotronStageMetadata.BlockKind]) throws -> QwenLongPrefillBudgetGeometry {
        try .init(layers: kinds.count, attentionLayers: kinds.filter { $0 == .attention }.count,
            recurrentLayers: kinds.filter { $0 == .mamba }.count, hiddenSize: geometry.hiddenSize,
            queryHeads: geometry.attentionHeads, kvHeads: geometry.keyValueHeads, headDimension: geometry.headDimension,
            linearKeyHeads: geometry.groups, linearValueHeads: geometry.mambaHeads,
            linearKeyDimension: geometry.stateSize, linearValueDimension: geometry.mambaHeadDimension,
            convolutionKernel: geometry.convolutionKernel)
    }

    static func expectedStateGeometry() throws -> QwenLongPrefillBudgetGeometry {
        try stateGeometry(geometry, kinds: kinds)
    }
}
