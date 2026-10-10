import DarkbloomClusterProtocol
import Darwin
import Foundation
@testable import DarkbloomClusterRuntimeChecks

struct CheckFailure: Error, CustomStringConvertible { let description: String }

func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try value() else { throw CheckFailure(description: message) }
}

func refuses(_ message: String, _ body: () throws -> Void) throws {
    do { try body() } catch is CheckFailure { throw CheckFailure(description: message) } catch { return }
    throw CheckFailure(description: "Unexpected acceptance: " + message)
}

@main enum NemotronStageCheck {
    static let modelID = "registered_nemotron35_lightning"
    static let pattern = NemotronInventoryFixture.pattern

    static func main() {
        do {
            guard CommandLine.arguments.count == 2 else { throw CheckFailure(description: "Expected the fixtures directory") }
            let fixtures = URL(fileURLWithPath: CommandLine.arguments[1])
            let configuration = try Data(contentsOf: fixtures.appendingPathComponent("registered-nemotron35-lightning.configuration.json"))
            let manifest = try Data(contentsOf: fixtures.appendingPathComponent("registered-nemotron35-lightning.manifest.json"))
            var passed: [String] = []
            func check(_ name: String, _ body: () throws -> Void) throws { try body(); passed.append(name) }
            let spec = try specification()
            let root = try JSONSerialization.jsonObject(with: configuration) as! [String: Any]
            let tensors = NemotronInventoryFixture.canonicalTensors()

            try check("fixtures-are-the-registered-metadata") {
                try require(sha256(configuration) == spec.configurationSHA256, "configuration fixture differs from its pin")
                try require(sha256(manifest) == spec.manifestSHA256, "manifest fixture differs from its pin")
                struct Manifest: Decodable { let aggregate_sha256: String, file_count: Int, total_size_bytes: Int, model_id: String, version: String }
                let declared = try JSONDecoder().decode(Manifest.self, from: manifest)
                try require(declared.aggregate_sha256 == spec.artifactSHA256 && declared.file_count == 10
                    && declared.total_size_bytes == 19_059_595_830, "manifest totals differ")
                try require(declared.model_id == "nvidia-nemotron-3.5-lightning" && declared.version == "2026-09-30-r1",
                    "manifest names another catalog entry")
            }

            try check("configuration-declares-the-pinned-geometry") {
                let geometry = try NemotronStageMetadata.geometry(root: root)
                try require(geometry == NemotronRegisteredLightning.geometry, "declared geometry differs from the pinned one")
                let symbols = geometry.kinds.map { $0 == .mamba ? "M" : $0 == .moe ? "E" : "*" }.joined()
                try require(symbols == pattern && geometry.layers == 52, "block pattern differs")
                try require(geometry.kinds.filter { $0 == .mamba }.count == 23 && geometry.kinds.filter { $0 == .moe }.count == 23
                    && geometry.kinds.filter { $0 == .attention }.count == 6, "block kind counts differ")
                try require(geometry.convolutionWidth == 6144 && geometry.mambaWidth == 4096 && geometry.attentionWidth == 4096,
                    "derived widths differ")
            }

            try check("unqualified-configurations-are-refused") {
                func changed(_ edit: (inout [String: Any]) -> Void) -> [String: Any] { var copy = root; edit(&copy); return copy }
                try refuses("unknown key") { _ = try NemotronStageMetadata.geometry(root: changed { $0["new_block_policy"] = 1 }) }
                try refuses("compact pattern spelling") { _ = try NemotronStageMetadata.geometry(root: changed { $0["hybrid_override_pattern"] = "ME" }) }
                try refuses("explicit step limits") { _ = try NemotronStageMetadata.geometry(root: changed { $0["time_step_limit"] = [0.0, 1.0] }) }
                try refuses("tied embeddings") { _ = try NemotronStageMetadata.geometry(root: changed { $0["tie_word_embeddings"] = true }) }
                try refuses("a plain mlp block") { _ = try NemotronStageMetadata.geometry(root: changed {
                    var kinds = $0["layers_block_type"] as! [String]; kinds[1] = "mlp"; $0["layers_block_type"] = kinds }) }
                try refuses("block list shorter than the layer count") { _ = try NemotronStageMetadata.geometry(root: changed {
                    $0["layers_block_type"] = Array(($0["layers_block_type"] as! [String]).dropLast()) }) }
                try refuses("a narrow SSM state") { _ = try NemotronStageMetadata.geometry(root: changed { $0["mamba_ssm_cache_dtype"] = "bfloat16" }) }
                try refuses("grouped expert selection") { _ = try NemotronStageMetadata.geometry(root: changed { $0["n_group"] = 2 }) }
                try refuses("another model type") { _ = try NemotronStageMetadata.geometry(root: changed { $0["model_type"] = "qwen3_5" }) }
            }

            let structural = NemotronStageMetadata.structuralCuts(NemotronRegisteredLightning.kinds)
            let definition = try QwenResidentModelDefinition(model: .nemotron35Lightning)
            try check("cuts-are-beside-expert-blocks-with-attention-on-both-sides") {
                let symbols = Array(pattern)
                let expected = (1..<52).filter { cut in
                    symbols[..<cut].contains("*") && symbols[cut...].contains("*") && (symbols[cut - 1] == "E" || symbols[cut] == "E")
                }
                try require(structural == expected && structural.count == 32 && structural.first == 6 && structural.last == 41,
                    "structural cuts differ")
                try require(![12, 19, 26, 33].contains(where: structural.contains), "a cut between a Mamba and an attention block was admitted")
                let cuts = definition.supportedCuts
                try require(!cuts.isEmpty && cuts.count <= 16 && cuts == cuts.sorted() && Set(cuts).count == cuts.count
                    && cuts.allSatisfy(structural.contains), "resident cuts are not a closed list of structural cuts")
                try require(cuts == structural.filter { symbols[$0 - 1] == "E" } && cuts.count == 16,
                    "the resident cuts are not exactly the structural cuts that follow an expert block")
                try require(cuts == NemotronRegisteredLightning.supportedCuts && cuts.contains(NemotronRegisteredLightning.planningCut),
                    "resident row differs from the registered constants")
            }

            try check("resident-row-names-its-own-adapter-and-arithmetic") {
                try require(definition.profileID == "registered_nemotron35_lightning_greedy_generation_v1"
                    && definition.specification.layers == 52, "resident row differs")
                try require(definition.adapter == .nemotronH && definition.arithmetic == .nemotronHybrid
                    && definition.arithmetic.contract == ClusterRuntimeAdapter.nemotronH.arithmeticPolicyID, "adapter or arithmetic differs")
                try require(definition.supportedGenerationModes.first == .pipeline, "the pipeline is not first")
                try require(try QwenResidentModelDefinition(runtimeModelID: modelID).specification.model == .nemotron35Lightning
                    && (try QwenResidentModelDefinition(configuration: configuration).specification.model) == .nemotron35Lightning,
                    "the row is not found by ID and by configuration")
                let dense = ["DARKBLOOM_CBV2_ATTN_QUERY_BLOCK": "128", "DARKBLOOM_BF16_WEIGHTS": "1", "MLX_ENABLE_TF32": "1"]
                try require(definition.arithmetic.requiredValues == dense, "arithmetic values differ from the dense three")
                let receipt = try definition.arithmetic.admit(dense)
                try require(receipt.contract == "nemotron_h_cbv2_query128_bf16_tf32_default_v1" && receipt.requiredValues == dense,
                    "arithmetic receipt differs")
                // The expert-tile switch does not select anything for these expert shapes.
                _ = try definition.arithmetic.admit(dense.merging(["MLX_GATHER_QMM_EXPERT_SLICES": "trust"]) { $1 })
                try refuses("a rank without TF32") { _ = try definition.arithmetic.admit(dense.filter { $0.key != "MLX_ENABLE_TF32" }) }
                try refuses("a forced Metal architecture") { _ = try definition.arithmetic.admit(dense.merging(["MLX_METAL_GPU_ARCH": "x"]) { $1 }) }
                let profile = try QwenResidentAdapterDefinition.profile(specification: spec)
                try require(profile.vocabularySize == 131_072 && profile.hiddenSize == 2688 && profile.activationDType == "bfloat16"
                    && profile.maximumPromptTokens == 8192 && profile.maximumContextTokens == 8320, "generation profile differs")
            }

            try check("inventory-is-the-geometrys-tensor-set") {
                try require(tensors.count == 729 && tensors.count == spec.tensorCount, "tensor count differs")
                try require(tensors.map(\.byteCount).reduce(0, +) == 18_290_661_248 && tensors.map(\.byteCount).max() == 319_291_392,
                    "tensor bytes differ")
                for tensor in tensors { try tensor.validate() }
                try require(QwenDenseProfileIdentity.fingerprint(tensors.sorted { $0.name < $1.name }.map(\.identity)) == spec.inventorySHA256,
                    "inventory fingerprint differs from its pin")
            }

            var planFingerprints = Set<String>(), stageFingerprints = Set<String>()
            for cut in definition.supportedCuts {
                try check("plan-at-cut-\(cut)") {
                    let plan = try QwenLayerStagePlan(configuration: configuration, ranges: [0..<cut, cut..<52])
                    try require(plan.layers == 52 && plan.interval == 0 && plan.stages.count == 2, "Plan geometry differs")
                    planFingerprints.insert(plan.fingerprint)
                    let kinds = Array(pattern).map { $0 == "M" ? "mamba" : $0 == "E" ? "moe" : "attention" }
                    var bytes = [0, 0], names = [0, 0]
                    let mapped = try plan.parameters(canonicalSourceNames: tensors.map(\.name))
                    try require(mapped.count == 729, "a canonical tensor has no owner")
                    let sizes = Dictionary(uniqueKeysWithValues: tensors.map { ($0.name, $0.byteCount) })
                    for parameter in mapped { bytes[parameter.stage] += sizes[parameter.sourceName]!; names[parameter.stage] += 1 }
                    try require(bytes[0] + bytes[1] == 18_290_661_248 && names[0] + names[1] == 729, "stages do not conserve the source")
                    for stage in plan.stages {
                        stageFingerprints.insert(stage.fingerprint)
                        let range = stage.index == 0 ? 0..<cut : cut..<52
                        try require(stage.sourceRange == range && stage.layers.map(\.globalIndex) == Array(range)
                            && stage.layers.map(\.localIndex) == Array(0..<range.count)
                            && stage.layers.map(\.kind) == Array(kinds[range]), "stage layer map differs")
                        let built = try JSONSerialization.jsonObject(with: stage.constructionConfiguration) as! [String: Any]
                        try require(built["layers_block_type"] as? [String] == Array(kinds[range])
                            && BoundedProbeInput.integer(built["num_hidden_layers"]) == range.count, "stage block list differs")
                        try require(BoundedProbeInput.integer(built["num_nextn_predict_layers"]) == 0
                            && (built["mtp_layers_block_type"] as? [String]) == [] && built["darkbloom_embedded_mtp"] == nil,
                            "a stage configuration still declares the speculative head")
                        try require(built["model_type"] as? String == "nemotron_h" && BoundedProbeInput.integer(built["vocab_size"]) == 131_072
                            && BoundedProbeInput.integer(built["hidden_size"]) == 2688, "stage configuration lost a width")
                        // The stage constructor must still admit its own configuration.
                        _ = try NemotronStageMetadata.geometry(root: built)
                        let policy = built["quantization"] as! [String: Any]
                        try require(try QwenStageMetadata.json(policy) == QwenStageMetadata.json(built["quantization_config"]!),
                            "the two quantization containers differ")
                        let paths = policy.keys.filter { !["bits", "group_size", "mode"].contains($0) }
                        try require(!paths.contains { $0.hasPrefix("mtp.") }, "a stage quantizes the speculative head")
                        let inert = Set(stage.inertModules.map(\.path))
                        try require(inert == (stage.index == 0 ? ["backbone.norm_f", "lm_head"] : ["backbone.embeddings"]),
                            "inert modules differ")
                        for path in inert {
                            try require((policy[path] as? NSNumber)?.boolValue == false, "an inert module inherits a quantization policy")
                        }
                        let layerPaths = paths.filter { $0.hasPrefix("backbone.layers.") }
                        try require(layerPaths.allSatisfy { Int($0.split(separator: ".")[2]).map { $0 < range.count } == true },
                            "a stage quantization path names a block it does not have")
                        let expectedLayerPaths = kinds[range].reduce(0) { $0 + ($1 == "mamba" ? 2 : 4) }
                        try require(layerPaths.count == expectedLayerPaths && stage.quantizationMappings.count
                            == expectedLayerPaths + 1, "stage quantization coverage differs")
                        try require(stage.activeModuleRoots.contains(stage.index == 0 ? "backbone.embeddings" : "lm_head")
                            && (stage.index == 0) != stage.activeModuleRoots.contains("backbone.norm_f"), "active roots differ")
                    }
                    // Local names: only the block index moves.
                    let first = try plan.parameter(canonicalSourceName: "backbone.layers.\(cut).norm.weight")
                    try require(first?.stage == 1 && first?.localName == "backbone.layers.0.norm.weight", "stage 1 does not start at its cut")
                    let last = try plan.parameter(canonicalSourceName: "backbone.layers.\(cut - 1).norm.weight")
                    try require(last?.stage == 0 && last?.localName == "backbone.layers.\(cut - 1).norm.weight", "stage 0 lost its last block")
                    try require(try plan.parameter(canonicalSourceName: "backbone.embeddings.scales")?.stage == 0
                        && (try plan.parameter(canonicalSourceName: "lm_head.weight")?.stage) == 1
                        && (try plan.parameter(canonicalSourceName: "backbone.norm_f.weight")?.stage) == 1, "the ends are misplaced")
                    try require(try plan.parameter(canonicalSourceName: "mtp.layers.0.mixer.q_proj.weight") == nil,
                        "the speculative head was given a stage")
                    try refuses("an unknown tensor name") { _ = try plan.parameter(canonicalSourceName: "backbone.layers.1.mixer.experts.0.up_proj.weight") }
                    try refuses("a block past the model") { _ = try plan.parameter(canonicalSourceName: "backbone.layers.52.norm.weight") }
                    // Mandatory names are the weights and plain parameters; a missing one is refused.
                    try refuses("an inventory without the final norm") {
                        _ = try plan.parameters(canonicalSourceNames: tensors.map(\.name).filter { $0 != "backbone.norm_f.weight" })
                    }
                }
            }
            try check("every-cut-has-its-own-identities") {
                try require(planFingerprints.count == definition.supportedCuts.count
                    && stageFingerprints.count == 2 * definition.supportedCuts.count, "two cuts share a Plan or stage identity")
            }
            try check("cuts-outside-the-structure-are-refused") {
                for cut in [0, 1, 5, 12, 19, 26, 33, 42, 43, 51, 52] {
                    try refuses("cut \(cut)") { _ = try QwenLayerStagePlan(configuration: configuration, ranges: [0..<cut, cut..<52]) }
                }
                try refuses("a gap between stages") { _ = try QwenLayerStagePlan(configuration: configuration, ranges: [0..<25, 26..<52]) }
                try refuses("three stages") { _ = try QwenLayerStagePlan(configuration: configuration, ranges: [0..<16, 16..<30, 30..<52]) }
                try refuses("active MTP") { _ = try QwenLayerStagePlan(configuration: configuration, ranges: [0..<25, 25..<52], activeMTP: true) }
            }

            try check("profile-admits-exactly-the-registered-artifact") {
                let profile = try QwenRegisteredDenseModelProfile.admit(configuration: configuration, manifest: manifest,
                    expectedArtifactAggregateSHA256: spec.artifactSHA256, canonicalTensors: tensors)
                try require(profile.model == .nemotron35Lightning && profile.vocabularySize == 131_072
                    && profile.geometry == (try spec.expectedGeometry()) && profile.sourceTensorBytes == 18_290_661_248,
                    "profile differs from the registered row")
                try require(profile.geometry.attentionLayers == 6 && profile.geometry.recurrentLayers == 23
                    && profile.geometry.fullAttentionInterval == 0, "state layer counts differ")
                try refuses("another aggregate") { _ = try QwenRegisteredDenseModelProfile.admit(configuration: configuration, manifest: manifest,
                    expectedArtifactAggregateSHA256: String(repeating: "0", count: 64), canonicalTensors: tensors) }
                try refuses("an inventory without one tensor") { _ = try QwenRegisteredDenseModelProfile.admit(configuration: configuration,
                    manifest: manifest, expectedArtifactAggregateSHA256: spec.artifactSHA256, canonicalTensors: Array(tensors.dropLast())) }
                var widened = tensors
                widened[0] = .init(name: widened[0].name, shape: widened[0].shape, sourceDType: "F16", byteCount: widened[0].byteCount)
                try refuses("an inventory with another dtype") { _ = try QwenRegisteredDenseModelProfile.admit(configuration: configuration,
                    manifest: manifest, expectedArtifactAggregateSHA256: spec.artifactSHA256, canonicalTensors: widened) }
                try refuses("a cut outside the resident row") { _ = try profile.makePlanningPlan(stageCut: 20) }

                // Storage and state per stage follow the kinds of the stage's own blocks.
                let symbols = Array(pattern)
                for cut in definition.supportedCuts {
                    let plan = try profile.makePlanningPlan(stageCut: cut)
                    let pair = try QwenDenseStorageRequirement.derive(profile: profile, plan: plan, role: .sequentialPair)
                    try require(pair.selectedActiveBytes == 18_290_661_248 && pair.fusionReplacementBytes == 0
                        && pair.finalState.attentionLayers == 6 && pair.finalState.recurrentLayers == 23, "pair requirement differs")
                    try require(pair.finalState.kvShape == [1, 2, 8192, 128] && pair.finalState.convolutionShape == [1, 3, 6144]
                        && pair.finalState.ssmShape == [1, 64, 64, 128], "state shapes differ")
                    for (index, range) in [0..<cut, cut..<52].enumerated() {
                        let stage = try QwenDenseStorageRequirement.derive(profile: profile, plan: plan, role: index == 0 ? .stage0 : .stage1)
                        try require(stage.finalState.attentionLayers == symbols[range].filter { $0 == "*" }.count
                            && stage.finalState.recurrentLayers == symbols[range].filter { $0 == "M" }.count
                            && stage.finalState.componentCount == 3 * stage.finalState.attentionLayers + 2 * stage.finalState.recurrentLayers,
                            "a stage's state does not follow its own blocks")
                        try require(stage.selectedInertBytes == (index == 0 ? 2 : 1) * 2688 * 2 && stage.fusionReplacementBytes == 0,
                            "a stage's inert bytes differ")
                    }
                    let stages = pair.stages
                    try require(stages[0].activeBytes + stages[1].activeBytes == 18_290_661_248, "stage bytes do not conserve the source")
                }
            }

            try check("state-budget-is-the-pinned-one-and-leaves-the-interval-models-alone") {
                let geometry = try spec.expectedGeometry()
                try require(try QwenLongPrefillTensorBudget.estimate(geometry: geometry, maximumTokens: 8193, chunkSize: 512)
                    .conservativeStateAndBoundaryBytes == 269_866_008 && spec.namedStateBytes == 269_866_008, "state estimate at 8,193 differs")
                try require(try QwenLongPrefillTensorBudget.estimate(geometry: geometry, maximumTokens: 8320, chunkSize: 512)
                    .conservativeStateAndBoundaryBytes == 271_556_632, "state estimate at 8,320 differs")
                let nine = try registeredSpecification(.qwen35NineB).expectedGeometry()
                try require(nine.stateLayers == nil && nine.attentionLayers == 8 && nine.recurrentLayers == 24, "the 9B geometry changed")
                let encoded = String(decoding: try canonicalJSONData(nine), as: UTF8.self)
                try require(!encoded.contains("stateLayers"), "an interval geometry's encoded form changed")
                try require(try QwenLongPrefillTensorBudget.estimate(geometry: nine, maximumTokens: 8193, chunkSize: 512)
                    .conservativeStateAndBoundaryBytes == 745_345_056, "the 9B state estimate changed")
            }

            try check("capability-has-one-partition-per-resident-cut") {
                let capability = try QwenResidentCapabilityMetadata.describe(configuration: configuration, manifest: manifest,
                    runtimeBinarySHA256: String(repeating: "1", count: 64))
                try require(capability.adapterID == "nemotron-h-layer-stage" && capability.runtimeModelID == modelID
                    && capability.partitions.map { $0.stages[0].sourceLayerEnd } == definition.supportedCuts, "capability differs")
                try require(try ClusterRuntimeCapabilityCodec.decode(ClusterRuntimeCapabilityCodec.encode(capability)) == capability,
                    "capability does not round-trip")
            }

            var output = try JSONSerialization.data(withJSONObject: ["passed": passed, "count": passed.count,
                "modelOrGPUExecution": false] as [String: Any], options: [.sortedKeys])
            output.append(10); FileHandle.standardOutput.write(output)
        } catch {
            FileHandle.standardError.write(Data("FAILED: \(error)\n".utf8)); Darwin.exit(1)
        }
    }

    static func specification() throws -> QwenDenseRegisteredSpecification { try registeredSpecification(.nemotron35Lightning) }
}

func registeredSpecification(_ model: QwenRegisteredDenseModel) throws -> QwenDenseRegisteredSpecification {
    guard let row = QwenDenseRegisteredSpecification.all.first(where: { $0.model == model }) else {
        throw CheckFailure(description: "\(model.rawValue) has no specification")
    }
    return row
}
