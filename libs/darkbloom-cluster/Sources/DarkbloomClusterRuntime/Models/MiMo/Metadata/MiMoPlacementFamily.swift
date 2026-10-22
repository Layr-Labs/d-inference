import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
import Foundation

/// MiMo's answers to the planner's questions, from its own stage plan. Each
/// layer owns its attention state and only the residual crosses a boundary,
/// so every layer boundary is a structural cut; the registered row lists the
/// ones admitted. The embedded MTP heads, the vision tower, the audio encoder
/// and the speech embeddings belong to no text stage. The private image
/// candidate alone adds the vision tower to rank 0 (the last rank of
/// `pipeline_mtp_v1` holds the heads beside its stage). Under the phase split
/// (a hand-off mode: kept, off by default) the decoding rank holds the whole
/// text model (the planner prices that with the layout's own sizes). Pure
/// metadata: no checkpoint payload and no GPU.
struct MiMoPlacementFamily: ClusterPlacementFamily {
    let imageCandidate: Bool
    let specification: MiMoRegisteredSpecification
    let profile: QwenLayerStageGenerationProfile
    let plans: [Int: MiMoLayerStagePlan]
    let layers: [MiMoLayerStagePlan.Layer]

    static func handles(configuration: Data) -> Bool {
        (try? MiMoRegisteredSpecification.specification(configuration: configuration)) != nil
    }

    init(configuration: Data,imageCandidate: Bool = false) throws {
        self.imageCandidate = imageCandidate
        specification = try MiMoRegisteredSpecification.specification(configuration: configuration)
        profile = try specification.profile(imageCandidate:imageCandidate)
        var plans: [Int: MiMoLayerStagePlan] = [:]
        for cut in 1..<specification.layers { plans[cut] = try MiMoLayerStagePlan(configuration: configuration, cut: cut,visionEnabled:imageCandidate) }
        guard let any = plans[1] else { throw ProbeError("MiMo has no cut") }
        layers = any.stages.flatMap(\.layers)
        guard layers.map(\.globalIndex) == Array(0..<specification.layers),
              layers.filter({ $0.attention == "full" }).map(\.globalIndex) == specification.fullAttentionLayers else {
            throw ProbeError("MiMo layer kinds differ from the registered row")
        }
        self.plans = plans
    }

    var runtimeModelID: String { specification.model.rawValue }
    var layerCount: Int { specification.layers }
    var admittedCuts: [Int] { specification.supportedCuts }
    var structuralCuts: [Int] { Array(1..<specification.layers) }
    var generationModes: [ClusterGenerationMode] {
        imageCandidate ? specification.supportedGenerationModes.filter { [.pipeline,.pipelineCompactDecode,.pipelineMTP].contains($0) } : specification.supportedGenerationModes
    }
    var prefillSchedules: [ClusterPrefillSchedule] { specification.supportedPrefillSchedules }
    /// Fit the full admitted prompt/output envelope, matching per-rank LOAD
    /// state. Measured request mixes may still refine performance predictions.
    var maximumPromptTokens: Int { profile.maximumPromptTokens }
    var maximumOutputTokens: Int { profile.maximumOutputTokens }
    var maximumChunkTokens: Int { ClusterPlacementPlanningLimits.chunk(profile.maximumChunkTokens) }
    var boundaryBytesPerToken: Int { specification.hidden * MiMoRequestStateBudget.activationBytes }

    func stage(ofStoredTensor name: String, cut: Int) throws -> Int? {
        if imageCandidate,name.hasPrefix("vision_tower.") { return 0 }
        guard let plan = plans[cut] else { throw ProbeError("Not a cut of the MiMo stage plan: \(cut)") }
        return try plan.parameter(sourceName: name)?.stage
    }

    /// Charge the retained unmeasured activation floor once on rank-0 ingress,
    /// beside KV and text transients, not as max(floor, KV) and not on each tensor.
    func requestWorkBytes(ofStoredTensor name: String, storedBytes: Int) -> Int {
        guard imageCandidate else { return 0 }
        if name == "language_model.model.embed_tokens.weight" { return ClusterMiMoImageCandidate.activationFloorBytes }
        if name == "language_model.model.norm.weight" { return ClusterMiMoImageCandidate.wireWorkingReserveBytes }
        return 0
    }

    static let layerPrefix = MiMoLayerStagePlan.sourceNamespace + "model.layers."

    func layer(ofStoredTensor name: String) -> Int? {
        guard name.hasPrefix(Self.layerPrefix), let first = name.dropFirst(Self.layerPrefix.count).split(separator: ".").first,
              let layer = Int(first), String(layer) == String(first) else { return nil }
        return layer
    }

    /// Attention kind and feed-forward kind: a routed layer and a dense one
    /// of the same attention cost differently.
    func layerKind(_ layer: Int) -> String { layers[layer].attention + "_" + layers[layer].feedForward }

    /// Keys and values in bfloat16: per token on a full-attention layer, the
    /// window plus one frame on a sliding one (`MiMoRequestStateBudget`).
    func requestState(layer: Int) throws -> ClusterPlacementLayerState {
        let s = specification, width = (s.keyWidth + s.valueWidth) * MiMoRequestStateBudget.activationBytes
        if layers[layer].attention == "full" {
            return .init(fixedBytes: 0, bytesPerToken: s.fullKeyValueHeads * width)
        }
        return .init(fixedBytes: s.slidingKeyValueHeads * width * (s.slidingWindow + MiMoRegisteredSpecification.maximumChunkTokens),
                     bytesPerToken: 0)
    }

    /// The family's own workspace term: one layer's float32 score matrix for a
    /// frame (64 query heads) against what it attends over, beside its output.
    func prefillTransient(layer: Int) -> ClusterPlacementLayerTransient {
        let s = specification, heads = 64
        return .init(bytesPerQuery: heads * s.valueWidth * 4, bytesPerQueryKey: heads * 4,
            keyWindow: layers[layer].attention == "full" ? nil : s.slidingWindow + MiMoRegisteredSpecification.maximumChunkTokens)
    }

    /// The artifact's three trained next-N heads: the last rank of
    /// `pipeline_mtp_v1` loads them (and a copy of the embedding) beside its stage.
    func isSpeculativeHead(storedTensor name: String) -> Bool {
        name.hasPrefix(MiMoLayerStagePlan.sourceNamespace + "model.mtp.")
    }

    /// The text tensors (every indexed tensor no stage excludes) are the
    /// registered inventory.
    func requireRegisteredInventory(_ tensors: [ClusterPlacementStoredTensor]) throws {
        if imageCandidate {
            let vision = tensors.filter { $0.name.hasPrefix("vision_tower.") }.sorted { $0.name < $1.name }
            let lines = vision.map { "visual.\($0.name.dropFirst("vision_tower.".count))|\($0.dtype)|\($0.shape)|\($0.byteCount)" }
            let bytes = try QwenLongPrefillCheckedBytes.sum(vision.map(\.byteCount))
            guard vision.count == ClusterMiMoImageCandidate.visionTensorCount,
                  vision.allSatisfy({ $0.dtype == "BF16" }), bytes == ClusterMiMoImageCandidate.visionTensorBytes,
                  vision.map(\.byteCount).max() == ClusterMiMoImageCandidate.largestVisionTensorBytes,
                  sha256(Data((specification.artifactSHA256+"|"+lines.joined(separator:"\n")).utf8)) == ClusterMiMoImageCandidate.visionStorageCommitmentSHA256 else {
                throw ProbeError("Candidate layout requires the exact pinned rank-0 vision inventory")
            }
        }
        let text = tensors.filter { name in !MiMoLayerStagePlan.excludedSourcePrefixes.contains(where: name.name.hasPrefix) }
        guard text.count == specification.tensorCount,
              ClusterPlacementInventory.fingerprint(text) == specification.inventorySHA256 else {
            throw ProbeError("The artifact's tensor headers are not the registered MiMo inventory")
        }
    }
}
