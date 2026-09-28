import Foundation

/// Registered32-layer plan selection only. Request/profile geometry, artifact
/// admission and native execution remain separate existing responsibilities.
enum QwenLongPrefillStageCut {
    static func resolved(_ selected: Int?) throws -> Int {
        let cut = selected ?? 16
        let legal = try QwenLayerStageCandidates.structuralCuts(layerCount: 32, fullAttentionInterval: 4)
        guard legal.contains(cut) else {
            throw ProbeError("Registered long stage cut must be one of 4, 8, 12, 16, 20, 24 or 28")
        }
        return cut
    }

    static func makePlan(configuration: Data, stageCut: Int?) throws -> QwenLayerStagePlan {
        let cut = try resolved(stageCut)
        let plan = try QwenLayerStagePlan(configuration: configuration, ranges: [0..<cut, cut..<32])
        try validateBinding(stageCut, plan: plan)
        return plan
    }

    /// Nil is an explicit promise of historical16/16, including direct callers
    /// carrying a previously admitted plan. This must run before model/group IO.
    static func validateBinding(_ stageCut: Int?, plan: QwenLayerStagePlan) throws {
        let cut = try resolved(stageCut)
        guard plan.layers == 32, plan.interval == 4,
              plan.stages.map(\.sourceRange) == [0..<cut, cut..<32] else {
            throw ProbeError("Selected long stage cut differs from the admitted registered plan")
        }
    }

    /// Counts support an additional assertion after the state initializer has
    /// derived every exact component key/shape/dtype from these admitted layers.
    /// This count never substitutes for complete set and local/global equality.
    static func componentCount(_ stage: QwenLayerStagePlan.Stage) throws -> Int {
        let counts = try stage.layers.map { layer -> Int in
            switch layer.kind {
            case "full_attention": return 3
            case "linear_attention": return 2
            default: throw ProbeError("Long stage has an unsupported state layer kind")
            }
        }
        return try QwenLongPrefillCheckedBytes.sum(counts)
    }
}
