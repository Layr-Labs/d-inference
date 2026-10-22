import Foundation

func checkQwenPreservation(_ input: FixtureInputs, _ checks: FixtureChecks) throws {
    struct Profile: Decodable {
        let configuration: Data
        let canonicalTensors: [QwenDenseCanonicalTensor]
    }
    struct Inputs: Decodable { let nine: Profile; let twentySeven: Profile }
    struct Golden: Decodable {
        let label: String
        let cut: Int
        let configurationSHA256: String
        let planSHA256: String
        let stageSHA256: [String]
    }
    let profiles = try JSONDecoder().decode(Inputs.self, from: FixtureInputs.read(input.root, "qwen-retained-inputs.json"))
    let goldens = try JSONDecoder().decode([Golden].self, from: FixtureInputs.read(input.root, "qwen-plan-goldens.json"))
    for golden in goldens {
        let profile = golden.label.hasPrefix("nine") ? profiles.nine : profiles.twentySeven
        let layers = golden.label.hasPrefix("nine") ? 32 : 64
        let plan = try QwenLayerStagePlan(configuration: profile.configuration, ranges: [0..<golden.cut, golden.cut..<layers])
        try checks.require(golden.label + " old configuration and Plan bytes", sha256(profile.configuration) == golden.configurationSHA256
            && plan.fingerprint == golden.planSHA256 && plan.stages.map(\.fingerprint) == golden.stageSHA256)
        var offset = 8
        let sources = try profile.canonicalTensors.sorted { $0.name < $1.name }.map { tensor -> LayerStageSourceTensor in
            let layout = try LayerStageTensorLayout(canonicalName: tensor.name, shape: tensor.shape,
                sourceDType: tensor.sourceDType, byteCount: tensor.byteCount)
            let result = try LayerStageSourceTensor(layout: layout, sourceFile: "qwen-metadata-fixture.safetensors", sourceOffset: offset)
            offset = try QwenLongPrefillCheckedBytes.sum([offset, tensor.byteCount])
            return result
        }
        let byName = Dictionary(uniqueKeysWithValues: sources.map { ($0.layout.canonicalName, $0) })
        let original = try plan.parameters(canonicalSourceNames: profile.canonicalTensors.map(\.name))
        let mappings = try original.map { item -> LayerStageTensorMapping in
            let name = item.sourceName
            let role: LayerStageTensorRole
            let global: Int?
            if name.hasPrefix("language_model.model.layers.") {
                let fields = name.split(separator: ".")
                guard fields.count > 3, let value = Int(fields[3]) else { throw ProbeError("Qwen fixture layer index") }
                role = .layer; global = value
            } else if name.hasPrefix("language_model.model.embed_tokens.") {
                role = .ingressEmbedding; global = nil
            } else if name == "language_model.model.norm.weight" {
                role = .finalNorm; global = nil
            } else {
                role = .outputProjection; global = nil
            }
            return .init(source: byName[name]!, destinations: [.init(rank: item.stage,
                localName: item.localName, role: role, globalLayerIndex: global)], replicationGroupID: nil)
        }
        let shared = try LayerStageStorageConservation.validate(sources: sources, mappings: mappings,
            excludedSourceNames: [], allowedReplication: [])
        try checks.require(golden.label + " shared accounting preserves exclusive conservation",
            shared.selectedSourceTensorCount == original.count && shared.destinationTensorCount == original.count
            && shared.additionalReplicaBytes == 0 && shared.destinationPayloadBytes == shared.selectedSourcePayloadBytes)
        try checks.require(golden.label + " old Plan remains unchanged after shared projection",
            plan.fingerprint == golden.planSHA256 && plan.stages.map(\.fingerprint) == golden.stageSHA256)
    }
}
