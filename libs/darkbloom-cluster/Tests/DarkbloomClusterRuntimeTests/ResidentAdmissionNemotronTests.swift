import Foundation
import DarkbloomClusterProtocol
import Testing
@testable import DarkbloomClusterRuntime

// The registered Nemotron 3.5 Lightning: the first resident model whose layer
// kinds follow an explicit list instead of an interval, and the first with
// layers that own no request state. Like the other admission suites this reads
// only the registered configuration and manifest metadata (byte-exact copies
// of the artifact's `config.json` and of its catalog manifest), never weights.
// The tensor inventory is rebuilt from the registered geometry alone. The
// model-free checks of its metadata, Plan and storage are also run without
// SwiftPM by `Tests/NemotronStageChecks/run.sh`. Loading the model and running
// a request are real runs, recorded in the handoff.

@Suite("Resident admission contract, registered Nemotron 3.5 Lightning (registered metadata, no model)")
struct ResidentAdmissionNemotronTests {
    private static let now: UInt64 = 1_000
    private static let matrix = Data(#"[[null,"tb5-a"],["tb5-b",null]]"#.utf8)
    private static let modelID = "registered_nemotron35_lightning"
    private static let profileID = "registered_nemotron35_lightning_greedy_generation_v1"
    private static let pattern = Array(NemotronInventoryFixture.pattern)

    private static func fixture(_ model: String, _ name: String) throws -> Data {
        let libraries = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: libraries.appendingPathComponent(
            "darkbloom-cluster-worker/Tests/CapabilityChecks/Fixtures/registered-\(model).\(name).json"))
    }
    private static func fixture(_ name: String) throws -> Data { try fixture("nemotron35-lightning", name) }

    private static func environment(rank: Int = 0) -> [String: String] {
        ["DARKBLOOM_CBV2_ATTN_QUERY_BLOCK": "128", "DARKBLOOM_BF16_WEIGHTS": "1", "MLX_ENABLE_TF32": "1",
         "JACCL_RANK": String(rank), "JACCL_IBV_DEVICES": "/opt/cluster/matrix.json",
         "JACCL_COORDINATOR": "10.0.0.5:4499"]
    }

    private static func specification(_ model: QwenRegisteredDenseModel = .nemotron35Lightning) throws -> QwenDenseRegisteredSpecification {
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

    private static func configuration(rank: Int = 0, cut: Int = 25,
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

    private static func profile() throws -> QwenRegisteredDenseModelProfile {
        try QwenRegisteredDenseModelProfile.admit(configuration: try fixture("configuration"),
            manifest: try fixture("manifest"), expectedArtifactAggregateSHA256: try specification().artifactSHA256,
            canonicalTensors: NemotronInventoryFixture.canonicalTensors())
    }

    @Test func definitionIsItsOwnClosedRow() throws {
        let row = try QwenResidentModelDefinition(model: .nemotron35Lightning)
        #expect(row.profileID == Self.profileID && row.specification.layers == 52)
        #expect(row.supportedCuts == NemotronRegisteredLightning.supportedCuts && row.supportedCuts.count <= 16)
        #expect(row.supportedCuts == [7, 9, 11, 14, 16, 18, 21, 23, 25, 28, 30, 32, 35, 37, 39, 41])
        #expect(row.supportedCuts.allSatisfy { Self.pattern[$0 - 1] == "E" })
        #expect(row.supportedPrefillSchedules == [.serial, .oneChunkLookahead])
        #expect(row.adapter == .nemotronH && row.arithmetic == .nemotronHybrid)
        #expect(row.arithmetic.contract == "nemotron_h_cbv2_query128_bf16_tf32_default_v1")
        #expect(row.arithmetic.requiredValues.count == 3 && row.arithmetic.requiredAbsentNames.count == 2)
        #expect(try QwenResidentModelDefinition(runtimeModelID: Self.modelID).specification.model == .nemotron35Lightning)
        #expect(try QwenResidentModelDefinition(configuration: Self.fixture("configuration")).specification.model == .nemotron35Lightning)
        for unknown in ["nvidia-nemotron-3.5-lightning", "registered_nemotron35_lightning ", "registered_nemotron35", "registered_nemotron_h"] {
            #expect(throws: (any Error).self, "model ID \(unknown.debugDescription)") {
                _ = try QwenResidentModelDefinition(runtimeModelID: unknown)
            }
        }
        let profile = try QwenResidentAdapterDefinition.profile(specification: row.specification)
        #expect(profile.identifier == Self.profileID && profile.hiddenSize == 2688 && profile.vocabularySize == 131_072)
        // The Qwen rows keep their vocabulary, adapters and interval geometry.
        for model in [QwenRegisteredDenseModel.qwen35NineB, .qwen38TwentySevenB, .qwen35ThirtyFiveBA3B] {
            let other = try QwenResidentModelDefinition(model: model)
            #expect(other.adapter != .nemotronH && other.arithmetic != .nemotronHybrid)
            #expect(try QwenResidentAdapterDefinition.profile(specification: other.specification).vocabularySize == 248_320)
            #expect(try other.specification.expectedGeometry().stateLayers == nil)
        }
    }

    @Test func ceilingsAreTheModelsOwn() throws {
        let spec = try Self.specification()
        let ceilings = try QwenResidentResourceCeilings(model: .nemotron35Lightning)
        #expect(ceilings.maximumManifestPayloadBytes == 19_059_595_830)
        #expect(ceilings.namedStateByteCeiling == 271_556_632 && ceilings.maximumNamedStateBytes == 271_556_632)
        let geometry = try spec.expectedGeometry()
        #expect(geometry.layers == 52 && geometry.attentionLayers == 6 && geometry.recurrentLayers == 23)
        #expect(geometry.fullAttentionInterval == 0 && geometry.kvHeads == 2 && geometry.headDimension == 128)
        #expect(try QwenLongPrefillTensorBudget.estimate(geometry: geometry, maximumTokens: 8193, chunkSize: 512)
            .conservativeStateAndBoundaryBytes == spec.namedStateBytes)
        #expect(try QwenResidentResourceCeilings(model: .qwen35NineB).maximumNamedStateBytes == 754_188_320)
        #expect(try QwenResidentResourceCeilings(model: .qwen38TwentySevenB).maximumNamedStateBytes == 1_616_248_896)
    }

    @Test func registeredMetadataAdmitsOnBothRanksWithOneAgreement() throws {
        let epoch = UUID()
        let leader = try Self.admit(Self.configuration(rank: 0, identity: try Self.identity(epoch: epoch)))
        let follower = try Self.admit(Self.configuration(rank: 1, identity: try Self.identity(epoch: epoch)))
        #expect(leader.jaccl.rank == 0 && follower.jaccl.rank == 1)
        #expect(leader.specification.model == .nemotron35Lightning && leader.wireProfile.id == Self.profileID)
        #expect(leader.wireProfile.vocabularySize == 131_072 && leader.profile.hiddenSize == 2688)
        #expect(leader.plan.stages.map(\.sourceRange) == [0..<25, 25..<52] && leader.plan.interval == 0)
        #expect(leader.arithmetic.contract == "nemotron_h_cbv2_query128_bf16_tf32_default_v1")
        let agreed = try leader.loadAgreementFingerprint()
        #expect(try follower.loadAgreementFingerprint() == agreed)
        #expect(try Self.admit(Self.configuration(cut: 23, identity: try Self.identity(epoch: epoch)))
            .loadAgreementFingerprint() != agreed)
        var plans = Set<String>()
        for cut in NemotronRegisteredLightning.supportedCuts { for rank in 0...1 {
            let admission = try Self.admit(Self.configuration(rank: rank, cut: cut, identity: try Self.identity()))
            #expect(admission.plan.stages.map(\.sourceRange) == [0..<cut, cut..<52])
            plans.insert(admission.plan.fingerprint)
        } }
        #expect(plans.count == NemotronRegisteredLightning.supportedCuts.count)
        let reservation = ClusterWorkerReservation(profileID: leader.profile.identifier,
            promptTokenIDs: Array(repeating: 1000, count: 8192), stopTokenIDs: [], outputCount: 128, chunkSize: 512,
            deadlineUptimeNanoseconds: Self.now + 1_000_000, capacityLimitBytes: 1)
        #expect(try leader.request(reservation, id: UUID(), now: Self.now).maximumTokens == 8320)
        // A token ID that only a larger vocabulary has is outside this profile.
        let outside = ClusterWorkerReservation(profileID: leader.profile.identifier,
            promptTokenIDs: [131_072], stopTokenIDs: [], outputCount: 1, chunkSize: 1,
            deadlineUptimeNanoseconds: Self.now + 1_000_000, capacityLimitBytes: 1)
        #expect(throws: (any Error).self) { _ = try leader.request(outside, id: UUID(), now: Self.now) }
    }

    @Test func admissionRefusesEachDepartureFromTheClosedIdentity() throws {
        let valid = try Self.identity()
        let small = try Self.specification(.qwen35NineB)
        func refuses(_ label: Comment, _ body: () throws -> QwenResidentAdmission) {
            #expect(throws: (any Error).self, label) { _ = try body() }
        }
        _ = try Self.admit(Self.configuration(identity: valid))
        // 20 and 26 are structural or near it but not in the closed row; 12 is
        // between a Mamba and an attention block; 4 leaves stage 0 no attention.
        for cut in [0, 4, 12, 20, 26, 44, 52, -4] {
            refuses("cut \(cut) is not in the resident row") { try Self.admit(Self.configuration(cut: cut, identity: valid)) }
        }
        var missing = Self.environment()
        missing.removeValue(forKey: "DARKBLOOM_CBV2_ATTN_QUERY_BLOCK")
        refuses("missing arithmetic binding") { try Self.admit(Self.configuration(identity: valid), environment: missing) }
        refuses("another query block") {
            try Self.admit(Self.configuration(identity: valid),
                environment: Self.environment().merging(["DARKBLOOM_CBV2_ATTN_QUERY_BLOCK": "256"]) { $1 })
        }
        // The expert-tile switch selects nothing for this model's expert
        // shapes, so its contract neither requires nor refuses it.
        _ = try Self.admit(Self.configuration(identity: valid),
            environment: Self.environment().merging(["MLX_GATHER_QMM_EXPERT_SLICES": "trust"]) { $1 })
        refuses("public catalog ID in place of the runtime model ID") {
            try Self.admit(Self.configuration(identity: try Self.identity(model: "nvidia-nemotron-3.5-lightning")))
        }
        refuses("the 9B's model ID with this model's hashes and metadata") {
            try Self.admit(Self.configuration(cut: 16, identity: try Self.identity(
                model: QwenRegisteredDenseModel.qwen35NineB.rawValue)))
        }
        refuses("this model's ID with the 9B's identity hashes") {
            try Self.admit(Self.configuration(identity: try Self.identity(
                configSHA: small.configurationSHA256, artifactSHA: small.artifactSHA256)))
        }
        refuses("this model's identity over the 9B's configuration and manifest") {
            try Self.admit(Self.configuration(cut: 16, identity: valid),
                config: try Self.fixture("qwen35-9b", "configuration"), manifest: try Self.fixture("qwen35-9b", "manifest"))
        }
        refuses("this model's configuration with the 27B's manifest") {
            try Self.admit(Self.configuration(identity: valid), manifest: try Self.fixture("qwen38-27b", "manifest"))
        }
        var altered = try Self.fixture("configuration")
        altered[altered.count / 2] ^= 1
        refuses("one flipped configuration bit") { try Self.admit(Self.configuration(identity: valid), config: altered) }
        refuses("JACCL rank differs from the configured rank") {
            try Self.admit(Self.configuration(rank: 0, identity: valid), environment: Self.environment(rank: 1))
        }
        // This model's cuts stay closed to the 9B, and the 9B's to it.
        let nine = ClusterWorkerIdentity(membershipEpoch: UUID(), modelID: QwenRegisteredDenseModel.qwen35NineB.rawValue,
            artifactSHA256: small.artifactSHA256, configurationSHA256: small.configurationSHA256, peers: valid.peers)
        #expect(throws: (any Error).self, "cut 25 on the 9B") {
            _ = try QwenResidentAdmission(configuration: Self.configuration(cut: 25, identity: nine),
                configBytes: try Self.fixture("qwen35-9b", "configuration"), manifestBytes: try Self.fixture("qwen35-9b", "manifest"),
                environment: Self.environment(), now: Self.now, read: { _, _ in Self.matrix })
        }
    }

    /// A request's named storage on either rank: the complete model's state
    /// estimate, charged conservatively to each rank as for every model, and
    /// no fused projections, because this model has none.
    @Test func requestAllowanceChargesStateAndNoFusion() throws {
        let profile = try Self.profile()
        for cut in [14, 25, 39] {
            let plan = try profile.makePlanningPlan(stageCut: cut)
            for rank in 0...1 {
                let allowance = try QwenResidentRequestAllowance.derive(profile: profile, plan: plan, rank: rank,
                    maximumTokens: 8320, chunkSize: 512, bound: { $0 })
                #expect(allowance.fusionBytes == 0 && allowance.reservedBytes == allowance.stateBytes)
                // 3 generations of 23 Mamba states, 6 attention K and V at F32 width, one host copy, two boundaries.
                let kv = 4 * 8320 * 2 * 128
                let expected = 3 * 23 * (73_728 + 2_097_152) + 2 * 6 * kv + 6 * 4 + kv + 2 * (512 * 2688 * 4)
                #expect(allowance.stateBytes == expected)
            }
        }
    }

    /// The state rank 0 hands over in a phase split: its Mamba blocks'
    /// convolution history and SSM state and its attention blocks' keys and
    /// values, by the block's index in the complete model; nothing for an
    /// expert block.
    @Test func handoffNamesOnlyTheBlocksThatOwnState() throws {
        let spec = try Self.specification()
        let geometry = try spec.expectedGeometry()
        let request = try QwenLayerStageGenerationRequest(
            profile: try QwenResidentAdapterDefinition.profile(specification: spec), requestID: UUID(),
            promptTokenIDs: (0..<8192).map { 1000 + $0 }, chunkSize: 512, outputCount: 128, stopTokenIDs: [])
        let ceilings = try QwenResidentResourceCeilings(model: .nemotron35Lightning)
        for cut in NemotronRegisteredLightning.supportedCuts {
            let plan = try QwenLayerStagePlan(configuration: try Self.fixture("configuration"), ranges: [0..<cut, cut..<52])
            let split = try QwenPhaseSplitPlan(plan: plan, geometry: geometry, request: request)
            let mamba = Self.pattern[..<cut].filter { $0 == "M" }.count, attention = Self.pattern[..<cut].filter { $0 == "*" }.count
            #expect(split.terms.producerLayerCount == cut && split.terms.entryCount == 2 * mamba + 3 * attention)
            #expect(split.terms.segmentCount == 2 * mamba + 2 * attention)
            #expect(split.terms.logicalBytes == mamba * (36_864 + 2_097_152) + attention * (2 * 4_194_304 + 4))
            #expect(split.terms.logicalBytes <= ceilings.namedStateByteCeiling)
            for shape in split.shapes {
                let kind = Self.pattern[shape.globalLayerIndex]
                switch shape.component {
                case "conv": #expect(kind == "M" && shape.shape == [1, 3, 6144] && shape.dtype == "bfloat16")
                case "ssm": #expect(kind == "M" && shape.shape == [1, 64, 64, 128] && shape.dtype == "float32")
                case "kv.keys", "kv.values": #expect(kind == "*" && shape.shape == [1, 2, 8192, 128] && shape.dtype == "bfloat16")
                default: #expect(kind == "*" && shape.component == QwenPhaseSplitStateShape.positionOffsets)
                }
            }
            // Four MiB of keys per attention block: nothing is cut, and one header names every component.
            #expect(split.segments.allSatisfy { $0.tokens == nil && $0.byteCount <= CollectivePointToPointShape.hardByteLimit })
            let bound = try QwenPhaseSplitHandoffHeader.encodedBytesBound(shapes: split.shapes)
            #expect(bound <= QwenPhaseSplitHandoffHeader.frameBytes - QwenControlFrame.headerBytes, "cut \(cut): \(bound) bytes")
        }
    }

    @Test func capabilityMetadataDescribesTheNemotronAdapter() throws {
        let value = try QwenResidentCapabilityMetadata.describe(configuration: try Self.fixture("configuration"),
            manifest: try Self.fixture("manifest"), runtimeBinarySHA256: String(repeating: "1", count: 64))
        #expect(value.adapterID == "nemotron-h-layer-stage" && value.runtimeModelID == Self.modelID)
        #expect(value.arithmeticPolicyID == "nemotron_h_cbv2_query128_bf16_tf32_default_v1")
        #expect(value.partitions.map { $0.stages[0].sourceLayerEnd } == NemotronRegisteredLightning.supportedCuts)
        let encoded = try ClusterRuntimeCapabilityCodec.encode(value)
        #expect(encoded.count < ClusterRuntimeCapabilityCodec.maximumBytes)
        #expect(try ClusterRuntimeCapabilityCodec.decode(encoded) == value)
        func edited(_ change: (inout [String: Any]) -> Void) throws -> Data {
            var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            change(&object)
            var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
            data.append(10)
            return data
        }
        #expect(try ClusterRuntimeCapabilityCodec.decode(edited { _ in }).runtimeModelID == Self.modelID)
        #expect(throws: (any Error).self, "the dense adapter does not register this model") {
            _ = try ClusterRuntimeCapabilityCodec.decode(edited { $0["adapterID"] = "qwen35-dense-layer-stage" })
        }
        #expect(throws: (any Error).self, "another adapter's arithmetic policy") {
            _ = try ClusterRuntimeCapabilityCodec.decode(edited { $0["arithmeticPolicyID"] = "qwen_cbv2_query128_bf16_tf32_default_v1" })
        }
    }
}
