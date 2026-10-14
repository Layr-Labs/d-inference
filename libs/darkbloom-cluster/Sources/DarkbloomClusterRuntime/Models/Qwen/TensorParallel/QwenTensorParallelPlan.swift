import Foundation

/// How a dense Qwen 3.5-family text model (full-attention layers with an
/// output gate, Gated DeltaNet linear-attention layers, a SwiGLU MLP) is split
/// across `size` ranks by heads and channels, with equal shards.
///
/// The recipe is the owner's oMLX `tensor_strategies.py` (Qwen3-Next adapter)
/// applied to Qwen 3.5's separate input projections:
///
/// - column parallel (each rank keeps a contiguous block of output rows): the
///   attention `q_proj` (query and gate interleaved per head), `k_proj`,
///   `v_proj`; the linear attention `in_proj_qkv` (its query, key and value
///   blocks each cut by heads), `in_proj_z`, `in_proj_b`, `in_proj_a`, the
///   depthwise `conv1d` channels, `A_log` and `dt_bias`; the MLP `gate_proj`
///   and `up_proj`; and the LM head by vocabulary rows;
/// - row parallel (each rank keeps the input columns of its heads or
///   channels, and the partial outputs are summed across ranks): the attention
///   `o_proj`, the linear attention `out_proj`, the MLP `down_proj`;
/// - replicated: the embedding, every norm, the per-head query/key norms and
///   the gated output norm (they act on one head at a time).
///
/// A value head of the linear attention reads key head `v / (Hv / Hk)` and a
/// query head of the full attention reads KV head `q / (Hq / Hkv)`, so
/// contiguous head blocks keep every head with the key and value heads it
/// reads. Quantization groups run along the input axis: a row cut never splits
/// a group, and a column cut must land on a group boundary (checked).
public struct QwenTensorParallelPlan: Sendable, Equatable {
    public let size: Int
    public let hiddenSize: Int
    public let layerCount: Int
    public let fullAttentionInterval: Int
    public let attentionHeads: Int
    public let kvHeads: Int
    public let headDim: Int
    public let linearKeyHeads: Int
    public let linearValueHeads: Int
    public let linearKeyHeadDim: Int
    public let linearValueHeadDim: Int
    public let intermediateSize: Int
    public let vocabularySize: Int
    public let groupSize: Int
    public let bits: Int

    /// A tensor's cut for one rank.
    public enum Cut: Equatable, Sendable {
        /// Every rank holds the whole tensor.
        case replicate
        /// These rows (axis 0), concatenated in order.
        case rows([Range<Int>])
        /// These logical input columns of a quantized linear: packed weight
        /// words and per-group scales/biases are cut accordingly.
        case inputColumns(Range<Int>)
    }

    /// What a checkpoint key is for this plan.
    public enum Disposition: Equatable, Sendable {
        case load(Cut)
        /// Not part of the text model (multi-token prediction head, vision tower).
        case skip
    }

    public static let modelTypes: Set<String> = ["qwen3_5_text"]

    /// `text` is the checkpoint's `text_config` object; `quantization` the
    /// checkpoint's top-level `quantization` object.
    public init(textConfiguration text: [String: Any], quantization: [String: Any], size: Int) throws {
        func integer(_ key: String) throws -> Int {
            guard let value = text[key] as? Int, value > 0 else {
                throw ProbeError("Tensor parallel plan: text configuration lacks a positive \(key)")
            }
            return value
        }
        guard let type = text["model_type"] as? String, Self.modelTypes.contains(type) else {
            throw ProbeError("Tensor parallel plan: only a dense qwen3_5_text model is supported")
        }
        guard (text["num_experts"] as? Int ?? 0) == 0 else {
            throw ProbeError("Tensor parallel plan: routed experts are not covered by the dense plan")
        }
        guard (text["tie_word_embeddings"] as? Bool ?? false) == false else {
            throw ProbeError("Tensor parallel plan: a tied LM head is not covered")
        }
        guard (text["attention_bias"] as? Bool ?? false) == false else {
            throw ProbeError("Tensor parallel plan: attention biases are not covered")
        }
        guard (text["attn_output_gate"] as? Bool ?? true) == true else {
            throw ProbeError("Tensor parallel plan: the query projection must carry the output gate")
        }
        guard let groupSize = quantization["group_size"] as? Int, let bits = quantization["bits"] as? Int,
              (quantization["mode"] as? String ?? "affine") == "affine", [4, 8].contains(bits), groupSize > 0 else {
            throw ProbeError("Tensor parallel plan: requires an affine 4- or 8-bit quantized checkpoint")
        }
        // Per-module overrides would change a cut's group arithmetic; refuse them.
        guard !quantization.values.contains(where: { $0 is [String: Any] }) else {
            throw ProbeError("Tensor parallel plan: per-module quantization overrides are not covered")
        }
        guard size >= 2 else { throw ProbeError("Tensor parallel plan: needs at least two ranks") }
        self.size = size
        self.groupSize = groupSize
        self.bits = bits
        hiddenSize = try integer("hidden_size")
        layerCount = try integer("num_hidden_layers")
        fullAttentionInterval = try integer("full_attention_interval")
        attentionHeads = try integer("num_attention_heads")
        kvHeads = try integer("num_key_value_heads")
        headDim = try integer("head_dim")
        linearKeyHeads = try integer("linear_num_key_heads")
        linearValueHeads = try integer("linear_num_value_heads")
        linearKeyHeadDim = try integer("linear_key_head_dim")
        linearValueHeadDim = try integer("linear_value_head_dim")
        intermediateSize = try integer("intermediate_size")
        vocabularySize = try integer("vocab_size")

        func divisible(_ value: Int, _ label: String) throws {
            guard value % size == 0 else {
                throw ProbeError("Tensor parallel plan: \(label) (\(value)) is not divisible by \(size) ranks")
            }
        }
        try divisible(attentionHeads, "attention heads")
        try divisible(kvHeads, "KV heads")
        try divisible(linearKeyHeads, "linear key heads")
        try divisible(linearValueHeads, "linear value heads")
        try divisible(intermediateSize, "intermediate size")
        try divisible(vocabularySize, "vocabulary")
        guard attentionHeads % kvHeads == 0, linearValueHeads % linearKeyHeads == 0 else {
            throw ProbeError("Tensor parallel plan: head groups are uneven")
        }
        // Row-parallel input widths must land on quantization groups and packed words.
        for (width, label) in [(attentionHeads / size * headDim, "attention output"),
                               (linearValueHeads / size * linearValueHeadDim, "linear attention output"),
                               (intermediateSize / size, "MLP down projection")] {
            guard width % groupSize == 0, (width * bits) % 32 == 0 else {
                throw ProbeError("Tensor parallel plan: the \(label) shard (\(width)) does not land on a quantization group")
            }
        }
    }

    /// The text configuration a rank constructs: heads and channels divided,
    /// no multi-token prediction head (the plan covers the target model only).
    public func shardTextConfiguration(_ text: [String: Any]) -> [String: Any] {
        var shard = text
        shard["num_attention_heads"] = attentionHeads / size
        shard["num_key_value_heads"] = kvHeads / size
        shard["linear_num_key_heads"] = linearKeyHeads / size
        shard["linear_num_value_heads"] = linearValueHeads / size
        shard["intermediate_size"] = intermediateSize / size
        shard["mtp_num_hidden_layers"] = 0
        return shard
    }

    /// The full text configuration without the multi-token prediction head.
    public func unshardedTextConfiguration(_ text: [String: Any]) -> [String: Any] {
        var full = text
        full["mtp_num_hidden_layers"] = 0
        return full
    }

    private func block(_ total: Int, rank: Int, offset: Int = 0) -> Range<Int> {
        let width = total / size
        return (offset + rank * width) ..< (offset + (rank + 1) * width)
    }

    /// The rows of the linear attention's packed query/key/value projection and
    /// its depthwise convolution channels that this rank keeps.
    func linearQKVRows(rank: Int) -> [Range<Int>] {
        let keyDim = linearKeyHeads * linearKeyHeadDim
        let valueDim = linearValueHeads * linearValueHeadDim
        return [block(keyDim, rank: rank), block(keyDim, rank: rank, offset: keyDim),
                block(valueDim, rank: rank, offset: 2 * keyDim)]
    }

    /// The cut of one checkpoint key (`language_model.` prefixed, as the
    /// registered checkpoint stores it) for `rank`. Unknown keys throw.
    public func disposition(key: String, rank: Int) throws -> Disposition {
        guard (0..<size).contains(rank) else { throw ProbeError("Tensor parallel plan: rank \(rank) is outside the group") }
        if key.hasPrefix("mtp.") || key.hasPrefix("vision_tower") || key.hasPrefix("model.visual")
            || key.hasPrefix("language_model.mtp.") {
            return .skip
        }
        if key.hasPrefix("language_model.model.embed_tokens.") || key == "language_model.model.norm.weight" {
            return .load(.replicate)
        }
        if key.hasPrefix("language_model.lm_head.") {
            return .load(.rows([block(vocabularySize, rank: rank)]))
        }
        let prefix = "language_model.model.layers."
        guard key.hasPrefix(prefix) else { throw ProbeError("Tensor parallel plan: unknown checkpoint key \(key)") }
        let rest = key.dropFirst(prefix.count)
        guard let dot = rest.firstIndex(of: "."), let layer = Int(rest[..<dot]), (0..<layerCount).contains(layer) else {
            throw ProbeError("Tensor parallel plan: unknown layer key \(key)")
        }
        let name = String(rest[rest.index(after: dot)...])
        let parts = name.split(separator: ".").map(String.init)
        guard parts.count >= 2 else { throw ProbeError("Tensor parallel plan: unknown layer key \(key)") }
        let module = parts.dropLast().joined(separator: ".")
        let leaf = parts[parts.count - 1]
        let quantizedLeaf = ["weight", "scales", "biases"].contains(leaf)
        let isLinear = (layer + 1) % fullAttentionInterval != 0
        let qkvWidth = 2 * headDim * attentionHeads
        switch module {
        case "input_layernorm", "post_attention_layernorm", "self_attn.q_norm", "self_attn.k_norm", "linear_attn.norm":
            guard leaf == "weight" else { break }
            return .load(.replicate)
        case "self_attn.q_proj" where !isLinear && quantizedLeaf:
            return .load(.rows([block(qkvWidth, rank: rank)]))
        case "self_attn.k_proj" where !isLinear && quantizedLeaf, "self_attn.v_proj" where !isLinear && quantizedLeaf:
            return .load(.rows([block(kvHeads * headDim, rank: rank)]))
        case "self_attn.o_proj" where !isLinear && quantizedLeaf:
            return .load(.inputColumns(block(attentionHeads * headDim, rank: rank)))
        case "linear_attn.in_proj_qkv" where isLinear && quantizedLeaf:
            return .load(.rows(linearQKVRows(rank: rank)))
        case "linear_attn.conv1d" where isLinear && leaf == "weight":
            return .load(.rows(linearQKVRows(rank: rank)))
        case "linear_attn.in_proj_z" where isLinear && quantizedLeaf:
            return .load(.rows([block(linearValueHeads * linearValueHeadDim, rank: rank)]))
        case "linear_attn.in_proj_b" where isLinear && quantizedLeaf, "linear_attn.in_proj_a" where isLinear && quantizedLeaf:
            return .load(.rows([block(linearValueHeads, rank: rank)]))
        case "linear_attn.out_proj" where isLinear && quantizedLeaf:
            return .load(.inputColumns(block(linearValueHeads * linearValueHeadDim, rank: rank)))
        case "mlp.gate_proj" where quantizedLeaf, "mlp.up_proj" where quantizedLeaf:
            return .load(.rows([block(intermediateSize, rank: rank)]))
        case "mlp.down_proj" where quantizedLeaf:
            return .load(.inputColumns(block(intermediateSize, rank: rank)))
        case "linear_attn" where isLinear && (name == "linear_attn.A_log" || name == "linear_attn.dt_bias"):
            return .load(.rows([block(linearValueHeads, rank: rank)]))
        default:
            break
        }
        throw ProbeError("Tensor parallel plan: unknown layer key \(key)")
    }

    /// The module paths (relative to the model root) whose outputs are partial
    /// sums under this plan: the attention output, the linear attention output
    /// and the MLP down projection of every layer.
    public func rowParallelModulePaths() -> [String] {
        (0..<layerCount).flatMap { layer -> [String] in
            let base = "language_model.model.layers.\(layer)."
            let mixer = (layer + 1) % fullAttentionInterval != 0 ? "linear_attn.out_proj" : "self_attn.o_proj"
            return [base + mixer, base + "mlp.down_proj"]
        }
    }

    /// Collectives one forward step issues (one per row-parallel module).
    public var reductionsPerForward: Int { 2 * layerCount }

    /// Vocabulary rows this rank's LM head holds.
    public func vocabularyRange(rank: Int) -> Range<Int> { block(vocabularySize, rank: rank) }
}
