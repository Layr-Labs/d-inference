import Foundation

/// How a dense Qwen 3.5-family text model (full-attention layers with an
/// output gate, Gated DeltaNet linear-attention layers, a SwiGLU MLP) is split
/// across `size` ranks by heads and channels: equal shards, or shares weighted
/// by `shares` for unequal Macs (`QwenTensorParallelShares`).
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
///
/// Weighted shares divide each part in its own whole units, in rank order and
/// contiguously: the full attention by KV heads (each with the query heads
/// that read it), the linear attention by key heads (each with its value
/// heads), the MLP by quantization groups of channels and the LM head by
/// vocabulary rows; every rank gets at least one unit of every part. The
/// arithmetic of a row-parallel sum is unchanged (each rank's float32 partial
/// over its own input columns, one float32 add, one rounding), so a weighted
/// split is held to the same near-tie rule as an equal one.
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
    /// The MLP width: the dense MLP's, or each routed expert's.
    public let intermediateSize: Int
    public let vocabularySize: Int
    /// Routed experts (0 for a dense model) and the shared expert's width.
    public let expertCount: Int
    public let sharedExpertIntermediateSize: Int
    public var routedExperts: Bool { expertCount > 0 }
    public let groupSize: Int
    public let bits: Int
    /// Each rank's weight (all ones: equal shards).
    public let shares: [Int]
    /// Per rank: KV heads of the full attention, key heads of the linear
    /// attention, MLP channels and vocabulary rows (rank order, contiguous).
    public let kvHeadsPerRank: [Int]
    public let linearKeyHeadsPerRank: [Int]
    public let intermediatePerRank: [Int]
    public let sharedExpertIntermediatePerRank: [Int]
    public let vocabularyPerRank: [Int]
    /// True when every rank holds the same share.
    public var equalShares: Bool { Set(shares).count == 1 }
    /// The plan's name as records and the placement family state it.
    public var name: String { routedExperts ? "qwen_moe_heads_and_expert_channels_v1" : "qwen_dense_heads_and_channels_v1" }

    /// A tensor's cut for one rank.
    public enum Cut: Equatable, Sendable {
        /// Every rank holds the whole tensor.
        case replicate
        /// These rows (axis 0), concatenated in order.
        case rows([Range<Int>])
        /// These logical input columns of a quantized linear: packed weight
        /// words and per-group scales/biases are cut accordingly.
        case inputColumns(Range<Int>)
        /// Every routed expert's rows (axis 1 of `[experts, out, in]`).
        case expertRows(Range<Int>)
        /// Every routed expert's logical input columns (axis 2, quantized).
        case expertInputColumns(Range<Int>)
    }

    /// What a checkpoint key is for this plan.
    public enum Disposition: Equatable, Sendable {
        case load(Cut)
        /// Not part of the text model (multi-token prediction head, vision tower).
        case skip
    }

    public static let modelTypes: Set<String> = ["qwen3_5_text", "qwen3_5_moe_text"]

    /// Unequal two-rank share weights a planner may try (rank order), from a
    /// quarter to three quarters; a model whose parts cannot divide so is
    /// refused per option by the plan itself.
    public static let candidateShares: [[Int]] = [[1, 3], [1, 2], [2, 3], [3, 2], [2, 1], [3, 1]]

    /// `text` is the checkpoint's `text_config` object; `quantization` the
    /// checkpoint's top-level `quantization` object; `shares` each rank's
    /// positive weight (nil: equal shards).
    public init(textConfiguration text: [String: Any], quantization: [String: Any], size: Int,
                shares: [Int]? = nil) throws {
        func integer(_ key: String) throws -> Int {
            guard let value = text[key] as? Int, value > 0 else {
                throw ProbeError("Tensor parallel plan: text configuration lacks a positive \(key)")
            }
            return value
        }
        guard let type = text["model_type"] as? String, Self.modelTypes.contains(type) else {
            throw ProbeError("Tensor parallel plan: only a dense qwen3_5_text or routed-expert qwen3_5_moe_text model is supported")
        }
        let experts = text["num_experts"] as? Int ?? 0
        guard (experts > 0) == (type == "qwen3_5_moe_text") else {
            throw ProbeError("Tensor parallel plan: routed experts belong to qwen3_5_moe_text only")
        }
        if experts > 0 {
            // Every layer routed (no dense-MLP layers), one shared expert: the A3B shape.
            guard (text["mlp_only_layers"] as? [Int] ?? []).isEmpty, (text["decoder_sparse_step"] as? Int ?? 1) == 1,
                  (text["num_experts_per_tok"] as? Int ?? 0) > 0 else {
                throw ProbeError("Tensor parallel plan: routed experts in every layer (no dense-MLP layers) are required")
            }
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
        let shares = shares ?? Array(repeating: 1, count: size)
        guard shares.count == size, shares.allSatisfy({ (1...1_000).contains($0) }) else {
            throw ProbeError("Tensor parallel plan: one positive share (at most 1000) per rank")
        }
        self.size = size
        self.shares = shares
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
        expertCount = experts
        intermediateSize = try integer(experts > 0 ? "moe_intermediate_size" : "intermediate_size")
        sharedExpertIntermediateSize = experts > 0 ? try integer("shared_expert_intermediate_size") : 0
        vocabularySize = try integer("vocab_size")

        guard attentionHeads % kvHeads == 0, linearValueHeads % linearKeyHeads == 0 else {
            throw ProbeError("Tensor parallel plan: head groups are uneven")
        }
        // Equal shares keep the original rule: every count divides by the ranks.
        let equal = Set(shares).count == 1
        if equal {
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
            if experts > 0 { try divisible(sharedExpertIntermediateSize, "shared expert size") }
            try divisible(vocabularySize, "vocabulary")
        }
        // Units each part moves in. Every row-parallel input width must stay on
        // a quantization group and on the quantized matrix-vector kernel's fast
        // path (MLX qmv_fast: input width a multiple of (32 / bits) x 2 x 32 =
        // 512 for 4-bit, 256 for 8-bit; output rows a multiple of 8). A width
        // off that alignment falls back to the slow kernel: measured on the M5
        // Ultra, a 3/4 shard of the 27B with a 13,056-wide MLP stepped in
        // 21.8 ms against 18.0 ms for the whole model.
        let alignment = Self.lcm(Self.fastKernelInputAlignment(bits: bits), groupSize)
        let qPerKV = attentionHeads / kvHeads, vPerK = linearValueHeads / linearKeyHeads
        let kvUnit = Self.unit(of: qPerKV * headDim, alignment: alignment, total: kvHeads)
        let keyUnit = Self.unit(of: vPerK * linearValueHeadDim, alignment: alignment, total: linearKeyHeads)
        let channelUnit = Self.lcm(alignment, 32 / bits)
        guard intermediateSize % channelUnit == 0 || equal, sharedExpertIntermediateSize % channelUnit == 0 || equal else {
            throw ProbeError("Tensor parallel plan: the MLP width (\(intermediateSize)) does not divide into aligned channel blocks")
        }
        if equal {
            // Equal shards: the original rule (each count divides by the ranks).
            kvHeadsPerRank = Array(repeating: kvHeads / size, count: size)
            linearKeyHeadsPerRank = Array(repeating: linearKeyHeads / size, count: size)
            intermediatePerRank = Array(repeating: intermediateSize / size, count: size)
            sharedExpertIntermediatePerRank = Array(repeating: sharedExpertIntermediateSize / size, count: size)
            vocabularyPerRank = Array(repeating: vocabularySize / size, count: size)
        } else {
            guard let kvUnit, let keyUnit else {
                throw ProbeError("Tensor parallel plan: the heads do not divide into kernel-aligned blocks for unequal shares")
            }
            kvHeadsPerRank = try Self.apportion(kvHeads / kvUnit, shares, "KV head blocks").map { $0 * kvUnit }
            linearKeyHeadsPerRank = try Self.apportion(linearKeyHeads / keyUnit, shares, "linear key head blocks").map { $0 * keyUnit }
            intermediatePerRank = try Self.apportion(intermediateSize / channelUnit, shares, "MLP channel blocks").map { $0 * channelUnit }
            sharedExpertIntermediatePerRank = experts > 0
                ? try Self.apportion(sharedExpertIntermediateSize / channelUnit, shares, "shared expert channel blocks").map { $0 * channelUnit }
                : Array(repeating: 0, count: size)
            var rows = try Self.apportion(vocabularySize / 8, shares, "vocabulary row blocks").map { $0 * 8 }
            rows[rows.count - 1] += vocabularySize % 8
            vocabularyPerRank = rows
        }
        // Row-parallel input widths must land on quantization groups and packed words.
        for rank in 0..<size {
            for (width, label) in [(kvHeadsPerRank[rank] * (attentionHeads / kvHeads) * headDim, "attention output"),
                                   (linearKeyHeadsPerRank[rank] * (linearValueHeads / linearKeyHeads) * linearValueHeadDim,
                                    "linear attention output"),
                                   (intermediatePerRank[rank], "MLP down projection")]
                + (experts > 0 ? [(sharedExpertIntermediatePerRank[rank], "shared expert down projection")] : []) {
                guard width % groupSize == 0, (width * bits) % 32 == 0 else {
                    throw ProbeError("Tensor parallel plan: the \(label) shard (\(width)) does not land on a quantization group")
                }
            }
        }
    }

    /// Whole units of a part divided by weight: largest remainder, ties to the
    /// lower rank, deterministic. Every rank must get at least one unit.
    static func apportion(_ units: Int, _ weights: [Int], _ label: String) throws -> [Int] {
        let total = weights.reduce(0, +)
        var counts = weights.map { units * $0 / total }
        let remainders = weights.enumerated().map { (rank: $0.offset, rest: units * $0.element % total) }
        var left = units - counts.reduce(0, +)
        for entry in remainders.sorted(by: { $0.rest != $1.rest ? $0.rest > $1.rest : $0.rank < $1.rank }) where left > 0 {
            counts[entry.rank] += 1; left -= 1
        }
        guard counts.allSatisfy({ $0 >= 1 }) else {
            throw ProbeError("Tensor parallel plan: shares \(weights) leave a rank without \(label) (\(units) in all)")
        }
        return counts
    }

    /// MLX's quantized matrix-vector fast path steps the input in
    /// pack_factor x (bits == 2 ? 1 : 2) x 32 values (`qmv_fast_k_alignment`).
    static func fastKernelInputAlignment(bits: Int) -> Int { (32 / bits) * (bits == 2 ? 1 : 2) * 32 }

    /// The smallest number of heads whose row-parallel width (`width` each) is
    /// a multiple of `alignment` and that divides `total`; nil if none does.
    static func unit(of width: Int, alignment: Int, total: Int) -> Int? {
        (1...total).first { ($0 * width) % alignment == 0 && total % $0 == 0 }
    }

    static func lcm(_ a: Int, _ b: Int) -> Int {
        func gcd(_ x: Int, _ y: Int) -> Int { y == 0 ? x : gcd(y, x % y) }
        return a / gcd(a, b) * b
    }

    /// The text configuration `rank` constructs: its heads and channels, no
    /// multi-token prediction head (the plan covers the target model only).
    public func shardTextConfiguration(_ text: [String: Any], rank: Int) -> [String: Any] {
        var shard = text
        shard["num_attention_heads"] = kvHeadsPerRank[rank] * (attentionHeads / kvHeads)
        shard["num_key_value_heads"] = kvHeadsPerRank[rank]
        shard["linear_num_key_heads"] = linearKeyHeadsPerRank[rank]
        shard["linear_num_value_heads"] = linearKeyHeadsPerRank[rank] * (linearValueHeads / linearKeyHeads)
        if routedExperts {
            shard["moe_intermediate_size"] = intermediatePerRank[rank]
            shard["shared_expert_intermediate_size"] = sharedExpertIntermediatePerRank[rank]
        } else {
            shard["intermediate_size"] = intermediatePerRank[rank]
        }
        shard["mtp_num_hidden_layers"] = 0
        return shard
    }

    /// The full text configuration without the multi-token prediction head.
    public func unshardedTextConfiguration(_ text: [String: Any]) -> [String: Any] {
        var full = text
        full["mtp_num_hidden_layers"] = 0
        return full
    }

    /// `rank`'s contiguous range of a part whose per-rank counts are `counts`
    /// (in units of `unit` elements), shifted by `offset`.
    private func block(_ counts: [Int], unit: Int = 1, rank: Int, offset: Int = 0) -> Range<Int> {
        let start = counts[..<rank].reduce(0, +) * unit
        return (offset + start) ..< (offset + start + counts[rank] * unit)
    }

    /// Per rank: query heads, value heads of the linear attention.
    public var attentionHeadsPerRank: [Int] { kvHeadsPerRank.map { $0 * (attentionHeads / kvHeads) } }
    public var linearValueHeadsPerRank: [Int] { linearKeyHeadsPerRank.map { $0 * (linearValueHeads / linearKeyHeads) } }

    /// The rows of the linear attention's packed query/key/value projection and
    /// its depthwise convolution channels that this rank keeps.
    func linearQKVRows(rank: Int) -> [Range<Int>] {
        let keyDim = linearKeyHeads * linearKeyHeadDim
        let k = block(linearKeyHeadsPerRank, unit: linearKeyHeadDim, rank: rank)
        return [k, block(linearKeyHeadsPerRank, unit: linearKeyHeadDim, rank: rank, offset: keyDim),
                block(linearValueHeadsPerRank, unit: linearValueHeadDim, rank: rank, offset: 2 * keyDim)]
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
            return .load(.rows([block(vocabularyPerRank, rank: rank)]))
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
        switch module {
        case "input_layernorm", "post_attention_layernorm", "self_attn.q_norm", "self_attn.k_norm", "linear_attn.norm":
            guard leaf == "weight" else { break }
            return .load(.replicate)
        case "self_attn.q_proj" where !isLinear && quantizedLeaf:
            return .load(.rows([block(attentionHeadsPerRank, unit: 2 * headDim, rank: rank)]))
        case "self_attn.k_proj" where !isLinear && quantizedLeaf, "self_attn.v_proj" where !isLinear && quantizedLeaf:
            return .load(.rows([block(kvHeadsPerRank, unit: headDim, rank: rank)]))
        case "self_attn.o_proj" where !isLinear && quantizedLeaf:
            return .load(.inputColumns(block(attentionHeadsPerRank, unit: headDim, rank: rank)))
        case "linear_attn.in_proj_qkv" where isLinear && quantizedLeaf:
            return .load(.rows(linearQKVRows(rank: rank)))
        case "linear_attn.conv1d" where isLinear && leaf == "weight":
            return .load(.rows(linearQKVRows(rank: rank)))
        case "linear_attn.in_proj_z" where isLinear && quantizedLeaf:
            return .load(.rows([block(linearValueHeadsPerRank, unit: linearValueHeadDim, rank: rank)]))
        case "linear_attn.in_proj_b" where isLinear && quantizedLeaf, "linear_attn.in_proj_a" where isLinear && quantizedLeaf:
            return .load(.rows([block(linearValueHeadsPerRank, rank: rank)]))
        case "linear_attn.out_proj" where isLinear && quantizedLeaf:
            return .load(.inputColumns(block(linearValueHeadsPerRank, unit: linearValueHeadDim, rank: rank)))
        case "mlp.gate_proj" where quantizedLeaf && !routedExperts, "mlp.up_proj" where quantizedLeaf && !routedExperts:
            return .load(.rows([block(intermediatePerRank, rank: rank)]))
        case "mlp.down_proj" where quantizedLeaf && !routedExperts:
            return .load(.inputColumns(block(intermediatePerRank, rank: rank)))
        // Routed experts: every expert divided by its intermediate channels (the
        // owner's shard_inplace of switch_mlp), the shared expert like a dense
        // MLP; the router and the shared expert's gate stay whole, so both ranks
        // route every token identically and each sums its own partial.
        case "mlp.gate" where quantizedLeaf && routedExperts, "mlp.shared_expert_gate" where quantizedLeaf && routedExperts:
            return .load(.replicate)
        case "mlp.switch_mlp.gate_proj" where quantizedLeaf && routedExperts,
             "mlp.switch_mlp.up_proj" where quantizedLeaf && routedExperts:
            return .load(.expertRows(block(intermediatePerRank, rank: rank)))
        case "mlp.switch_mlp.down_proj" where quantizedLeaf && routedExperts:
            return .load(.expertInputColumns(block(intermediatePerRank, rank: rank)))
        case "mlp.shared_expert.gate_proj" where quantizedLeaf && routedExperts,
             "mlp.shared_expert.up_proj" where quantizedLeaf && routedExperts:
            return .load(.rows([block(sharedExpertIntermediatePerRank, rank: rank)]))
        case "mlp.shared_expert.down_proj" where quantizedLeaf && routedExperts:
            return .load(.inputColumns(block(sharedExpertIntermediatePerRank, rank: rank)))
        case "linear_attn" where isLinear && (name == "linear_attn.A_log" || name == "linear_attn.dt_bias"):
            return .load(.rows([block(linearValueHeadsPerRank, rank: rank)]))
        default:
            break
        }
        throw ProbeError("Tensor parallel plan: unknown layer key \(key)")
    }

    /// The module paths (relative to the model root) whose outputs are partial
    /// sums under this plan, where the reduction is applied: the attention
    /// output, the linear attention output and the MLP down projection of
    /// every layer; for routed experts the whole MLP block (each rank's
    /// experts and shared expert sum into one partial, reduced once).
    public func rowParallelModulePaths() -> [String] {
        (0..<layerCount).flatMap { layer -> [String] in
            let base = "language_model.model.layers.\(layer)."
            let mixer = (layer + 1) % fullAttentionInterval != 0 ? "linear_attn.out_proj" : "self_attn.o_proj"
            return [base + mixer, base + (routedExperts ? "mlp" : "mlp.down_proj")]
        }
    }

    /// The modules whose stored weights are cut by input columns (the
    /// projections that produce partial sums).
    public func inputColumnModulePaths() -> [String] {
        (0..<layerCount).flatMap { layer -> [String] in
            let base = "language_model.model.layers.\(layer)."
            let mixer = (layer + 1) % fullAttentionInterval != 0 ? "linear_attn.out_proj" : "self_attn.o_proj"
            return [base + mixer] + (routedExperts ? [base + "mlp.switch_mlp.down_proj", base + "mlp.shared_expert.down_proj"]
                                                   : [base + "mlp.down_proj"])
        }
    }

    /// Collectives one forward step issues (one per row-parallel module).
    public var reductionsPerForward: Int { 2 * layerCount }

    /// Vocabulary rows this rank's LM head holds.
    public func vocabularyRange(rank: Int) -> Range<Int> { block(vocabularyPerRank, rank: rank) }
}
