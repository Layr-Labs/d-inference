import Foundation
import DarkbloomClusterProtocol
import Testing
@testable import DarkbloomClusterRuntime

// Ternary Bonsai 2 27B as a registered resident model: the 27B's geometry in
// a Prism Hadamard pack. Like the 27B suite this reads only the registered
// configuration and manifest, never weights; unlike it, the tensor inventory
// is available (see `BonsaiFixture`), so the profile's planning scope, the
// storage requirement and the request allowance are exercised here too.
// Loading the model and running a request need the artifact and are recorded
// as real runs in the evidence ledger, never simulated here.

@Suite("Resident admission contract, registered Bonsai 2 27B (registered metadata, no model)")
struct ResidentAdmissionBonsaiTests {
    private typealias F = BonsaiFixture

    @Test func theFixturesAreTheRegisteredMetadata() throws {
        let spec = try F.specification()
        #expect(sha256(try F.data("configuration")) == spec.configurationSHA256)
        #expect(sha256(try F.data("manifest")) == spec.manifestSHA256)
        struct Manifest: Decodable {
            struct Entry: Decodable { let path: String }
            let aggregate_sha256: String, file_count: Int, total_size_bytes: Int, model_id: String, version: String
            let files: [Entry]
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: try F.data("manifest"))
        #expect(manifest.aggregate_sha256 == spec.artifactSHA256)
        #expect(manifest.file_count == 8 && manifest.total_size_bytes == 8_608_670_713)
        #expect(manifest.model_id == "ternary-bonsai-2-27b" && manifest.version == "2026-09-17-r1")
        // The transform file is one of the artifact's hashed files.
        #expect(manifest.files.map(\.path).contains(QwenPrismStageConfiguration.transformFile))
        // The written-out inventory is the pinned one: names, shapes, dtypes, bytes.
        let inventory = F.inventory()
        #expect(inventory.count == spec.tensorCount && spec.tensorCount == 1655)
        #expect(QwenDenseProfileIdentity.fingerprint(inventory.map(\.identity)) == spec.inventorySHA256)
        #expect(inventory.reduce(0) { $0 + $1.byteCount } == spec.sourceBytes && spec.sourceBytes == 7_662_073_856)
        #expect(inventory.map(\.byteCount).max() == spec.largestTensorBytes)
        #expect(Set(inventory.map(\.sourceDType)) == ["U32", "F16", "F32"])
        #expect(F.signNames().count == 402)
    }

    @Test func definitionIsItsOwnClosedRow() throws {
        let packed = try QwenResidentModelDefinition(model: .ternaryBonsai2TwentySevenB)
        #expect(packed.profileID == F.profileID)
        #expect(packed.specification.layers == 64 && packed.supportedCuts == F.cuts)
        #expect(packed.supportedPrefillSchedules == [.serial, .oneChunkLookahead])
        #expect(packed.supportedGenerationModes == [.pipeline, .pipelineCompactDecode, .phaseSplit])
        #expect(packed.adapter == .qwen35PrismHadamard && packed.arithmetic == .prismHadamard)
        #expect(try QwenResidentModelDefinition(runtimeModelID: F.modelID).specification.model == .ternaryBonsai2TwentySevenB)
        #expect(try QwenResidentModelDefinition(configuration: F.data("configuration")).specification.model == .ternaryBonsai2TwentySevenB)
        for unknown in ["ternary-bonsai-2-27b", F.modelID + " ", "registered_ternary_bonsai_2_27b_v2", "registered_bonsai"] {
            #expect(throws: (any Error).self, "model ID \(unknown.debugDescription)") {
                _ = try QwenResidentModelDefinition(runtimeModelID: unknown)
            }
        }
        // The other rows keep their adapter, policy and dtype.
        for model in [QwenRegisteredDenseModel.qwen35NineB, .qwen38TwentySevenB] {
            let dense = try QwenResidentModelDefinition(model: model)
            #expect(dense.adapter == .qwen35Dense && dense.arithmetic == .dense && model.pack == .affineBFloat16)
            #expect(try QwenResidentAdapterDefinition.profile(specification: dense.specification).activationDType == "bfloat16")
        }
        // What the pack is: no load conversion, an F32 stream, no fused projections.
        let pack = QwenRegisteredDenseModel.ternaryBonsai2TwentySevenB.pack
        #expect(pack == .prismHadamard && pack.rootModelType == "prism_hadamard_qwen35")
        #expect(!pack.convertsFloat16ToBFloat16 && !pack.fusesGatedDeltaInputProjections)
        #expect(pack.activationDType == "float32" && pack.activationElementBytes == 4)
        let profile = try QwenResidentAdapterDefinition.profile(specification: packed.specification)
        #expect(profile.identifier == packed.profileID && profile.hiddenSize == 5120)
        #expect(profile.vocabularySize == 248_320 && profile.activationDType == "float32")
        #expect(profile.maximumPromptTokens == 8192 && profile.maximumChunkTokens == 512)
        #expect(profile.maximumOutputTokens == 128 && profile.maximumContextTokens == 8320)
        let large = try QwenResidentAdapterDefinition.profile(specification: F.specification(.qwen38TwentySevenB))
        #expect(profile.fingerprint != large.fingerprint)
        // No pinned content inventory: a stage of this model cannot be received from a peer.
        #expect(try QwenRegisteredContentInventory.admit(packed.specification) == nil)
    }

    @Test func ceilingsAreTheModelsOwn() throws {
        let packed = try QwenResidentResourceCeilings(model: .ternaryBonsai2TwentySevenB)
        #expect(packed.maximumManifestPayloadBytes == 8_608_670_713)
        // Above the legacy 8 GiB bound the 9B is admitted under, by 18.7 MiB.
        #expect(packed.maximumManifestPayloadBytes > LocalCorrectnessStorage.maximumManifestPayloadBytes)
        // The 27B's geometry, and a formula that already counts four bytes per state element.
        #expect(packed.namedStateByteCeiling == 1_616_248_896 && packed.maximumNamedStateBytes == 1_616_248_896)
        let spec = try F.specification()
        #expect(try spec.expectedGeometry() == F.specification(.qwen38TwentySevenB).expectedGeometry())
        #expect(try QwenLongPrefillTensorBudget.estimate(geometry: spec.expectedGeometry(), maximumTokens: 8193, chunkSize: 512)
            .conservativeStateAndBoundaryBytes == spec.namedStateBytes)
        // The other rows are untouched.
        #expect(try QwenResidentResourceCeilings(model: .qwen35NineB).maximumManifestPayloadBytes == 8 * 1024 * 1024 * 1024)
        #expect(try QwenResidentResourceCeilings(model: .qwen38TwentySevenB).maximumManifestPayloadBytes == 16_320_415_757)
    }

    @Test func registeredMetadataAdmitsOnBothRanksWithOneAgreement() throws {
        let epoch = UUID()
        let leader = try F.admit(F.configuration(rank: 0, identity: try F.identity(epoch: epoch)))
        let follower = try F.admit(F.configuration(rank: 1, identity: try F.identity(epoch: epoch)))
        #expect(leader.jaccl.rank == 0 && follower.jaccl.rank == 1)
        #expect(leader.specification.model == .ternaryBonsai2TwentySevenB)
        #expect(leader.wireProfile.id == F.profileID && leader.profile.activationDType == "float32")
        #expect(leader.plan.fingerprint == follower.plan.fingerprint)
        #expect(leader.plan.stages.map(\.sourceRange) == [0..<24, 24..<64])
        #expect(leader.arithmetic.contract == "qwen_cbv2_query128_tf32_prism_hadamard_f32_v1")
        let agreed = try leader.loadAgreementFingerprint()
        #expect(try follower.loadAgreementFingerprint() == agreed)
        #expect(try F.admit(F.configuration(cut: 28, identity: try F.identity(epoch: epoch))).loadAgreementFingerprint() != agreed)
        #expect(try F.admit(F.configuration(schedule: .oneChunkLookahead, identity: try F.identity(epoch: epoch)))
            .loadAgreementFingerprint() != agreed)
        var plans = Set<String>()
        for cut in F.cuts { for rank in 0...1 {
            let admission = try F.admit(F.configuration(rank: rank, cut: cut, identity: try F.identity()))
            #expect(admission.plan.stages.map(\.sourceRange) == [0..<cut, cut..<64])
            plans.insert(admission.plan.fingerprint)
        } }
        #expect(plans.count == F.cuts.count)
        // The same cut of the same geometry is a different Plan from the 27B's.
        let dense = try QwenLayerStagePlan(configuration: F.data("qwen38-27b", "configuration"), ranges: [0..<24, 24..<64])
        #expect(!plans.contains(dense.fingerprint))
        let reservation = ClusterWorkerReservation(profileID: leader.profile.identifier,
            promptTokenIDs: Array(repeating: 1000, count: 8192), stopTokenIDs: [], outputCount: 128, chunkSize: 512,
            deadlineUptimeNanoseconds: F.now + 1_000_000, capacityLimitBytes: 1)
        #expect(try leader.request(reservation, id: UUID(), now: F.now).maximumTokens == 8320)
        #expect(throws: (any Error).self, "the 27B's profile ID on a Bonsai admission") {
            _ = try leader.request(.init(profileID: "registered_qwen38_27b_greedy_generation_v1",
                promptTokenIDs: [1000], stopTokenIDs: [], outputCount: 1, chunkSize: 1,
                deadlineUptimeNanoseconds: F.now + 1_000_000, capacityLimitBytes: 1), id: UUID(), now: F.now)
        }
    }

    /// Each case changes exactly one input of an admission that otherwise passes.
    @Test func admissionRefusesEachDepartureFromTheClosedIdentity() throws {
        let valid = try F.identity()
        let large = try F.specification(.qwen38TwentySevenB)
        func refuses(_ label: Comment, _ body: () throws -> QwenResidentAdmission) {
            #expect(throws: (any Error).self, label) { _ = try body() }
        }
        _ = try F.admit(F.configuration(identity: valid))
        for cut in [0, 2, 6, 26, 62, 64, 68, -4] {
            refuses("cut \(cut) is not a whole-interval partition of 64 layers") {
                try F.admit(F.configuration(cut: cut, identity: valid))
            }
        }
        refuses("public catalog ID in place of the runtime model ID") {
            try F.admit(F.configuration(identity: try F.identity(model: "ternary-bonsai-2-27b")))
        }
        // Same geometry, different model: neither identity admits the other's bytes.
        refuses("the 27B's model ID with Bonsai's hashes and metadata") {
            try F.admit(F.configuration(identity: try F.identity(model: QwenRegisteredDenseModel.qwen38TwentySevenB.rawValue)))
        }
        refuses("Bonsai's model ID with the 27B's identity hashes") {
            try F.admit(F.configuration(identity: try F.identity(
                configSHA: large.configurationSHA256, artifactSHA: large.artifactSHA256)))
        }
        refuses("Bonsai's identity over the 27B's configuration and manifest") {
            try F.admit(F.configuration(identity: valid),
                config: try F.data("qwen38-27b", "configuration"), manifest: try F.data("qwen38-27b", "manifest"))
        }
        refuses("Bonsai's configuration with the 27B's manifest") {
            try F.admit(F.configuration(identity: valid), manifest: try F.data("qwen38-27b", "manifest"))
        }
        var altered = try F.data("configuration")
        altered[altered.count / 2] ^= 1
        refuses("one flipped configuration bit") { try F.admit(F.configuration(identity: valid), config: altered) }
        var alteredManifest = try F.data("manifest")
        alteredManifest[alteredManifest.count / 2] ^= 1
        refuses("one flipped manifest bit") { try F.admit(F.configuration(identity: valid), manifest: alteredManifest) }
        // The pack's arithmetic contract: the dense three, both switches at
        // their serving value, and the process-wide cache switch absent.
        for name in ["DARKBLOOM_CBV2_ATTN_QUERY_BLOCK", "DARKBLOOM_BF16_WEIGHTS", "MLX_ENABLE_TF32",
                     "DARKBLOOM_BONSAI_PREFILL_CARRY_ASYNC", "DARKBLOOM_BONSAI_F16_CONSTANT_CACHE"] {
            var environment = F.environment()
            environment.removeValue(forKey: name)
            refuses("missing \(name)") { try F.admit(F.configuration(identity: valid), environment: environment) }
        }
        for name in ["DARKBLOOM_BONSAI_PREFILL_CARRY_ASYNC", "DARKBLOOM_BONSAI_F16_CONSTANT_CACHE"] {
            for value in ["0", "", "true"] {
                var environment = F.environment()
                environment[name] = value
                refuses("\(name)=\(value.debugDescription)") { try F.admit(F.configuration(identity: valid), environment: environment) }
            }
        }
        for name in ["MLX_QUANTIZED_CONSTANT_CACHE", "MLX_METAL_GPU_ARCH", "MLX_SDPA_BLOCKS"] {
            for value in ["0", "1", ""] {
                var environment = F.environment()
                environment[name] = value
                refuses("\(name) present") { try F.admit(F.configuration(identity: valid), environment: environment) }
            }
        }
        refuses("JACCL rank differs from the configured rank") {
            try F.admit(F.configuration(rank: 0, identity: valid), environment: F.environment(rank: 1))
        }
        // The dense models still admit under the dense contract alone, and are
        // indifferent to the pack's switches.
        let denseIdentity = ClusterWorkerIdentity(membershipEpoch: UUID(),
            modelID: QwenRegisteredDenseModel.qwen38TwentySevenB.rawValue, artifactSHA256: large.artifactSHA256,
            configurationSHA256: large.configurationSHA256, peers: valid.peers)
        var denseEnvironment = F.environment()
        for remove in [true, false] {
            if remove {
                denseEnvironment.removeValue(forKey: "DARKBLOOM_BONSAI_PREFILL_CARRY_ASYNC")
                denseEnvironment.removeValue(forKey: "DARKBLOOM_BONSAI_F16_CONSTANT_CACHE")
            }
            let dense = try QwenResidentAdmission(configuration: F.configuration(cut: 16, identity: denseIdentity),
                configBytes: try F.data("qwen38-27b", "configuration"), manifestBytes: try F.data("qwen38-27b", "manifest"),
                environment: denseEnvironment, now: F.now, read: { _, _ in F.matrix })
            #expect(dense.arithmetic.contract == QwenLongPrefillArithmeticEnvironment.contract)
            #expect(dense.arithmetic == (try QwenLongPrefillArithmeticEnvironment.admit(denseEnvironment)))
        }
    }

    @Test func theArithmeticReceiptNamesThePacksOwnSwitches() throws {
        let receipt = try QwenResidentArithmeticPolicy.prismHadamard.admit(F.environment())
        #expect(receipt.contract == ClusterRuntimeAdapter.qwen35PrismHadamard.arithmeticPolicyID)
        #expect(receipt.requiredValues == ["DARKBLOOM_CBV2_ATTN_QUERY_BLOCK": "128", "DARKBLOOM_BF16_WEIGHTS": "1",
            "MLX_ENABLE_TF32": "1", "DARKBLOOM_BONSAI_PREFILL_CARRY_ASYNC": "1", "DARKBLOOM_BONSAI_F16_CONSTANT_CACHE": "1"])
        #expect(receipt.requiredAbsentNames == ["MLX_METAL_GPU_ARCH", "MLX_SDPA_BLOCKS", "MLX_QUANTIZED_CONSTANT_CACHE"])
        #expect(QwenResidentArithmeticPolicy.prismHadamard.requiredValues == receipt.requiredValues)
        #expect(QwenResidentArithmeticPolicy.prismHadamard.requiredAbsentNames == receipt.requiredAbsentNames)
        // The dense receipt is the one it always was.
        let dense = try QwenResidentArithmeticPolicy.dense.admit(F.environment())
        #expect(dense == (try QwenLongPrefillArithmeticEnvironment.admit(F.environment())))
        #expect(dense.requiredValues.count == 3 && dense.defaultBindings.count == 5 && receipt.defaultBindings.count == 9)
    }

    @Test func aStageConfigurationNamesTheDenseConstructorAndCarriesItsOwnPackedModules() throws {
        let root = try #require(try JSONSerialization.jsonObject(with: F.data("configuration")) as? [String: Any])
        let declaration = try #require(try QwenPrismStageConfiguration.admit(root: root, nested: true))
        #expect(declaration.modules.count == 402 && declaration.modules.filter(\.embedding).map(\.path) == ["model.embed_tokens"])
        // 3 per gated-delta layer, 4 per attention layer, 3 feed-forward per layer, the embedding and the head.
        #expect(declaration.modules.count == 2 + 48 * 3 + 16 * 4 + 64 * 3)
        // A dense configuration has no declaration and plans exactly as before.
        let dense = try #require(try JSONSerialization.jsonObject(with: F.data("qwen38-27b", "configuration")) as? [String: Any])
        #expect(try QwenPrismStageConfiguration.admit(root: dense, nested: true) == nil)
        for cut in [24, 28] {
            let plan = try F.admit(cut: cut).plan
            var seen = 0
            for stage in plan.stages {
                let stageRoot = try #require(try JSONSerialization.jsonObject(with: stage.constructionConfiguration) as? [String: Any])
                #expect(stageRoot["model_type"] as? String == "qwen3_5")
                let text = try #require(stageRoot["text_config"] as? [String: Any])
                #expect(text["num_hidden_layers"] as? Int == stage.sourceRange.count)
                let modules = try QwenPrismStageConfiguration.stageModules(constructionConfiguration: stage.constructionConfiguration)
                seen += modules.count
                let layers = stage.sourceRange.count
                #expect(modules.count == 1 + (layers - layers / 4) * 3 + (layers / 4) * 4 + layers * 3)
                #expect(modules.contains { $0.path == "model.embed_tokens" && $0.embedding } == (stage.index == 0))
                #expect(modules.contains { $0.path == "lm_head" } == (stage.index == 1))
                // Re-indexed to the stage's own layers: none is at or beyond its count.
                for module in modules where module.path.hasPrefix("model.layers.") {
                    let index = try #require(Int(module.path.split(separator: ".")[2]))
                    #expect(index < layers)
                }
                // The inert placeholders are never packed.
                let policy = try #require(stageRoot["quantization"] as? [String: Any])
                for inert in stage.inertModules { #expect(policy[inert.path] as? Bool == false) }
                #expect(policy["bits"] as? Int == 2 && policy["group_size"] as? Int == 128)
            }
            #expect(seen == 402)
            // Ownership: every inventory tensor has one stage, a sign tensor has
            // none, and scales on a module the pack stores plain are refused.
            let parameters = try plan.parameters(canonicalSourceNames: F.inventory().map(\.name) + F.signNames())
            #expect(parameters.count == 1655)
            #expect(parameters.filter { $0.stage == 0 }.count == (cut == 24 ? 621 : 724))
            for name in F.signNames().prefix(8) { #expect(try plan.parameter(canonicalSourceName: name) == nil) }
            for name in ["language_model.model.layers.0.linear_attn.in_proj_a.scales",
                         "language_model.model.layers.0.linear_attn.in_proj_a.signs",
                         "language_model.model.norm.signs", "language_model.model.layers.3.mlp.gate_proj.sign"] {
                #expect(throws: (any Error).self, "\(name)") { _ = try plan.parameter(canonicalSourceName: name) }
            }
        }
        // A dense Plan gives a sign tensor no such pass.
        let densePlan = try QwenLayerStagePlan(configuration: F.data("qwen38-27b", "configuration"), ranges: [0..<24, 24..<64])
        #expect(throws: (any Error).self) {
            _ = try densePlan.parameter(canonicalSourceName: "language_model.model.layers.0.mlp.gate_proj.signs")
        }
    }

    /// Each case departs from the registered declaration in one place.
    @Test func aPackDeclarationThatDiffersIsRefused() throws {
        let original = try #require(try JSONSerialization.jsonObject(with: F.data("configuration")) as? [String: Any])
        func plan(_ edit: (inout [String: Any]) -> Void) throws -> QwenLayerStagePlan {
            var root = original
            edit(&root)
            return try QwenLayerStagePlan(configuration: JSONSerialization.data(withJSONObject: root), ranges: [0..<24, 24..<64])
        }
        _ = try plan { _ in }
        func modules(_ root: [String: Any]) -> [[String: Any]] { root["modules"] as! [[String: Any]] }
        let cases: [(Comment, (inout [String: Any]) -> Void)] = [
            ("schema version", { $0["schema_version"] = 3 }),
            ("base model type", { $0["base_model_type"] = "qwen3_5_moe" }),
            ("ungrouped gated-delta layout", { $0["gdn_activation_layout"] = "tiled" }),
            ("another tensor namespace", { $0["tensor_namespace"] = "mlx-lm" }),
            ("another transform file", { $0["hadamard_config"] = "other.json" }),
            ("an MTP component", { $0["components"] = ["text": true, "vision": true, "mtp": true] }),
            ("no text component", { $0["components"] = ["text": false, "vision": true, "mtp": false] }),
            ("another bit width", { $0["quantization"] = ["bits": 4, "group_size": 128, "mode": "affine"] }),
            ("another group size", { $0["quantization"] = ["bits": 2, "group_size": 64, "mode": "affine"] }),
            ("a per-module override", {
                $0["quantization"] = ["bits": 2, "group_size": 128, "mode": "affine",
                                      "language_model.model.layers.0.mlp.up_proj": ["bits": 4, "group_size": 128]] as [String: Any]
            }),
            ("an unknown root key", { $0["decode_kernel"] = "fast" }),
            ("no packed modules", { $0["modules"] = [[String: Any]]() }),
            ("a module declared twice", { $0["modules"] = modules($0) + [modules($0)[1]] }),
            ("a missing packed module", { $0["modules"] = Array(modules($0).dropFirst()) }),
            ("a plain projection declared packed", {
                $0["modules"] = modules($0) + [["path": "model.layers.0.linear_attn.in_proj_a", "block": 1024,
                                                "embedding": false, "dtype": "float16"]]
            }),
            ("another block size", { root in
                var list = modules(root); list[1]["block"] = 2048; root["modules"] = list
            }),
            ("another packed dtype", { root in
                var list = modules(root); list[1]["dtype"] = "bfloat16"; root["modules"] = list
            }),
            ("a second packed embedding", { root in
                var list = modules(root); list[1]["embedding"] = true; root["modules"] = list
            }),
            ("an extra field in a record", { root in
                var list = modules(root); list[1]["bits"] = 2; root["modules"] = list
            }),
        ]
        for (label, edit) in cases {
            #expect(throws: (any Error).self, label) { _ = try plan(edit) }
        }
    }

    @Test func theProfileAndStorageRequirementFollowThePack() throws {
        let profile = try F.profile()
        #expect(profile.model == .ternaryBonsai2TwentySevenB && profile.canonicalTensors.count == 1655)
        #expect(profile.requiredNativeDType == "float32" && !profile.requiredBF16ConversionPolicy)
        #expect(profile.sourceTensorBytes == 7_662_073_856 && profile.largestSourceTensorBytes == 317_849_600)
        // An inventory that carries a sign tensor, or lacks a tensor, is not the registered one.
        var withSigns = F.inventory()
        withSigns.append(.init(name: F.signNames()[0], shape: [5120], sourceDType: "F32", byteCount: 20480))
        #expect(throws: (any Error).self) {
            _ = try QwenRegisteredDenseModelProfile.admit(configuration: F.data("configuration"), manifest: F.data("manifest"),
                expectedArtifactAggregateSHA256: F.specification().artifactSHA256, canonicalTensors: withSigns)
        }
        #expect(throws: (any Error).self) {
            _ = try QwenRegisteredDenseModelProfile.admit(configuration: F.data("configuration"), manifest: F.data("manifest"),
                expectedArtifactAggregateSHA256: F.specification().artifactSHA256, canonicalTensors: Array(F.inventory().dropLast()))
        }
        // The profile's planning scope: the half cut and the resident cuts.
        for cut in F.cuts { #expect(try profile.makePlanningPlan(stageCut: cut).stages[0].sourceRange == 0..<cut) }
        #expect(throws: (any Error).self) { _ = try profile.makePlanningPlan(stageCut: 26) }
        for (cut, active) in [(24, [2_962_665_216, 4_699_408_640]), (28, [3_396_845_952, 4_265_227_904])] {
            let plan = try profile.makePlanningPlan(stageCut: cut)
            let pair = try QwenDenseStorageRequirement.derive(profile: profile, plan: plan, role: .sequentialPair)
            #expect(pair.stages.map(\.activeBytes) == active && active[0] + active[1] == 7_662_073_856)
            #expect(pair.stages.map(\.canonicalCount).reduce(0, +) == 1655)
            // Nothing is fused, and the placeholders are F32: a norm weight
            // and a head row for stage 0, an embedding row for stage 1.
            #expect(pair.fusionReplacementBytes == 0 && pair.stages.allSatisfy { $0.fusionReplacementBytes == 0 })
            #expect(pair.stages.map(\.inertBytes) == [2 * 5120 * 4, 5120 * 4])
            #expect(pair.finalState.kvDType == "float32" && pair.finalState.convolutionDType == "float32")
            #expect(pair.finalState.kvBytesPerTensor == 4 * 8192 * 256 * 4)
            #expect(pair.finalState.convolutionBytesPerTensor == 3 * 10240 * 4)
            for rank in 0...1 {
                let selected = try QwenDenseStorageRequirement.derive(profile: profile, plan: plan, role: rank == 0 ? .stage0 : .stage1)
                #expect(selected.selectedActiveBytes == active[rank])
                // The request allowance: state as for the 27B, and in place of
                // fusion one F32 copy of each packed projection's F16 scales
                // and biases. The embedding's are not copied.
                let allowance = try QwenResidentRequestAllowance.derive(profile: profile, plan: plan, rank: rank,
                    maximumTokens: 8320, chunkSize: 512, bound: { $0 })
                let owned = try plan.parameters(canonicalSourceNames: profile.canonicalTensors.map(\.name))
                    .filter { $0.stage == rank }.map(\.sourceName)
                let constants = profile.canonicalTensors.filter {
                    owned.contains($0.name) && $0.sourceDType == "F16" && !$0.name.contains("embed_tokens")
                }
                #expect(allowance.fusionBytes == 2 * constants.reduce(0) { $0 + $1.byteCount })
                #expect(allowance.fusionBytes == (cut == 24 ? [570_163_200, 1_029_734_400] : [665_190_400, 934_707_200])[rank])
                #expect(allowance.reservedBytes == allowance.stateBytes + allowance.fusionBytes)
                #expect(try QwenPrismHadamardConstants.widenedBytes(profile: profile, plan: plan, rank: rank).count == constants.count)
            }
        }
    }

    @Test func capabilityMetadataDescribesThePackUnderItsOwnAdapter() throws {
        let binary = String(repeating: "1", count: 64)
        let spec = try F.specification()
        let value = try QwenResidentCapabilityMetadata.describe(configuration: try F.data("configuration"),
            manifest: try F.data("manifest"), runtimeBinarySHA256: binary)
        #expect(value.adapterID == ClusterRuntimeAdapter.qwen35PrismHadamard.rawValue)
        #expect(value.runtimeModelID == F.modelID && value.profile.id == F.profileID)
        #expect(value.artifactSHA256 == spec.artifactSHA256 && value.configurationSHA256 == spec.configurationSHA256)
        #expect(value.manifestSHA256 == spec.manifestSHA256)
        #expect(value.arithmeticPolicyID == "qwen_cbv2_query128_tf32_prism_hadamard_f32_v1")
        #expect(value.supportedPrefillSchedules == [.serial, .oneChunkLookahead])
        #expect(value.supportedGenerationModes == [.pipeline, .pipelineCompactDecode, .phaseSplit])
        #expect(value.partitions.map { $0.stages[0].sourceLayerEnd } == F.cuts)
        let admission = try F.admit(cut: 24)
        #expect(value.partitions[5].planSHA256 == admission.plan.fingerprint)
        #expect(value.profileFingerprint == admission.profile.fingerprint)
        #expect(value.arithmeticPolicySHA256 == admission.arithmeticSHA256)
        let encoded = try ClusterRuntimeCapabilityCodec.encode(value)
        #expect(encoded.count < ClusterRuntimeCapabilityCodec.maximumBytes)
        #expect(try ClusterRuntimeCapabilityCodec.decode(encoded) == value)
        #expect(throws: (any Error).self, "Bonsai configuration, 27B manifest") {
            _ = try QwenResidentCapabilityMetadata.describe(configuration: try F.data("configuration"),
                manifest: try F.data("qwen38-27b", "manifest"), runtimeBinarySHA256: binary)
        }
        let registered = try #require(QwenResidentCapabilityMetadata.registeredModel(runtimeModelID: F.modelID))
        #expect(registered.profileID == F.profileID && registered.supportedCuts == F.cuts && registered.layerCount == 64)
        #expect(registered.manifestSHA256 == spec.manifestSHA256)
        #expect(registered.requiredArithmeticEnvironment == QwenResidentArithmeticPolicy.prismHadamard.requiredValues)
        #expect(try QwenResidentCapabilityMetadata.registeredModel(configuration: F.data("configuration")) == registered)
        #expect(QwenResidentCapabilityMetadata.registeredModels.map(\.runtimeModelID).contains(F.modelID))
        #expect(QwenResidentCapabilityMetadata.registeredCutsUsage.split(separator: "\n").contains(Substring(
            F.modelID + ": " + F.cuts.map(String.init).joined(separator: "|"))))
        // The protocol accepts the pack only under its own adapter, profile and policy.
        func edited(_ edit: (inout [String: Any]) -> Void) throws -> Data {
            var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            edit(&object)
            var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
            data.append(10)
            return data
        }
        #expect(try ClusterRuntimeCapabilityCodec.decode(edited { _ in }).runtimeModelID == F.modelID)
        let dense = ClusterRuntimeAdapter.qwen35Dense
        #expect(throws: (any Error).self, "the dense adapter") {
            _ = try ClusterRuntimeCapabilityCodec.decode(edited { $0["adapterID"] = dense.rawValue })
        }
        #expect(throws: (any Error).self, "the dense arithmetic policy") {
            _ = try ClusterRuntimeCapabilityCodec.decode(edited { $0["arithmeticPolicyID"] = dense.arithmeticPolicyID })
        }
        #expect(throws: (any Error).self, "the 27B's profile") {
            _ = try ClusterRuntimeCapabilityCodec.decode(edited { object in
                var profile = object["profile"] as! [String: Any]
                profile["id"] = "registered_qwen38_27b_greedy_generation_v1"; object["profile"] = profile
            })
        }
        #expect(throws: (any Error).self, "the 27B's model ID") {
            _ = try ClusterRuntimeCapabilityCodec.decode(edited { $0["runtimeModelID"] = "registered_qwen38_27b" })
        }
        #expect(ClusterRuntimeAdapter.registering(runtimeModelID: F.modelID) == .qwen35PrismHadamard)
        #expect(ClusterRuntimeAdapter.admittedModels.contains { $0.runtimeModelID == F.modelID && $0.profileID == F.profileID })
        // The dense adapter's two pairs are the ones it always had.
        #expect(dense.registeredProfiles.map(\.runtimeModelID) == ["registered_qwen35_9b", "registered_qwen38_27b"])
    }
}
