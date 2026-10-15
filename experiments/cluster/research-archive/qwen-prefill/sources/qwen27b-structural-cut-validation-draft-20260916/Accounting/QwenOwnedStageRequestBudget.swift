import Foundation

/// Prospective CPU accounting only. Not in the native overlay or any owner
/// reservation path. This keeps the existing F32 conservative terms and bounds;
/// it only substitutes the actual admitted stage's layer counts.
struct QwenOwnedStageRequestBudget {
    let rank: Int
    let attentionLayers, recurrentLayers: Int
    let stateBytes, fullModelStateBytes: Int
    let runtimeEnabled = false

    static func derive(profile: QwenRegisteredDenseModelProfile, plan: QwenLayerStagePlan,
                       rank: Int, maximumTokens: Int, chunkSize: Int,
                       bound: (Int) throws -> Int) throws -> Self {
        guard profile.model == .qwen38TwentySevenB, (0...1).contains(rank), plan.stages.count == 2,
              plan.originalConfiguration == profile.configuration,
              plan.layers == profile.geometry.layers,
              plan.interval == profile.geometry.fullAttentionInterval else {
            throw QwenDenseProfileError("Prospective accounting needs the exact registered 27B Plan")
        }
        let rebuilt = try profile.makePlanningPlan(stageCut: plan.stages[0].sourceRange.upperBound)
        guard rebuilt.fingerprint == plan.fingerprint else {
            throw QwenDenseProfileError("Prospective accounting received an unadmitted Plan")
        }
        let stage = plan.stages[rank]
        let full = try QwenDenseRegisteredResourceProfile(profile: profile)
            .namedStateBudget(maximumTokens: maximumTokens, chunkSize: chunkSize)
        let localGeometry = try QwenDenseStateBudget.geometry(profile.geometry, layers: stage.layers.count)
        let local = try QwenLongPrefillTensorBudget.estimate(geometry: localGeometry,
            maximumTokens: maximumTokens, chunkSize: chunkSize)
        guard stage.layers.map(\.globalIndex) == Array(stage.sourceRange),
              stage.layers.map(\.localIndex) == Array(0..<stage.layers.count),
              stage.layers.filter({ $0.kind == "full_attention" }).count == local.attentionLayers,
              stage.layers.filter({ $0.kind == "linear_attention" }).count == local.recurrentLayers,
              local.attentionLayers + local.recurrentLayers == stage.layers.count else {
            throw QwenDenseProfileError("Prospective local state counts do not match actual Plan ownership")
        }
        func bytes(_ b: QwenLongPrefillTensorBudget) throws -> Int {
            let sum = QwenLongPrefillCheckedBytes.sum, product = QwenLongPrefillCheckedBytes.product
            func arrays(_ count: Int, _ logical: Int) throws -> Int {
                let rounded = try bound(logical)
                guard logical > 0, rounded >= logical else {
                    throw QwenDenseProfileError("Prospective per-array bound is invalid")
                }
                return try product([count, rounded])
            }
            return try sum([
                arrays(3 * b.recurrentLayers, b.convolutionBytesPerLayer),
                arrays(3 * b.recurrentLayers, b.ssmBytesPerLayer),
                arrays(2 * b.attentionLayers, b.kvCapacityBytesPerAttentionLayer / 2),
                arrays(b.attentionLayers, 4),
                arrays(1, b.largestSingleHostStateComponentBytes),
                arrays(2, b.boundaryBytes),
            ])
        }
        let localBytes = try bytes(local), fullBytes = try bytes(full)
        guard localBytes <= fullBytes else { throw QwenDenseProfileError("Local accounting exceeds full model") }
        return .init(rank: rank, attentionLayers: local.attentionLayers,
            recurrentLayers: local.recurrentLayers, stateBytes: localBytes, fullModelStateBytes: fullBytes)
    }
}
