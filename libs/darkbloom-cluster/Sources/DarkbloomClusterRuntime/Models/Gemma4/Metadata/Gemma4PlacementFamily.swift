import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
import Foundation

/// Gemma 4's answers to the planner's questions, from its own stage planning.
/// A stage keeps each layer's index in the whole model, so its layer kinds
/// never depend on where it starts and every layer boundary is a structural
/// cut; the resident row lists the cuts a pair is admitted at. The tied
/// embedding is held at both ends: the first range looks tokens up in it and
/// the last uses it as the output projection. Pure metadata: no checkpoint
/// payload and no GPU.
struct Gemma4PlacementFamily: ClusterPlacementFamily {
    let specification: Gemma4RegisteredSpecification
    let profile: QwenLayerStageGenerationProfile

    /// The row a manifest names, or, without one, the first row of this
    /// configuration: the two 8-bit catalog entries are one artifact (one
    /// configuration, aggregate and inventory) and lay out identically.
    init(configuration: Data, manifest: Data?) throws {
        if let manifest {
            specification = try Gemma4RegisteredSpecification.registered(configuration: configuration, manifest: manifest)
        } else {
            let digest = sha256(configuration)
            guard let row = Gemma4RegisteredSpecification.all.first(where: { $0.configurationSHA256 == digest }) else {
                throw ProbeError("Not a registered Gemma 4 configuration")
            }
            specification = row
        }
        _ = try Gemma4StageGeometry.decode(configuration, defaultQuantizationBits: specification.defaultQuantizationBits)
        profile = try Gemma4ResidentAdapterDefinition.profile(specification: specification)
    }

    var runtimeModelID: String { specification.model.rawValue }
    var layerCount: Int { Gemma4StageGeometry.layerCount }
    var admittedCuts: [Int] { Gemma4ResidentAdapterDefinition.supportedCuts }
    var structuralCuts: [Int] { Array(1..<Gemma4StageGeometry.layerCount) }
    var generationModes: [ClusterGenerationMode] { Gemma4ResidentAdapterDefinition.supportedGenerationModes }
    var prefillSchedules: [ClusterPrefillSchedule] { Gemma4ResidentAdapterDefinition.supportedPrefillSchedules }
    var maximumPromptTokens: Int { ClusterPlacementPlanningLimits.prompt(profile.maximumPromptTokens) }
    var maximumOutputTokens: Int { ClusterPlacementPlanningLimits.output(profile.maximumOutputTokens) }
    var maximumChunkTokens: Int { ClusterPlacementPlanningLimits.chunk(profile.maximumChunkTokens) }
    var boundaryBytesPerToken: Int { Gemma4StageGeometry.hiddenSize * 2 }

    /// Either rank is charged the whole model's state (`Gemma4StateBudget`).
    /// At the planned request's context (`ClusterPlacementPlanningLimits`).
    var requestChargeEveryRankBytes: Int { charge(ClusterPlacementPlanningLimits.context(profile.maximumContextTokens)) }
    var requestChargeEveryRankBytesPerToken: Int? {
        let high = ClusterPlacementPlanningLimits.context(profile.maximumContextTokens), low = max(maximumChunkTokens + 1, high / 2)
        return high > low ? max(0, (charge(high) - charge(low)) / (high - low)) : nil
    }
    private func charge(_ tokens: Int) -> Int {
        (try? Gemma4StateBudget.estimate(maximumTokens: tokens, chunkSize: maximumChunkTokens).stateAndBoundaryBytes) ?? 0
    }

    static let textPrefix = Gemma4LayerStagePlanning.namespace
    static let layerPrefix = Gemma4LayerStagePlanning.namespace + "model.layers."

    /// The stage `Gemma4LayerStagePlanning` gives a text tensor at this cut:
    /// the module that owns it (or the parameter itself, for the few direct
    /// parameters) as one stage names it. Nil for the vision tower.
    func stage(ofStoredTensor name: String, cut: Int) throws -> Int? {
        guard name.hasPrefix(Self.textPrefix) else { return nil }
        guard structuralCuts.contains(cut) else { throw ProbeError("Not a cut of the Gemma 4 stage plan: \(cut)") }
        if loadsAtBothEnds(storedTensor: name) { return 0 }
        let pieces = name.split(separator: ".", omittingEmptySubsequences: false)
        let module = pieces.dropLast().joined(separator: ".")
        var owners: [Int] = []
        for (index, range) in [0..<cut, cut..<layerCount].enumerated() {
            if Gemma4LayerStagePlanning.localModule(module, range: range, stage: index) != nil
                || Gemma4LayerStagePlanning.localModule(name, range: range, stage: index) != nil { owners.append(index) }
        }
        guard owners.count == 1 else { throw ProbeError("Gemma tensor has no single owning stage: \(name)") }
        return owners[0]
    }

    func loadsAtBothEnds(storedTensor name: String) -> Bool {
        name.hasPrefix(Gemma4LayerStagePlanning.embeddingModule + ".")
    }

    func layer(ofStoredTensor name: String) -> Int? {
        guard name.hasPrefix(Self.layerPrefix), let first = name.dropFirst(Self.layerPrefix.count).split(separator: ".").first,
              let layer = Int(first), String(layer) == String(first) else { return nil }
        return layer
    }

    func layerKind(_ layer: Int) -> String { Gemma4StageGeometry.kind(globalLayerIndex: layer) }

    /// Keys and values in bfloat16: per token on a full-attention layer; on a
    /// sliding layer a ring of the window, allocated whole, and the view one
    /// frame attends over (`Gemma4StateBudget`).
    func requestState(layer: Int) throws -> ClusterPlacementLayerState {
        typealias G = Gemma4StageGeometry
        if G.isFullAttention(globalLayerIndex: layer) {
            return .init(fixedBytes: 4, bytesPerToken: 2 * G.fullKVHeads * G.fullHeadDimension * 2)
        }
        let row = G.slidingKVHeads * G.slidingHeadDimension * 2
        return .init(fixedBytes: 4 + 2 * G.slidingWindow * row + 2 * (G.slidingWindow - 1 + maximumChunkTokens) * row,
                     bytesPerToken: 0)
    }

    /// Head dimensions 256 and 512 take MLX's unfused path: float32 scores
    /// over the whole history on a full layer, over the window on a sliding one.
    func prefillTransient(layer: Int) -> ClusterPlacementLayerTransient {
        typealias G = Gemma4StageGeometry
        return G.isFullAttention(globalLayerIndex: layer)
            ? .attention(queryHeads: G.queryHeads, headDimension: G.fullHeadDimension)
            : .attention(queryHeads: G.queryHeads, headDimension: G.slidingHeadDimension,
                         keyWindow: G.slidingWindow - 1 + maximumChunkTokens)
    }

    /// The text tensors are the registered inventory, in name, dtype, shape and bytes.
    func requireRegisteredInventory(_ tensors: [ClusterPlacementStoredTensor]) throws {
        let text = tensors.filter { $0.name.hasPrefix(Self.textPrefix) }
        guard text.count == specification.tensorCount,
              ClusterPlacementInventory.fingerprint(text) == specification.inventorySHA256 else {
            throw ProbeError("The artifact's tensor headers are not the registered Gemma 4 inventory")
        }
    }
}
