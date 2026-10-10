import Foundation
import DarkbloomClusterProtocol
import MLXLLM
import Testing
@testable import DarkbloomClusterRuntime

// The registered MiMo V2.6 Flash as a two-stage layer pipeline. This reads only
// the artifact's own metadata: byte-exact copies of its `config.json` and
// catalog manifest, and the name, dtype, shape and byte count of every tensor
// in its shard headers. Never weights. Loading a stage and running a request
// need the 173 GB artifact and are recorded as real runs in the handoff, never
// simulated here.

@Suite("Resident admission contract, registered MiMo V2.6 (registered metadata, no model)")
struct MiMoResidentAdmissionTests {
    private static let now: UInt64 = 1_000
    private static let matrix = Data(#"[[null,"tb5-a"],["tb5-b",null]]"#.utf8)
    private static let gib = 1_073_741_824

    private static func fixture(_ name: String) throws -> Data {
        let libraries = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: libraries.appendingPathComponent(
            "darkbloom-cluster-worker/Tests/CapabilityChecks/Fixtures/registered-mimo-v26-flash-mopd.\(name).json"))
    }
    private static func inventory() throws -> [MiMoCanonicalTensor] {
        try JSONDecoder().decode([MiMoCanonicalTensor].self, from: fixture("tensor-inventory"))
    }
    private static func specification() throws -> MiMoRegisteredSpecification {
        try MiMoRegisteredSpecification.specification(.v26FlashMOPD)
    }
    private static func profile(_ tensors: [MiMoCanonicalTensor]? = nil, manifest: Data? = nil,
                                aggregate: String? = nil) throws -> MiMoRegisteredModelProfile {
        try MiMoRegisteredModelProfile.admit(configuration: fixture("configuration"),
            manifest: try manifest ?? fixture("manifest"),
            expectedArtifactAggregateSHA256: try aggregate ?? specification().artifactSHA256,
            indexedTensors: try tensors ?? inventory())
    }

    private static func environment(rank: Int = 0) -> [String: String] {
        ["MLX_ENABLE_TF32": "1", "DARKBLOOM_CBV2_ATTN_QUERY_BLOCK": "128", "DARKBLOOM_BF16_WEIGHTS": "1",
         "JACCL_RANK": String(rank), "JACCL_IBV_DEVICES": "/opt/cluster/matrix.json",
         "JACCL_COORDINATOR": "10.0.0.5:4499"]
    }
    private static func identity(epoch: UUID = UUID(), model: String? = nil, configSHA: String? = nil,
                                 artifactSHA: String? = nil) throws -> ClusterWorkerIdentity {
        let spec = try specification()
        return ClusterWorkerIdentity(membershipEpoch: epoch, modelID: model ?? spec.model.rawValue,
            artifactSHA256: artifactSHA ?? spec.artifactSHA256,
            configurationSHA256: configSHA ?? spec.configurationSHA256,
            peers: [ClusterWorkerPeer(id: "peer-a", buildSHA256: String(repeating: "a", count: 64)),
                    ClusterWorkerPeer(id: "peer-b", buildSHA256: String(repeating: "b", count: 64))])
    }
    private static func configuration(rank: Int = 0, cut: Int = 32, schedule: ClusterPrefillSchedule = .serial,
                                      deadline: UInt64 = now + 1_800_000_000_000,
                                      identity: ClusterWorkerIdentity) -> QwenResidentLoadConfiguration {
        QwenResidentLoadConfiguration(identity: identity, modelDirectory: URL(fileURLWithPath: "/tmp"), rank: rank,
            stageCut: cut, deadlineUptimeNanoseconds: deadline, prefillSchedule: schedule)
    }
    private static func admit(_ configuration: QwenResidentLoadConfiguration, config: Data? = nil,
                              manifest: Data? = nil, environment: [String: String]? = nil) throws -> MiMoResidentAdmission {
        try MiMoResidentAdmission(configuration: configuration, configBytes: try config ?? fixture("configuration"),
            manifestBytes: try manifest ?? fixture("manifest"),
            environment: environment ?? Self.environment(rank: configuration.rank), now: now, read: { _, _ in matrix })
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
        #expect(manifest.file_count == 53 && manifest.total_size_bytes == 172_863_462_401)
        #expect(manifest.model_id == "mimo-v2.6-flash-mopd" && manifest.version == "2026-09-28-r1")
        #expect(try Self.inventory().count == 1732)
    }

    @Test func theRowIsClosedAndCarriesItsOwnCeilings() throws {
        let spec = try Self.specification()
        #expect(MiMoRegisteredSpecification.all.count == 1 && MiMoRegisteredModel.allCases.count == 1)
        #expect(spec.profileID == "registered_mimo_v26_flash_mopd_greedy_generation_v1")
        #expect(spec.layers == 48 && spec.hidden == 4096 && spec.vocabulary == 152_576)
        #expect(spec.supportedCuts == [16, 20, 24, 28, 30, 32, 34, 36, 38, 40, 42, 44])
        #expect(spec.supportedPrefillSchedules == [.serial])
        // No phase split: the rank that decodes alone would hold the whole model.
        #expect(spec.supportedGenerationModes == [.pipeline, .pipelineCompactDecode])
        #expect(spec.maximumManifestPayloadBytes == 172_863_462_401 && spec.maximumStageTensorBytes == 167_264_120_704)
        #expect(MiMoRegisteredSpecification.maximumLifetimeNanoseconds == 1_800_000_000_000)
        #expect(MiMoRegisteredSpecification.maximumRequests == 16)
        #expect(try MiMoRegisteredSpecification.specification(runtimeModelID: "registered_mimo_v26_flash_mopd").model == .v26FlashMOPD)
        #expect(try MiMoRegisteredSpecification.specification(configuration: Self.fixture("configuration")).model == .v26FlashMOPD)
        for unknown in ["", "registered_mimo_v26_flash_mopd ", "mimo-v2.6-flash-mopd", "registered_qwen35_9b"] {
            #expect(throws: (any Error).self, "model ID \(unknown.debugDescription)") {
                _ = try MiMoRegisteredSpecification.specification(runtimeModelID: unknown)
            }
        }
        var altered = try Self.fixture("configuration")
        altered[altered.count / 2] ^= 1
        #expect(throws: (any Error).self) { _ = try MiMoRegisteredSpecification.specification(configuration: altered) }
        #expect(throws: (any Error).self) { _ = try MiMoRegisteredSpecification.specification(configuration: Data()) }
        let profile = try spec.profile()
        #expect(profile.identifier == spec.profileID && profile.hiddenSize == 4096 && profile.vocabularySize == 152_576)
        #expect(profile.maximumPromptTokens == 8192 && profile.maximumChunkTokens == 512
            && profile.maximumOutputTokens == 128 && profile.maximumContextTokens == 8320)
    }

    @Test func theProfileAdmitsExactlyTheRegisteredMetadata() throws {
        let profile = try Self.profile()
        #expect(profile.tensors.count == 1103 && profile.tensors.map(\.name) == profile.tensors.map(\.name).sorted())
        #expect(profile.tensors.reduce(0) { $0 + $1.byteCount } == 167_264_120_704)
        // 48 layers of four packed attention projections, the dense MLP of layer 0,
        // the embedding and the head are affine 8-bit; 47 layers of three expert banks are MXFP4.
        let affine = profile.quantization.values.filter { $0.mode == "affine" }
        let mxfp4 = profile.quantization.values.filter { $0.mode == "mxfp4" }
        #expect(affine.count == 48 * 4 + 3 + 2 && affine.allSatisfy { $0.bits == 8 && $0.groupSize == 64 })
        #expect(mxfp4.count == 47 * 3 && mxfp4.allSatisfy { $0.bits == 4 && $0.groupSize == 32 })
        #expect(profile.configuration.numHiddenLayers == 48)
        // Identity: any other manifest or expected artifact is refused.
        var manifest = try Self.fixture("manifest"); manifest[10] ^= 1
        #expect(throws: (any Error).self) { _ = try Self.profile(manifest: manifest) }
        #expect(throws: (any Error).self) { _ = try Self.profile(aggregate: String(repeating: "0", count: 64)) }
        // Inventory: a missing, renamed, reshaped or retyped tensor is refused.
        let all = try Self.inventory()
        #expect(throws: (any Error).self) { _ = try Self.profile(Array(all.dropLast())) }
        func replaced(_ name: String, _ change: (MiMoCanonicalTensor) -> MiMoCanonicalTensor) -> [MiMoCanonicalTensor] {
            all.map { $0.name == name ? change($0) : $0 }
        }
        let router = "language_model.model.layers.7.mlp.gate.weight"
        #expect(all.contains { $0.name == router })
        #expect(throws: (any Error).self) {
            _ = try Self.profile(replaced(router) { .init(name: $0.name + "_x", shape: $0.shape, sourceDType: $0.sourceDType, byteCount: $0.byteCount) })
        }
        #expect(throws: (any Error).self) {
            _ = try Self.profile(replaced(router) { .init(name: $0.name, shape: [4096, 256], sourceDType: $0.sourceDType, byteCount: $0.byteCount) })
        }
        #expect(throws: (any Error).self) {
            _ = try Self.profile(replaced(router) { .init(name: $0.name, shape: [128, 4096], sourceDType: "F32", byteCount: $0.byteCount) })
        }
        // An excluded component is counted too: one vision tensor fewer is another artifact.
        let vision = try #require(all.first { $0.name.hasPrefix("vision_tower.") })
        #expect(throws: (any Error).self) { _ = try Self.profile(all.filter { $0 != vision }) }
        #expect(throws: (any Error).self) {
            _ = try MiMoCanonicalTensor(name: "a.b", shape: [2, 3], sourceDType: "U8", byteCount: 7).validate()
        }
        try MiMoCanonicalTensor(name: "a.b", shape: [2, 3], sourceDType: "U8", byteCount: 6).validate()
        #expect(throws: (any Error).self) {
            _ = try MiMoCanonicalTensor(name: "a.b", shape: [2], sourceDType: "F16", byteCount: 4).validate()
        }
    }

    @Test func everyListedCutDividesTheTextModelExactly() throws {
        let spec = try Self.specification(), profile = try Self.profile()
        let bytes = Dictionary(uniqueKeysWithValues: profile.tensors.map { ($0.name, $0.byteCount) })
        var fingerprints = Set<String>()
        for cut in spec.supportedCuts {
            let plan = try MiMoLayerStagePlan(configuration: Self.fixture("configuration"), cut: cut)
            #expect(plan.layers == 48 && plan.stages.map(\.sourceRange) == [0..<cut, cut..<48])
            #expect(plan.fingerprint == (try MiMoLayerStagePlan(configuration: Self.fixture("configuration"), cut: cut)).fingerprint)
            fingerprints.insert(plan.fingerprint)
            #expect(plan.stages[0].fingerprint != plan.stages[1].fingerprint)
            let mappings = try plan.parameters(sourceNames: try Self.inventory().map(\.name))
            #expect(mappings.count == 1103)
            let stageBytes = (0...1).map { stage in mappings.filter { $0.stage == stage }.reduce(0) { $0 + bytes[$1.sourceName]! } }
            #expect(stageBytes[0] + stageBytes[1] == spec.sourceBytes)
            // Layer 0 is the one dense layer; a full-attention MoE layer is 5,570,688 bytes
            // smaller than a sliding one (four key-value heads instead of eight, no sink bias).
            let expected = 664_010_752 + 308_625_408 + (1..<cut).reduce(0) {
                $0 + (spec.fullAttentionLayers.contains($1) ? 3_519_366_144 : 3_524_936_832)
            }
            #expect(stageBytes[0] == expected, "cut \(cut)")
            // Stage 0 owns the embedding and no readout; stage 1 the final norm and the head.
            #expect(mappings.filter { $0.localName.hasPrefix("model.embed_tokens.") }.allSatisfy { $0.stage == 0 })
            #expect(mappings.filter { $0.localName.hasPrefix("lm_head.") || $0.localName == "model.norm.weight" }
                .allSatisfy { $0.stage == 1 })
            for stage in plan.stages {
                // The product's own parser accepts the compact bytes and agrees with the source's geometry.
                let compact = try plan.productConfiguration(stage: stage.index)
                #expect(compact.numHiddenLayers == stage.sourceRange.count && compact.tieWordEmbeddings == (stage.index == 0))
                #expect(compact.vision == nil && compact.audio == nil && compact.numNextnPredictLayers == 0)
                #expect(stage.layers.map(\.globalIndex) == Array(stage.sourceRange))
                #expect(stage.layers.map(\.localIndex) == Array(0..<stage.sourceRange.count))
                #expect(stage.layers.allSatisfy {
                    $0.attention == (spec.fullAttentionLayers.contains($0.globalIndex) ? "full" : "sliding")
                        && $0.feedForward == ($0.globalIndex == 0 ? "dense" : "moe")
                })
                // The compact bytes are canonical: decoding and encoding them again changes nothing.
                #expect(try QwenStageMetadata.json(JSONSerialization.jsonObject(with: stage.constructionConfiguration))
                    == stage.constructionConfiguration)
            }
            // The first layer of stage 1 is local layer 0 there.
            let first = try #require(try plan.parameter(sourceName: "language_model.model.layers.\(cut).input_layernorm.weight"))
            #expect(first.stage == 1 && first.localName == "model.layers.0.input_layernorm.weight")
            #expect(try plan.sourceModulePath(stage: 1, localModulePath: "model.layers.0.self_attn.q_proj")
                == "language_model.model.layers.\(cut).self_attn.q_proj")
            #expect(try plan.sourceModulePath(stage: 1, localModulePath: "lm_head") == "language_model.lm_head")
            #expect(try plan.parameter(sourceName: "language_model.model.mtp.layers.0.eh_proj.weight") == nil)
            #expect(try plan.parameter(sourceName: "vision_tower.merger.ln_q.weight") == nil)
            #expect(throws: (any Error).self) { _ = try plan.parameter(sourceName: "language_model.model.layers.48.input_layernorm.weight") }
            #expect(throws: (any Error).self) { _ = try plan.parameter(sourceName: "model.layers.0.input_layernorm.weight") }
        }
        #expect(fingerprints.count == spec.supportedCuts.count)
        // Cut 32, the first placement: 102.65 GiB on rank 0 and 53.13 GiB on rank 1.
        let plan = try MiMoLayerStagePlan(configuration: Self.fixture("configuration"), cut: 32)
        let mappings = try plan.parameters(sourceNames: profile.tensors.map(\.name))
        #expect(mappings.filter { $0.stage == 0 }.reduce(0) { $0 + bytes[$1.sourceName]! } == 110_217_824_512)
        #expect(mappings.filter { $0.stage == 1 }.reduce(0) { $0 + bytes[$1.sourceName]! } == 57_046_296_192)
        for cut in [0, 48, -1, 49] {
            #expect(throws: (any Error).self) { _ = try MiMoLayerStagePlan(configuration: Self.fixture("configuration"), cut: cut) }
        }
    }

    @Test func requestStateIsNamedFromGeometryAndStaysSmall() throws {
        let spec = try Self.specification()
        func budget(_ layers: Range<Int>, rank: Int, tokens: Int = 8320, chunk: Int = 512) throws -> MiMoRequestStateBudget {
            try .estimate(specification: spec, layers: layers, rank: rank, maximumTokens: tokens, chunkSize: chunk, bound: { $0 })
        }
        let zero = try budget(0..<32, rank: 0), one = try budget(32..<48, rank: 1)
        #expect(zero.fullAttentionLayers == 6 && zero.slidingLayers == 26 && one.fullAttentionLayers == 3 && one.slidingLayers == 13)
        // 8,320 tokens round up to 8,448 in steps of 256; keys and values of four heads, held twice.
        #expect(zero.fullAttentionStateBytes == 6 * 2 * 4 * 8448 * (192 + 128) * 2)
        #expect(zero.slidingStateBytes == 26 * 2 * 8 * (128 + 512) * (192 + 128) * 2)
        #expect(zero.boundaryBytes == 2 * 512 * 4096 * 2 && zero.rowBytes == 0 && one.rowBytes == 2 * 152_576 * 4)
        #expect(zero.workspaceBytes == 64 * 512 * 8448 * 4)
        #expect(zero.reservedBytes < 2 * Self.gib && one.reservedBytes < 2 * Self.gib)
        #expect(try budget(0..<32, rank: 0, tokens: 64, chunk: 64).reservedBytes < zero.reservedBytes)
        for (tokens, chunk) in [(0, 1), (8321, 512), (100, 0), (100, 513)] {
            #expect(throws: (any Error).self) { _ = try budget(0..<32, rank: 0, tokens: tokens, chunk: chunk) }
        }
        #expect(throws: (any Error).self) { _ = try budget(0..<49, rank: 0) }
        #expect(throws: (any Error).self) { _ = try budget(0..<32, rank: 2) }
    }

    @Test func admissionTakesTheClosedIdentityOnBothRanksAtEveryCut() throws {
        let spec = try Self.specification()
        for cut in spec.supportedCuts {
            let epoch = UUID()
            let ranks = try (0...1).map { try Self.admit(Self.configuration(rank: $0, cut: cut, identity: Self.identity(epoch: epoch))) }
            #expect(ranks[0].plan.fingerprint == ranks[1].plan.fingerprint)
            #expect(ranks[0].arithmeticSHA256 == ranks[1].arithmeticSHA256 && ranks[0].jaccl.fingerprint == ranks[1].jaccl.fingerprint)
            func agreement(_ rank: Int, mode: QwenResidentGenerationMode = .pipeline, residency: Bool = true,
                           measured: Bool = false) throws -> String {
                try ranks[rank].loadAgreementFingerprint(mode: mode, transport: .jaccl, residency: residency, measuredGate: measured)
            }
            // Rank, path and local clock are not in it; everything both were told is.
            #expect(try agreement(0) == agreement(1))
            #expect(try agreement(0) != agreement(1, mode: .pipelineCompactDecode))
            #expect(try agreement(0) != agreement(1, residency: false))
            #expect(try agreement(0) != agreement(1, measured: true))
            #expect(try agreement(0) != ranks[1].loadAgreementFingerprint(mode: .pipeline, transport: .localSocketTest,
                                                                         residency: true, measuredGate: false))
            #expect(ranks[0].wireProfile.id == spec.profileID && ranks[0].wireProfile.vocabularySize == 152_576)
        }
        let a = try Self.admit(Self.configuration(cut: 32, identity: Self.identity()))
        let b = try Self.admit(Self.configuration(cut: 28, identity: Self.identity(epoch: a.configuration.identity.membershipEpoch)))
        #expect(try a.loadAgreementFingerprint(mode: .pipeline, transport: .jaccl, residency: true, measuredGate: false)
            != b.loadAgreementFingerprint(mode: .pipeline, transport: .jaccl, residency: true, measuredGate: false))
    }

    @Test func admissionRefusesEverythingOutsideTheRow() throws {
        func refused(_ label: String, _ body: () throws -> MiMoResidentAdmission) {
            #expect(throws: (any Error).self, "\(label)") { _ = try body() }
        }
        refused("another model's ID") { try Self.admit(Self.configuration(identity: Self.identity(model: "registered_qwen38_27b"))) }
        refused("an unlisted cut") { try Self.admit(Self.configuration(cut: 31, identity: Self.identity())) }
        refused("a cut outside the model") { try Self.admit(Self.configuration(cut: 48, identity: Self.identity())) }
        refused("lookahead") { try Self.admit(Self.configuration(schedule: .oneChunkLookahead, identity: Self.identity())) }
        refused("a lifetime over the row's") {
            try Self.admit(Self.configuration(deadline: Self.now + 1_800_000_000_001, identity: Self.identity()))
        }
        refused("a past deadline") { try Self.admit(Self.configuration(deadline: Self.now, identity: Self.identity())) }
        refused("another configuration hash") {
            try Self.admit(Self.configuration(identity: Self.identity(configSHA: String(repeating: "0", count: 64))))
        }
        refused("another artifact hash") {
            try Self.admit(Self.configuration(identity: Self.identity(artifactSHA: String(repeating: "0", count: 64))))
        }
        refused("altered configuration bytes") {
            var config = try Self.fixture("configuration"); config[config.count / 2] ^= 1
            return try Self.admit(Self.configuration(identity: Self.identity()), config: config)
        }
        refused("another manifest") {
            var manifest = try Self.fixture("manifest"); manifest[10] ^= 1
            return try Self.admit(Self.configuration(identity: Self.identity()), manifest: manifest)
        }
        refused("a rank that differs from JACCL's") {
            try Self.admit(Self.configuration(rank: 1, identity: Self.identity()), environment: Self.environment(rank: 0))
        }
        // The arithmetic contract: the product's defaults, on both ranks.
        var environment = Self.environment()
        environment["MLX_ENABLE_TF32"] = nil
        refused("no TF32 declaration") { try Self.admit(Self.configuration(identity: Self.identity()), environment: environment) }
        for name in ["DARKBLOOM_MIMO_FUSED_DECODE_NORMS", "DARKBLOOM_MIMO_V26_NAX_ATTENTION", "DARKBLOOM_MIMO_FP32_WEIGHTED_REDUCE",
                     "MLX_SDPA_BLOCKS", "MLX_METAL_GPU_ARCH"] {
            var overridden = Self.environment()
            overridden[name] = "1"
            refused(name) { try Self.admit(Self.configuration(identity: Self.identity()), environment: overridden) }
        }
        // The dense rows' own arithmetic names are not MiMo switches and do not matter here.
        _ = try Self.admit(Self.configuration(identity: Self.identity()))
        // The last second of the row's lifetime is admitted.
        _ = try Self.admit(Self.configuration(deadline: Self.now + 1_800_000_000_000, identity: Self.identity()))
    }

    @Test func aRequestIsHeldToTheRowsProfile() throws {
        let admission = try Self.admit(Self.configuration(identity: Self.identity()))
        func reservation(profile: String? = nil, prompt: [Int] = [1, 2, 3], stops: [Int] = [151_643, 151_645, 151_672],
                         output: Int = 4, chunk: Int = 512, deadline: UInt64 = Self.now + 10) -> ClusterWorkerReservation {
            .init(profileID: profile ?? admission.profile.identifier, promptTokenIDs: prompt, stopTokenIDs: stops,
                  outputCount: output, chunkSize: chunk, deadlineUptimeNanoseconds: deadline, capacityLimitBytes: 1 << 40)
        }
        let request = try admission.request(reservation(), id: UUID(), now: Self.now)
        #expect(request.promptCount == 3 && request.outputCount == 4 && request.stopTokenIDs == [151_643, 151_645, 151_672])
        for bad in [reservation(profile: "registered_qwen35_9b_greedy_generation_v1"), reservation(prompt: [152_576]),
                    reservation(prompt: []), reservation(stops: [5, 4]), reservation(output: 129), reservation(chunk: 513),
                    reservation(deadline: Self.now), reservation(prompt: Array(repeating: 1, count: 8193))] {
            #expect(throws: (any Error).self) { _ = try admission.request(bad, id: UUID(), now: Self.now) }
        }
    }

    @Test func theCapabilityRecordDescribesTheRowAndPassesTheProtocol() throws {
        let spec = try Self.specification()
        let binary = String(repeating: "c", count: 64)
        let value = try MiMoResidentCapabilityMetadata.describe(configuration: Self.fixture("configuration"),
            manifest: Self.fixture("manifest"), runtimeBinarySHA256: binary)
        #expect(value.adapterID == ClusterRuntimeAdapter.mimoV26LayerStage.rawValue && value.adapterVersion == 1)
        #expect(value.runtimeModelID == spec.model.rawValue && value.profile.id == spec.profileID)
        #expect(value.artifactSHA256 == spec.artifactSHA256 && value.manifestSHA256 == spec.manifestSHA256)
        #expect(value.partitions.map { $0.stages[0].sourceLayerEnd } == spec.supportedCuts)
        #expect(value.partitions.allSatisfy { $0.stages[1].sourceLayerEnd == 48 })
        #expect(value.maxLifetimeSeconds == 1800 && value.maxRequests == 16)
        #expect(value.supportedPrefillSchedules == [.serial])
        #expect(value.supportedGenerationModes == [.pipeline, .pipelineCompactDecode])
        #expect(value.arithmeticPolicyID == "mimo_v26_text_ordinary_cache_bf16_defaults_v1")
        let plan = try MiMoLayerStagePlan(configuration: Self.fixture("configuration"), cut: 32)
        #expect(try value.selection(planSHA256: plan.fingerprint).stages.map(\.stagePlanSHA256) == plan.stages.map(\.fingerprint))
        // It survives the wire codec unchanged.
        let encoded = try ClusterRuntimeCapabilityCodec.encode(value)
        #expect(try ClusterRuntimeCapabilityCodec.decode(encoded) == value)
        #expect(throws: (any Error).self) {
            _ = try MiMoResidentCapabilityMetadata.describe(configuration: Self.fixture("configuration"),
                manifest: Data("{}".utf8), runtimeBinarySHA256: binary)
        }
    }

    @Test func theProtocolKeepsEachAdaptersOwnPolicyAndLifetime() throws {
        let dense = ClusterRuntimeAdapter.qwen35Dense, mimo = ClusterRuntimeAdapter.mimoV26LayerStage
        #expect(ClusterRuntimeAdapter.registering(runtimeModelID: "registered_mimo_v26_flash_mopd") == mimo)
        // Every adapter but MiMo keeps the 300 seconds that used to be one literal.
        #expect(ClusterRuntimeAdapter.allCases.filter { $0 != mimo }.allSatisfy { $0.maximumLifetimeSeconds == 300 })
        // The dense adapter's values are the ones it always had.
        #expect(dense.maximumLifetimeSeconds == 300 && dense.arithmeticPolicyID == "qwen_cbv2_query128_bf16_tf32_default_v1")
        #expect(dense.registeredProfiles.map(\.runtimeModelID) == ["registered_qwen35_9b", "registered_qwen38_27b"])
        #expect(mimo.maximumLifetimeSeconds == 1800 && mimo.registeredProfiles.count == 1)
        func capability(adapter: ClusterRuntimeAdapter, model: String? = nil, profile: String? = nil,
                        policy: String? = nil, lifetime: Int) throws -> ClusterRuntimeCapability {
            let hash = String(repeating: "d", count: 64), other = String(repeating: "e", count: 64)
            return try ClusterRuntimeCapability(runtimeBinarySHA256: hash, adapterID: adapter.rawValue,
                adapterVersion: 1, runtimeModelID: model ?? adapter.runtimeModelID, artifactSHA256: hash,
                configurationSHA256: hash, manifestSHA256: hash,
                profile: .init(id: profile ?? adapter.profileID, vocabularySize: 1000, maximumPromptTokens: 8192,
                               maximumOutputTokens: 128, maximumChunkTokens: 512, maximumContextTokens: 8320),
                profileFingerprint: hash,
                partitions: [.init(planSHA256: hash, stages: [
                    .init(rank: 0, sourceLayerStart: 0, sourceLayerEnd: 4, stagePlanSHA256: hash,
                          constructionConfigurationSHA256: hash),
                    .init(rank: 1, sourceLayerStart: 4, sourceLayerEnd: 8, stagePlanSHA256: other,
                          constructionConfigurationSHA256: hash)])],
                arithmeticPolicyID: policy ?? adapter.arithmeticPolicyID, arithmeticPolicySHA256: hash,
                maxLifetimeSeconds: lifetime, maxRequests: 16)
        }
        _ = try capability(adapter: dense, lifetime: 300)
        _ = try capability(adapter: mimo, lifetime: 1800)
        #expect(throws: (any Error).self) { _ = try capability(adapter: dense, lifetime: 301) }
        #expect(throws: (any Error).self) { _ = try capability(adapter: mimo, lifetime: 1801) }
        // Neither adapter may borrow the other's policy, model or profile.
        #expect(throws: (any Error).self) { _ = try capability(adapter: dense, policy: mimo.arithmeticPolicyID, lifetime: 300) }
        #expect(throws: (any Error).self) { _ = try capability(adapter: mimo, policy: dense.arithmeticPolicyID, lifetime: 300) }
        #expect(throws: (any Error).self) { _ = try capability(adapter: dense, model: mimo.runtimeModelID, lifetime: 300) }
        #expect(throws: (any Error).self) { _ = try capability(adapter: mimo, profile: dense.profileID, lifetime: 300) }
    }

    @Test func theCatalogListsEveryAdaptersModelsFromTheirOwnRows() throws {
        let all = ClusterResidentModelCatalog.all
        #expect(all.map(\.runtimeModelID) == ["registered_qwen35_9b", "registered_qwen38_27b", "registered_qwen35_35b_a3b",
            "registered_qwen36_35b_a3b", "registered_ternary_bonsai_2_27b", "registered_nemotron35_lightning",
            "registered_gpt_oss_20b", "registered_mimo_v26_flash_mopd",
            "registered_gemma4_26b_qat_4bit", "registered_gemma4_26b", "registered_gemma4_26b_8bit"])
        #expect(all.map(\.family) == Array(repeating: .qwenDense, count: 6) + [.gptoss, .mimoV26]
            + Array(repeating: .qwenDense, count: 3))
        // Every entry is a pair the protocol admits for that adapter.
        for entry in all {
            let adapter = try #require(ClusterRuntimeAdapter(rawValue: entry.adapterID))
            #expect(adapter.registeredProfiles.contains { $0.runtimeModelID == entry.runtimeModelID && $0.profileID == entry.profileID })
            #expect(entry.maximumLifetimeSeconds == adapter.maximumLifetimeSeconds)
            #expect(ClusterResidentModelCatalog.entry(runtimeModelID: entry.runtimeModelID) == entry)
        }
        let nine = try #require(ClusterResidentModelCatalog.entry(runtimeModelID: "registered_qwen35_9b"))
        #expect(nine.supportedCuts == [4, 8, 12, 16] && nine.layerCount == 32 && nine.maximumLifetimeSeconds == 300)
        #expect(nine.supportedGenerationModes == [.pipeline, .pipelineCompactDecode, .phaseSplit])
        let mimo = try ClusterResidentModelCatalog.entry(configuration: Self.fixture("configuration"))
        #expect(mimo.family == .mimoV26 && mimo.layerCount == 48 && mimo.supportedCuts == [16, 20, 24, 28, 30, 32, 34, 36, 38, 40, 42, 44])
        #expect(mimo.maximumLifetimeSeconds == 1800 && mimo.supportedGenerationModes == [.pipeline, .pipelineCompactDecode])
        #expect(ClusterResidentModelCatalog.entry(runtimeModelID: "mimo-v2.6-flash-mopd") == nil)
        #expect(throws: (any Error).self) { _ = try ClusterResidentModelCatalog.entry(configuration: Data("{}".utf8)) }
        let described = try ClusterResidentModelCatalog.describe(configuration: Self.fixture("configuration"),
            manifest: Self.fixture("manifest"), runtimeBinarySHA256: String(repeating: "c", count: 64))
        #expect(described.adapterID == ClusterRuntimeAdapter.mimoV26LayerStage.rawValue)
    }

    @Test func stageResidencyKeepsTheProductsCeiling() {
        let gib = Self.gib
        // 256 GiB: a tenth (25.6 GiB) is the larger reserve; 128 GiB: 16 GiB is.
        #expect(MiMoStageResidency.ceiling(physicalBytes: 256 * gib, recommendedBytes: 250 * gib) == 256 * gib - (256 * gib / 10 + 1))
        #expect(MiMoStageResidency.ceiling(physicalBytes: 128 * gib, recommendedBytes: 120 * gib) == 112 * gib)
        // Never above the device's recommended working set.
        #expect(MiMoStageResidency.ceiling(physicalBytes: 128 * gib, recommendedBytes: 96 * gib) == 96 * gib)
        #expect(MiMoStageResidency.ceiling(physicalBytes: 16 * gib, recommendedBytes: 12 * gib) == nil)
        #expect(MiMoStageResidency.ceiling(physicalBytes: 0, recommendedBytes: 1) == nil)
        #expect(MiMoStageResidency.ceiling(physicalBytes: 128 * gib, recommendedBytes: 0) == nil)
    }
}
