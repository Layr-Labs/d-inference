import Foundation
import DarkbloomClusterProtocol
import MLX
import MLXLMCommon
import Testing
@testable import DarkbloomClusterRuntime

// The registered Gemma 4 26B artifacts as a second resident family. Like the
// Qwen suites, this reads only the registered configuration and manifest
// metadata (byte-exact copies of the artifacts' own files), never weights.
// Loading a stage and running a request need the full artifact and are recorded
// as real runs in the hand-off write-up, never simulated here.

@Suite("Resident admission contract, registered Gemma 4 26B (registered metadata, no model)")
struct ResidentAdmissionGemma4Tests {
    private static let now: UInt64 = 1_000
    private static let matrix = Data(#"[[null,"tb5-a"],["tb5-b",null]]"#.utf8)

    private static func fixture(_ model: String, _ name: String) throws -> Data {
        // Tests/DarkbloomClusterRuntimeTests -> libs, then the worker's fixtures.
        let libraries = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: libraries.appendingPathComponent(
            "darkbloom-cluster-worker/Tests/CapabilityChecks/Fixtures/registered-\(model).\(name).json"))
    }

    /// The artifact files each row was registered from. The two 8-bit catalog
    /// entries are one artifact, so they share the configuration fixture.
    private static func files(_ model: Gemma4RegisteredModel) throws -> (configuration: Data, manifest: Data) {
        switch model {
        case .twentySixBQAT4Bit:
            return (try fixture("gemma4-26b-qat-4bit", "configuration"), try fixture("gemma4-26b-qat-4bit", "manifest"))
        case .twentySixB:
            return (try fixture("gemma4-26b", "configuration"), try fixture("gemma4-26b", "manifest"))
        case .twentySixB8Bit:
            return (try fixture("gemma4-26b", "configuration"), try fixture("gemma4-26b-8bit", "manifest"))
        }
    }

    private static func environment(rank: Int = 0) -> [String: String] {
        var values = Gemma4ArithmeticEnvironment.requiredValues
        values["JACCL_RANK"] = String(rank)
        values["JACCL_IBV_DEVICES"] = "/opt/cluster/matrix.json"
        values["JACCL_COORDINATOR"] = "10.0.0.5:4499"
        return values
    }

    private static func identity(_ model: Gemma4RegisteredModel, modelID: String? = nil,
                                 configSHA: String? = nil, artifactSHA: String? = nil) throws -> ClusterWorkerIdentity {
        let spec = try Gemma4RegisteredSpecification.registered(model)
        return ClusterWorkerIdentity(membershipEpoch: UUID(), modelID: modelID ?? model.rawValue,
            artifactSHA256: artifactSHA ?? spec.artifactSHA256,
            configurationSHA256: configSHA ?? spec.configurationSHA256,
            peers: [ClusterWorkerPeer(id: "peer-a", buildSHA256: String(repeating: "a", count: 64)),
                    ClusterWorkerPeer(id: "peer-b", buildSHA256: String(repeating: "b", count: 64))])
    }

    private static func admit(_ model: Gemma4RegisteredModel, rank: Int = 0, cut: Int = 12,
                              identity: ClusterWorkerIdentity? = nil, config: Data? = nil, manifest: Data? = nil,
                              environment: [String: String]? = nil,
                              deadline: UInt64 = now + 300_000_000_000) throws -> Gemma4ResidentAdmission {
        let files = try Self.files(model)
        return try Gemma4ResidentAdmission(configuration: .init(identity: try identity ?? Self.identity(model),
                modelDirectory: URL(fileURLWithPath: "/tmp"), rank: rank, stageCut: cut,
                deadlineUptimeNanoseconds: deadline),
            configBytes: config ?? files.configuration, manifestBytes: manifest ?? files.manifest,
            environment: environment ?? Self.environment(rank: rank), now: now, read: { _, _ in matrix })
    }

    /// The text tensors a configuration's geometry and quantization imply,
    /// written out independently of the loader: name, stored dtype, shape, bytes.
    private static func expectedInventory(defaultBits: Int) -> [QwenDenseCanonicalTensor] {
        var result: [QwenDenseCanonicalTensor] = []
        func tensor(_ name: String, _ dtype: String, _ shape: [Int]) {
            result.append(.init(name: name, shape: shape, sourceDType: dtype,
                                byteCount: shape.reduce(dtype == "U32" ? 4 : 2, *)))
        }
        func quantized(_ module: String, _ shape: [Int], bits: Int) {
            let width = shape[shape.count - 1]
            tensor(module + ".weight", "U32", Array(shape.dropLast()) + [width * bits / 32])
            for suffix in ["scales", "biases"] { tensor(module + "." + suffix, "BF16", Array(shape.dropLast()) + [width / 64]) }
        }
        let prefix = "language_model.model.", h = 2816
        quantized(prefix + "embed_tokens", [262_144, h], bits: defaultBits)
        tensor(prefix + "norm.weight", "BF16", [h])
        for layer in 0..<30 {
            let base = prefix + "layers.\(layer).", full = (layer + 1) % 6 == 0
            for name in ["input_layernorm", "post_attention_layernorm", "pre_feedforward_layernorm",
                         "post_feedforward_layernorm", "post_feedforward_layernorm_1",
                         "pre_feedforward_layernorm_2", "post_feedforward_layernorm_2"] {
                tensor(base + name + ".weight", "BF16", [h])
            }
            tensor(base + "layer_scalar", "BF16", [1])
            tensor(base + "router.scale", "BF16", [h])
            tensor(base + "router.per_expert_scale", "BF16", [128])
            quantized(base + "router.proj", [128, h], bits: 8)
            for (name, output, input) in [("gate_proj", 2112, h), ("up_proj", 2112, h), ("down_proj", h, 2112)] {
                quantized(base + "mlp." + name, [output, input], bits: 8)
            }
            for (name, output, input) in [("gate_proj", 704, h), ("up_proj", 704, h), ("down_proj", h, 704)] {
                quantized(base + "experts.switch_glu." + name, [128, output, input], bits: defaultBits)
            }
            let head = full ? 512 : 256, kv = full ? 2 : 8
            quantized(base + "self_attn.q_proj", [16 * head, h], bits: defaultBits)
            quantized(base + "self_attn.k_proj", [kv * head, h], bits: defaultBits)
            quantized(base + "self_attn.o_proj", [h, 16 * head], bits: defaultBits)
            // Full-attention layers reuse the key projection for values.
            if !full { quantized(base + "self_attn.v_proj", [kv * head, h], bits: defaultBits) }
            for name in ["q_norm", "k_norm"] { tensor(base + "self_attn." + name + ".weight", "BF16", [head]) }
        }
        return result.sorted { $0.name < $1.name }
    }

    @Test func theFixturesAreTheRegisteredMetadata() throws {
        for model in Gemma4RegisteredModel.allCases {
            let spec = try Gemma4RegisteredSpecification.registered(model), files = try Self.files(model)
            #expect(sha256(files.configuration) == spec.configurationSHA256)
            #expect(sha256(files.manifest) == spec.manifestSHA256)
            let manifest = try JSONDecoder().decode(CheckpointManifest.self, from: files.manifest)
            #expect(manifest.aggregate_sha256 == spec.artifactSHA256)
            #expect(manifest.file_count == spec.manifestFileCount && manifest.files.count == spec.manifestFileCount)
            #expect(manifest.total_size_bytes == spec.manifestBytes)
            #expect(manifest.files.reduce(0) { $0 + $1.size_bytes } == spec.manifestBytes)
            #expect(manifest.files.first { $0.path == "config.json" }?.sha256 == spec.configurationSHA256)
            let named = try JSONSerialization.jsonObject(with: files.manifest) as? [String: Any]
            #expect(named?["model_id"] as? String == spec.catalogModelID)
        }
    }

    @Test func catalogIsOneClosedRowPerCatalogEntry() throws {
        let rows = Gemma4RegisteredSpecification.all
        #expect(rows.map(\.model) == Gemma4RegisteredModel.allCases)
        #expect(Set(rows.map(\.manifestSHA256)).count == 3 && Set(rows.map(\.catalogModelID)).count == 3)
        #expect(rows.map(\.catalogModelID) == ["gemma-4-26b-qat-4bit", "gemma-4-26b", "gemma-4-26b-8bit"])
        // One artifact under two IDs: everything but the manifest pin is shared.
        let (a, b) = (rows[1], rows[2])
        #expect(a.configurationSHA256 == b.configurationSHA256 && a.artifactSHA256 == b.artifactSHA256
            && a.inventorySHA256 == b.inventorySHA256 && a.sourceBytes == b.sourceBytes)
        #expect(rows[0].artifactSHA256 != a.artifactSHA256 && rows[0].configurationSHA256 != a.configurationSHA256)
        for model in Gemma4RegisteredModel.allCases {
            let files = try Self.files(model)
            #expect(try Gemma4RegisteredSpecification.registered(configuration: files.configuration,
                                                                 manifest: files.manifest).model == model)
            #expect(try Gemma4RegisteredSpecification.registered(runtimeModelID: model.rawValue).model == model)
        }
        // A manifest of one artifact with the configuration of the other is no row.
        #expect(throws: (any Error).self) {
            try Gemma4RegisteredSpecification.registered(
                configuration: try Self.files(.twentySixB).configuration,
                manifest: try Self.files(.twentySixBQAT4Bit).manifest)
        }
        #expect(throws: (any Error).self) { try Gemma4RegisteredSpecification.registered(runtimeModelID: "gemma-4-26b") }
        #expect(throws: (any Error).self) {
            try Gemma4RegisteredSpecification.registered(runtimeModelID: QwenRegisteredDenseModel.qwen35NineB.rawValue)
        }
    }

    @Test func registeredInventoryFollowsFromTheConfigurationAlone() throws {
        for spec in Gemma4RegisteredSpecification.all {
            let tensors = Self.expectedInventory(defaultBits: spec.defaultQuantizationBits)
            for tensor in tensors { try tensor.validate() }
            #expect(tensors.count == spec.tensorCount)
            #expect(tensors.reduce(0) { $0 + $1.byteCount } == spec.sourceBytes)
            #expect(tensors.map(\.byteCount).max() == spec.largestTensorBytes)
            #expect(QwenDenseProfileIdentity.fingerprint(tensors.map(\.identity)) == spec.inventorySHA256)
        }
    }

    @Test func geometryIsHeldFieldByField() throws {
        for model in [Gemma4RegisteredModel.twentySixBQAT4Bit, .twentySixB] {
            let spec = try Gemma4RegisteredSpecification.registered(model), config = try Self.files(model).configuration
            let decoded = try Gemma4StageGeometry.decode(config, defaultQuantizationBits: spec.defaultQuantizationBits)
            #expect(decoded.quantizationOverrides.count == 120)
            #expect(decoded.quantizationDefaults["bits"] as? Int == spec.defaultQuantizationBits)
            // The other artifact's default bits do not describe this configuration.
            #expect(throws: (any Error).self) {
                try Gemma4StageGeometry.decode(config, defaultQuantizationBits: 12 - spec.defaultQuantizationBits)
            }
            func edited(_ edit: (inout [String: Any], inout [String: Any]) -> Void) throws -> Data {
                var root = try #require(try JSONSerialization.jsonObject(with: config) as? [String: Any])
                var text = try #require(root["text_config"] as? [String: Any])
                edit(&root, &text); root["text_config"] = text
                return try JSONSerialization.data(withJSONObject: root)
            }
            let departures: [(inout [String: Any], inout [String: Any]) -> Void] = [
                { _, text in text["num_hidden_layers"] = 29 },
                { _, text in text["num_kv_shared_layers"] = 4 },
                { _, text in text["hidden_size_per_layer_input"] = 256 },
                { _, text in text["sliding_window"] = 512 },
                { _, text in text["attention_k_eq_v"] = false },
                { _, text in var kinds = text["layer_types"] as! [String]; kinds[4] = "full_attention"; text["layer_types"] = kinds },
                { root, _ in root["tie_word_embeddings"] = false },
                { root, _ in var table = root["quantization"] as! [String: Any]
                    table["language_model.model.layers.0.self_attn.q_proj"] = ["bits": 8, "group_size": 64]
                    root["quantization"] = table },
            ]
            for departure in departures {
                let bytes = try edited(departure)
                #expect(throws: (any Error).self) {
                    try Gemma4StageGeometry.decode(bytes, defaultQuantizationBits: spec.defaultQuantizationBits)
                }
            }
        }
    }

    @Test func planKeepsEachLayersOwnKindAtEveryRegisteredCut() throws {
        var fingerprints = Set<String>()
        for model in [Gemma4RegisteredModel.twentySixBQAT4Bit, .twentySixB] {
            let spec = try Gemma4RegisteredSpecification.registered(model), config = try Self.files(model).configuration
            let names = Self.expectedInventory(defaultBits: spec.defaultQuantizationBits)
            let bytes = Dictionary(uniqueKeysWithValues: names.map { ($0.name, $0.byteCount) })
            for cut in Gemma4LayerStagePlanning.supportedCuts {
                let plan = try Gemma4LayerStagePlanning.plan(specification: spec, configuration: config, cut: cut)
                #expect(fingerprints.insert(plan.fingerprint).inserted)
                #expect(plan.layers == 30 && plan.stages.count == 2 && plan.originalConfiguration == config)
                #expect(plan.stages.map(\.sourceRange) == [0..<cut, cut..<30])
                #expect(plan.stages[0].fingerprint != plan.stages[1].fingerprint)
                for stage in plan.stages {
                    #expect(stage.inertModules.isEmpty)
                    #expect(stage.layers.map(\.globalIndex) == Array(stage.sourceRange))
                    #expect(stage.layers.map(\.localIndex) == Array(0..<stage.sourceRange.count))
                    // Global indices 5, 11, 17, 23 and 29 are full attention wherever the stage starts.
                    #expect(stage.layers.allSatisfy { $0.kind == (($0.globalIndex + 1) % 6 == 0 ? "full_attention" : "sliding_attention") })
                    #expect(stage.quantizationMappings.count == 4 * stage.sourceRange.count)
                    #expect(stage.quantizationMappings.count + stage.excludedQuantizationPaths.count == 120)
                    let descriptor = try #require(try JSONSerialization.jsonObject(with: stage.constructionConfiguration) as? [String: Any])
                    let text = try #require(descriptor["text_config"] as? [String: Any])
                    #expect(text["num_hidden_layers"] as? Int == stage.sourceRange.count)
                    #expect(text["vocab_size"] as? Int == 262_144 && text["hidden_size"] as? Int == 2816)
                }
                let mapped = try Gemma4LayerStagePlanning.parameters(plan: plan, canonicalSourceNames: names.map(\.name))
                // 1,339 tensors, the tied embedding's three on both ranks.
                #expect(mapped.count == 1342 && Set(mapped.map(\.sourceName)).count == 1339)
                #expect(mapped.filter { $0.sourceName.hasPrefix("language_model.model.embed_tokens.") }.count == 6)
                #expect(mapped.filter { $0.sourceName == "language_model.model.norm.weight" }.map(\.stage) == [1])
                #expect(mapped.allSatisfy { parameter in
                    plan.stages[parameter.stage].activeModuleRoots.contains { parameter.localName.hasPrefix($0 + ".") }
                })
                let rank = (0...1).map { stage in mapped.filter { $0.stage == stage }.reduce(0) { $0 + bytes[$1.sourceName]! } }
                #expect(rank[0] + rank[1] == spec.sourceBytes + (model == .twentySixBQAT4Bit ? 415_236_096 : 784_334_848))
                if model == .twentySixBQAT4Bit, cut == 12 { #expect(rank == [6_036_214_808, 8_846_709_796]) }
                if model == .twentySixBQAT4Bit, cut == 15 { #expect(rank == [7_437_403_934, 7_445_520_670]) }
                // The Qwen mapping does not answer for a Gemma plan.
                #expect(throws: (any Error).self) { try plan.parameters(canonicalSourceNames: names.map(\.name)) }
            }
            for cut in [0, 1, 5, 7, 29, 30] {
                #expect(throws: (any Error).self) {
                    try Gemma4LayerStagePlanning.plan(specification: spec, configuration: config, cut: cut)
                }
            }
            // An unowned or malformed tensor name is an error, never a skip.
            let plan = try Gemma4LayerStagePlanning.plan(specification: spec, configuration: config, cut: 12)
            for name in ["vision_tower.encoder.weight", "language_model.model.layers.30.layer_scalar",
                         "language_model.lm_head.weight"] {
                #expect(throws: (any Error).self) {
                    try Gemma4LayerStagePlanning.parameters(plan: plan, canonicalSourceNames: [name])
                }
            }
        }
        // Two catalog entries of one artifact plan identically.
        let a = try Gemma4LayerStagePlanning.plan(specification: .registered(.twentySixB),
            configuration: try Self.files(.twentySixB).configuration, cut: 12)
        let b = try Gemma4LayerStagePlanning.plan(specification: .registered(.twentySixB8Bit),
            configuration: try Self.files(.twentySixB8Bit).configuration, cut: 12)
        #expect(a.fingerprint == b.fingerprint)
    }

    @Test func registeredMetadataAdmitsOnBothRanks() throws {
        for model in Gemma4RegisteredModel.allCases {
            let identity = try Self.identity(model)
            let ranks = try (0...1).map { try Self.admit(model, rank: $0, cut: 10, identity: identity) }
            #expect(ranks[0].plan.fingerprint == ranks[1].plan.fingerprint)
            #expect(ranks[0].arithmeticSHA256 == ranks[1].arithmeticSHA256)
            #expect(ranks[0].arithmeticContract == Gemma4ArithmeticEnvironment.contract)
            #expect(ranks[0].profile.identifier == model.rawValue + "_greedy_generation_v1")
            #expect(ranks[0].profile.vocabularySize == 262_144 && ranks[0].profile.hiddenSize == 2816)
            #expect(ranks[0].profile.maximumPromptTokens == 8192 && ranks[0].profile.maximumContextTokens == 8320)
            // The residual crosses in the activation dtype; the logits row is float32, as in the product.
            #expect(ranks[0].profile.activationDType == "bfloat16" && ranks[0].profile.selectedRowDType == "float32")
            #expect(ranks[0].jaccl.rank == 0 && ranks[1].jaccl.rank == 1)
            // The family seam selects this admission for a Gemma identity and no other.
            let selected = try LayerStageResidentFamily.admission(configuration: ranks[0].configuration,
                configBytes: ranks[0].configBytes, manifestBytes: ranks[0].manifestBytes,
                environment: Self.environment(), now: Self.now, read: { _, _ in Self.matrix })
            #expect(selected is Gemma4ResidentAdmission && selected.plan.fingerprint == ranks[0].plan.fingerprint)
        }
    }

    @Test func admissionRefusesEachDepartureFromTheClosedIdentity() throws {
        let model = Gemma4RegisteredModel.twentySixBQAT4Bit
        func refuses(_ label: Comment, _ body: () throws -> Gemma4ResidentAdmission) {
            #expect(throws: (any Error).self, label) { _ = try body() }
        }
        _ = try Self.admit(model)
        refuses("a Qwen model ID") { try Self.admit(model, identity: Self.identity(model, modelID: "registered_qwen35_9b")) }
        refuses("a catalog ID instead of a runtime ID") { try Self.admit(model, identity: Self.identity(model, modelID: "gemma-4-26b-qat-4bit")) }
        refuses("the other artifact's ID") { try Self.admit(model, identity: Self.identity(model, modelID: Gemma4RegisteredModel.twentySixB.rawValue)) }
        refuses("another artifact hash") { try Self.admit(model, identity: Self.identity(model, artifactSHA: String(repeating: "0", count: 64))) }
        refuses("another configuration hash") { try Self.admit(model, identity: Self.identity(model, configSHA: String(repeating: "0", count: 64))) }
        refuses("a cut outside the row") { try Self.admit(model, cut: 7) }
        refuses("rank 2") { try Self.admit(model, rank: 2) }
        refuses("the other artifact's manifest") { try Self.admit(model, manifest: Self.files(.twentySixB).manifest) }
        refuses("the other artifact's configuration") { try Self.admit(model, config: Self.files(.twentySixB).configuration) }
        refuses("a lifetime over 300 s") { try Self.admit(model, deadline: Self.now + 300_000_000_001) }
        refuses("a deadline in the past") { try Self.admit(model, deadline: Self.now) }
        // One artifact, two manifests: each ID is admitted only with its own.
        refuses("the 8-bit entry with the plain entry's manifest") {
            try Self.admit(.twentySixB8Bit, manifest: Self.files(.twentySixB).manifest)
        }
        refuses("the plain entry with the 8-bit entry's manifest") {
            try Self.admit(.twentySixB, manifest: Self.files(.twentySixB8Bit).manifest)
        }
        for name in Gemma4ArithmeticEnvironment.requiredValues.keys {
            var environment = Self.environment(); environment[name] = nil
            refuses("no \(name)") { try Self.admit(model, environment: environment) }
        }
        for name in Gemma4ArithmeticEnvironment.requiredAbsentNames {
            var environment = Self.environment(); environment[name] = "1"
            refuses("a set \(name)") { try Self.admit(model, environment: environment) }
        }
        var wrongValue = Self.environment(); wrongValue["MLX_GATHER_QMM_EXPERT_SLICES"] = "1"
        refuses("the drained expert route") { try Self.admit(model, environment: wrongValue) }
        var wrongRank = Self.environment(); wrongRank["JACCL_RANK"] = "1"
        refuses("a rank that differs from JACCL's") { try Self.admit(model, rank: 0, environment: wrongRank) }
    }

    @Test func requestAdmissionIsTheProfilesOwn() throws {
        let admission = try Self.admit(.twentySixBQAT4Bit)
        func reservation(profile: String? = nil, prompt: Int = 16, output: Int = 4, chunk: Int = 8,
                         token: Int = 262_143, stops: [Int] = [1, 106]) -> ClusterWorkerReservation {
            .init(profileID: profile ?? admission.profile.identifier, promptTokenIDs: Array(repeating: token, count: prompt),
                stopTokenIDs: stops, outputCount: output, chunkSize: chunk,
                deadlineUptimeNanoseconds: Self.now + 1_000_000_000, capacityLimitBytes: 1)
        }
        let request = try admission.request(reservation(), id: UUID(), now: Self.now)
        #expect(request.promptCount == 16 && request.maximumTokens == 20)
        #expect(throws: (any Error).self) {
            try admission.request(reservation(profile: QwenResidentAdapterDefinition.profileID), id: UUID(), now: Self.now)
        }
        #expect(throws: (any Error).self) { try admission.request(reservation(prompt: 8193), id: UUID(), now: Self.now) }
        #expect(throws: (any Error).self) { try admission.request(reservation(output: 129), id: UUID(), now: Self.now) }
        #expect(throws: (any Error).self) { try admission.request(reservation(chunk: 513), id: UUID(), now: Self.now) }
        #expect(throws: (any Error).self) { try admission.request(reservation(stops: [106, 1]), id: UUID(), now: Self.now) }
    }

    @Test func ceilingsAndStateLedgerBelongToTheGeometry() throws {
        for spec in Gemma4RegisteredSpecification.all {
            let ceilings = try Gemma4ResidentResourceCeilings(specification: spec)
            #expect(ceilings.maximumManifestPayloadBytes == spec.manifestBytes)
            #expect(ceilings.maximumNamedStateBytes == 719_380_600 && ceilings.namedStateByteCeiling == 719_380_600)
        }
        let largest = try Gemma4StateBudget.estimate(maximumTokens: 8320, chunkSize: 512)
        #expect(largest.fullLayers == 5 && largest.slidingLayers == 25)
        #expect(largest.fullKVBytes == 8320 * 2 * 512 * 2 && largest.ringKVBytes == 1024 * 8 * 256 * 2)
        #expect(largest.slidingViewKVBytes == 1535 * 8 * 256 * 2)
        // Rounding every array up never lowers the charge, and nothing is fused.
        let allowance = try largest.allowance(bound: { ($0 + 16_383) / 16_384 * 16_384 })
        #expect(allowance.fusionBytes == 0 && allowance.reservedBytes == allowance.stateBytes)
        #expect(allowance.stateBytes >= largest.stateAndBoundaryBytes)
        #expect(throws: (any Error).self) { try Gemma4StateBudget.estimate(maximumTokens: 8320, chunkSize: 513) }
        let small = try Gemma4StateBudget.estimate(maximumTokens: 62, chunkSize: 30)
        #expect(small.stateAndBoundaryBytes < largest.stateAndBoundaryBytes)
    }

    @Test func onlyTheLastLayerOfTheOutputRankNarrowsAPromptChunk() {
        typealias Policy = Gemma4StagePromptPolicy
        func decide(_ layer: Int, prefill: Bool = true, owns: Bool = true, length: Int = 512,
                    lastQuery: Bool = true) -> Policy.Decision {
            Policy.decide(globalLayerIndex: layer, prefill: prefill, ownsFinalOutput: owns, batchSize: 1,
                          sequenceLength: length, cacheSupportsLastQuery: lastQuery)
        }
        let whole = Policy.Decision(outputTailRows: nil, useLastQuery: false)
        #expect(decide(29) == .init(outputTailRows: 1, useLastQuery: true))
        #expect(decide(29, length: 128) == .init(outputTailRows: 1, useLastQuery: true))
        // Below the product's minimum chunk the last layer keeps every row.
        #expect(decide(29, length: 127) == whole && decide(29, length: 1) == whole)
        #expect(decide(29, prefill: false) == whole)
        // Rank 0 never narrows: its rows are the residual it sends.
        #expect(decide(29, owns: false) == whole)
        #expect((0..<29).allSatisfy { decide($0) == whole && decide($0, owns: false) == whole })
        // A cache that cannot commit full keys and values for one query narrows after attention.
        #expect(decide(29, lastQuery: false) == .init(outputTailRows: 1, useLastQuery: false))
    }

    @Test func aStagesStateIsOneRowPerLayerAndNoRecurrentState() throws {
        func kinds(_ range: Range<Int>) -> [CBv2LayerKind] {
            range.enumerated().map { local, global in
                let full = (global + 1) % 6 == 0
                return CBv2LayerKind(attention: full ? .full : .slidingWindow(1024), headDim: full ? 512 : 256,
                    kvHeads: full ? 2 : 8, queryHeads: 16, modelLayerIndex: local)
            }
        }
        let geometry = try CBv2RequestGeometry(gemma4StageKinds: kinds(8..<30), kvDType: .bfloat16, maximumTokens: 8320)
        #expect(geometry.kinds.count == 22 && geometry.caches.count == 22 && geometry.recurrent.layers.isEmpty)
        // Four full layers at capacity and eighteen rings, keys and values.
        #expect(geometry.kvCapacityBytes == 4 * 2 * 8320 * 2 * 512 * 2 + 18 * 2 * 1024 * 8 * 256 * 2)
        #expect(geometry.kinds[3].retainedTokens(atFrontier: 5000) == 5000)
        #expect(geometry.kinds[0].retainedTokens(atFrontier: 5000) == 1024)
        #expect(geometry.kinds[0].retainedTokens(atFrontier: 30) == 30)
        // Kinds keyed by anything but the stage's own storage index are refused.
        var global = kinds(8..<30); global[0].modelLayerIndex = 8
        #expect(throws: (any Error).self) {
            try CBv2RequestGeometry(gemma4StageKinds: global, kvDType: .bfloat16, maximumTokens: 8320)
        }
        var window = kinds(0..<6); window[0].attention = .slidingWindow(512)
        #expect(throws: (any Error).self) {
            try CBv2RequestGeometry(gemma4StageKinds: window, kvDType: .bfloat16, maximumTokens: 8320)
        }
        // A request state with no recurrent layer binds, evaluates and commits nothing.
        let recurrent = try CBv2RecurrentRequestState(spec: geometry.recurrent)
        let evaluation = try recurrent.bind()
        #expect(try evaluation.evaluate().isEmpty)
        try evaluation.commit()
        #expect(recurrent.confirmedStateSnapshot() == nil && recurrent.materializedByteCount == 0)
        try recurrent.release()
    }

    @Test func everyFamilysRowsAreListedOnceAndQwenRowsAreUnchanged() throws {
        let all = RegisteredResidentModels.all
        let qwen = QwenResidentCapabilityMetadata.registeredModels
        // The Qwen catalog first, exactly as it lists itself; then the three Gemma rows.
        #expect(Array(all.prefix(qwen.count)) == qwen)
        #expect(all.dropFirst(qwen.count).map(\.runtimeModelID)
            == ["registered_gemma4_26b_qat_4bit", "registered_gemma4_26b", "registered_gemma4_26b_8bit"])
        #expect(Set(all.map(\.runtimeModelID)).count == all.count && Set(all.map(\.manifestSHA256)).count == all.count)
        for model in all.suffix(3) {
            #expect(model.layerCount == 30 && model.supportedCuts == [6, 8, 10, 12, 15, 18, 24])
            #expect(model.supportedGenerationModes == [.pipeline])
            #expect(model.supportedPrefillSchedules == [.serial, .oneChunkLookahead])
            #expect(model.profileID == model.runtimeModelID + "_greedy_generation_v1")
            #expect(model.requiredArithmeticEnvironment == Gemma4ArithmeticEnvironment.requiredValues)
            #expect(RegisteredResidentModels.registeredModel(runtimeModelID: model.runtimeModelID) == model)
        }
        #expect(RegisteredResidentModels.registeredModel(runtimeModelID: "gemma-4-26b") == nil)
        #expect(RegisteredResidentModels.registeredCutsUsage.split(separator: "\n").count == all.count)
        // A Qwen artifact still selects its Qwen row, by configuration, as before.
        for (name, id) in [("qwen35-9b", "registered_qwen35_9b"), ("qwen38-27b", "registered_qwen38_27b")] {
            let row = try RegisteredResidentModels.identity(configuration: try Self.fixture(name, "configuration"),
                                                            manifest: try Self.fixture(name, "manifest"))
            #expect(row.runtimeModelID == id)
            #expect(try RegisteredResidentModels.registeredModel(configuration: try Self.fixture(name, "configuration"),
                manifest: try Self.fixture(name, "manifest")).runtimeModelID == id)
        }
        let files = try Self.files(.twentySixB8Bit)
        #expect(try RegisteredResidentModels.registeredModel(configuration: files.configuration,
            manifest: files.manifest).runtimeModelID == "registered_gemma4_26b_8bit")
    }
}
