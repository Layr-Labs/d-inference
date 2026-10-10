import Foundation
import DarkbloomClusterProtocol
import Testing
@testable import DarkbloomClusterRuntime

// The registered Qwen3.6 35B A3B: the text model of the catalog artifact
// `qwen3.6-35b-a3b-vl-mtp-mxfp8`, registered without its vision tower and with
// its MTP head off. Same geometry as the 35B A3B; what differs is the
// artifact: 8-bit routers declared per module, a bfloat16 recurrent decay, and
// vision and MTP tensors in the same weight files as the text model. This
// reads the artifact's own `config.json` and its catalog manifest only.

@Suite("Resident admission contract, registered Qwen3.6 35B A3B (registered metadata, no model)")
struct ResidentAdmissionQwen36A3BTests {
    private static let now: UInt64 = 1_000
    private static let matrix = Data(#"[[null,"tb5-a"],["tb5-b",null]]"#.utf8)
    private static let cuts = Array(stride(from: 4, through: 36, by: 4))
    private static let modelID = "registered_qwen36_35b_a3b"
    private static let profileID = "registered_qwen36_35b_a3b_greedy_generation_v1"

    private static func fixture(_ model: String, _ name: String) throws -> Data {
        let libraries = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: libraries.appendingPathComponent(
            "darkbloom-cluster-worker/Tests/CapabilityChecks/Fixtures/registered-\(model).\(name).json"))
    }
    private static func fixture(_ name: String) throws -> Data { try fixture("qwen36-35b-a3b", name) }

    private static func environment(rank: Int = 0) -> [String: String] {
        ["DARKBLOOM_CBV2_ATTN_QUERY_BLOCK": "128", "DARKBLOOM_BF16_WEIGHTS": "1", "MLX_ENABLE_TF32": "1",
         "MLX_GATHER_QMM_EXPERT_SLICES": "trust", "JACCL_RANK": String(rank),
         "JACCL_IBV_DEVICES": "/opt/cluster/matrix.json", "JACCL_COORDINATOR": "10.0.0.5:4499"]
    }

    private static func specification(_ model: QwenRegisteredDenseModel = .qwen36ThirtyFiveBA3B) throws -> QwenDenseRegisteredSpecification {
        try #require(QwenDenseRegisteredSpecification.all.first { $0.model == model })
    }

    private static func identity(model: QwenRegisteredDenseModel = .qwen36ThirtyFiveBA3B, id: String? = nil,
                                 epoch: UUID = UUID()) throws -> ClusterWorkerIdentity {
        let spec = try specification(model)
        return ClusterWorkerIdentity(membershipEpoch: epoch, modelID: id ?? model.rawValue,
            artifactSHA256: spec.artifactSHA256, configurationSHA256: spec.configurationSHA256,
            peers: [ClusterWorkerPeer(id: "peer-a", buildSHA256: String(repeating: "a", count: 64)),
                    ClusterWorkerPeer(id: "peer-b", buildSHA256: String(repeating: "b", count: 64))])
    }

    private static func admit(rank: Int = 0, cut: Int = 20, identity: ClusterWorkerIdentity,
                              files: String = "qwen36-35b-a3b") throws -> QwenResidentAdmission {
        try QwenResidentAdmission(configuration: QwenResidentLoadConfiguration(identity: identity,
                modelDirectory: URL(fileURLWithPath: "/tmp"), rank: rank, stageCut: cut,
                deadlineUptimeNanoseconds: now + 300_000_000_000),
            configBytes: try fixture(files, "configuration"), manifestBytes: try fixture(files, "manifest"),
            environment: environment(rank: rank), now: now, read: { _, _ in matrix })
    }

    @Test func theFixturesAreTheRegisteredMetadata() throws {
        let spec = try Self.specification()
        #expect(sha256(try Self.fixture("configuration")) == spec.configurationSHA256)
        #expect(sha256(try Self.fixture("manifest")) == spec.manifestSHA256)
        struct Manifest: Decodable {
            struct Entry: Decodable { let path: String }
            let aggregate_sha256: String, file_count: Int, total_size_bytes: Int, model_id: String, version: String
            let files: [Entry]
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: try Self.fixture("manifest"))
        #expect(manifest.aggregate_sha256 == spec.artifactSHA256)
        #expect(manifest.file_count == 13 && manifest.total_size_bytes == 21_308_856_601)
        #expect(manifest.model_id == "qwen3.6-35b-a3b-vl-mtp-mxfp8" && manifest.version == "2026-08-11-r1")
        // Unlike the 35B A3B, the MTP head is not a file of its own: it is inside the weight shards.
        #expect(!manifest.files.contains { $0.path == "mtp.safetensors" })
        // The artifact declares a vision tower and an mxfp8 MTP head; neither is the text model's.
        let root = try #require(try JSONSerialization.jsonObject(with: try Self.fixture("configuration")) as? [String: Any])
        #expect(root["vision_config"] is [String: Any])
        #expect((root["mtplx_mtp_quantization"] as? [String: Any])?["mode"] as? String == "mxfp8")
        #expect((root["quantization"] as? [String: Any])?["mode"] as? String == "affine")
    }

    @Test func definitionAndCeilingsAreItsOwnRow() throws {
        let row = try QwenResidentModelDefinition(model: .qwen36ThirtyFiveBA3B)
        #expect(row.profileID == Self.profileID && row.specification.layers == 40 && row.supportedCuts == Self.cuts)
        #expect(row.supportedGenerationModes == [.pipeline, .pipelineCompactDecode, .phaseSplit])
        #expect(row.adapter == .qwen35RoutedExperts && row.arithmetic == .routedExperts)
        // Only this artifact's headers are read under the scope that describes
        // unsigned bytes; every other registered model keeps the dense scope.
        #expect(QwenDenseRegisteredSpecification.all.filter(\.unownedUInt8Tensors).map(\.model) == [.qwen36ThirtyFiveBA3B])
        let siblingSpecification = try Self.specification(.qwen35ThirtyFiveBA3B)
        #expect(row.specification.routedExperts == siblingSpecification.routedExperts)
        #expect(try QwenResidentModelDefinition(runtimeModelID: Self.modelID).specification.model == .qwen36ThirtyFiveBA3B)
        #expect(try QwenResidentModelDefinition(configuration: Self.fixture("configuration")).specification.model == .qwen36ThirtyFiveBA3B)
        #expect(throws: (any Error).self) { _ = try QwenResidentModelDefinition(runtimeModelID: "qwen3.6-35b-a3b-vl-mtp-mxfp8") }
        let profile = try QwenResidentAdapterDefinition.profile(specification: row.specification)
        #expect(profile.identifier == Self.profileID && profile.hiddenSize == 2048)
        // Same geometry as the 35B A3B, so the same profile numbers under another name.
        let sibling = try QwenResidentAdapterDefinition.profile(specification: siblingSpecification)
        #expect(profile.fingerprint != sibling.fingerprint && profile.maximumContextTokens == sibling.maximumContextTokens)
        let ceilings = try QwenResidentResourceCeilings(model: .qwen36ThirtyFiveBA3B)
        #expect(ceilings.maximumManifestPayloadBytes == 21_308_856_601)
        #expect(ceilings.namedStateByteCeiling == 563_806_248 && ceilings.maximumNamedStateBytes == 563_806_248)
        #expect(try QwenResidentResourceCeilings(model: .qwen35ThirtyFiveBA3B).maximumManifestPayloadBytes == 20_893_747_852)
    }

    @Test func theRegisteredInventoryIsTheGeometrysTensorSetWithEightBitRouters() throws {
        let spec = try Self.specification()
        let tensors = RoutedExpertInventoryFixture.canonicalTensors(routerBits: 8, decayDType: "BF16")
        #expect(tensors.count == 1637 && tensors.map(\.byteCount).reduce(0, +) == 19_508_787_456)
        let profile = try QwenRegisteredDenseModelProfile.admit(configuration: try Self.fixture("configuration"),
            manifest: try Self.fixture("manifest"), expectedArtifactAggregateSHA256: spec.artifactSHA256,
            canonicalTensors: tensors)
        #expect(profile.model == .qwen36ThirtyFiveBA3B && profile.canonicalInventorySHA256 == spec.inventorySHA256)
        // The 35B A3B's inventory (4-bit routers, float32 decay) is not this artifact's.
        #expect(throws: (any Error).self) {
            _ = try QwenRegisteredDenseModelProfile.admit(configuration: try Self.fixture("configuration"),
                manifest: try Self.fixture("manifest"), expectedArtifactAggregateSHA256: spec.artifactSHA256,
                canonicalTensors: RoutedExpertInventoryFixture.canonicalTensors(routerBits: 4, decayDType: "F32"))
        }
        let linearLayer = 474_335_744, fullLayer = 470_658_176, ends = 286_064_640
        for cut in Self.cuts {
            let plan = try profile.makePlanningPlan(stageCut: cut)
            let pair = try QwenDenseStorageRequirement.derive(profile: profile, plan: plan, role: .sequentialPair)
            let lower = ends + (cut / 4) * (3 * linearLayer + fullLayer)
            #expect(pair.stages[0].activeBytes == lower && pair.stages[1].activeBytes == spec.sourceBytes - lower)
            #expect(pair.stages.map(\.canonicalCount).reduce(0, +) == 1637)
        }
    }

    /// Each stage is constructed with the 8-bit policy of its own layers'
    /// routers under their local indices, and with none of the other stage's.
    @Test func eachStageCarriesItsOwnRoutersPolicies() throws {
        let admission = try Self.admit(cut: 12, identity: try Self.identity())
        for (stage, count) in zip(admission.plan.stages, [12, 28]) {
            #expect(stage.quantizationMappings.count == 2 * count && stage.excludedQuantizationPaths.count == 80 - 2 * count)
            let root = try #require(try JSONSerialization.jsonObject(with: stage.constructionConfiguration) as? [String: Any])
            let text = try #require(root["text_config"] as? [String: Any])
            #expect(root["model_type"] as? String == "qwen3_5_moe" && text["num_hidden_layers"] as? Int == count)
            #expect(text["mtp_num_hidden_layers"] as? Int == 0)
            #expect((root["mtplx_mtp"] as? [String: Any])?["included"] as? Bool == false)
            for container in ["quantization", "quantization_config"] {
                let policy = try #require(root[container] as? [String: Any])
                #expect(policy["bits"] as? Int == 4 && policy["group_size"] as? Int == 64 && policy["mode"] as? String == "affine")
                let routers = policy.keys.filter { $0.hasSuffix(".mlp.gate") || $0.hasSuffix(".mlp.shared_expert_gate") }
                #expect(Set(routers) == Set((0..<count).flatMap { ["language_model.model.layers.\($0).mlp.gate",
                    "language_model.model.layers.\($0).mlp.shared_expert_gate"] }))
                for path in routers {
                    let option = try #require(policy[path] as? [String: Any])
                    #expect(option["bits"] as? Int == 8 && option["group_size"] as? Int == 64)
                }
                // A placeholder never inherits the artifact's default policy.
                for inert in stage.inertModules { #expect(policy[inert.path] as? Bool == false) }
            }
        }
        #expect(admission.plan.stages[1].quantizationMappings.first { $0.sourcePath == "language_model.model.layers.12.mlp.gate" }?
            .localPath == "language_model.model.layers.0.mlp.gate")
    }

    @Test func admissionIsClosedBetweenTheTwoRoutedExpertModels() throws {
        let epoch = UUID()
        let leader = try Self.admit(rank: 0, identity: try Self.identity(epoch: epoch))
        let follower = try Self.admit(rank: 1, identity: try Self.identity(epoch: epoch))
        #expect(leader.specification.model == .qwen36ThirtyFiveBA3B && leader.wireProfile.id == Self.profileID)
        #expect(try leader.loadAgreementFingerprint() == follower.loadAgreementFingerprint())
        #expect(leader.arithmetic.contract == "qwen_cbv2_query128_bf16_tf32_expert_tiles_v1")
        var plans = Set<String>()
        for cut in Self.cuts { plans.insert(try Self.admit(cut: cut, identity: try Self.identity()).plan.fingerprint) }
        #expect(plans.count == Self.cuts.count)
        // Same geometry, different artifact: nothing of one admits as the other.
        let sibling = try Self.admit(identity: try Self.identity(model: .qwen35ThirtyFiveBA3B), files: "qwen35-35b-a3b")
        #expect(sibling.plan.fingerprint != leader.plan.fingerprint && sibling.profile.fingerprint != leader.profile.fingerprint)
        #expect(sibling.arithmeticSHA256 == leader.arithmeticSHA256)
        func refuses(_ label: Comment, _ body: () throws -> QwenResidentAdmission) {
            #expect(throws: (any Error).self, label) { _ = try body() }
        }
        refuses("this model's identity over the 35B A3B's files") {
            try Self.admit(identity: try Self.identity(), files: "qwen35-35b-a3b")
        }
        refuses("the 35B A3B's identity over this model's files") {
            try Self.admit(identity: try Self.identity(model: .qwen35ThirtyFiveBA3B))
        }
        refuses("the 35B A3B's model ID with this model's hashes") {
            try Self.admit(identity: try Self.identity(id: "registered_qwen35_35b_a3b"))
        }
        refuses("the public catalog ID") { try Self.admit(identity: try Self.identity(id: "qwen3.6-35b-a3b-vl-mtp-mxfp8")) }
        refuses("cut 38") { try Self.admit(cut: 38, identity: try Self.identity()) }
    }

    @Test func capabilityMetadataDescribesTheModel() throws {
        let binary = String(repeating: "1", count: 64)
        let spec = try Self.specification()
        let value = try QwenResidentCapabilityMetadata.describe(configuration: try Self.fixture("configuration"),
            manifest: try Self.fixture("manifest"), runtimeBinarySHA256: binary)
        #expect(value.adapterID == "qwen35-routed-expert-layer-stage" && value.runtimeModelID == Self.modelID)
        #expect(value.profile.id == Self.profileID && value.manifestSHA256 == spec.manifestSHA256)
        #expect(value.arithmeticPolicyID == "qwen_cbv2_query128_bf16_tf32_expert_tiles_v1")
        #expect(value.partitions.map { $0.stages[0].sourceLayerEnd } == Self.cuts)
        let encoded = try ClusterRuntimeCapabilityCodec.encode(value)
        #expect(encoded.count < ClusterRuntimeCapabilityCodec.maximumBytes)
        #expect(try ClusterRuntimeCapabilityCodec.decode(encoded) == value)
        #expect(throws: (any Error).self, "this configuration with the 35B A3B's manifest") {
            _ = try QwenResidentCapabilityMetadata.describe(configuration: try Self.fixture("configuration"),
                manifest: try Self.fixture("qwen35-35b-a3b", "manifest"), runtimeBinarySHA256: binary)
        }
        #expect(ClusterRuntimeAdapter.qwen35RoutedExperts.registeredProfiles.map(\.runtimeModelID)
            == ["registered_qwen35_35b_a3b", Self.modelID])
        #expect(ClusterRuntimeAdapter.qwen35Dense.registeredProfiles.count == 2)
    }
}
