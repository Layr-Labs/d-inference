import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
import Foundation

/// Nemotron 3.5 Lightning's answers to the planner's questions, from its own
/// block list (`layers_block_type`) through `NemotronLayerStagePlan`. A block
/// is a Mamba2, an attention or a mixture-of-experts block; the plan cuts at
/// any block boundary that keeps an attention block on each side and sits
/// beside an expert block, so the structural cuts follow the block list, not
/// an interval. Pure metadata: no checkpoint payload and no GPU.
struct NemotronPlacementFamily: ClusterPlacementFamily {
    let definition: QwenResidentModelDefinition
    let geometry: NemotronStageGeometry
    let stateGeometry: QwenLongPrefillBudgetGeometry
    let profile: QwenLayerStageGenerationProfile
    let plans: [Int: QwenLayerStagePlan]
    let structuralCuts: [Int]

    /// Prefill cost of one block of each kind relative to an expert block,
    /// measured on real weights (Mac B, 4,096 prompt tokens in frames of 512,
    /// best of two passes: Mamba2 22.3 ms, expert 31.2 ms, attention 13.1 ms
    /// per block; `T/evidence/nemotron-20261009/block-cost`). Bytes are 92 %
    /// expert blocks and time is not, so equal cost per block would misplace
    /// the cut. A measured figure, not a property of the block list.
    static let measuredRelativeCost: [NemotronStageMetadata.BlockKind: Double] = [
        .moe: 1.0, .mamba: 22.3 / 31.2, .attention: 13.1 / 31.2,
    ]

    init(configuration: Data) throws {
        definition = try QwenResidentModelDefinition(configuration: configuration)
        guard definition.specification.model == .nemotron35Lightning,
              let root = try JSONSerialization.jsonObject(with: configuration) as? [String: Any] else {
            throw ProbeError("Not a registered Nemotron configuration")
        }
        geometry = try NemotronStageMetadata.geometry(root: root)
        stateGeometry = try NemotronRegisteredLightning.stateGeometry(geometry, kinds: geometry.kinds)
        profile = try QwenResidentAdapterDefinition.profile(specification: definition.specification)
        let cuts = NemotronStageMetadata.structuralCuts(geometry.kinds)
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
    var maximumPromptTokens: Int { ClusterPlacementPlanningLimits.prompt(profile.maximumPromptTokens) }
    var maximumOutputTokens: Int { ClusterPlacementPlanningLimits.output(profile.maximumOutputTokens) }
    var maximumChunkTokens: Int { ClusterPlacementPlanningLimits.chunk(profile.maximumChunkTokens) }
    var boundaryBytesPerToken: Int { geometry.hiddenSize * ((try? qwenStageWireElementBytes(profile.activationDType)) ?? 4) }
    /// The Qwen resident allowance charges either rank the whole model's state.
    var requestChargeEveryRankBytes: Int {
        QwenPlacementCharge.wholeModelStateBytes(geometry: stateGeometry, profile: profile)
    }
    var requestChargeEveryRankBytesPerToken: Int? {
        QwenPlacementCharge.wholeModelStateBytesPerToken(geometry: stateGeometry, profile: profile)
    }

    func stage(ofStoredTensor name: String, cut: Int) throws -> Int? {
        guard let plan = plans[cut] else { throw ProbeError("Not a cut of the Nemotron stage plan: \(cut)") }
        return try plan.parameter(canonicalSourceName: name)?.stage
    }

    func layer(ofStoredTensor name: String) -> Int? {
        let prefix = NemotronStageMetadata.layerPrefix
        guard name.hasPrefix(prefix), let first = name.dropFirst(prefix.count).split(separator: ".").first,
              let layer = Int(first), String(layer) == String(first) else { return nil }
        return layer
    }

    func layerKind(_ layer: Int) -> String { geometry.kinds[layer].rawValue }
    func layerCost(_ layer: Int) -> Double { Self.measuredRelativeCost[geometry.kinds[layer]] ?? 1 }

    /// A Mamba2 block keeps a convolution history (bfloat16) and an SSM state
    /// (float32) whatever the context; an attention block keys and values per
    /// token; an expert block nothing.
    func requestState(layer: Int) throws -> ClusterPlacementLayerState {
        let g = geometry
        switch g.kinds[layer] {
        case .mamba:
            return .init(fixedBytes: (g.convolutionKernel - 1) * g.convolutionWidth * 2
                + g.mambaHeads * g.mambaHeadDimension * g.stateSize * 4, bytesPerToken: 0)
        case .attention:
            return .init(fixedBytes: 4, bytesPerToken: 2 * g.keyValueHeads * g.headDimension * 2)
        case .moe:
            return .init(fixedBytes: 0, bytesPerToken: 0)
        }
    }

    func prefillTransient(layer: Int) -> ClusterPlacementLayerTransient {
        geometry.kinds[layer] == .attention
            ? .attention(queryHeads: geometry.attentionHeads, headDimension: geometry.headDimension) : .none
    }

    /// The stages load every stored tensor but the speculative head, and those
    /// are the registered inventory.
    func requireRegisteredInventory(_ tensors: [ClusterPlacementStoredTensor]) throws {
        let loaded = tensors.filter { !NemotronStageMetadata.excluded($0.name) }
        let specification = definition.specification
        guard loaded.count == specification.tensorCount,
              ClusterPlacementInventory.fingerprint(loaded) == specification.inventorySHA256 else {
            throw ProbeError("The artifact's tensor headers are not the registered Nemotron inventory")
        }
    }
}
