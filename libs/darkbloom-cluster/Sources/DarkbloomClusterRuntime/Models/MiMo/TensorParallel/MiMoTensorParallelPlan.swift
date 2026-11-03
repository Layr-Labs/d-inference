import Foundation

/// How the MiMo V2.6 Flash text model (`mimo_v2`, untied head; the registered
/// `mimo-v2.6-flash-mopd` artifact) divides across two ranks by heads and
/// channels with equal shares: `mimo_v26_heads_and_expert_channels_v1`.
/// CPU metadata only: nothing here imports MLX or reads a payload.
///
/// - Attention: contiguous halves of the query heads with the KV heads they
///   read. `q_proj`, `k_proj`, `v_proj` by output rows, the sliding layers'
///   learned sink bias per query head, `o_proj` by input columns (registered:
///   32 query heads per rank, 2 full and 4 sliding KV heads, sinks 32).
/// - Dense layer 0 and every routed expert: half the channels (gate/up output
///   rows; down input columns, axis 2 of the `[experts, hidden, width]` bank).
///   Every cut lands on whole quantization groups and packed words (registered:
///   1,024 expert channels = 32 MXFP4 groups of 32), so no rank stores padding.
/// - Replicated: every norm, the router (`mlp.gate`: weight and score
///   correction, so both ranks choose the same experts), the final norm and
///   the token embedding (a lookup). The untied `lm_head` is divided by
///   vocabulary rows.
/// - Excluded: the trained MTP heads, the vision tower, the audio encoder and
///   the speech embeddings belong to no tensor-parallel text rank; `cut`
///   refuses them, and every other unknown name, as text.
///
/// Collectives: per layer the `o_proj` partial (stored BF16, summed in FP32,
/// rounded once) and the feed-forward partial (layer 0's BF16 dense partial;
/// a routed layer's experts combined locally in FP32 with the replicated
/// router weights), one FP32 hidden row per token each; one per decode step
/// for the vocabulary-split selection. MTP stays off.
public struct MiMoTensorParallelPlan: Sendable, Equatable {
    public static let name = "mimo_v26_heads_and_expert_channels_v1"
    public let size = 2

    /// What a rank does with one indexed tensor.
    public enum Disposition: Equatable, Sendable {
        case replicated
        /// Each rank keeps its half along `axis` of the stored tensor.
        case divided(axis: Int)
        /// Not part of the tensor-parallel text model.
        case excluded(component: String)
    }

    /// A quantized module's packing.
    public struct Policy: Equatable, Sendable {
        public let mode: String
        public let bits: Int
        public let groupSize: Int
        /// Logical values per stored 32-bit word.
        public var valuesPerWord: Int { 32 / bits }
    }

    public let hiddenSize: Int
    public let layerCount: Int
    public let vocabularySize: Int
    public let denseWidth: Int
    public let expertWidth: Int
    public let expertCount: Int
    public let expertsPerToken: Int
    public let fullQueryHeads: Int
    public let fullKVHeads: Int
    public let fullHeadDim: Int
    public let fullValueHeadDim: Int
    public let slidingQueryHeads: Int
    public let slidingKVHeads: Int
    public let slidingHeadDim: Int
    public let slidingValueHeadDim: Int
    public let fullSinks: Bool
    public let slidingSinks: Bool
    /// Per layer: a sliding-window layer (`hybrid_layer_pattern` 1).
    public let slidingLayers: [Bool]
    /// Per layer: a routed MoE layer (`moe_layer_freq` 1).
    public let routedLayers: [Bool]
    public let configurationSHA256: String
    private let defaultPolicy: Policy?
    private let overridePolicies: [String: Policy]

    static let textNamespace = "language_model."
    static let excludedComponents: [(prefix: String, component: String)] = [
        ("language_model.model.mtp.", "mtp"), ("vision_tower.", "vision"),
        ("audio_encoder.", "audio"), ("speech_embeddings.", "speech"),
    ]

    /// `configuration` is the artifact's whole `config.json`.
    public init(configuration: Data) throws {
        guard (1 ... 4 << 20).contains(configuration.count),
              let root = try JSONSerialization.jsonObject(with: configuration) as? [String: Any] else {
            throw ProbeError("MiMo tensor parallel plan: the configuration is not a bounded JSON object")
        }
        guard root["model_type"] as? String == "mimo_v2" else {
            throw ProbeError("MiMo tensor parallel plan: expected a mimo_v2 configuration")
        }
        func integer(_ key: String) throws -> Int {
            guard let value = BoundedProbeInput.integer(root[key]), value > 0 else {
                throw ProbeError("MiMo tensor parallel plan: the configuration lacks a positive \(key)")
            }
            return value
        }
        func flag(_ key: String) throws -> Bool {
            guard let number = root[key] as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                throw ProbeError("MiMo tensor parallel plan: the configuration lacks the flag \(key)")
            }
            return number.boolValue
        }
        func flags(_ key: String, count: Int) throws -> [Bool] {
            guard let values = root[key] as? [Any], values.count == count else {
                throw ProbeError("MiMo tensor parallel plan: \(key) needs one entry per layer")
            }
            return try values.map {
                guard let value = BoundedProbeInput.integer($0), (0 ... 1).contains(value) else {
                    throw ProbeError("MiMo tensor parallel plan: \(key) has an unknown layer kind")
                }
                return value == 1
            }
        }
        guard try !flag("tie_word_embeddings") else {
            throw ProbeError("MiMo tensor parallel plan: only the untied head is covered")
        }
        guard try !flag("attention_bias") else {
            throw ProbeError("MiMo tensor parallel plan: attention biases are not covered")
        }
        guard ["bfloat16", "float32"].contains(root["dtype"] as? String ?? "") else {
            throw ProbeError("MiMo tensor parallel plan: activations are bfloat16 (float32 for synthetic checks)")
        }
        if let shared = root["n_shared_experts"], !(shared is NSNull), BoundedProbeInput.integer(shared) != 0 {
            throw ProbeError("MiMo tensor parallel plan: shared experts are not covered")
        }
        hiddenSize = try integer("hidden_size")
        layerCount = try integer("num_hidden_layers")
        vocabularySize = try integer("vocab_size")
        denseWidth = try integer("intermediate_size")
        expertWidth = try integer("moe_intermediate_size")
        expertCount = try integer("n_routed_experts")
        expertsPerToken = try integer("num_experts_per_tok")
        fullQueryHeads = try integer("num_attention_heads")
        fullKVHeads = try integer("num_key_value_heads")
        fullHeadDim = try integer("head_dim")
        fullValueHeadDim = try integer("v_head_dim")
        slidingQueryHeads = try integer("swa_num_attention_heads")
        slidingKVHeads = try integer("swa_num_key_value_heads")
        slidingHeadDim = try integer("swa_head_dim")
        slidingValueHeadDim = try integer("swa_v_head_dim")
        fullSinks = try flag("add_full_attention_sink_bias")
        slidingSinks = try flag("add_swa_attention_sink_bias")
        slidingLayers = try flags("hybrid_layer_pattern", count: layerCount)
        routedLayers = try flags("moe_layer_freq", count: layerCount)
        guard expertsPerToken <= expertCount else {
            throw ProbeError("MiMo tensor parallel plan: more experts per token than experts")
        }
        configurationSHA256 = sha256(configuration)

        // The default policy, and one entry per quantized module (indexed path).
        let quantization = (root["quantization"] ?? root["quantization_config"]) as? [String: Any] ?? [:]
        func policy(_ entry: [String: Any], _ label: String) throws -> Policy {
            guard let bits = BoundedProbeInput.integer(entry["bits"]),
                  let group = BoundedProbeInput.integer(entry["group_size"]) else {
                throw ProbeError("MiMo tensor parallel plan: quantization entry \(label) lacks bits or a group size")
            }
            let mode = entry["mode"] as? String ?? "affine"
            guard (mode == "affine" && [4, 8].contains(bits) && [32, 64, 128].contains(group))
                    || (mode == "mxfp4" && bits == 4 && group == 32) else {
                throw ProbeError("MiMo tensor parallel plan: quantization entry \(label) is not affine 4/8-bit or MXFP4 g32")
            }
            return Policy(mode: mode, bits: bits, groupSize: group)
        }
        defaultPolicy = quantization["bits"] == nil ? nil : try policy(quantization, "default")
        var overrides: [String: Policy] = [:]
        for (key, value) in quantization where !["group_size", "bits", "mode"].contains(key) {
            if Self.excludedComponents.contains(where: { key.hasPrefix($0.prefix) }) { continue }
            guard let entry = value as? [String: Any] else {
                throw ProbeError("MiMo tensor parallel plan: quantization entry \(key) is not a policy")
            }
            overrides[key] = try policy(entry, key)
        }
        overridePolicies = overrides

        // Whole query groups per rank, and every cut on whole groups and words.
        for (label, queries, kv) in [("full", fullQueryHeads, fullKVHeads), ("sliding", slidingQueryHeads, slidingKVHeads)] {
            guard kv % size == 0, queries % kv == 0 else {
                throw ProbeError("MiMo tensor parallel plan: \(label) KV heads (\(kv)) do not split into whole query groups")
            }
        }
        guard vocabularySize % size == 0, denseWidth % size == 0, expertWidth % size == 0 else {
            throw ProbeError("MiMo tensor parallel plan: the vocabulary or a channel width does not divide by \(size)")
        }
        for module in overrides.keys {
            guard module.hasPrefix(Self.textNamespace),
                  let quantized = try? textTensor(String(module.dropFirst(Self.textNamespace.count)) + ".weight"),
                  quantized.quantized else {
                throw ProbeError("MiMo tensor parallel plan: quantization entry for an unknown text module \(module)")
            }
        }
        for module in ["model.embed_tokens", "lm_head"] {
            if let packing = self.policy(module: Self.textNamespace + module) {
                guard packing == Policy(mode: "affine", bits: 8, groupSize: 64) else {
                    throw ProbeError("MiMo tensor parallel plan: \(module) must be affine 8-bit, group 64")
                }
            }
        }
        for layer in 0 ..< layerCount {
            let base = Self.layerRoot(layer)
            let expertsBits = routedLayers[layer] ? self.policy(module: base + "mlp.switch_mlp.down_proj") : nil
            let checks: [(String, Int, Policy?)] = [
                ("o_proj", queryHeads(layer: layer) / size * valueHeadDim(layer: layer), self.policy(module: base + "self_attn.o_proj")),
                routedLayers[layer] ? ("expert down_proj", expertWidth / size, expertsBits)
                    : ("down_proj", denseWidth / size, self.policy(module: base + "mlp.down_proj")),
            ]
            for (label, width, packing) in checks {
                if let packing, width % packing.groupSize != 0 || width % packing.valuesPerWord != 0 {
                    throw ProbeError("MiMo tensor parallel plan: layer \(layer)'s \(label) shard (\(width)) does not land on a quantization group")
                }
            }
        }
    }

    static func layerRoot(_ layer: Int) -> String { "language_model.model.layers.\(layer)." }

    public func queryHeads(layer: Int) -> Int { slidingLayers[layer] ? slidingQueryHeads : fullQueryHeads }
    public func kvHeads(layer: Int) -> Int { slidingLayers[layer] ? slidingKVHeads : fullKVHeads }
    public func headDim(layer: Int) -> Int { slidingLayers[layer] ? slidingHeadDim : fullHeadDim }
    public func valueHeadDim(layer: Int) -> Int { slidingLayers[layer] ? slidingValueHeadDim : fullValueHeadDim }
    public func hasSinks(layer: Int) -> Bool { slidingLayers[layer] ? slidingSinks : fullSinks }

    /// Per layer, the KV heads one rank holds (registered: 2 full, 4 sliding).
    public var kvHeadsPerRank: [Int] { (0 ..< layerCount).map { kvHeads(layer: $0) / size } }
    /// Per layer, the query heads (and sink biases) one rank holds.
    public var queryHeadsPerRank: [Int] { (0 ..< layerCount).map { queryHeads(layer: $0) / size } }

    /// The packing of a quantized text module (indexed path), when stored packed.
    public func policy(module path: String) -> Policy? { overridePolicies[path] ?? defaultPolicy }

    /// Vocabulary rows this rank's head projects.
    public func vocabularyRange(rank: Int) -> Range<Int> {
        let half = vocabularySize / size
        return (rank * half) ..< ((rank + 1) * half)
    }

    // MARK: - Collective facts

    public let reductionsPerLayer = 2
    public let reductionsPerStep = 1
    /// FP32 bytes one token's collective carries (one hidden row).
    public var partialBytesPerToken: Int { hiddenSize * 4 }
    public var reductionsPerForward: Int { reductionsPerLayer * layerCount }

    /// What two ranks must agree on before they serve together: the plan,
    /// where each sum is taken and what it carries. Each row-parallel product
    /// takes an exact FP32 widening of its input, so its partial is stored as
    /// FP32 and rounded only once, after the sum (v2; v1 stored BF16 partials).
    public static let arithmeticAgreementFields = [
        name,
        "mimo-v26-o-proj-partial-stored-float32-sum-float32-rounded-once-v2",
        "mimo-v26-dense-down-partial-stored-float32-sum-float32-rounded-once-v2",
        "mimo-v26-expert-rows-stored-float32-local-float32-combine-sum-float32-rounded-once-v2",
        "mimo-v26-untied-head-vocabulary-halves-v1",
        "mimo-v26-mtp-off-v1",
    ]

    /// Binds the plan, its agreement fields and the source configuration.
    public var fingerprint: String {
        sha256(Data(([Self.name, configurationSHA256] + Self.arithmeticAgreementFields).joined(separator: "\n").utf8))
    }

    // MARK: - Configuration

    /// The configuration `rank` constructs, canonical JSON: half the query
    /// and KV heads of both layer kinds and half of both channel widths, no
    /// MTP heads, towers or their metadata. Every other field is whole.
    public func shardConfigurationData(_ configuration: Data, rank: Int) throws -> Data {
        guard (0 ..< size).contains(rank), sha256(configuration) == configurationSHA256,
              var fields = try JSONSerialization.jsonObject(with: configuration) as? [String: Any] else {
            throw ProbeError("MiMo tensor parallel plan: shard configuration of another source or rank")
        }
        for key in ["num_attention_heads", "num_key_value_heads", "swa_num_attention_heads",
                    "swa_num_key_value_heads", "intermediate_size", "moe_intermediate_size"] {
            guard let value = BoundedProbeInput.integer(fields[key]), value % size == 0 else {
                throw ProbeError("MiMo tensor parallel plan: \(key) does not halve")
            }
            fields[key] = value / size
        }
        fields["num_nextn_predict_layers"] = 0
        for key in ["omlx_mimo_mtp", "vision_config", "audio_config", "processor_config"] { fields[key] = nil }
        return try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    }

    // MARK: - Stored tensors

    /// The disposition of one indexed tensor. Unknown names throw.
    public func disposition(of name: String) throws -> Disposition {
        if let excluded = Self.excludedComponents.first(where: { name.hasPrefix($0.prefix) }) {
            return .excluded(component: excluded.component)
        }
        guard name.hasPrefix(Self.textNamespace) else {
            throw ProbeError("MiMo tensor parallel plan: unknown tensor \(name)")
        }
        let tensor = try textTensor(String(name.dropFirst(Self.textNamespace.count)))
        return tensor.axis.map { .divided(axis: $0) } ?? .replicated
    }

    /// The axis a text tensor is divided on (nil: replicated). Excluded and
    /// unknown tensors throw: they are not part of the text model.
    public func cut(key: String) throws -> Int? {
        switch try disposition(of: key) {
        case .replicated: return nil
        case .divided(let axis): return axis
        case .excluded(let component):
            throw ProbeError("MiMo tensor parallel plan: \(component) tensors are not part of the tensor-parallel text model (\(key))")
        }
    }

    /// The stored shape of a text tensor of the whole model.
    public func expectedShape(key: String) throws -> [Int] {
        guard key.hasPrefix(Self.textNamespace), Self.excludedComponents.allSatisfy({ !key.hasPrefix($0.prefix) }) else {
            throw ProbeError("MiMo tensor parallel plan: not a text tensor \(key)")
        }
        return try textTensor(String(key.dropFirst(Self.textNamespace.count))).shape
    }

    /// The shape one rank stores for a text tensor of `shape`, refusing a
    /// cut axis that would split a packed word or a quantization group.
    public func localShape(key: String, shape: [Int]) throws -> [Int] {
        guard let axis = try cut(key: key) else { return shape }
        guard shape.indices.contains(axis), shape[axis] % size == 0 else {
            throw ProbeError("MiMo tensor parallel plan: \(key) \(shape) does not halve on axis \(axis)")
        }
        var local = shape
        local[axis] /= size
        return local
    }

    /// A text tensor by its local name (`model.…` or `lm_head.…`): its axis,
    /// stored shape and whether its module is stored packed.
    private func textTensor(_ name: String) throws -> (axis: Int?, shape: [Int], quantized: Bool) {
        func unknown() -> ProbeError { ProbeError("MiMo tensor parallel plan: unknown text tensor \(name)") }
        let parts = name.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard let leaf = parts.last, !parts.contains("") else { throw unknown() }
        let module = parts.dropLast().joined(separator: ".")
        // A packed module stores weight words, scales and (affine) offsets.
        func packed(_ logical: [Int], axis: Int?) throws -> (axis: Int?, shape: [Int], quantized: Bool) {
            guard let packing = policy(module: Self.textNamespace + module) else {
                guard leaf == "weight" else { throw unknown() }
                return (axis, logical, false)
            }
            let leading = Array(logical.dropLast()), last = logical[logical.count - 1]
            switch leaf {
            case "weight": return (axis, leading + [last / packing.valuesPerWord], true)
            case "scales": return (axis, leading + [last / packing.groupSize], true)
            case "biases" where packing.mode == "affine": return (axis, leading + [last / packing.groupSize], true)
            default: throw unknown()
            }
        }
        switch module {
        case "model.embed_tokens": return try packed([vocabularySize, hiddenSize], axis: nil)
        case "lm_head": return try packed([vocabularySize, hiddenSize], axis: 0)
        case "model.norm" where leaf == "weight": return (nil, [hiddenSize], false)
        default: break
        }
        guard parts.count >= 5, parts[0] == "model", parts[1] == "layers", let layer = Int(parts[2]),
              String(layer) == parts[2], (0 ..< layerCount).contains(layer) else { throw unknown() }
        let rest = parts[3...].joined(separator: ".")
        let routed = routedLayers[layer]
        switch rest {
        case "input_layernorm.weight", "post_attention_layernorm.weight": return (nil, [hiddenSize], false)
        case "self_attn.attention_sink_bias" where hasSinks(layer: layer): return (0, [queryHeads(layer: layer)], false)
        case "mlp.gate.weight" where routed: return (nil, [expertCount, hiddenSize], false)
        case "mlp.gate.e_score_correction_bias" where routed: return (nil, [expertCount], false)
        default: break
        }
        let queries = queryHeads(layer: layer), kv = kvHeads(layer: layer)
        switch parts[3 ..< parts.count - 1].joined(separator: ".") {
        case "self_attn.q_proj": return try packed([queries * headDim(layer: layer), hiddenSize], axis: 0)
        case "self_attn.k_proj": return try packed([kv * headDim(layer: layer), hiddenSize], axis: 0)
        case "self_attn.v_proj": return try packed([kv * valueHeadDim(layer: layer), hiddenSize], axis: 0)
        case "self_attn.o_proj": return try packed([hiddenSize, queries * valueHeadDim(layer: layer)], axis: 1)
        case "mlp.gate_proj" where !routed, "mlp.up_proj" where !routed:
            return try packed([denseWidth, hiddenSize], axis: 0)
        case "mlp.down_proj" where !routed: return try packed([hiddenSize, denseWidth], axis: 1)
        case "mlp.switch_mlp.gate_proj" where routed, "mlp.switch_mlp.up_proj" where routed:
            return try packed([expertCount, expertWidth, hiddenSize], axis: 1)
        case "mlp.switch_mlp.down_proj" where routed: return try packed([expertCount, hiddenSize, expertWidth], axis: 2)
        default: throw unknown()
        }
    }
}
