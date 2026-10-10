import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
import Foundation

/// The dense Qwen family's answers to the planner's questions, each read from
/// the artifact's own configuration through `QwenLayerStagePlan` and the
/// registered model's row. Pure metadata: no checkpoint payload and no GPU.
struct QwenDensePlacementFamily: ClusterPlacementFamily {
    let definition: QwenResidentModelDefinition
    let geometry: QwenLongPrefillBudgetGeometry
    let profile: QwenLayerStageGenerationProfile
    let layerPrefix: String
    /// One two-stage plan per position the plan's own rule allows.
    let plans: [Int: QwenLayerStagePlan]
    let structuralCuts: [Int]

    init(configuration: Data) throws {
        definition = try QwenResidentModelDefinition(configuration: configuration)
        guard let root = try JSONSerialization.jsonObject(with: configuration) as? [String: Any] else {
            throw ProbeError("Placement needs the artifact's configuration object")
        }
        let nested = root["text_config"] as? [String: Any]
        let text = nested ?? root
        func n(_ key: String) throws -> Int { try QwenStageMetadata.integer(text, key, limit: 1_048_576) }
        // The geometry is the artifact's own; the registered row only names the model.
        geometry = try .init(layers: n("num_hidden_layers"), fullAttentionInterval: n("full_attention_interval"),
            hiddenSize: n("hidden_size"), queryHeads: n("num_attention_heads"), kvHeads: n("num_key_value_heads"),
            headDimension: n("head_dim"), linearKeyHeads: n("linear_num_key_heads"),
            linearValueHeads: n("linear_num_value_heads"), linearKeyDimension: n("linear_key_head_dim"),
            linearValueDimension: n("linear_value_head_dim"), convolutionKernel: n("linear_conv_kernel_dim"))
        profile = try QwenResidentAdapterDefinition.profile(specification: definition.specification)
        layerPrefix = (root["model_type"] as? String == "qwen3_5" ? "language_model." : "") + "model.layers."
        let cuts = try QwenLayerStageCandidates.structuralCuts(layerCount: geometry.layers,
            fullAttentionInterval: geometry.fullAttentionInterval)
        var plans: [Int: QwenLayerStagePlan] = [:]
        for cut in cuts {
            plans[cut] = try QwenLayerStagePlan(configuration: configuration, ranges: [0..<cut, cut..<geometry.layers])
        }
        self.plans = plans; structuralCuts = cuts
    }

    var runtimeModelID: String { definition.specification.model.rawValue }
    var layerCount: Int { geometry.layers }
    var admittedCuts: [Int] { definition.supportedCuts }
    var generationModes: [ClusterGenerationMode] { definition.supportedGenerationModes }
    var prefillSchedules: [ClusterPrefillSchedule] { definition.supportedPrefillSchedules }
    var maximumPromptTokens: Int { profile.maximumPromptTokens }
    var maximumOutputTokens: Int { profile.maximumOutputTokens }
    var maximumChunkTokens: Int { profile.maximumChunkTokens }
    var boundaryBytesPerToken: Int { geometry.hiddenSize * ((try? qwenStageWireElementBytes(profile.activationDType)) ?? 4) }

    /// `QwenResidentRequestAllowance` charges the whole model's conservative
    /// state to either rank: the same named arrays, each rounded up by the
    /// allocator. The allocator's rounding is bounded here by one 16 KiB page
    /// per array.
    var requestChargeEveryRankBytes: Int {
        guard let b = try? QwenLongPrefillTensorBudget.estimate(geometry: geometry,
            maximumTokens: profile.maximumContextTokens, chunkSize: profile.maximumChunkTokens) else { return 0 }
        let arrays = 6 * b.recurrentLayers + 3 * b.attentionLayers + 3
        return 3 * b.recurrentLayers * (b.convolutionBytesPerLayer + b.ssmBytesPerLayer)
            + b.attentionLayers * (b.kvCapacityBytesPerAttentionLayer + 4)
            + b.largestSingleHostStateComponentBytes + 2 * b.boundaryBytes + arrays * 16_384
    }

    func stage(ofStoredTensor name: String, cut: Int) throws -> Int? {
        guard let plan = plans[cut] else { throw ProbeError("Not a cut of the dense Qwen stage plan: \(cut)") }
        return try plan.parameter(canonicalSourceName: name)?.stage
    }

    func layer(ofStoredTensor name: String) -> Int? {
        guard name.hasPrefix(layerPrefix),
              let first = name.dropFirst(layerPrefix.count).split(separator: ".").first,
              let layer = Int(first), String(layer) == String(first) else { return nil }
        return layer
    }

    func layerKind(_ layer: Int) -> String {
        (layer + 1) % geometry.fullAttentionInterval == 0 ? "full_attention" : "linear_attention"
    }

    /// The logical request state of one layer, as `QwenDenseStateBudget.finalState`
    /// shapes it: keys and values per token for a full-attention layer, a
    /// convolution window and a recurrent matrix for a linear one.
    func requestState(layer: Int) throws -> ClusterPlacementLayerState {
        let g = geometry
        if (layer + 1) % g.fullAttentionInterval == 0 {
            return .init(fixedBytes: 4, bytesPerToken: 2 * g.kvHeads * g.headDimension * 2)
        }
        let channels = 2 * g.linearKeyHeads * g.linearKeyDimension + g.linearValueHeads * g.linearValueDimension
        return .init(fixedBytes: (g.convolutionKernel - 1) * channels * 2
            + g.linearValueHeads * g.linearValueDimension * g.linearKeyDimension * 4, bytesPerToken: 0)
    }

    /// The projections a linear-attention layer fuses at request time exist
    /// beside their fused bank while it is built; the request gate allows for both.
    func requestWorkBytes(ofStoredTensor name: String, storedBytes: Int) -> Int {
        let parts = name.split(separator: ".")
        guard parts.count >= 2, parts.contains("linear_attn"),
              ["in_proj_qkv", "in_proj_z", "in_proj_b", "in_proj_a"].contains(String(parts[parts.count - 2])) else { return 0 }
        return storedBytes
    }
}

/// Layouts of the families this build places. One case per family; a family
/// adds its own beside the dense Qwen one.
public enum ClusterPlacementLayouts {
    /// The layout of the artifact these headers and this configuration belong
    /// to. `tensors` are every stored tensor of the artifact, as its
    /// safetensors headers name them. For a registered dense Qwen model the
    /// tensors its stages load must be exactly the registered inventory.
    public static func layout(configuration: Data, tensors: [ClusterPlacementStoredTensor]) throws -> ClusterModelLayout {
        let family = try QwenDensePlacementFamily(configuration: configuration)
        let specification = family.definition.specification
        guard let anyCut = family.structuralCuts.first else { throw ProbeError("The model has no cut") }
        let loaded = try tensors.filter { try family.stage(ofStoredTensor: $0.name, cut: anyCut) != nil }
            .map { QwenDenseCanonicalTensor(name: $0.name, shape: $0.shape, sourceDType: $0.dtype, byteCount: $0.byteCount) }
            .sorted { $0.name < $1.name }
        guard loaded.count == specification.tensorCount,
              QwenDenseProfileIdentity.fingerprint(loaded.map(\.identity)) == specification.inventorySHA256 else {
            throw ProbeError("The artifact's tensor headers are not the registered model's inventory")
        }
        return try ClusterModelLayoutBuilder.build(family: family, tensors: tensors,
            artifactSHA256: specification.artifactSHA256, configurationSHA256: specification.configurationSHA256)
    }
}
