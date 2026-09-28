import CoreFoundation
import Foundation
import MLXLLM
import MLXLMCommon
import MLXNN

/// Two-rank, FFN-only Gemma partition. A rank owns the same complete quantization
/// groups in every layer; its dense and routed widths need not match its peer's.
/// Both branches reduce at their own RMSNorm INPUT, before nonlinear normalization.
struct GemmaPartitionPlan {
    let kind = QwenPartitionKind.ffn
    let attentionOutputPrecision = AttentionOutputPrecision.native
    let ffnBranchPrecision: FFNBranchPrecision
    let originalConfiguration: Data
    let fingerprint: String
    let layers: Int
    let hidden: Int
    let intermediate: Int
    let isMoE: Bool
    let denseIntervals: [Range<Int>]
    let expertIntervals: [Range<Int>]
    let expectedSourceShapes: [String: [Int]]
    let normalizationInputPaths: [String]
    private let rankConfigurations: [Data]
    private let config: Gemma4TextConfiguration
    private let prefix: String
    private let policies: [String: BaseConfiguration.Quantization]

    init(configuration: Data, kind: QwenPartitionKind = .ffn,
         ffnBranchPrecision: FFNBranchPrecision = .native) throws {
        guard kind == .ffn else { throw ProbeError("Gemma currently supports FFN partitioning only") }
        guard let root = try JSONSerialization.jsonObject(with: configuration) as? [String: Any],
              let modelType = root["model_type"] as? String,
              ["gemma4", "gemma4_text"].contains(modelType) else {
            throw ProbeError("Gemma partition requires gemma4 or gemma4_text configuration")
        }
        let wrapped = modelType == "gemma4"
        let text: [String: Any]
        if wrapped {
            guard let nested = root["text_config"] as? [String: Any],
                  (nested["model_type"] as? String ?? "gemma4_text") == "gemma4_text" else {
                throw ProbeError("Gemma wrapper requires a gemma4_text text_config")
            }
            text = nested
        } else {
            guard root["text_config"] == nil else { throw ProbeError("Unexpected nested Gemma text configuration") }
            text = root
        }
        let hidden = try gemmaPlanInteger(text, "hidden_size")
        let layers = try gemmaPlanInteger(text, "num_hidden_layers")
        let intermediate = try gemmaPlanInteger(text, "intermediate_size")
        guard layers <= 4096 else { throw ProbeError("Gemma partition layer count exceeds its bounded scope") }
        // The public decoder builds a default layer schedule with modulo;
        // reject a zero/malformed pattern before invoking that decoder.
        if text["sliding_window_pattern"] != nil {
            _ = try gemmaPlanInteger(text, "sliding_window_pattern")
        }
        let decoded = try JSONDecoder().decode(Gemma4TextConfiguration.self,
            from: JSONSerialization.data(withJSONObject: text))
        try Self.validateGeometry(decoded, text: text)
        let denseIntervals = try Self.intervals(width: intermediate)
        let expertIntervals = try decoded.enableMoeBlock
            ? Self.intervals(width: gemmaPlanInteger(text, "moe_intermediate_size")) : []
        try Self.validateQuantizationCopies(root: root, text: wrapped ? text : nil)
        guard let policy = try JSONDecoder().decode(BaseConfiguration.self, from: configuration).perLayerQuantization else {
            throw ProbeError("Gemma partition requires an explicit checkpoint quantization policy")
        }
        let prefix = wrapped ? "language_model." : ""
        // Gemma4Configuration assigns its top-level vocab (default262144) to
        // the nested text model, even when text_config declares another value.
        let vocabulary = try wrapped
            ? (root["vocab_size"] == nil ? 262_144 : gemmaPlanInteger(root, "vocab_size"))
            : gemmaPlanInteger(text, "vocab_size")
        let layout = try GemmaPartitionLayout(config: decoded, vocabulary: vocabulary,
                                              prefix: prefix, policy: policy)
        var rankConfigurations: [Data] = []
        for rank in 0..<2 {
            var changedText = text
            changedText["intermediate_size"] = denseIntervals[rank].count
            if decoded.enableMoeBlock { changedText["moe_intermediate_size"] = expertIntervals[rank].count }
            var changedRoot = root
            if wrapped { changedRoot["text_config"] = changedText } else { changedRoot = changedText }
            rankConfigurations.append(try JSONSerialization.data(withJSONObject: changedRoot, options: [.sortedKeys]))
        }
        let normalizationInputPaths = (0..<layers).flatMap { layer in
            let path = prefix + "model.layers.\(layer)."
            return decoded.enableMoeBlock
                ? [path + "post_feedforward_layernorm_1", path + "post_feedforward_layernorm_2"]
                : [path + "post_feedforward_layernorm"]
        }
        let policyIdentity = layout.policies.mapValues { value in
            ["bits": value.bits, "groupSize": value.groupSize, "mode": "affine"] as [String: Any]
        }
        fingerprint = sha256(try JSONSerialization.data(withJSONObject: [
            "adapter": "gemma4-ffn-two-rank-v1", "kind": "ffn", "attentionOutputPrecision": "native",
            "ffnBranchPrecision": ffnBranchPrecision.rawValue,
            "sourceConfigurationSHA256": sha256(configuration),
            "rankConstructionConfigurationSHA256": rankConfigurations.map(sha256),
            "denseIntervals": denseIntervals.map { [$0.lowerBound, $0.upperBound] },
            "expertIntervals": expertIntervals.map { [$0.lowerBound, $0.upperBound] },
            "projectionPolicies": policyIdentity,
            "normalizationInputPaths": normalizationInputPaths,
            "branchCollectiveOrder": "dense-before-sparse-per-layer-dependency-v1",
        ], options: [.sortedKeys]))
        self.originalConfiguration = configuration
        self.ffnBranchPrecision = ffnBranchPrecision
        self.config = decoded; self.prefix = prefix; self.policies = layout.policies
        self.hidden = hidden; self.layers = layers; self.intermediate = intermediate
        self.isMoE = decoded.enableMoeBlock
        self.denseIntervals = denseIntervals; self.expertIntervals = expertIntervals
        self.expectedSourceShapes = layout.shapes
        self.normalizationInputPaths = normalizationInputPaths
        self.rankConfigurations = rankConfigurations
    }

    func constructionConfiguration(rank: Int) throws -> Data {
        guard (0..<2).contains(rank) else { throw ProbeError("Invalid Gemma partition rank") }
        return rankConfigurations[rank]
    }

    /// The FFN byte category includes dense projections, expert banks and the
    /// replicated router, but excludes all normalization/scalar/PLE parameters.
    func isFeedForwardTensor(name: String) -> Bool {
        guard let components = layerTensor(name) else { return false }
        return ["mlp", "experts", "router"].contains(components.relative.first ?? "")
    }

    func selection(name: String, shape: [Int], rank: Int) throws -> TensorSelection {
        guard (0..<2).contains(rank) else { throw ProbeError("Invalid Gemma partition rank") }
        guard expectedSourceShapes[name] == shape else {
            throw ProbeError("Unsupported Gemma source tensor name or packed shape: \(name)")
        }
        guard let location = layerTensor(name) else { return .all }
        let relative = location.relative
        if relative.first == "mlp" {
            guard relative.count == 3 else { throw ProbeError("Unsupported Gemma dense tensor") }
            let doubled = config.useDoubleWideMlp && config.layerUsesSharedKV(layerIdx: location.layer)
            let factor = doubled ? 2 : 1
            let base = denseIntervals[rank]
            let interval = (base.lowerBound * factor)..<(base.upperBound * factor)
            let module = String(name.dropLast(relative[2].count + 1))
            guard let policy = policies[module] else { throw ProbeError("Missing Gemma dense quantization") }
            let down = relative[1] == "down_proj"
            let divisor = down ? (relative[2] == "weight" ? 32 / policy.bits : 64) : 1
            return .axis(down ? 1 : 0, [(interval.lowerBound / divisor)..<(interval.upperBound / divisor)])
        }
        if relative.first == "experts" {
            guard relative.count == 4, relative[1] == "switch_glu", isMoE,
                  let experts = config.numExperts, let width = config.moeIntermediateSize else {
                throw ProbeError("Unsupported Gemma expert bank tensor")
            }
            let bank = prefix + "model.layers.\(location.layer).experts.switch_glu."
            var bits: [String: Int] = [:]
            for projection in ["gate_proj", "up_proj", "down_proj"] {
                guard let policy = policies[bank + projection] else { throw ProbeError("Missing Gemma expert quantization") }
                bits[projection] = policy.bits
            }
            let plan = try ExpertPartitionPlan(inputDims: hidden, intermediateDims: width,
                numExperts: experts, interval: expertIntervals[rank], activation: .geluTanh,
                fusedGateUp: false, projectionBits: bits)
            return try plan.selection(name: relative.suffix(2).joined(separator: "."), shape: shape)
        }
        return .all
    }

    /// Validate every boundary before callers replace any modules. These are
    /// RMSNorm inputs, not an instruction to reduce normalized branch outputs.
    func normalizationInputPaths(in model: Module) throws -> [String] {
        let modules = Dictionary(uniqueKeysWithValues: model.namedModules())
        for path in normalizationInputPaths {
            guard let norm = modules[path] as? RMSNorm, norm.weight.shape == [hidden] else {
                throw ProbeError("Missing Gemma pre-normalization reduction boundary: \(path)")
            }
        }
        return normalizationInputPaths
    }

    private func layerTensor(_ name: String) -> (layer: Int, relative: [String])? {
        let root = prefix + "model.layers."
        guard name.hasPrefix(root) else { return nil }
        let parts = name.dropFirst(root.count).split(separator: ".").map(String.init)
        guard let first = parts.first, let layer = Int(first), (0..<layers).contains(layer) else { return nil }
        return (layer, Array(parts.dropFirst()))
    }

    private static func intervals(width: Int) throws -> [Range<Int>] {
        guard width >= 128, width % 64 == 0 else {
            throw ProbeError("Gemma intermediate width needs at least two complete G64 groups")
        }
        let cut = (width / 64 / 2) * 64
        return [0..<cut, cut..<width]
    }

    private static func validateGeometry(_ config: Gemma4TextConfiguration, text: [String: Any]) throws {
        let positive = [config.hiddenSize, config.intermediateSize, config.numHiddenLayers,
                        config.numAttentionHeads, config.numKeyValueHeads, config.headDim,
                        config.globalHeadDim, config.maxPositionEmbeddings, config.slidingWindow]
        guard positive.allSatisfy({ (1...1_048_576).contains($0) }), config.numHiddenLayers <= 4096,
              config.hiddenSize % 64 == 0, config.numKvSharedLayers >= 0,
              config.numKvSharedLayers < config.numHiddenLayers,
              config.hiddenSizePerLayerInput >= 0, config.hiddenSizePerLayerInput <= 1_048_576,
              config.hiddenSizePerLayerInput == 0 || (config.hiddenSizePerLayerInput % 64 == 0
                && (1...1_048_576).contains(config.vocabSizePerLayerInput)),
              config.rmsNormEps.isFinite, config.rmsNormEps > 0,
              config.finalLogitSoftcapping.isFinite,
              config.numAttentionHeads % config.numKeyValueHeads == 0,
              config.layerTypes.count == config.numHiddenLayers,
              config.layerTypes.allSatisfy({ ["sliding_attention", "full_attention"].contains($0) }) else {
            throw ProbeError("Unsupported Gemma attention, PLE or KV-sharing geometry")
        }
        if let global = config.numGlobalKeyValueHeads {
            guard global > 0, global <= 1_048_576, config.numAttentionHeads % global == 0 else {
                throw ProbeError("Invalid Gemma global KV head geometry")
            }
        }
        if let types = text["layer_types"] {
            guard let types = types as? [String], types == config.layerTypes else {
                throw ProbeError("Gemma layer_types must exactly describe every layer")
            }
        }
        if let activation = text["hidden_activation"] {
            guard let activation = activation as? String, activation == "gelu_pytorch_tanh" else {
                throw ProbeError("Only Gemma's pinned tanh GELU activation is supported")
            }
        }
        if let bias = text["attention_bias"] {
            guard let value = bias as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID(), !value.boolValue else {
                throw ProbeError("Gemma attention bias is unsupported by the pinned constructor")
            }
        }
        if let dropout = text["attention_dropout"] {
            guard let value = dropout as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                  value.doubleValue == 0 else {
                throw ProbeError("Gemma attention dropout must be zero for this inference plan")
            }
        }
        if let mode = config.useBidirectionalAttention, !["none", "vision"].contains(mode) {
            throw ProbeError("Text-only Gemma partition does not support globally bidirectional attention")
        }
        if config.enableMoeBlock {
            let experts = try gemmaPlanInteger(text, "num_experts")
            let topK = try gemmaPlanInteger(text, "top_k_experts")
            guard topK <= experts else { throw ProbeError("Gemma top-k exceeds the global expert count") }
        } else if (config.numExperts ?? 0) != 0 || (config.moeIntermediateSize ?? 0) != 0 {
            throw ProbeError("Gemma expert geometry is present with its MoE block disabled")
        }
        let firstShared = config.numHiddenLayers - config.numKvSharedLayers
        let available = Set(config.layerTypes.prefix(firstShared))
        guard config.layerTypes.dropFirst(firstShared).allSatisfy({ available.contains($0) }) else {
            throw ProbeError("Gemma shared-KV layer has no preceding non-shared source of its attention type")
        }
    }

    private static func validateQuantizationCopies(root: [String: Any], text: [String: Any]?) throws {
        func canonical(_ value: Any) throws -> Data {
            guard let object = value as? [String: Any] else { throw ProbeError("Gemma quantization must be an object") }
            for (key, entry) in object where !["bits", "group_size", "mode"].contains(key) {
                // The public BaseConfiguration decoder silently ignores true
                // entries and some descriptive keys. This adapter only admits
                // explicit per-projection quantization, not ignored policies.
                guard entry is [String: Any] else {
                    throw ProbeError("Gemma quantization override must be an explicit projection policy: \(key)")
                }
            }
            return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        }
        guard let policy = root["quantization"] ?? root["quantization_config"] else {
            throw ProbeError("Missing Gemma quantization policy")
        }
        let expected = try canonical(policy)
        for object in [root, text].compactMap({ $0 }) {
            for key in ["quantization", "quantization_config"] {
                if let value = object[key], try canonical(value) != expected {
                    throw ProbeError("Conflicting Gemma quantization policies")
                }
            }
        }
    }
}

private func gemmaPlanInteger(_ object: [String: Any], _ key: String) throws -> Int {
    guard let number = object[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
          let value = object[key] as? Int, (1...1_048_576).contains(value) else {
        throw ProbeError("Gemma partition requires an explicit positive integer \(key)")
    }
    return value
}
