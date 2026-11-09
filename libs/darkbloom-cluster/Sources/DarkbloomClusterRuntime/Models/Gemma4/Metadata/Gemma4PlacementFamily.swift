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
    /// The memory plan's request (`Gemma4ResidentAdapterDefinition.memoryProfile`),
    /// which the planner, every quote and every LOAD gate size the pair for;
    /// the capability advertises the native context, and a longer request is
    /// charged at its own context when a rank reserves it.
    let profile: QwenLayerStageGenerationProfile
    /// The tensor-parallel plan (`Gemma4TensorParallelPlan`, two ranks by
    /// heads and expert channels) when the resident row lists the mode.
    let tensorParallel: Gemma4TensorParallelPlan?
    /// The native request reservation of a tensor-parallel rank
    /// (`Gemma4TensorParallelRequestBudget`), set where the allocator's bound
    /// is known (`ClusterPlacementLayouts.layout`); nil in metadata-only layouts.
    var tensorParallelRequestAllowance: ClusterTensorParallelRequestAllowance?

    /// The row a manifest names, or, without one, the first row of this
    /// configuration: the two 8-bit catalog entries are one artifact (one
    /// configuration, aggregate and inventory) and lay out identically.
    init(configuration: Data, manifest: Data?) throws {
        let specification: Gemma4RegisteredSpecification
        if let manifest {
            specification = try Gemma4RegisteredSpecification.registered(configuration: configuration, manifest: manifest)
        } else {
            let digest = sha256(configuration)
            guard let row = Gemma4RegisteredSpecification.all.first(where: { $0.configurationSHA256 == digest }) else {
                throw ProbeError("Not a registered Gemma 4 configuration")
            }
            specification = row
        }
        try self.init(specification: specification,
            decoded: Gemma4StageGeometry.decode(configuration, defaultQuantizationBits: specification.defaultQuantizationBits))
    }

    /// The row's family over a configuration already held to its geometry.
    init(specification: Gemma4RegisteredSpecification, decoded: Gemma4StageGeometry.Decoded) throws {
        self.specification = specification
        profile = try Gemma4ResidentAdapterDefinition.memoryProfile(specification: specification)
        tensorParallel = Gemma4ResidentAdapterDefinition.supportedGenerationModes.contains(.tensorParallel)
            ? try Gemma4TensorParallelPlan(configuration: decoded.root) : nil
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

    /// A decode step reads 8 of every layer's 128 expert banks; the router and
    /// the dense MLP beside them are read whole.
    var expertRouting: ClusterExpertRouting? {
        ClusterExpertRouting(selected: Gemma4StageGeometry.expertsPerToken, experts: Gemma4StageGeometry.routedExperts)
    }

    func isRoutedExpert(storedTensor name: String) -> Bool {
        layer(ofStoredTensor: name) != nil && name.contains(".experts.switch_glu.")
    }

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

    // MARK: - Tensor parallel

    /// `Gemma4TensorParallelResidentRuntime`'s plan: each layer sums its
    /// attention partial and one packed feed-forward collective (the dense
    /// row and the 8 selected experts' rows, FP32), and each step the
    /// vocabulary-split selection once. Each rank keeps its own KV heads.
    /// Equal shares only (overlapping zero-padded channel splits). Chosen
    /// only where predicted faster than the pipeline
    /// (`ClusterTensorParallelChoice.fastest`): on big Macs one Gemma step is
    /// mostly a per-token floor that two ranks do not halve, while 61 sums
    /// cross the link (`docs/architecture/inference.md`).
    var tensorParallelPlan: ClusterTensorParallelFamilyPlan? {
        tensorParallel.map { plan in
            ClusterTensorParallelFamilyPlan(plan: Gemma4TensorParallelPlan.name, ranks: [plan.size],
                reductionsPerLayer: plan.reductionsPerLayer, reductionsPerStep: plan.reductionsPerStep,
                partialBytesPerToken: plan.feedForwardPartialBytesPerToken,
                layerPartialBytesPerToken: plan.layerPartialBytesPerToken, stateDividesByHeads: true,
                requestAllowance: tensorParallelRequestAllowance, choice: .fastest)
        }
    }

    /// The plan's cut (the same on both ranks): replicated, or rows, input
    /// columns or expert channels divided. The tied embedding is listed at
    /// both ends of the layout (the lookup and the head); a rank holds it
    /// once, whole, and its head reads its own half of the vocabulary rows,
    /// so each end counts as divided: two halves are the one copy a rank holds.
    func tensorParallelCut(ofStoredTensor name: String) -> ClusterTensorParallelTensorCut? {
        guard let plan = tensorParallel else { return nil }
        if loadsAtBothEnds(storedTensor: name) { return .divided }
        guard let cut = try? plan.cut(key: name, rank: 0) else { return nil }
        return cut == .replicate ? .replicated : .divided
    }

    /// Both ranks store the down projection's middle quantization group and
    /// pad their gate and up rows with the other rank's half of it as zeros
    /// (`Gemma4TensorParallelPlan.ChannelSplit`): a rank's share of such a
    /// tensor is more than half, by these bytes.
    func tensorParallelOverlapBytes(of tensor: ClusterPlacementStoredTensor, loadedBytes: Int) -> Int {
        guard let plan = tensorParallel, layer(ofStoredTensor: tensor.name) != nil,
              let cut = try? plan.cut(key: tensor.name, rank: 0),
              let local = try? plan.localShape(key: tensor.name, shape: tensor.shape, cut: cut) else { return 0 }
        let elements = tensor.shape.reduce(1, *), held = local.reduce(1, *)
        guard elements > 0, tensor.byteCount % elements == 0, loadedBytes == tensor.byteCount else { return 0 }
        return max(0, 2 * held * (tensor.byteCount / elements) - tensor.byteCount)
    }
}
