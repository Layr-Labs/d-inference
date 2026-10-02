import Foundation

/// Prospective pure-source fixture; caller supplies the retained registered 9B
/// configuration and its 927 canonical descriptor names, without payload data.
/// These checks exercise enumeration/ownership, not existing metadata-policy tests.
func checkQwenLayerStageCandidates(configuration: Data, canonicalSourceNames: [String]) throws {
    func require(_ value: Bool, _ message: String) throws {
        guard value else { throw ProbeError("Candidate fixture: " + message) }
    }
    func reject(_ body: () throws -> Void) throws {
        do { try body() } catch { return }
        throw ProbeError("Candidate fixture accepted a negative case")
    }
    let examples: [(Int, Int, [Int])] = [
        (7, 4, []), (8, 4, [4]), (9, 4, [4]), (10, 4, [4]),
        (12, 4, [4, 8]), (15, 4, [4, 8]),
        (32, 4, [4, 8, 12, 16, 20, 24, 28]),
        (64, 4, [4, 8, 12, 16, 20, 24, 28, 32, 36, 40, 44, 48, 52, 56, 60]),
        (128, 64, [64]), (128, 128, []),
    ]
    for (layers, interval, expected) in examples {
        try require(try QwenLayerStageCandidates.structuralCuts(layerCount: layers,
            fullAttentionInterval: interval) == expected, "structural cut positions differ")
    }
    for (layers, interval) in [(0, 4), (129, 4), (8, 0), (8, 1), (8, 129)] {
        try reject { _ = try QwenLayerStageCandidates.structuralCuts(layerCount: layers,
            fullAttentionInterval: interval) }
    }
    let candidates = try QwenLayerStageCandidates.enumerate(configuration: configuration,
        canonicalSourceNames: canonicalSourceNames)
    try require(canonicalSourceNames.count == 927 && candidates.map(\.cut) == examples[6].2,
        "caller fixture must retain registered 32-layer/interval-4 canonical names")
    let originalNames = Set(canonicalSourceNames)
    for candidate in candidates {
        let cycle = candidate.cut / 4
        let owners = candidate.ownership
        try require(candidate.plan.layers == 32 && candidate.plan.interval == 4
            && candidate.plan.originalConfiguration == configuration
            && candidate.computeCostStatus == .unknown && owners.count == 2,
            "candidate changed original identity or introduced a compute estimate")
        try require(owners.map(\.stageIndex) == [0, 1]
            && owners.map { $0.parameters.count } == [115 * cycle + 3, 115 * (8 - cycle) + 4]
            && owners.map { $0.state.flatMap(\.components).count } == [9 * cycle, 9 * (8 - cycle)],
            "affine tensor/component ownership counts differ")
        let parameters = owners.flatMap(\.parameters)
        try require(parameters.count == 927 && Set(parameters.map(\.sourceName)) == originalNames
            && Set(parameters.map { "\($0.stage):\($0.localName)" }).count == parameters.count
            && candidate.excludedCanonicalSourceNames.isEmpty, "source ownership is not complete and disjoint")
        for owner in owners {
            let start = owner.stageIndex == 0 ? 0 : candidate.cut
            let end = owner.stageIndex == 0 ? candidate.cut : 32
            try require(owner.computeCostStatus == .unknown
                && owner.state.map { $0.layer.globalIndex } == Array(start..<end)
                && owner.state.map { $0.layer.localIndex } == Array(0..<(end - start)),
                "state global/local ownership differs")
            for entry in owner.state {
                let attention = (entry.layer.globalIndex + 1) % 4 == 0
                let expected: [QwenLayerStageCandidates.StateComponent] = attention
                    ? [.keys, .values, .offsets] : [.convolution, .ssm]
                try require(entry.components == expected
                    && attention == ((entry.layer.localIndex + 1) % 4 == 0), "state interval phase changed")
            }
        }
    }
    // Reuse the supplied geometry/default quantization, retaining the exact
    // metadata keys. The 10-layer fixture proves there is no end-alignment or
    // blind-halving requirement: its sole valid split is 4+6, not 5+5.
    var root = try JSONSerialization.jsonObject(with: configuration) as! [String: Any]
    var text = root["text_config"] as! [String: Any]
    text["num_hidden_layers"] = 10
    text["layer_types"] = (0..<10).map { ($0 + 1) % 4 == 0 ? "full_attention" : "linear_attention" }
    root["text_config"] = text
    let ten = try QwenStageMetadata.json(root)
    let prefix = "language_model.model.layers."
    let tenNames = canonicalSourceNames.filter { name in
        guard name.hasPrefix(prefix) else { return true }
        let index = Int(name.dropFirst(prefix.count).split(separator: ".")[0])!
        return index < 10
    }
    let partialEnd = try QwenLayerStageCandidates.enumerate(configuration: ten, canonicalSourceNames: tenNames)
    try require(partialEnd.map(\.cut) == [4]
        && partialEnd[0].ownership.map { $0.state.count } == [4, 6], "unaligned final end was rejected")
    let excluded = ["mtp.layers.0.weight", "vision_tower.unused.weight"]
    let withExclusions = try QwenLayerStageCandidates.enumerate(configuration: ten,
        canonicalSourceNames: tenNames + excluded)
    try require(withExclusions[0].excludedCanonicalSourceNames == excluded.sorted()
        && withExclusions[0].ownership.flatMap(\.parameters).count == tenNames.count,
        "explicit exclusions changed text ownership")
    text["output_gate_type"] = "sigmoid"; root["text_config"] = text
    try reject { _ = try QwenLayerStageCandidates.enumerate(configuration: QwenStageMetadata.json(root),
        canonicalSourceNames: tenNames) }
    try reject { _ = try QwenLayerStageCandidates.enumerate(configuration: ten,
        canonicalSourceNames: Array(tenNames.dropLast())) }
    try reject { _ = try QwenLayerStageCandidates.enumerate(configuration: ten,
        canonicalSourceNames: tenNames + [tenNames[0]]) }
    try reject { _ = try QwenLayerStageCandidates.enumerate(configuration: ten,
        canonicalSourceNames: tenNames, activeMTP: true) }
}
