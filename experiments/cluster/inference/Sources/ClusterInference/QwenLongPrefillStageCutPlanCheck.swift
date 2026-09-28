import Foundation

/// Synthetic metadata only. The registered artifact/configuration pin is not
/// bypassed by this fixture; it calls the shared plan selector directly.
func checkQwenLongPrefillStageCutPlans(configuration: Data) throws -> (accepted: Int, rejected: Int) {
    guard var text = try JSONSerialization.jsonObject(with: configuration) as? [String: Any] else {
        throw ProbeError("Long cut plan fixture requires its synthetic object")
    }
    text["num_hidden_layers"] = 32; text["full_attention_interval"] = 4
    text["layer_types"] = (0..<32).map { ($0 + 1) % 4 == 0 ? "full_attention" : "linear_attention" }
    let source = try JSONSerialization.data(withJSONObject: text, options: [.sortedKeys])
    let original = try QwenLayerStagePlan(configuration: source, ranges: [0..<16, 16..<32])
    let omitted = try QwenLongPrefillStageCut.makePlan(configuration: source, stageCut: nil)
    guard original.fingerprint == omitted.fingerprint,
          original.stages.map(\.constructionConfiguration) == omitted.stages.map(\.constructionConfiguration) else {
        throw ProbeError("Long cut changed historical omitted-cut construction or identity")
    }
    var accepted = 1, rejected = 0
    func reject(_ label: String, _ action: () throws -> Void) throws {
        do { try action() } catch { rejected += 1; return }
        throw ProbeError("Long cut plan admitted " + label)
    }
    let cuts = [4, 8, 12, 16, 20, 24, 28]
    let leftComponents = [9, 18, 27, 36, 45, 54, 63]
    for (cut, expectedCount) in zip(cuts, leftComponents) {
        let plan = try QwenLongPrefillStageCut.makePlan(configuration: source, stageCut: cut)
        try QwenLongPrefillStageCut.validateBinding(cut, plan: plan)
        let counts = try plan.stages.map(QwenLongPrefillStageCut.componentCount)
        guard plan.originalConfiguration == source,
              plan.stages.map(\.sourceRange) == [0..<cut, cut..<32],
              plan.stages.flatMap(\.layers).map(\.globalIndex) == Array(0..<32),
              counts == [expectedCount, 72 - expectedCount],
              (plan.fingerprint == original.fingerprint) == (cut == 16) else {
            throw ProbeError("Long cut lost original source, complete ownership, or candidate identity")
        }
        for stage in plan.stages {
            guard let local = try JSONSerialization.jsonObject(with: stage.constructionConfiguration) as? [String: Any] else {
                throw ProbeError("Long cut fixture lost its compact object")
            }
            guard local["num_hidden_layers"] as? Int == stage.sourceRange.count,
                  (local["hidden_size"] as? Int) == (text["hidden_size"] as? Int),
                  stage.layers.map(\.localIndex) == Array(0..<stage.sourceRange.count) else {
                throw ProbeError("Long cut compact construction or local index mapping differs")
            }
        }
        // Complete32-layer inverse mapping, not only a tensor count assertion.
        for global in 0..<32 {
            let owner = global < cut ? 0 : 1, local = global < cut ? global : global - cut
            let mapping = try plan.parameter(canonicalSourceName: "model.layers.\(global).mlp.down_proj.weight")
            guard mapping?.stage == owner, mapping?.localName == "model.layers.\(local).mlp.down_proj.weight" else {
                throw ProbeError("Long cut assigned a parameter to the wrong compact stage")
            }
        }
        let embedding = try plan.parameter(canonicalSourceName: "model.embed_tokens.weight")
        let norm = try plan.parameter(canonicalSourceName: "model.norm.weight")
        let head = try plan.parameter(canonicalSourceName: "lm_head.weight")
        guard embedding?.stage == 0, norm?.stage == 1, head?.stage == 1 else {
            throw ProbeError("Long cut changed embedding/finalnorm/head responsibilities")
        }
        accepted += 1
    }
    let unequal = try QwenLongPrefillStageCut.makePlan(configuration: source, stageCut: 12)
    try reject("nil with unequal supplied plan") { try QwenLongPrefillStageCut.validateBinding(nil, plan: unequal) }
    try reject("explicit half with unequal supplied plan") { try QwenLongPrefillStageCut.validateBinding(16, plan: unequal) }
    try reject("explicit unequal with default supplied plan") { try QwenLongPrefillStageCut.validateBinding(12, plan: original) }
    for cut in [Int.min, -1, 0, 1, 5, 29, 32, 128, Int.max] {
        try reject("invalid range \(cut)") { _ = try QwenLongPrefillStageCut.makePlan(configuration: source, stageCut: cut) }
    }
    for (layers, interval) in [(28, 4), (32, 2)] {
        var changed = text; changed["num_hidden_layers"] = layers; changed["full_attention_interval"] = interval
        changed["layer_types"] = (0..<layers).map { ($0 + 1) % interval == 0 ? "full_attention" : "linear_attention" }
        let data = try JSONSerialization.data(withJSONObject: changed)
        try reject("foreign registered geometry") { _ = try QwenLongPrefillStageCut.makePlan(configuration: data, stageCut: 12) }
    }
    return (accepted, rejected)
}
