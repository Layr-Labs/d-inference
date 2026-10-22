import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
import Foundation

/// GPT-OSS's answers to the planner's questions, from its own stage plan.
/// The product class builds each layer's attention from that layer's own
/// `layer_types` entry, so every layer boundary is a structural cut; the
/// registered row lists the ones a pair has been admitted at. Pure metadata:
/// no checkpoint payload and no GPU.
struct GPTOSSPlacementFamily: ClusterPlacementFamily {
    let specification: GPTOSSRegisteredSpecification
    let profile: QwenLayerStageGenerationProfile
    let layerTypes: [String]
    let plans: [Int: GPTOSSLayerStagePlan]

    init(configuration: Data) throws {
        specification = try GPTOSSRegisteredSpecification.specification(configuration: configuration)
        profile = try specification.profile()
        var plans: [Int: GPTOSSLayerStagePlan] = [:]
        for cut in 1..<specification.layers { plans[cut] = try GPTOSSLayerStagePlan(configuration: configuration, cut: cut) }
        guard let any = plans[1] else { throw ProbeError("GPT-OSS has no cut") }
        layerTypes = any.layerTypes; self.plans = plans
    }

    var runtimeModelID: String { specification.model.rawValue }
    var layerCount: Int { specification.layers }
    var admittedCuts: [Int] { specification.supportedCuts }
    var structuralCuts: [Int] { Array(1..<specification.layers) }
    var generationModes: [ClusterGenerationMode] { specification.supportedGenerationModes }
    var prefillSchedules: [ClusterPrefillSchedule] { specification.supportedPrefillSchedules }
    var maximumPromptTokens: Int { ClusterPlacementPlanningLimits.prompt(profile.maximumPromptTokens) }
    var maximumOutputTokens: Int { ClusterPlacementPlanningLimits.output(profile.maximumOutputTokens) }
    var maximumChunkTokens: Int { ClusterPlacementPlanningLimits.chunk(profile.maximumChunkTokens) }
    /// The residual crosses a cut in float32 (`GPTOSSRegisteredSpecification.residualDType`).
    var boundaryBytesPerToken: Int { specification.hidden * GPTOSSRequestStateBudget.activationBytes }

    func stage(ofStoredTensor name: String, cut: Int) throws -> Int? {
        guard let plan = plans[cut] else { throw ProbeError("Not a cut of the GPT-OSS stage plan: \(cut)") }
        return try plan.parameter(sourceName: name).stage
    }

    func layer(ofStoredTensor name: String) -> Int? {
        let prefix = GPTOSSLayerStagePlan.layerPrefix
        guard name.hasPrefix(prefix), let first = name.dropFirst(prefix.count).split(separator: ".").first,
              let layer = Int(first), String(layer) == String(first) else { return nil }
        return layer
    }

    func layerKind(_ layer: Int) -> String { layerTypes[layer] }

    private func isFull(_ layer: Int) -> Bool { layerTypes[layer] == GPTOSSRegisteredSpecification.fullAttention }

    /// Keys and values in float32: per token on a full-attention layer, a
    /// window of `slidingWindow` positions plus one frame on a sliding one
    /// (`GPTOSSRequestStateBudget`).
    func requestState(layer: Int) throws -> ClusterPlacementLayerState {
        let s = specification, row = 2 * s.keyValueHeads * s.headDimension * GPTOSSRequestStateBudget.activationBytes
        return isFull(layer) ? .init(fixedBytes: 0, bytesPerToken: row)
            : .init(fixedBytes: (s.slidingWindow + GPTOSSRegisteredSpecification.maximumChunkTokens) * row, bytesPerToken: 0)
    }

    /// The family's own workspace term: one layer's float32 score matrix for
    /// a frame against what it attends over (the whole history, or the
    /// window), beside its output.
    func prefillTransient(layer: Int) -> ClusterPlacementLayerTransient {
        let s = specification
        return .init(bytesPerQuery: s.queryHeads * s.headDimension * 4, bytesPerQueryKey: s.queryHeads * 4,
            keyWindow: isFull(layer) ? nil : s.slidingWindow + GPTOSSRegisteredSpecification.maximumChunkTokens)
    }

    /// Every stored tensor is in the closed inventory the registered geometry
    /// reproduces, with the same dtype, shape and bytes.
    func requireRegisteredInventory(_ tensors: [ClusterPlacementStoredTensor]) throws {
        let expected = GPTOSSStageMetadata.tensors(specification: specification).map(\.identity).sorted()
        let actual = tensors.map { $0.name + "|" + $0.dtype + "|" + $0.shape.map(String.init).joined(separator: ",")
            + "|" + String($0.byteCount) }.sorted()
        guard actual == expected else {
            throw ProbeError("The artifact's tensor headers are not the registered GPT-OSS inventory")
        }
    }
}
