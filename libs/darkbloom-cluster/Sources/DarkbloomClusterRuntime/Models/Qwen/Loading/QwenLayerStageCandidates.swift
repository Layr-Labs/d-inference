import Foundation

/// Metadata candidates only. No model constructor, descriptor/payload read,
/// device assignment, execution admission, runtime estimate or ranking.
enum QwenLayerStageCandidates {
    enum ComputeCostStatus: String { case unknown }
    enum StateComponent: String, Equatable {
        case convolution = "conv", ssm
        case keys = "kv.keys", values = "kv.values", offsets = "kv.position_offsets"
    }
    struct StateOwnership {
        /// The existing plan owns the exact global/local index and layer kind.
        let layer: QwenLayerStagePlan.Layer
        let components: [StateComponent]
    }
    struct StageOwnership {
        let stageIndex: Int
        let parameters: [QwenLayerStagePlan.Parameter]
        let state: [StateOwnership]
        let computeCostStatus = ComputeCostStatus.unknown
    }
    struct Candidate {
        let cut: Int
        let plan: QwenLayerStagePlan
        let ownership: [StageOwnership]
        let excludedCanonicalSourceNames: [String]
        let computeCostStatus = ComputeCostStatus.unknown
    }

    /// Structural positions only. A returned cut does not admit a configuration.
    /// Preserve Plan's rules: each range has at least one complete interval and
    /// both starts retain the interval phase. The last end need NOT be aligned.
    static func structuralCuts(layerCount: Int, fullAttentionInterval: Int) throws -> [Int] {
        guard (1...128).contains(layerCount), (2...128).contains(fullAttentionInterval) else {
            throw ProbeError("Candidate cuts require bounded layer count and attention interval")
        }
        let lastCut = layerCount - fullAttentionInterval
        guard lastCut >= fullAttentionInterval else { return [] }
        return Array(stride(from: fullAttentionInterval, through: lastCut, by: fullAttentionInterval))
    }

    /// Callers supply already-canonical names. Existing Plan validation remains
    /// authoritative for metadata, wrappers, exclusions and quantization paths.
    /// One error rejects this call; invalid candidates are never silently skipped.
    /// Name coverage does not prove tensor shapes/dtypes/triplets, stored bytes,
    /// loaded compact buffers, state byte sizes or model semantic compatibility.
    static func enumerate(configuration: Data, canonicalSourceNames: [String],
                          activeMTP: Bool = false) throws -> [Candidate] {
        guard !activeMTP, configuration.count <= 1_048_576,
              let root = try JSONSerialization.jsonObject(with: configuration) as? [String: Any] else {
            throw ProbeError("Candidate enumeration requires bounded configuration and inactive MTP")
        }
        let text: [String: Any]
        if let nested = root["text_config"] {
            guard let object = nested as? [String: Any] else {
                throw ProbeError("Candidate text_config must retain an object")
            }
            text = object
        } else { text = root }
        let layers = try QwenStageMetadata.integer(text, "num_hidden_layers", limit: 128)
        let interval = try QwenStageMetadata.integer(text, "full_attention_interval", limit: 128)
        let cuts = try structuralCuts(layerCount: layers, fullAttentionInterval: interval)
        guard !cuts.isEmpty else {
            throw ProbeError("Configuration has no two-stage interval-phase cut")
        }
        return try cuts.map { cut in
            let plan = try QwenLayerStagePlan(configuration: configuration,
                ranges: [0..<cut, cut..<layers], activeMTP: activeMTP)
            let parameters = try plan.parameters(canonicalSourceNames: canonicalSourceNames)
            let retainedNames = Set(parameters.map(\.sourceName))
            let ownership = try plan.stages.map { stage in
                let state = try stage.layers.map { layer -> StateOwnership in
                    let components: [StateComponent]
                    switch layer.kind {
                    case "linear_attention": components = [.convolution, .ssm]
                    case "full_attention": components = [.keys, .values, .offsets]
                    default: throw ProbeError("Candidate state ownership has an unsupported layer kind")
                    }
                    return StateOwnership(layer: layer, components: components)
                }
                return StageOwnership(stageIndex: stage.index,
                    parameters: parameters.filter { $0.stage == stage.index }, state: state)
            }
            return Candidate(cut: cut, plan: plan, ownership: ownership,
                excludedCanonicalSourceNames: canonicalSourceNames.filter { !retainedNames.contains($0) }.sorted())
        }
    }
}
