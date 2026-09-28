import Foundation

func checkCandidateRejections() throws -> [String] {
    let fixture = CandidateFixture(layers: 12, form: .nestedWrapper)
    let original = try candidateJSON(fixture.object)
    var passed: [String] = []
    func reject(_ label: String, _ body: () throws -> Void) throws {
        do { try body() } catch { passed.append(label); return }
        throw ProbeError("Candidate metadata accepted invalid fixture: " + label)
    }
    for (label, names) in [
        ("missing required norm", fixture.canonicalNames.filter { $0 != "language_model.model.norm.weight" }),
        ("duplicate source tensor", fixture.canonicalNames + [fixture.canonicalNames[0]]),
        ("unknown source tensor", fixture.canonicalNames + ["language_model.model.layers.0.mlp.unknown.weight"]),
        ("wrong layer kind tensor", fixture.canonicalNames + ["language_model.model.layers.3.linear_attn.A_log"]),
        ("noncanonical layer index", fixture.canonicalNames + ["language_model.model.layers.00.mlp.up_proj.weight"]),
    ] {
        try reject(label) { _ = try QwenLayerStageCandidates.enumerate(configuration: original, canonicalSourceNames: names) }
    }
    for (label, key, value) in [
        ("tied embeddings", "tie_word_embeddings", true as Any),
        ("MoE policy", "num_experts", 8),
        ("Boolean layer count", "num_hidden_layers", false),
        ("fractional layer count", "num_hidden_layers", 12.5),
        ("no supported attention interval", "full_attention_interval", 1),
        ("contradictory layer policy", "layer_types", Array(repeating: "full_attention", count: 12)),
    ] {
        try reject(label) { _ = try QwenLayerStageCandidates.enumerate(
            configuration: fixture.changingText(key, to: value), canonicalSourceNames: fixture.canonicalNames) }
    }
    let short = CandidateFixture(layers: 7, form: .text)
    try reject("no legal two-stage cut") { _ = try QwenLayerStageCandidates.enumerate(
        configuration: candidateJSON(short.object), canonicalSourceNames: short.canonicalNames) }
    try reject("active MTP") { _ = try QwenLayerStageCandidates.enumerate(
        configuration: original, canonicalSourceNames: fixture.canonicalNames, activeMTP: true) }
    var conflicting = fixture.object
    conflicting["quantization_config"] = ["bits": 8, "group_size": 64]
    try reject("conflicting quantization aliases") { _ = try QwenLayerStageCandidates.enumerate(
        configuration: candidateJSON(conflicting), canonicalSourceNames: fixture.canonicalNames) }
    var alias = fixture.object, policy = fixture.object["quantization"] as! [String: Any]
    policy["model.layers.8.mlp.down_proj"] = false
    alias["quantization"] = policy; alias["quantization_config"] = policy
    try reject("wrong namespace quantization override") { _ = try QwenLayerStageCandidates.enumerate(
        configuration: candidateJSON(alias), canonicalSourceNames: fixture.canonicalNames) }
    try reject("malformed nested wrapper") { _ = try QwenLayerStageCandidates.enumerate(
        configuration: candidateJSON(["model_type": "qwen3_5", "text_config": [1, 2]]), canonicalSourceNames: fixture.canonicalNames) }
    try reject("oversized configuration") { _ = try QwenLayerStageCandidates.enumerate(
        configuration: Data(repeating: 32, count: 1_048_577), canonicalSourceNames: fixture.canonicalNames) }
    for (layers, interval) in [(0, 4), (129, 4), (8, 0), (8, 129)] {
        try reject("structural bounds \(layers)/\(interval)") {
            _ = try QwenLayerStageCandidates.structuralCuts(layerCount: layers, fullAttentionInterval: interval)
        }
    }
    return passed
}
