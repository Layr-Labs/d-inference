import Foundation
import DarkbloomClusterProtocol
import Testing
@testable import DarkbloomClusterRuntime

// The registered Qwen3.5 35B A3B: the first resident model whose layers carry
// routed experts. Like the 9B and 27B suites this reads only the registered
// configuration and manifest metadata (byte-exact copies of the artifact's
// `config.json` and of its catalog manifest), never weights. The tensor
// inventory is rebuilt here from the registered geometry alone; that it hashes
// to the specification's pin is what makes it the artifact's inventory. Loading
// the model and running a request are real runs, recorded in the handoff.

@Suite("Resident admission contract, registered 35B A3B (registered metadata, no model)")
struct ResidentAdmissionA3BTests {
    private static let now: UInt64 = 1_000
    private static let matrix = Data(#"[[null,"tb5-a"],["tb5-b",null]]"#.utf8)
    private static let cuts = Array(stride(from: 4, through: 36, by: 4))
    private static let modelID = "registered_qwen35_35b_a3b"
    private static let profileID = "registered_qwen35_35b_a3b_greedy_generation_v1"

    private static func fixture(_ model: String, _ name: String) throws -> Data {
        // Tests/DarkbloomClusterRuntimeTests -> libs, then the worker's fixtures.
        let libraries = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: libraries.appendingPathComponent(
            "darkbloom-cluster-worker/Tests/CapabilityChecks/Fixtures/registered-\(model).\(name).json"))
    }
    private static func fixture(_ name: String) throws -> Data { try fixture("qwen35-35b-a3b", name) }

    private static func denseEnvironment(rank: Int = 0) -> [String: String] {
        ["DARKBLOOM_CBV2_ATTN_QUERY_BLOCK": "128", "DARKBLOOM_BF16_WEIGHTS": "1", "MLX_ENABLE_TF32": "1",
         "JACCL_RANK": String(rank), "JACCL_IBV_DEVICES": "/opt/cluster/matrix.json",
         "JACCL_COORDINATOR": "10.0.0.5:4499"]
    }
    private static func environment(rank: Int = 0) -> [String: String] {
        denseEnvironment(rank: rank).merging(["MLX_GATHER_QMM_EXPERT_SLICES": "trust"]) { $1 }
    }

    private static func specification(_ model: QwenRegisteredDenseModel = .qwen35ThirtyFiveBA3B) throws -> QwenDenseRegisteredSpecification {
        try #require(QwenDenseRegisteredSpecification.all.first { $0.model == model })
    }

    private static func identity(epoch: UUID = UUID(), model: String = modelID,
                                 configSHA: String? = nil, artifactSHA: String? = nil) throws -> ClusterWorkerIdentity {
        let spec = try specification()
        return ClusterWorkerIdentity(membershipEpoch: epoch, modelID: model,
            artifactSHA256: artifactSHA ?? spec.artifactSHA256,
            configurationSHA256: configSHA ?? spec.configurationSHA256,
            peers: [ClusterWorkerPeer(id: "peer-a", buildSHA256: String(repeating: "a", count: 64)),
                    ClusterWorkerPeer(id: "peer-b", buildSHA256: String(repeating: "b", count: 64))])
    }

    private static func configuration(rank: Int = 0, cut: Int = 20,
                                      schedule: ClusterPrefillSchedule = .serial,
                                      identity: ClusterWorkerIdentity) -> QwenResidentLoadConfiguration {
        QwenResidentLoadConfiguration(identity: identity,
            modelDirectory: URL(fileURLWithPath: "/tmp"), rank: rank, stageCut: cut,
            deadlineUptimeNanoseconds: now + 300_000_000_000, prefillSchedule: schedule)
    }

    private static func admit(_ configuration: QwenResidentLoadConfiguration,
                              config: Data? = nil, manifest: Data? = nil,
                              environment: [String: String]? = nil) throws -> QwenResidentAdmission {
        try QwenResidentAdmission(configuration: configuration,
            configBytes: try config ?? fixture("configuration"),
            manifestBytes: try manifest ?? fixture("manifest"),
            environment: environment ?? Self.environment(rank: configuration.rank),
            now: now, read: { _, _ in matrix })
    }

    private static func canonicalTensors() -> [QwenDenseCanonicalTensor] {
        RoutedExpertInventoryFixture.canonicalTensors(routerBits: 4, decayDType: "F32")
    }

    @Test func theFixturesAreTheRegisteredMetadata() throws {
        let spec = try Self.specification()
        #expect(sha256(try Self.fixture("configuration")) == spec.configurationSHA256)
        #expect(sha256(try Self.fixture("manifest")) == spec.manifestSHA256)
        struct Manifest: Decodable {
            let aggregate_sha256: String, file_count: Int, total_size_bytes: Int, model_id: String, version: String
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: try Self.fixture("manifest"))
        #expect(manifest.aggregate_sha256 == spec.artifactSHA256)
        #expect(manifest.file_count == 14 && manifest.total_size_bytes == 20_893_747_852)
        #expect(manifest.model_id == "qwen3.5-35b-a3b" && manifest.version == "2026-08-25-r1")
    }

    @Test func definitionIsItsOwnClosedRow() throws {
        let row = try QwenResidentModelDefinition(model: .qwen35ThirtyFiveBA3B)
        #expect(row.profileID == Self.profileID && row.specification.layers == 40 && row.supportedCuts == Self.cuts)
        #expect(row.supportedPrefillSchedules == [.serial, .oneChunkLookahead])
        #expect(row.supportedGenerationModes == [.pipeline, .pipelineCompactDecode, .phaseSplit])
        #expect(row.adapter == .qwen35RoutedExperts && row.arithmetic == .routedExperts)
        #expect(row.specification.kvHeads == 2 && row.specification.rootModelType == "qwen3_5_moe")
        #expect(row.specification.routedExperts == .init(experts: 256, expertsPerToken: 8,
                                                         expertIntermediate: 512, sharedIntermediate: 512))
        #expect(try QwenResidentModelDefinition(runtimeModelID: Self.modelID).specification.model == .qwen35ThirtyFiveBA3B)
        #expect(try QwenResidentModelDefinition(configuration: Self.fixture("configuration")).specification.model == .qwen35ThirtyFiveBA3B)
        for unknown in ["qwen3.5-35b-a3b", "registered_qwen35_35b_a3b ", "registered_qwen35_35b_a3b_v2", "registered_qwen35_35b"] {
            #expect(throws: (any Error).self, "model ID \(unknown.debugDescription)") {
                _ = try QwenResidentModelDefinition(runtimeModelID: unknown)
            }
        }
        let profile = try QwenResidentAdapterDefinition.profile(specification: row.specification)
        #expect(profile.identifier == Self.profileID && profile.hiddenSize == 2048)
        #expect(profile.vocabularySize == 248_320 && profile.activationDType == "bfloat16")
        #expect(profile.maximumPromptTokens == 8192 && profile.maximumChunkTokens == 512)
        #expect(profile.maximumOutputTokens == 128 && profile.maximumContextTokens == 8320)
        // The dense rows keep what they had: adapter, arithmetic, geometry constants.
        for dense in [QwenRegisteredDenseModel.qwen35NineB, .qwen38TwentySevenB] {
            let definition = try QwenResidentModelDefinition(model: dense)
            #expect(definition.adapter == .qwen35Dense && definition.arithmetic == .dense)
            #expect(definition.specification.kvHeads == 4 && definition.specification.routedExperts == nil)
            #expect(definition.specification.rootModelType == "qwen3_5")
        }
        #expect(try QwenResidentModelDefinition(model: .qwen35NineB).supportedCuts == [4, 8, 12, 16])
    }

    @Test func ceilingsAreTheModelsOwn() throws {
        let spec = try Self.specification()
        let ceilings = try QwenResidentResourceCeilings(model: .qwen35ThirtyFiveBA3B)
        #expect(ceilings.maximumManifestPayloadBytes == 20_893_747_852)
        #expect(ceilings.namedStateByteCeiling == 563_806_248 && ceilings.maximumNamedStateBytes == 563_806_248)
        let geometry = try spec.expectedGeometry()
        #expect(geometry.kvHeads == 2 && geometry.layers == 40 && geometry.hiddenSize == 2048)
        #expect(try QwenLongPrefillTensorBudget.estimate(geometry: geometry, maximumTokens: 8193, chunkSize: 512)
            .conservativeStateAndBoundaryBytes == spec.namedStateBytes)
        // The other rows are untouched by this one.
        #expect(try QwenResidentResourceCeilings(model: .qwen35NineB).maximumNamedStateBytes == 754_188_320)
        #expect(try QwenResidentResourceCeilings(model: .qwen35NineB).maximumManifestPayloadBytes == 8 * 1024 * 1024 * 1024)
        #expect(try QwenResidentResourceCeilings(model: .qwen38TwentySevenB).maximumNamedStateBytes == 1_616_248_896)
        #expect(try QwenResidentResourceCeilings(model: .qwen38TwentySevenB).maximumManifestPayloadBytes == 16_320_415_757)
    }

    @Test func theRegisteredInventoryIsTheGeometrysTensorSet() throws {
        let spec = try Self.specification()
        let tensors = Self.canonicalTensors()
        #expect(tensors.count == 1637 && tensors.count == spec.tensorCount)
        #expect(tensors.map(\.byteCount).reduce(0, +) == 19_498_262_656)
        #expect(tensors.map(\.byteCount).max() == 268_435_456)
        let profile = try QwenRegisteredDenseModelProfile.admit(configuration: try Self.fixture("configuration"),
            manifest: try Self.fixture("manifest"), expectedArtifactAggregateSHA256: spec.artifactSHA256,
            canonicalTensors: tensors)
        #expect(profile.model == .qwen35ThirtyFiveBA3B && profile.canonicalInventorySHA256 == spec.inventorySHA256)
        // One renamed, resized or retyped tensor is another inventory.
        var renamed = tensors
        renamed[10] = .init(name: renamed[10].name + "x", shape: renamed[10].shape,
                            sourceDType: renamed[10].sourceDType, byteCount: renamed[10].byteCount)
        #expect(throws: (any Error).self) {
            _ = try QwenRegisteredDenseModelProfile.admit(configuration: try Self.fixture("configuration"),
                manifest: try Self.fixture("manifest"), expectedArtifactAggregateSHA256: spec.artifactSHA256,
                canonicalTensors: renamed)
        }
        // The stored, unfused halves are not the canonical inventory.
        let split = tensors.flatMap { tensor -> [QwenDenseCanonicalTensor] in
            guard tensor.name.contains(".switch_mlp.gate_up_proj.") else { return [tensor] }
            var shape = tensor.shape; shape[1] /= 2
            return ["gate_proj", "up_proj"].map {
                .init(name: tensor.name.replacingOccurrences(of: "gate_up_proj", with: $0), shape: shape,
                      sourceDType: tensor.sourceDType, byteCount: tensor.byteCount / 2)
            }
        }
        #expect(split.count == 1757)
        #expect(throws: (any Error).self) {
            _ = try QwenRegisteredDenseModelProfile.admit(configuration: try Self.fixture("configuration"),
                manifest: try Self.fixture("manifest"), expectedArtifactAggregateSHA256: spec.artifactSHA256,
                canonicalTensors: split)
        }
    }

    /// Every cut conserves the registered bytes and names between two stages,
    /// and a layer's routed experts go with the layer.
    @Test func everyCutConservesTheInventoryBetweenItsStages() throws {
        let spec = try Self.specification()
        let profile = try QwenRegisteredDenseModelProfile.admit(configuration: try Self.fixture("configuration"),
            manifest: try Self.fixture("manifest"), expectedArtifactAggregateSHA256: spec.artifactSHA256,
            canonicalTensors: Self.canonicalTensors())
        let linearLayer = 474_072_640, fullLayer = 470_395_008, ends = 286_064_640
        for cut in Self.cuts {
            let plan = try profile.makePlanningPlan(stageCut: cut)
            let pair = try QwenDenseStorageRequirement.derive(profile: profile, plan: plan, role: .sequentialPair)
            #expect(pair.stages.map(\.activeBytes).reduce(0, +) == spec.sourceBytes)
            #expect(pair.stages.map(\.canonicalCount).reduce(0, +) == 1637)
            // Stage 0: the embedding and `cut` layers; stage 1: the rest, the norm and the head.
            let lower = ends + (cut / 4) * (3 * linearLayer + fullLayer)
            #expect(pair.stages[0].activeBytes == lower)
            #expect(pair.stages[1].activeBytes == spec.sourceBytes - lower)
            #expect(pair.stages.allSatisfy { $0.largestHostTensorBytes == 268_435_456 })
            // The request-time fusion is the recurrent layers' four projections only.
            #expect(pair.stages[0].fusionReplacementBytes == (cut / 4) * 3 * 14_229_504)
            let mappings = try plan.parameters(canonicalSourceNames: profile.canonicalTensors.map(\.name))
            for mapping in mappings where mapping.sourceName.contains(".mlp.") {
                let layer = try #require(Int(mapping.sourceName.split(separator: ".")[3]))
                #expect(mapping.stage == (layer < cut ? 0 : 1))
                #expect(mapping.localName.contains(".layers.\(layer < cut ? layer : layer - cut).mlp."))
            }
        }
        #expect(throws: (any Error).self, "cut 2 is inside an attention interval") {
            _ = try profile.makePlanningPlan(stageCut: 2)
        }
        #expect(throws: (any Error).self, "cut 40 leaves stage 1 empty") { _ = try profile.makePlanningPlan(stageCut: 40) }
    }

    @Test func registeredMetadataAdmitsOnBothRanksWithOneAgreement() throws {
        let epoch = UUID()
        let leader = try Self.admit(Self.configuration(rank: 0, identity: try Self.identity(epoch: epoch)))
        let follower = try Self.admit(Self.configuration(rank: 1, identity: try Self.identity(epoch: epoch)))
        #expect(leader.jaccl.rank == 0 && follower.jaccl.rank == 1)
        #expect(leader.specification.model == .qwen35ThirtyFiveBA3B && leader.wireProfile.id == Self.profileID)
        #expect(leader.profile.hiddenSize == 2048 && leader.plan.stages.map(\.sourceRange) == [0..<20, 20..<40])
        #expect(leader.arithmetic.contract == "qwen_cbv2_query128_bf16_tf32_expert_tiles_v1")
        #expect(leader.arithmetic.requiredValues["MLX_GATHER_QMM_EXPERT_SLICES"] == "trust")
        #expect(leader.arithmetic.requiredAbsentNames.contains("MLX_QWEN_DIRECT_EXPERT_REDUCTION"))
        let agreed = try leader.loadAgreementFingerprint()
        #expect(try follower.loadAgreementFingerprint() == agreed)
        #expect(try Self.admit(Self.configuration(cut: 16, identity: try Self.identity(epoch: epoch)))
            .loadAgreementFingerprint() != agreed)
        var plans = Set<String>()
        for cut in Self.cuts { for rank in 0...1 {
            let admission = try Self.admit(Self.configuration(rank: rank, cut: cut, identity: try Self.identity()))
            #expect(admission.plan.stages.map(\.sourceRange) == [0..<cut, cut..<40])
            plans.insert(admission.plan.fingerprint)
        } }
        #expect(plans.count == Self.cuts.count)
        let reservation = ClusterWorkerReservation(profileID: leader.profile.identifier,
            promptTokenIDs: Array(repeating: 1000, count: 8192), stopTokenIDs: [], outputCount: 128, chunkSize: 512,
            deadlineUptimeNanoseconds: Self.now + 1_000_000, capacityLimitBytes: 1)
        #expect(try leader.request(reservation, id: UUID(), now: Self.now).maximumTokens == 8320)
    }

    @Test func admissionRefusesEachDepartureFromTheClosedIdentity() throws {
        let valid = try Self.identity()
        let small = try Self.specification(.qwen35NineB)
        func refuses(_ label: Comment, _ body: () throws -> QwenResidentAdmission) {
            #expect(throws: (any Error).self, label) { _ = try body() }
        }
        _ = try Self.admit(Self.configuration(identity: valid))
        for cut in [0, 2, 6, 18, 38, 40, 44, -4] {
            refuses("cut \(cut) is not a whole-interval partition of 40 layers") {
                try Self.admit(Self.configuration(cut: cut, identity: valid))
            }
        }
        // The routed experts' own arithmetic contract: the dense environment
        // alone is not enough, and no other value of the route is accepted.
        refuses("the dense arithmetic environment without the expert route") {
            try Self.admit(Self.configuration(identity: valid), environment: Self.denseEnvironment())
        }
        for value in ["1", "0", "", "Trust", "true"] {
            refuses("expert route \(value.debugDescription)") {
                try Self.admit(Self.configuration(identity: valid),
                    environment: Self.environment().merging(["MLX_GATHER_QMM_EXPERT_SLICES": value]) { $1 })
            }
        }
        for value in ["1", "0", ""] {
            refuses("opt-in direct expert reduction present as \(value.debugDescription)") {
                try Self.admit(Self.configuration(identity: valid),
                    environment: Self.environment().merging(["MLX_QWEN_DIRECT_EXPERT_REDUCTION": value]) { $1 })
            }
        }
        var missing = Self.environment()
        missing.removeValue(forKey: "DARKBLOOM_BF16_WEIGHTS")
        refuses("missing common arithmetic binding") {
            try Self.admit(Self.configuration(identity: valid), environment: missing)
        }
        // The model ID is a closed choice and is never crossed with another model's identity.
        refuses("public catalog ID in place of the runtime model ID") {
            try Self.admit(Self.configuration(identity: try Self.identity(model: "qwen3.5-35b-a3b")))
        }
        refuses("the 9B's model ID with this model's hashes and metadata") {
            try Self.admit(Self.configuration(cut: 4, identity: try Self.identity(
                model: QwenRegisteredDenseModel.qwen35NineB.rawValue)))
        }
        refuses("this model's ID with the 9B's identity hashes") {
            try Self.admit(Self.configuration(identity: try Self.identity(
                configSHA: small.configurationSHA256, artifactSHA: small.artifactSHA256)))
        }
        refuses("this model's identity over the 9B's configuration and manifest") {
            try Self.admit(Self.configuration(cut: 4, identity: valid),
                config: try Self.fixture("qwen35-9b", "configuration"), manifest: try Self.fixture("qwen35-9b", "manifest"))
        }
        refuses("this model's configuration with the 27B's manifest") {
            try Self.admit(Self.configuration(identity: valid), manifest: try Self.fixture("qwen38-27b", "manifest"))
        }
        var altered = try Self.fixture("configuration")
        altered[altered.count / 2] ^= 1
        refuses("one flipped configuration bit") { try Self.admit(Self.configuration(identity: valid), config: altered) }
        var alteredManifest = try Self.fixture("manifest")
        alteredManifest[alteredManifest.count / 2] ^= 1
        refuses("one flipped manifest bit") { try Self.admit(Self.configuration(identity: valid), manifest: alteredManifest) }
        refuses("JACCL rank differs from the configured rank") {
            try Self.admit(Self.configuration(rank: 0, identity: valid), environment: Self.environment(rank: 1))
        }
        // A dense model is not admitted under the routed experts' environment
        // by accident of an extra variable, nor refused by it: its contract
        // does not name the route. And this model's cuts stay closed to the 9B.
        let nine = ClusterWorkerIdentity(membershipEpoch: UUID(), modelID: QwenRegisteredDenseModel.qwen35NineB.rawValue,
            artifactSHA256: small.artifactSHA256, configurationSHA256: small.configurationSHA256, peers: valid.peers)
        let dense = try QwenResidentAdmission(configuration: Self.configuration(cut: 8, identity: nine),
            configBytes: try Self.fixture("qwen35-9b", "configuration"), manifestBytes: try Self.fixture("qwen35-9b", "manifest"),
            environment: Self.denseEnvironment(), now: Self.now, read: { _, _ in Self.matrix })
        #expect(dense.arithmetic.contract == "qwen_cbv2_query128_bf16_tf32_default_v1")
        #expect(dense.arithmetic.requiredValues.count == 3 && dense.arithmetic.requiredAbsentNames.count == 2)
        #expect(throws: (any Error).self, "cut 20 on the 9B") {
            _ = try QwenResidentAdmission(configuration: Self.configuration(cut: 20, identity: nine),
                configBytes: try Self.fixture("qwen35-9b", "configuration"), manifestBytes: try Self.fixture("qwen35-9b", "manifest"),
                environment: Self.denseEnvironment(), now: Self.now, read: { _, _ in Self.matrix })
        }
    }

    /// The stage configurations the loader constructs from: each stage keeps
    /// its own layers' routed experts and the artifact's quantization policy.
    @Test func stageConstructionKeepsTheRoutedExpertsOfItsOwnLayers() throws {
        let admission = try Self.admit(Self.configuration(cut: 12, identity: try Self.identity()))
        for (stage, count) in zip(admission.plan.stages, [12, 28]) {
            let root = try #require(try JSONSerialization.jsonObject(with: stage.constructionConfiguration) as? [String: Any])
            let text = try #require(root["text_config"] as? [String: Any])
            #expect(root["model_type"] as? String == "qwen3_5_moe" && text["model_type"] as? String == "qwen3_5_moe_text")
            #expect(text["num_hidden_layers"] as? Int == count && (text["layer_types"] as? [String])?.count == count)
            #expect(text["num_experts"] as? Int == 256 && text["num_experts_per_tok"] as? Int == 8)
            #expect(text["moe_intermediate_size"] as? Int == 512 && text["shared_expert_intermediate_size"] as? Int == 512)
            #expect(text["mtp_num_hidden_layers"] as? Int == 0)
            #expect((root["mtplx_mtp"] as? [String: Any])?["included"] as? Bool == false)
            let quantization = try #require(root["quantization"] as? [String: Any])
            #expect(quantization["bits"] as? Int == 4 && quantization["group_size"] as? Int == 64)
        }
        #expect(admission.plan.stages[0].inertModules.map(\.path) == ["language_model.model.norm", "language_model.lm_head"])
        #expect(admission.plan.stages[1].inertModules.map(\.path) == ["language_model.model.embed_tokens"])
        // A stored half of the routed bank is not a canonical parameter; the fused tensor is.
        #expect(try admission.plan.parameter(canonicalSourceName: "language_model.model.layers.13.mlp.switch_mlp.gate_up_proj.weight")
            == .init(sourceName: "language_model.model.layers.13.mlp.switch_mlp.gate_up_proj.weight", stage: 1,
                     localName: "language_model.model.layers.1.mlp.switch_mlp.gate_up_proj.weight"))
        #expect(throws: (any Error).self) {
            _ = try admission.plan.parameter(canonicalSourceName: "language_model.model.layers.13.mlp.switch_mlp.gate_proj.weight")
        }
        #expect(throws: (any Error).self, "a dense feed-forward name on a routed-expert layer") {
            _ = try admission.plan.parameter(canonicalSourceName: "language_model.model.layers.13.mlp.gate_proj.weight")
        }
        // Vision and MTP are excluded, never owned by a stage.
        #expect(try admission.plan.parameter(canonicalSourceName: "vision_tower.blocks.0.attn.proj.weight") == nil)
        #expect(try admission.plan.parameter(canonicalSourceName: "mtp.layers.0.mlp.switch_mlp.gate_proj.weight") == nil)
        #expect(QwenRoutedExpertStageMetadata.sourcePartCount(
            canonicalName: "language_model.model.layers.0.mlp.switch_mlp.gate_up_proj.scales") == 2)
        #expect(QwenRoutedExpertStageMetadata.sourcePartCount(
            canonicalName: "language_model.model.layers.0.mlp.switch_mlp.down_proj.scales") == 1)
    }

    /// One departure of the configuration at a time from the routed-expert wrapper.
    @Test func routedExpertMetadataIsAdmittedOnlyAsDeclared() throws {
        let original = try #require(try JSONSerialization.jsonObject(with: try Self.fixture("configuration")) as? [String: Any])
        func plan(root edit: ((inout [String: Any]) -> Void)? = nil, text editText: ((inout [String: Any]) -> Void)? = nil) throws -> QwenLayerStagePlan {
            var root = original
            var text = try #require(root["text_config"] as? [String: Any])
            editText?(&text); root["text_config"] = text; edit?(&root)
            return try QwenLayerStagePlan(configuration: try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]),
                                          ranges: [0..<20, 20..<40])
        }
        _ = try plan()
        func refuses(_ label: Comment, root: ((inout [String: Any]) -> Void)? = nil, text: ((inout [String: Any]) -> Void)? = nil) {
            #expect(throws: (any Error).self, label) { _ = try plan(root: root, text: text) }
        }
        refuses("dense wrapper type over routed-expert sizes", root: { $0["model_type"] = "qwen3_5" })
        refuses("dense text type under the routed-expert wrapper", text: { $0["model_type"] = "qwen3_5_text" })
        refuses("no experts", text: { $0["num_experts"] = 0 })
        refuses("missing experts per token", text: { $0.removeValue(forKey: "num_experts_per_tok") })
        refuses("more experts per token than experts", text: { $0["num_experts_per_tok"] = 257 })
        refuses("a dense width beside the routed experts", text: { $0["intermediate_size"] = 8192 })
        refuses("router logits requested", text: { $0["output_router_logits"] = true })
        refuses("unnormalized top-k routing", text: { $0["norm_topk_prob"] = false })
        refuses("an unknown text key", text: { $0["expert_dropout"] = 0.1 })
        refuses("layers that skip the experts", text: { $0["mlp_only_layers"] = [0] })
        refuses("a non-affine default policy", root: { root in
            for key in ["quantization", "quantization_config"] { root[key] = ["bits": 8, "group_size": 32, "mode": "mxfp8"] }
        })
        refuses("a policy for a stored half the canonical module tree does not have", root: { root in
            for key in ["quantization", "quantization_config"] {
                var policy = root[key] as! [String: Any]
                policy["language_model.model.layers.0.mlp.switch_mlp.gate_proj"] = ["bits": 8, "group_size": 64]
                root[key] = policy
            }
        })
        // An explicit router policy on a canonical module is carried to the stage that owns it.
        let routed = try plan(root: { root in
            for key in ["quantization", "quantization_config"] {
                var policy = root[key] as! [String: Any]
                policy["language_model.model.layers.21.mlp.gate"] = ["bits": 8, "group_size": 64]
                root[key] = policy
            }
        })
        #expect(routed.stages[0].quantizationMappings.isEmpty)
        #expect(routed.stages[1].quantizationMappings.map(\.localPath) == ["language_model.model.layers.1.mlp.gate"])
        // The dense wrapper still refuses routed-expert sizes, with its own words.
        let dense = try #require(try JSONSerialization.jsonObject(with: try Self.fixture("qwen35-9b", "configuration")) as? [String: Any])
        var withExperts = dense
        var text = try #require(withExperts["text_config"] as? [String: Any])
        text["num_experts"] = 256; withExperts["text_config"] = text
        #expect(throws: (any Error).self) {
            _ = try QwenLayerStagePlan(configuration: try JSONSerialization.data(withJSONObject: withExperts, options: [.sortedKeys]),
                                       ranges: [0..<16, 16..<32])
        }
    }

    @Test func capabilityMetadataDescribesTheRoutedExpertAdapter() throws {
        let binary = String(repeating: "1", count: 64)
        let spec = try Self.specification()
        let value = try QwenResidentCapabilityMetadata.describe(configuration: try Self.fixture("configuration"),
            manifest: try Self.fixture("manifest"), runtimeBinarySHA256: binary)
        #expect(value.adapterID == "qwen35-routed-expert-layer-stage" && value.adapterVersion == 1)
        #expect(value.runtimeModelID == Self.modelID && value.profile.id == Self.profileID)
        #expect(value.artifactSHA256 == spec.artifactSHA256 && value.configurationSHA256 == spec.configurationSHA256)
        #expect(value.manifestSHA256 == spec.manifestSHA256)
        #expect(value.arithmeticPolicyID == "qwen_cbv2_query128_bf16_tf32_expert_tiles_v1")
        #expect(value.supportedPrefillSchedules == [.serial, .oneChunkLookahead])
        #expect(value.supportedGenerationModes == [.pipeline, .pipelineCompactDecode, .phaseSplit])
        #expect(value.partitions.map { $0.stages[0].sourceLayerEnd } == Self.cuts)
        for partition in value.partitions {
            #expect(partition.stages.flatMap { Array($0.sourceLayerStart..<$0.sourceLayerEnd) } == Array(0..<40))
        }
        let admission = try Self.admit(Self.configuration(cut: 20, identity: try Self.identity()))
        #expect(value.partitions[4].planSHA256 == admission.plan.fingerprint)
        #expect(value.profileFingerprint == admission.profile.fingerprint)
        #expect(value.arithmeticPolicySHA256 == admission.arithmeticSHA256)
        let encoded = try ClusterRuntimeCapabilityCodec.encode(value)
        #expect(encoded.count < ClusterRuntimeCapabilityCodec.maximumBytes)
        #expect(try ClusterRuntimeCapabilityCodec.decode(encoded) == value)
        // The protocol holds a capability to its adapter's own pairs and policy.
        func edited(_ edit: (inout [String: Any]) -> Void) throws -> Data {
            var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            edit(&object)
            var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
            data.append(10)
            return data
        }
        #expect(try ClusterRuntimeCapabilityCodec.decode(edited { _ in }).runtimeModelID == Self.modelID)
        #expect(throws: (any Error).self, "this model under the dense adapter") {
            _ = try ClusterRuntimeCapabilityCodec.decode(edited { $0["adapterID"] = "qwen35-dense-layer-stage" })
        }
        #expect(throws: (any Error).self, "this model under the dense arithmetic policy") {
            _ = try ClusterRuntimeCapabilityCodec.decode(edited { $0["arithmeticPolicyID"] = "qwen_cbv2_query128_bf16_tf32_default_v1" })
        }
        #expect(throws: (any Error).self, "a dense model under this adapter") {
            _ = try ClusterRuntimeCapabilityCodec.decode(edited { $0["runtimeModelID"] = "registered_qwen35_9b" })
        }
        #expect(throws: (any Error).self, "this model with the 27B's profile") {
            _ = try ClusterRuntimeCapabilityCodec.decode(edited { object in
                var profile = object["profile"] as! [String: Any]
                profile["id"] = "registered_qwen38_27b_greedy_generation_v1"; object["profile"] = profile
            })
        }
        #expect(throws: (any Error).self, "this configuration with the 9B's manifest") {
            _ = try QwenResidentCapabilityMetadata.describe(configuration: try Self.fixture("configuration"),
                manifest: try Self.fixture("qwen35-9b", "manifest"), runtimeBinarySHA256: binary)
        }
        // What a launcher may ask before any load.
        let registered = try #require(QwenResidentCapabilityMetadata.registeredModel(runtimeModelID: Self.modelID))
        #expect(registered.profileID == Self.profileID && registered.supportedCuts == Self.cuts && registered.layerCount == 40)
        #expect(registered.manifestSHA256 == spec.manifestSHA256)
        #expect(registered.requiredArithmeticEnvironment == ["DARKBLOOM_CBV2_ATTN_QUERY_BLOCK": "128",
            "DARKBLOOM_BF16_WEIGHTS": "1", "MLX_ENABLE_TF32": "1", "MLX_GATHER_QMM_EXPERT_SLICES": "trust"])
        #expect(try QwenResidentCapabilityMetadata.registeredModel(configuration: Self.fixture("configuration")) == registered)
    }

    /// Registering this model changed nothing the two dense models are
    /// identified by: Plans, profiles, arithmetic receipts and capability bytes.
    @Test func theDenseModelsKeepTheirIdentities() throws {
        let binary = String(repeating: "1", count: 64)
        let small = try QwenResidentCapabilityMetadata.describe(configuration: try Self.fixture("qwen35-9b", "configuration"),
            manifest: try Self.fixture("qwen35-9b", "manifest"), runtimeBinarySHA256: binary)
        #expect(small.adapterID == "qwen35-dense-layer-stage" && small.runtimeModelID == "registered_qwen35_9b")
        #expect(small.arithmeticPolicyID == "qwen_cbv2_query128_bf16_tf32_default_v1")
        #expect(small.partitions.map(\.planSHA256).first == "67bf0b1bf94f229682df58ae1ae10c758e2a386d66d3e1b68146f5c090f6309f")
        #expect(small.profileFingerprint == "73532005bbf8385dc43db4bdb529bcd5d612af7d1055becbefe721b4be2324ff")
        // The 9B's capability record, byte for byte, apart from the two fields
        // added after the golden was recorded (schedules and generation modes).
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let golden = try ClusterRuntimeCapabilityCodec.decode(Data(contentsOf: package.appendingPathComponent(
            "Tests/CapabilityChecks/Fixtures/registered-qwen35-9b.capability.json")))
        var current = try #require(try JSONSerialization.jsonObject(with: ClusterRuntimeCapabilityCodec.encode(small)) as? [String: Any])
        current["runtimeBinarySHA256"] = golden.runtimeBinarySHA256
        current.removeValue(forKey: "supportedPrefillSchedules"); current.removeValue(forKey: "supportedGenerationModes")
        var legacy = try JSONSerialization.data(withJSONObject: current, options: [.sortedKeys, .withoutEscapingSlashes])
        legacy.append(10)
        #expect(try ClusterRuntimeCapabilityCodec.decode(legacy) == golden)
        #expect(small.arithmeticPolicySHA256 == golden.arithmeticPolicySHA256)
        let large = try QwenResidentCapabilityMetadata.describe(configuration: try Self.fixture("qwen38-27b", "configuration"),
            manifest: try Self.fixture("qwen38-27b", "manifest"), runtimeBinarySHA256: binary)
        #expect(large.adapterID == "qwen35-dense-layer-stage" && large.partitions.count == 15)
        #expect(large.arithmeticPolicySHA256 == small.arithmeticPolicySHA256)
        // The dense receipt is the receipt it always was.
        let dense = try QwenLongPrefillArithmeticEnvironment.admit(QwenLongPrefillArithmeticEnvironment.requiredValues)
        #expect(try QwenResidentArithmeticPolicy.dense.admit(QwenLongPrefillArithmeticEnvironment.requiredValues) == dense)
        #expect(sha256(try canonicalJSONData(dense)) == small.arithmeticPolicySHA256)
        // Every Qwen adapter's pairs are the runtime's Qwen rows, and the other way round.
        // (Gemma 4's adapter has its own rows; RegisteredModelListsTests covers every family.)
        let rows = try QwenRegisteredDenseModel.allCases.map { try QwenResidentModelDefinition(model: $0) }
        let pairs = ClusterRuntimeAdapter.allCases.filter { $0 != .gemma4LayerStage }.flatMap { adapter in
            adapter.registeredProfiles.map { "\(adapter.rawValue)|\($0.runtimeModelID)|\($0.profileID)|\(adapter.arithmeticPolicyID)" }
        }
        #expect(Set(pairs) == Set(rows.map {
            "\($0.adapter.rawValue)|\($0.specification.model.rawValue)|\($0.profileID)|\($0.arithmetic.contract)"
        }) && pairs.count == rows.count)
        #expect(ClusterRuntimeAdapter.qwen35Dense.registeredProfiles.map(\.runtimeModelID)
            == ["registered_qwen35_9b", "registered_qwen38_27b"])
        #expect(QwenResidentCapabilityMetadata.registeredModels.map(\.runtimeModelID) == QwenRegisteredDenseModel.allCases.map(\.rawValue))
        #expect(QwenResidentCapabilityMetadata.registeredCutsUsage.split(separator: "\n").count == rows.count)
    }
}
