import Foundation

private func checkOwnership(_ candidate: QwenLayerStageCandidates.Candidate,
    fixture: CandidateFixture, configuration: Data) throws {
    let sourceNames = Set(fixture.canonicalNames)
    let parameters = candidate.ownership.flatMap(\.parameters)
    try candidateRequire(candidate.plan.originalConfiguration == configuration, "source configuration identity changed")
    try candidateRequire(candidate.computeCostStatus == .unknown
        && candidate.ownership.allSatisfy { $0.computeCostStatus == .unknown }, "candidate invented a compute estimate")
    try candidateRequire(candidate.ownership.map(\.stageIndex) == [0, 1]
        && Set(parameters.map(\.sourceName)) == sourceNames && parameters.count == sourceNames.count,
        "input names do not have exactly one owner")
    try candidateRequire(Set(parameters.map { "\($0.stage):\($0.localName)" }).count == parameters.count,
        "two source names alias one local parameter")
    let prefix = fixture.namespace + "model.layers."
    for parameter in parameters {
        if parameter.sourceName.hasPrefix(prefix) {
            let sourceParts = parameter.sourceName.dropFirst(prefix.count).split(separator: ".")
            let localParts = parameter.localName.dropFirst(prefix.count).split(separator: ".")
            guard parameter.localName.hasPrefix(prefix), let sourceFirst = sourceParts.first,
                let localFirst = localParts.first, let global = Int(sourceFirst), let local = Int(localFirst) else {
                throw ProbeError("Malformed candidate layer mapping")
            }
            let expectedStage = global < candidate.cut ? 0 : 1
            let offset = expectedStage == 0 ? 0 : candidate.cut
            try candidateRequire(parameter.stage == expectedStage && global == local + offset
                && sourceParts.dropFirst().elementsEqual(localParts.dropFirst()),
                "local parameter cannot round-trip to its original global tensor")
        } else {
            let embedding = parameter.sourceName.hasPrefix(fixture.namespace + "model.embed_tokens.")
            try candidateRequire(parameter.stage == (embedding ? 0 : 1)
                && parameter.localName == parameter.sourceName, "embedding/norm/head responsibility changed")
        }
    }
    try candidateRequire(candidate.ownership.flatMap(\.state).map { $0.layer.globalIndex } == Array(0..<fixture.layerCount),
        "state layers do not preserve full source order")
    for owner in candidate.ownership {
        let start = owner.stageIndex == 0 ? 0 : candidate.cut
        let end = owner.stageIndex == 0 ? candidate.cut : fixture.layerCount
        try candidateRequire(owner.state.map { $0.layer.globalIndex } == Array(start..<end)
            && owner.state.map { $0.layer.localIndex } == Array(0..<(end - start)), "state ownership has a gap or overlap")
        for entry in owner.state {
            let isFull = (entry.layer.globalIndex + 1) % 4 == 0
            let components: [QwenLayerStageCandidates.StateComponent] = isFull
                ? [.keys, .values, .offsets] : [.convolution, .ssm]
            try candidateRequire(entry.components == components
                && entry.layer.kind == (isFull ? "full_attention" : "linear_attention")
                && isFull == ((entry.layer.localIndex + 1) % 4 == 0), "state kind/phase changed after reindexing")
        }
        let stage = candidate.plan.stages[owner.stageIndex]
        let construction = try candidateObject(stage.constructionConfiguration)
        var localText = try fixture.text(in: construction)
        var sourceText = try fixture.text(in: fixture.object)
        try candidateRequire(localText["num_hidden_layers"] as? Int == end - start
            && localText["mtp_num_hidden_layers"] as? Int == 0, "compact count or disabled MTP changed")
        try candidateRequire((construction["mtplx_mtp"] as? [String: Any])?["included"] as? Bool == false,
            "stage construction left optional MTP attached")
        try candidateRequire(localText["layer_types"] as? [String] == owner.state.map { $0.layer.kind },
            "construction layer policy differs from owned state")
        for key in ["num_hidden_layers", "layer_types", "mtp_num_hidden_layers", "mtplx_mtp", "quantization", "quantization_config"] {
            localText.removeValue(forKey: key); sourceText.removeValue(forKey: key)
        }
        try candidateRequire(try candidateJSON(localText) == candidateJSON(sourceText),
            "stage changed full widths, dtype, RoPE or other model metadata")
        let inertPaths = stage.inertModules.map(\.path).sorted()
        let expectedInert = owner.stageIndex == 0
            ? [fixture.namespace + "model.norm", fixture.namespace + "lm_head"].sorted()
            : [fixture.namespace + "model.embed_tokens"]
        try candidateRequire(inertPaths == expectedInert, "inactive module responsibility is not explicit")
        guard let policy = construction["quantization"] as? [String: Any] else { throw ProbeError("Missing compact policy") }
        try candidateRequire(try candidateJSON(policy) == candidateJSON(construction["quantization_config"]!),
            "quantization aliases diverged")
        try candidateRequire(policy["bits"] as? Int == 4 && policy["group_size"] as? Int == 64
            && policy["quant_method"] as? String == "synthetic-retained-metadata", "policy defaults or metadata changed")
        for path in expectedInert { try candidateRequire(policy[path] as? Bool == false, "inert module inherited quantization") }
    }
    if fixture.layerCount > 8 {
        let source = fixture.namespace + "model.layers.8.mlp.down_proj"
        let expectedLocal = fixture.namespace + "model.layers.\(8 - candidate.cut).mlp.down_proj"
        let mapping = candidate.plan.stages[1].quantizationMappings.filter { $0.sourcePath == source }
        try candidateRequire(mapping.count == 1 && mapping[0].localPath == expectedLocal,
            "per-module quantization policy lost its original layer")
        let policy = try candidateObject(Data(mapping[0].policyJSON.utf8))
        try candidateRequire(policy["bits"] as? Int == 8 && policy["group_size"] as? Int == 128,
            "per-module policy precision changed")
        try candidateRequire(candidate.plan.stages[0].excludedQuantizationPaths.contains(source),
            "non-owning stage retained the override")
    }
}

func checkCandidateOwnership() throws -> [String] {
    var passed: [String] = []
    for form in CandidateFixture.Form.allCases {
        let fixture = CandidateFixture(layers: 12, form: form)
        let data = try candidateJSON(fixture.object)
        let candidates = try QwenLayerStageCandidates.enumerate(configuration: data, canonicalSourceNames: fixture.canonicalNames)
        try candidateRequire(candidates.map(\.cut) == [4, 8], "legal candidate set is incomplete")
        try candidateRequire(Set(candidates.map { $0.plan.fingerprint }).count == 2, "distinct cuts share a plan identity")
        for candidate in candidates { try checkOwnership(candidate, fixture: fixture, configuration: data) }
        let reversed = try QwenLayerStageCandidates.enumerate(configuration: data,
            canonicalSourceNames: Array(fixture.canonicalNames.reversed()))
        try candidateRequire(candidates.map { $0.plan.fingerprint } == reversed.map { $0.plan.fingerprint }
            && zip(candidates, reversed).allSatisfy { pair in pair.0.ownership.flatMap(\.parameters) == pair.1.ownership.flatMap(\.parameters) },
            "caller name ordering changed deterministic metadata")
        passed.append("12-layer ownership and metadata: \(form)")
    }
    let fixture = CandidateFixture(layers: 10, form: .nestedWrapper)
    let data = try candidateJSON(fixture.object)
    let candidates = try QwenLayerStageCandidates.enumerate(configuration: data, canonicalSourceNames: fixture.canonicalNames)
    try candidateRequire(candidates.map(\.cut) == [4] && candidates[0].ownership.map { $0.state.count } == [4, 6],
        "a valid final partial interval requires the 4+6 split")
    try checkOwnership(candidates[0], fixture: fixture, configuration: data)
    passed.append("unaligned final end retains 4+6 ownership")
    let exclusions = ["vision_tower.unused.weight", "mtp.layers.0.weight"]
    let excluded = try QwenLayerStageCandidates.enumerate(configuration: data,
        canonicalSourceNames: fixture.canonicalNames + exclusions)
    try candidateRequire(excluded[0].excludedCanonicalSourceNames == exclusions.sorted()
        && excluded[0].ownership.flatMap(\.parameters) == candidates[0].ownership.flatMap(\.parameters),
        "explicit inactive components changed text ownership")
    passed.append("inactive source components remain explicit")
    return passed
}
