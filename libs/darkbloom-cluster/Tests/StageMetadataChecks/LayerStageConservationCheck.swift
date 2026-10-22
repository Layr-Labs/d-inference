import Foundation

func checkLayerStageRefusals(_ input: FixtureInputs, _ checks: FixtureChecks) throws {
    let plan = try Gemma4LayerStagePlan(artifact: input.artifact, cut: 15)
    func validate(_ mappings: [LayerStageTensorMapping], excluded: [String]? = nil,
                  replicas: [LayerStageTiedEmbeddingReplication]? = nil) throws {
        _ = try LayerStageStorageConservation.validate(sources: input.artifact.sources, mappings: mappings,
            excludedSourceNames: excluded ?? input.artifact.excludedSourceNames, allowedReplication: replicas ?? plan.replication)
    }
    try checks.refuses("missing selected source") { try validate(Array(plan.mappings.dropLast())) }
    try checks.refuses("duplicate source mapping") { try validate(plan.mappings + [plan.mappings[0]]) }
    try checks.refuses("missing excluded vision") { try validate(plan.mappings, excluded: Array(input.artifact.excludedSourceNames.dropLast())) }
    try checks.refuses("unknown excluded name") { try validate(plan.mappings, excluded: input.artifact.excludedSourceNames + ["vision_tower.unknown"]) }
    let replicaIndex = plan.mappings.firstIndex { $0.replicationGroupID != nil }!
    let replica = plan.mappings[replicaIndex]
    func replaced(_ index: Int, source: LayerStageSourceTensor? = nil,
                  targets: [LayerStageTensorDestination], group: String?) -> [LayerStageTensorMapping] {
        var values = plan.mappings
        values[index] = .init(source: source ?? values[index].source, destinations: targets, replicationGroupID: group)
        return values
    }
    try checks.refuses("tied replica omitted") {
        try validate(replaced(replicaIndex, targets: [replica.destinations[0]], group: replica.replicationGroupID))
    }
    try checks.refuses("tied replica duplicated onto same rank") {
        try validate(replaced(replicaIndex, targets: [replica.destinations[0], replica.destinations[0]], group: replica.replicationGroupID))
    }
    try checks.refuses("tied replica has unknown group") {
        try validate(replaced(replicaIndex, targets: replica.destinations, group: "unknown"))
    }
    try checks.refuses("tied replica unadmitted") { try validate(plan.mappings, replicas: []) }
    let layerIndex = plan.mappings.firstIndex { $0.destinations.first?.role == .layer }!
    let layer = plan.mappings[layerIndex]
    try checks.refuses("ordinary layer replicated") {
        try validate(replaced(layerIndex, targets: layer.destinations + layer.destinations, group: nil))
    }
    try checks.refuses("source offset changed after planning") {
        let source = try LayerStageSourceTensor(layout: layer.source.layout,
            sourceFile: layer.source.sourceFile, sourceOffset: layer.source.sourceOffset + 4)
        try validate(replaced(layerIndex, source: source, targets: layer.destinations, group: nil))
    }
    try checks.refuses("destination name collision") {
        let other = plan.mappings.indices.first { $0 != layerIndex && plan.mappings[$0].destinations.first?.role == .layer }!
        try validate(replaced(other, targets: layer.destinations, group: nil))
    }
    try checks.refuses("wrong global index despite conserved bytes") {
        let target = layer.destinations[0]
        let changed = replaced(layerIndex, targets: [.init(rank: target.rank, localName: target.localName,
            role: .layer, globalLayerIndex: 29)], group: nil)
        _ = try plan.validateStorage(mappings: changed, excludedSourceNames: input.artifact.excludedSourceNames)
    }
    for cut in [-1, 0, 30, 31] {
        try checks.refuses("invalid cut\(cut)") { _ = try Gemma4LayerStagePlan(artifact: input.artifact, cut: cut) }
    }
    try checks.refuses("rank0 range starts after global0") {
        _ = try Gemma4StageConstructionDescriptor(artifact: input.artifact, rank: 0, sourceLayerRange: 1..<15)
    }
    try checks.refuses("rank1 range omits final global29") {
        _ = try Gemma4StageConstructionDescriptor(artifact: input.artifact, rank: 1, sourceLayerRange: 15..<29)
    }
    try checks.refuses("whole model cannot masquerade as one paired stage") {
        _ = try Gemma4StageConstructionDescriptor(artifact: input.artifact, rank: 1, sourceLayerRange: 0..<30)
    }
    try checks.refuses("layout same-byte wrong shape rejected by artifact expectation") {
        let expected = try Gemma4TensorInventory.expectedText(input.artifact.text)
        let name = "language_model.model.layers.0.experts.switch_glu.gate_proj.weight"
        let original = expected[name]!
        let wrong = try LayerStageTensorLayout(canonicalName: name, shape: [64, 1408, 352],
            sourceDType: original.sourceDType, byteCount: original.byteCount)
        let changed = try input.artifact.sources.map { source -> LayerStageSourceTensor in
            guard source.layout.canonicalName == name else { return source }
            return try .init(layout: wrong, sourceFile: source.sourceFile, sourceOffset: source.sourceOffset)
        }
        _ = try Gemma4ArtifactMetadata.validateSourceInventory(changed, text: input.artifact.text)
    }
    try checks.refuses("descriptor arithmetic overflow") {
        _ = try LayerStageTensorLayout(canonicalName: "model.layers.0.weight",
            shape: [Int(Int32.max), Int(Int32.max), Int(Int32.max)], sourceDType: "F32", byteCount: 1)
    }
}
