import Foundation

/// How a Gemma 4 MoE text model (`gemma4_text` inside the `gemma4` wrapper,
/// tied head; the registered 26B A4B artifacts at 4 and 8 bits) is split
/// across two ranks by heads and channels with equal shares:
/// `gemma4_heads_and_expert_channels_v1`.
///
/// - Attention: contiguous halves of the query heads with the KV heads they
///   read: `q_proj`, `k_proj` and (sliding layers) `v_proj` by output rows,
///   `o_proj` by input columns. Query head `h` reads KV head `h / (Hq / Hkv)`,
///   so halves keep each group whole (26B: sliding 8 query and 4 KV heads per
///   rank, full 8 and 1). Full layers have K=V and store no `v_proj`.
/// - Dense MLP and every routed expert: each rank computes a contiguous half
///   of the channels (gate/up output rows). The down projection is quantized
///   in groups along its input axis, so its stored input columns widen to
///   whole groups; with an odd group count (2112 = 33 x 64, 704 = 11 x 64)
///   both ranks store the middle group, and each rank's gate and up carry
///   zero rows (zero weights, scales and offsets) for the other rank's half
///   of it. Those channels are exactly zero, the shared columns add nothing
///   on the rank that does not own them, and both ranks hold the same width
///   (1088 and 384): equal shares, no unequal-share contract.
/// - Replicated: every norm, `layer_scalar`, the router (`proj`, `scale`,
///   `per_expert_scale`; both ranks route identically), the per-head
///   `q_norm`/`k_norm`, the final norm and the tied embedding. The head
///   projects this rank's half of the embedding's vocabulary rows (views).
///
/// Collectives: per layer the attention partial before
/// `post_attention_layernorm`, and one packed feed-forward collective carrying
/// the dense partial and every selected expert's FP32 row (each summed before
/// rounding, router weighting and its branch's post-norm); one per step for
/// the vocabulary-split selection. Vision tower tensors are refused: the
/// plan covers the text model only, as the pipeline stages do.
public struct Gemma4TensorParallelPlan: Sendable, Equatable {
    public static let name = "gemma4_heads_and_expert_channels_v1"
    public let size = 2

    public enum LayerKind: String, Sendable, Equatable {
        case sliding = "sliding_attention"
        case full = "full_attention"
    }

    public let hiddenSize: Int
    public let layerCount: Int
    public let layerKinds: [LayerKind]
    public let vocabularySize: Int
    public let queryHeads: Int
    public let slidingKVHeads: Int
    public let fullKVHeads: Int
    public let slidingHeadDim: Int
    public let fullHeadDim: Int
    public let denseWidth: Int
    public let expertWidth: Int
    public let expertCount: Int
    public let expertsPerToken: Int
    public let groupSize: Int
    public let defaultBits: Int
    /// Explicit per-module bits (`language_model.model.layers.N.<module>`).
    private let overrideBits: [String: Int]

    /// One rank's equal share of a channel-parallel width (see the type note).
    public struct ChannelSplit: Sendable, Equatable {
        public let width: Int
        public let groupSize: Int
        public let rank: Int
        /// Channels of the full width this rank computes.
        public let channels: Range<Int>
        /// Input columns of the down projection this rank stores.
        public let storedColumns: Range<Int>

        public init(width: Int, groupSize: Int, rank: Int) throws {
            guard (0 ..< 2).contains(rank), width > 0, groupSize > 0, width % groupSize == 0, width % 2 == 0 else {
                throw ProbeError("Gemma tensor parallel plan: width \(width) is not whole groups of \(groupSize)")
            }
            let half = width / 2
            self.width = width; self.groupSize = groupSize; self.rank = rank
            channels = rank == 0 ? 0 ..< half : half ..< width
            storedColumns = (channels.lowerBound / groupSize * groupSize)
                ..< ((channels.upperBound + groupSize - 1) / groupSize * groupSize)
        }

        public var localWidth: Int { storedColumns.count }
        public var zeroBefore: Int { channels.lowerBound - storedColumns.lowerBound }
        public var zeroAfter: Int { storedColumns.upperBound - channels.upperBound }
    }

    /// A stored tensor's cut for one rank.
    public enum Cut: Equatable, Sendable {
        /// Every rank holds the whole tensor.
        case replicate
        /// Output rows (axis 0) in order, with all-zero rows before and after.
        case rows(Range<Int>, zeroBefore: Int, zeroAfter: Int)
        /// Logical input columns (axis 1) of a quantized linear: packed words
        /// and per-group scales/offsets are cut accordingly.
        case inputColumns(Range<Int>)
        /// Every expert's output rows (axis 1 of `[E, out, in]`), with all-zero
        /// rows before and after.
        case expertRows(Range<Int>, zeroBefore: Int, zeroAfter: Int)
        /// Every expert's logical input columns (axis 2, quantized).
        case expertInputColumns(Range<Int>)
    }

    /// `root` is the artifact's whole `config.json` object.
    public init(configuration root: [String: Any]) throws {
        guard root["model_type"] as? String == "gemma4", let text = root["text_config"] as? [String: Any],
              text["model_type"] as? String == "gemma4_text" else {
            throw ProbeError("Gemma tensor parallel plan: expected a gemma4 wrapper around gemma4_text")
        }
        func integer(_ key: String) throws -> Int {
            guard let number = text[key] as? NSNumber, CFNumberIsFloatType(number) == false, number.intValue > 0 else {
                throw ProbeError("Gemma tensor parallel plan: text configuration lacks a positive \(key)")
            }
            return number.intValue
        }
        func flag(_ value: Any?) -> Bool? {
            guard let number = value as? NSNumber, String(cString: number.objCType) == "c" else { return nil }
            return number.boolValue
        }
        guard flag(text["tie_word_embeddings"]) ?? true, flag(root["tie_word_embeddings"]) ?? true else {
            throw ProbeError("Gemma tensor parallel plan: only the tied head is covered")
        }
        guard flag(text["enable_moe_block"]) == true else {
            throw ProbeError("Gemma tensor parallel plan: only the MoE text model is covered")
        }
        guard flag(text["attention_k_eq_v"]) == true else {
            throw ProbeError("Gemma tensor parallel plan: full layers must reuse K as V")
        }
        guard (text["num_kv_shared_layers"] as? Int ?? 0) == 0, (text["hidden_size_per_layer_input"] as? Int ?? 0) == 0,
              flag(text["attention_bias"]) != true else {
            throw ProbeError("Gemma tensor parallel plan: shared KV, per-layer embeddings and attention biases are not covered")
        }
        hiddenSize = try integer("hidden_size")
        layerCount = try integer("num_hidden_layers")
        vocabularySize = try integer("vocab_size")
        queryHeads = try integer("num_attention_heads")
        slidingKVHeads = try integer("num_key_value_heads")
        fullKVHeads = try integer("num_global_key_value_heads")
        slidingHeadDim = try integer("head_dim")
        fullHeadDim = try integer("global_head_dim")
        denseWidth = try integer("intermediate_size")
        expertWidth = try integer("moe_intermediate_size")
        expertCount = try integer("num_experts")
        expertsPerToken = try integer("top_k_experts")
        guard expertsPerToken <= expertCount else {
            throw ProbeError("Gemma tensor parallel plan: more experts per token than experts")
        }
        guard let types = text["layer_types"] as? [String], types.count == layerCount else {
            throw ProbeError("Gemma tensor parallel plan: every layer needs an explicit attention kind")
        }
        layerKinds = try types.map {
            guard let kind = LayerKind(rawValue: $0) else {
                throw ProbeError("Gemma tensor parallel plan: unknown layer kind \($0)")
            }
            return kind
        }

        guard let quantization = (root["quantization"] ?? root["quantization_config"]) as? [String: Any],
              let group = quantization["group_size"] as? Int, let bits = quantization["bits"] as? Int,
              (quantization["mode"] as? String ?? "affine") == "affine", [4, 8].contains(bits), [32, 64, 128].contains(group) else {
            throw ProbeError("Gemma tensor parallel plan: requires an affine 4- or 8-bit quantized checkpoint")
        }
        groupSize = group
        defaultBits = bits
        let quantizedModules = Set(["self_attn.q_proj", "self_attn.k_proj", "self_attn.v_proj", "self_attn.o_proj",
                                    "mlp.gate_proj", "mlp.up_proj", "mlp.down_proj", "router.proj",
                                    "experts.switch_glu.gate_proj", "experts.switch_glu.up_proj",
                                    "experts.switch_glu.down_proj"])
        var overrides: [String: Int] = [:]
        for (key, value) in quantization where !["group_size", "bits", "mode"].contains(key) {
            let prefix = "language_model.model.layers."
            guard key.hasPrefix(prefix), let entry = value as? [String: Any],
                  Set(entry.keys).isSubset(of: ["group_size", "bits", "mode"]),
                  entry["group_size"] as? Int == group, let moduleBits = entry["bits"] as? Int, [4, 8].contains(moduleBits),
                  (entry["mode"] as? String ?? "affine") == "affine" else {
                throw ProbeError("Gemma tensor parallel plan: quantization override \(key) is not an affine 4/8-bit entry of the default group size")
            }
            let rest = key.dropFirst(prefix.count)
            guard let dot = rest.firstIndex(of: "."), let layer = Int(rest[..<dot]), (0 ..< layerCount).contains(layer),
                  quantizedModules.contains(String(rest[rest.index(after: dot)...])) else {
                throw ProbeError("Gemma tensor parallel plan: quantization override for an unknown module \(key)")
            }
            overrides[key] = moduleBits
        }
        overrideBits = overrides

        // Whole query groups per rank on both layer kinds.
        for (label, kv) in [("sliding", slidingKVHeads), ("full", fullKVHeads)] {
            guard kv % size == 0, queryHeads % kv == 0 else {
                throw ProbeError("Gemma tensor parallel plan: \(label) KV heads (\(kv)) do not split into whole query groups")
            }
        }
        guard queryHeads % size == 0, vocabularySize % size == 0 else {
            throw ProbeError("Gemma tensor parallel plan: query heads or the vocabulary do not divide by \(size)")
        }
        _ = try ChannelSplit(width: denseWidth, groupSize: groupSize, rank: 0)
        _ = try ChannelSplit(width: expertWidth, groupSize: groupSize, rank: 0)
        // Every row-parallel input cut must land on quantization groups and packed words.
        for layer in 0 ..< layerCount {
            let width = queryHeads / size * self.headDim(layer: layer)
            let perWord = 32 / self.bits(forModule: Self.layerRoot(layer) + "self_attn.o_proj")
            guard width % groupSize == 0, width % perWord == 0 else {
                throw ProbeError("Gemma tensor parallel plan: layer \(layer)'s attention output shard (\(width)) does not land on a quantization group")
            }
        }
    }

    static func layerRoot(_ layer: Int) -> String { "language_model.model.layers.\(layer)." }

    public func headDim(layer: Int) -> Int { layerKinds[layer] == .full ? fullHeadDim : slidingHeadDim }
    public func kvHeads(layer: Int) -> Int { layerKinds[layer] == .full ? fullKVHeads : slidingKVHeads }

    /// Per layer, the KV heads one rank holds (26B: 4 sliding, 1 full).
    public var kvHeadsPerRank: [Int] { (0 ..< layerCount).map { kvHeads(layer: $0) / size } }
    public var queryHeadsPerRank: Int { queryHeads / size }

    /// Bits of a quantized module (`language_model.model.layers.N.mlp.down_proj`).
    public func bits(forModule path: String) -> Int { overrideBits[path] ?? defaultBits }

    public func denseSplit(rank: Int) throws -> ChannelSplit {
        try ChannelSplit(width: denseWidth, groupSize: groupSize, rank: rank)
    }

    public func expertSplit(rank: Int) throws -> ChannelSplit {
        try ChannelSplit(width: expertWidth, groupSize: groupSize, rank: rank)
    }

    /// Vocabulary rows this rank's head projects.
    public func vocabularyRange(rank: Int) -> Range<Int> {
        let half = vocabularySize / size
        return (rank * half) ..< ((rank + 1) * half)
    }

    // MARK: - Collective facts

    /// Collectives per layer (the attention partial, the packed feed-forward)
    /// and per decode step (the vocabulary-split selection).
    public let reductionsPerLayer = 2
    public let reductionsPerStep = 1
    /// FP32 bytes one token's attention collective carries.
    public var attentionPartialBytesPerToken: Int { hiddenSize * 4 }
    /// FP32 bytes one token's packed feed-forward collective carries: every
    /// selected expert's row and the dense branch's row.
    public var feedForwardPartialBytesPerToken: Int { (expertsPerToken + 1) * hiddenSize * 4 }
    public var layerPartialBytesPerToken: Int { attentionPartialBytesPerToken + feedForwardPartialBytesPerToken }
    /// Collectives one forward issues.
    public var reductionsPerForward: Int { reductionsPerLayer * layerCount }

    /// What two ranks must agree on before they serve together: the plan,
    /// where each sum is taken and what it carries. A peer with any other
    /// schedule refuses to load with this one.
    public static let arithmeticAgreementFields = [
        name,
        "gemma4-attention-f32-sum-before-post-attention-norm-v1",
        "gemma4-dense-and-expert-f32-rows-one-collective-before-branch-norms-v1",
        "gemma4-odd-group-channels-overlap-zero-padded-v1",
        "gemma4-tied-head-vocabulary-halves-v1",
    ]

    // MARK: - Configuration

    /// The text configuration `rank` constructs: half the query and KV heads
    /// of each layer kind, the local channel widths. Everything else is whole.
    public func shardTextConfiguration(_ text: [String: Any], rank: Int) throws -> [String: Any] {
        var shard = text
        shard["num_attention_heads"] = queryHeads / size
        shard["num_key_value_heads"] = slidingKVHeads / size
        shard["num_global_key_value_heads"] = fullKVHeads / size
        shard["intermediate_size"] = try denseSplit(rank: rank).localWidth
        shard["moe_intermediate_size"] = try expertSplit(rank: rank).localWidth
        return shard
    }

    // MARK: - Stored tensors

    /// True for the artifact's vision tower and its embedder, which no
    /// tensor-parallel rank loads (the loader skips them; `cut` refuses them).
    public static func isVisionTensor(_ key: String) -> Bool {
        key.hasPrefix("vision_tower.") || key.hasPrefix("embed_vision.") || key.hasPrefix("multi_modal_projector.")
            || key.hasPrefix("audio_tower.") || key.hasPrefix("embed_audio.")
    }

    private static let replicatedLayerTensors: Set<String> = [
        "input_layernorm.weight", "post_attention_layernorm.weight", "pre_feedforward_layernorm.weight",
        "post_feedforward_layernorm.weight", "post_feedforward_layernorm_1.weight",
        "pre_feedforward_layernorm_2.weight", "post_feedforward_layernorm_2.weight", "layer_scalar",
        "router.scale", "router.per_expert_scale", "self_attn.q_norm.weight", "self_attn.k_norm.weight",
    ]

    /// The cut of one stored text tensor (`language_model.` keys, as the
    /// registered checkpoints store them) for `rank`. Unknown, vision and
    /// untied-head tensors throw.
    public func cut(key: String, rank: Int) throws -> Cut {
        guard (0 ..< size).contains(rank) else {
            throw ProbeError("Gemma tensor parallel plan: rank \(rank) is outside the group")
        }
        if Self.isVisionTensor(key) {
            throw ProbeError("Gemma tensor parallel plan: vision tensors are not part of the tensor-parallel text model (\(key))")
        }
        if ["language_model.model.embed_tokens.weight", "language_model.model.embed_tokens.scales",
            "language_model.model.embed_tokens.biases", "language_model.model.norm.weight"].contains(key) {
            return .replicate
        }
        let prefix = "language_model.model.layers."
        guard key.hasPrefix(prefix) else { throw ProbeError("Gemma tensor parallel plan: unknown checkpoint key \(key)") }
        let rest = key.dropFirst(prefix.count)
        guard let dot = rest.firstIndex(of: "."), let layer = Int(rest[..<dot]), (0 ..< layerCount).contains(layer),
              String(layer) == rest[..<dot] else {
            throw ProbeError("Gemma tensor parallel plan: unknown layer key \(key)")
        }
        let name = String(rest[rest.index(after: dot)...])
        if Self.replicatedLayerTensors.contains(name) { return .replicate }
        let parts = name.split(separator: ".").map(String.init)
        guard parts.count >= 2, ["weight", "scales", "biases"].contains(parts.last!) else {
            throw ProbeError("Gemma tensor parallel plan: unknown layer key \(key)")
        }
        let module = parts.dropLast().joined(separator: ".")
        let full = layerKinds[layer] == .full
        let headDim = self.headDim(layer: layer)
        let queries = queryHeads / size, kv = self.kvHeads(layer: layer) / size
        switch module {
        case "router.proj":
            return .replicate
        case "self_attn.q_proj":
            return .rows((rank * queries * headDim) ..< ((rank + 1) * queries * headDim), zeroBefore: 0, zeroAfter: 0)
        case "self_attn.k_proj":
            return .rows((rank * kv * headDim) ..< ((rank + 1) * kv * headDim), zeroBefore: 0, zeroAfter: 0)
        case "self_attn.v_proj" where !full:
            return .rows((rank * kv * headDim) ..< ((rank + 1) * kv * headDim), zeroBefore: 0, zeroAfter: 0)
        case "self_attn.o_proj":
            return .inputColumns((rank * queries * headDim) ..< ((rank + 1) * queries * headDim))
        case "mlp.gate_proj", "mlp.up_proj":
            let split = try denseSplit(rank: rank)
            return .rows(split.channels, zeroBefore: split.zeroBefore, zeroAfter: split.zeroAfter)
        case "mlp.down_proj":
            return .inputColumns(try denseSplit(rank: rank).storedColumns)
        case "experts.switch_glu.gate_proj", "experts.switch_glu.up_proj":
            let split = try expertSplit(rank: rank)
            return .expertRows(split.channels, zeroBefore: split.zeroBefore, zeroAfter: split.zeroAfter)
        case "experts.switch_glu.down_proj":
            return .expertInputColumns(try expertSplit(rank: rank).storedColumns)
        default:
            throw ProbeError("Gemma tensor parallel plan: unknown layer key \(key)")
        }
    }

    /// The stored shape the plan expects for a text tensor of the whole
    /// model (affine packing: `in / (32 / bits)` words, `in / group` scales).
    public func expectedShape(key: String) throws -> [Int] {
        if key.hasPrefix("language_model.model.embed_tokens.") {
            return try packed(key, [vocabularySize, hiddenSize], bits: defaultBits)
        }
        if key == "language_model.model.norm.weight" { return [hiddenSize] }
        let prefix = "language_model.model.layers."
        guard key.hasPrefix(prefix) else { throw ProbeError("Gemma tensor parallel plan: unknown checkpoint key \(key)") }
        let rest = key.dropFirst(prefix.count)
        guard let dot = rest.firstIndex(of: "."), let layer = Int(rest[..<dot]), (0 ..< layerCount).contains(layer) else {
            throw ProbeError("Gemma tensor parallel plan: unknown layer key \(key)")
        }
        let name = String(rest[rest.index(after: dot)...])
        let headDim = self.headDim(layer: layer), kv = self.kvHeads(layer: layer)
        switch name {
        case "layer_scalar": return [1]
        case "router.per_expert_scale": return [expertCount]
        case "self_attn.q_norm.weight", "self_attn.k_norm.weight": return [headDim]
        default: break
        }
        if Self.replicatedLayerTensors.contains(name) { return [hiddenSize] }
        let module = name.split(separator: ".").dropLast().joined(separator: ".")
        let bits = self.bits(forModule: Self.layerRoot(layer) + module)
        let logical: [Int]
        switch module {
        case "router.proj": logical = [expertCount, hiddenSize]
        case "self_attn.q_proj": logical = [queryHeads * headDim, hiddenSize]
        case "self_attn.k_proj", "self_attn.v_proj": logical = [kv * headDim, hiddenSize]
        case "self_attn.o_proj": logical = [hiddenSize, queryHeads * headDim]
        case "mlp.gate_proj", "mlp.up_proj": logical = [denseWidth, hiddenSize]
        case "mlp.down_proj": logical = [hiddenSize, denseWidth]
        case "experts.switch_glu.gate_proj", "experts.switch_glu.up_proj": logical = [expertCount, expertWidth, hiddenSize]
        case "experts.switch_glu.down_proj": logical = [expertCount, hiddenSize, expertWidth]
        default: throw ProbeError("Gemma tensor parallel plan: unknown layer key \(key)")
        }
        return try packed(key, logical, bits: bits)
    }

    private func packed(_ key: String, _ logical: [Int], bits: Int) throws -> [Int] {
        guard let last = logical.last else { throw ProbeError("Gemma tensor parallel plan: empty shape for \(key)") }
        let leaf = key.split(separator: ".").last.map(String.init) ?? ""
        switch leaf {
        case "weight": return logical.dropLast() + [last / (32 / bits)]
        case "scales", "biases": return logical.dropLast() + [last / groupSize]
        default: throw ProbeError("Gemma tensor parallel plan: unknown quantized leaf in \(key)")
        }
    }

    /// The shape one rank stores for a text tensor of `shape` under `cut`,
    /// refusing a cut that leaves the tensor or splits a packed word or group.
    public func localShape(key: String, shape: [Int], cut: Cut) throws -> [Int] {
        let leaf = key.split(separator: ".").last.map(String.init) ?? ""
        let module = key.split(separator: ".").dropLast().joined(separator: ".")
        let divisor = leaf == "weight" ? 32 / bits(forModule: module) : groupSize
        var local = shape
        switch cut {
        case .replicate:
            return shape
        case .rows(let range, let before, let after):
            guard !shape.isEmpty, range.lowerBound >= 0, range.upperBound <= shape[0], !range.isEmpty else {
                throw ProbeError("Gemma tensor parallel plan: rows \(range) do not fit \(key) \(shape)")
            }
            local[0] = before + range.count + after
        case .inputColumns(let logical):
            guard shape.count == 2, ["weight", "scales", "biases"].contains(leaf),
                  logical.lowerBound % groupSize == 0, logical.upperBound % groupSize == 0,
                  logical.lowerBound % divisor == 0, logical.upperBound % divisor == 0,
                  logical.upperBound / divisor <= shape[1] else {
                throw ProbeError("Gemma tensor parallel plan: columns \(logical) split a group or word of \(key) \(shape)")
            }
            local[1] = logical.count / divisor
        case .expertRows(let range, let before, let after):
            guard shape.count == 3, range.lowerBound >= 0, range.upperBound <= shape[1], !range.isEmpty else {
                throw ProbeError("Gemma tensor parallel plan: expert rows \(range) do not fit \(key) \(shape)")
            }
            local[1] = before + range.count + after
        case .expertInputColumns(let logical):
            guard shape.count == 3, ["weight", "scales", "biases"].contains(leaf),
                  logical.lowerBound % groupSize == 0, logical.upperBound % groupSize == 0,
                  logical.lowerBound % divisor == 0, logical.upperBound % divisor == 0,
                  logical.upperBound / divisor <= shape[2] else {
                throw ProbeError("Gemma tensor parallel plan: expert columns \(logical) split a group or word of \(key) \(shape)")
            }
            local[2] = logical.count / divisor
        }
        return local
    }
}
