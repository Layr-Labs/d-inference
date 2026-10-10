import Foundation
import DarkbloomClusterProtocol
import Testing
@testable import DarkbloomClusterRuntime

// The registered Qwen3.8 27B as the second resident model. Like the 9B suite,
// this reads only the registered configuration and manifest metadata (7.6 KB,
// byte-exact copies of the artifact's own files), never weights. Loading the
// model and running a request need the full artifact and are recorded as real
// runs in the evidence ledger, never simulated here. The tensor inventory is
// not a fixture, so the profile's planning scope and the request allowance are
// exercised by those runs and not by this suite.

@Suite("Resident admission contract, registered 27B (registered metadata, no model)")
struct ResidentAdmission27BTests {
    private static let now: UInt64 = 1_000
    private static let matrix = Data(#"[[null,"tb5-a"],["tb5-b",null]]"#.utf8)
    private static let cuts = Array(stride(from: 4, through: 60, by: 4))

    private static func fixture(_ model: String, _ name: String) throws -> Data {
        // Tests/DarkbloomClusterRuntimeTests -> libs, then the worker's fixtures.
        let libraries = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: libraries.appendingPathComponent(
            "darkbloom-cluster-worker/Tests/CapabilityChecks/Fixtures/registered-\(model).\(name).json"))
    }
    private static func fixture(_ name: String) throws -> Data { try fixture("qwen38-27b", name) }

    private static func environment(rank: Int = 0) -> [String: String] {
        ["DARKBLOOM_CBV2_ATTN_QUERY_BLOCK": "128", "DARKBLOOM_BF16_WEIGHTS": "1", "MLX_ENABLE_TF32": "1",
         "JACCL_RANK": String(rank), "JACCL_IBV_DEVICES": "/opt/cluster/matrix.json",
         "JACCL_COORDINATOR": "10.0.0.5:4499"]
    }

    private static func specification(_ model: QwenRegisteredDenseModel = .qwen38TwentySevenB) throws -> QwenDenseRegisteredSpecification {
        try #require(QwenDenseRegisteredSpecification.all.first { $0.model == model })
    }

    private static func identity(epoch: UUID = UUID(),
                                 model: String = QwenRegisteredDenseModel.qwen38TwentySevenB.rawValue,
                                 configSHA: String? = nil, artifactSHA: String? = nil,
                                 peers: [ClusterWorkerPeer]? = nil) throws -> ClusterWorkerIdentity {
        let spec = try specification()
        return ClusterWorkerIdentity(membershipEpoch: epoch, modelID: model,
            artifactSHA256: artifactSHA ?? spec.artifactSHA256,
            configurationSHA256: configSHA ?? spec.configurationSHA256,
            peers: peers ?? [
                ClusterWorkerPeer(id: "peer-a", buildSHA256: String(repeating: "a", count: 64)),
                ClusterWorkerPeer(id: "peer-b", buildSHA256: String(repeating: "b", count: 64)),
            ])
    }

    private static func configuration(rank: Int = 0, cut: Int = 16,
                                      schedule: ClusterPrefillSchedule = .serial,
                                      deadline: UInt64 = now + 300_000_000_000,
                                      identity: ClusterWorkerIdentity) -> QwenResidentLoadConfiguration {
        QwenResidentLoadConfiguration(identity: identity,
            modelDirectory: URL(fileURLWithPath: "/tmp"), rank: rank, stageCut: cut,
            deadlineUptimeNanoseconds: deadline, prefillSchedule: schedule)
    }

    /// One admission with every input valid unless the caller replaces it.
    private static func admit(_ configuration: QwenResidentLoadConfiguration,
                              config: Data? = nil, manifest: Data? = nil,
                              environment: [String: String]? = nil) throws -> QwenResidentAdmission {
        try QwenResidentAdmission(configuration: configuration,
            configBytes: try config ?? fixture("configuration"),
            manifestBytes: try manifest ?? fixture("manifest"),
            environment: environment ?? Self.environment(rank: configuration.rank),
            now: now, read: { _, _ in matrix })
    }

    @Test func theFixturesAreTheRegisteredMetadata() throws {
        let spec = try Self.specification()
        #expect(sha256(try Self.fixture("configuration")) == spec.configurationSHA256)
        #expect(sha256(try Self.fixture("manifest")) == spec.manifestSHA256)
        struct Manifest: Decodable {
            let aggregate_sha256: String, file_count: Int, total_size_bytes: Int, model_id: String
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: try Self.fixture("manifest"))
        #expect(manifest.aggregate_sha256 == spec.artifactSHA256)
        #expect(manifest.file_count == 14 && manifest.total_size_bytes == 16_320_415_757)
        #expect(manifest.model_id == "EigenLabs/Qwen3.8-27B-4bit-mtp")
    }

    @Test func definitionIsOneClosedRowPerRegisteredModel() throws {
        let large = try QwenResidentModelDefinition(model: .qwen38TwentySevenB)
        #expect(large.profileID == "registered_qwen38_27b_greedy_generation_v1")
        #expect(large.specification.layers == 64 && large.supportedCuts == Self.cuts)
        #expect(large.supportedPrefillSchedules == [.serial, .oneChunkLookahead])
        // The 9B row is the original definition, unchanged.
        let small = try QwenResidentModelDefinition(model: .qwen35NineB)
        #expect(small.profileID == QwenResidentAdapterDefinition.profileID)
        #expect(small.supportedCuts == [4, 8, 12, 16])
        // Selection is by the closed enumeration: by wire ID or by pinned configuration bytes.
        #expect(try QwenResidentModelDefinition(runtimeModelID: "registered_qwen38_27b").specification.model == .qwen38TwentySevenB)
        #expect(try QwenResidentModelDefinition(configuration: Self.fixture("configuration")).specification.model == .qwen38TwentySevenB)
        #expect(try QwenResidentModelDefinition(configuration: Self.fixture("qwen35-9b", "configuration")).specification.model == .qwen35NineB)
        for unknown in ["", "registered_qwen38_27b ", "Registered_Qwen38_27B", "EigenLabs/Qwen3.8-27B-4bit-mtp", "registered_qwen38_27b_v2"] {
            #expect(throws: (any Error).self, "model ID \(unknown.debugDescription)") {
                _ = try QwenResidentModelDefinition(runtimeModelID: unknown)
            }
        }
        var altered = try Self.fixture("configuration")
        altered[altered.count / 2] ^= 1
        #expect(throws: (any Error).self) { _ = try QwenResidentModelDefinition(configuration: altered) }
        #expect(throws: (any Error).self) { _ = try QwenResidentModelDefinition(configuration: Data()) }
        // One profile per model, with the model's own hidden size.
        let profile = try QwenResidentAdapterDefinition.profile(specification: large.specification)
        #expect(profile.identifier == large.profileID && profile.hiddenSize == 5120)
        #expect(profile.vocabularySize == 248_320 && profile.activationDType == "bfloat16")
        #expect(profile.maximumPromptTokens == 8192 && profile.maximumChunkTokens == 512)
        #expect(profile.maximumOutputTokens == 128 && profile.maximumContextTokens == 8320)
        let smallProfile = try QwenResidentAdapterDefinition.profile(specification: small.specification)
        #expect(smallProfile.identifier == QwenResidentAdapterDefinition.profileID && smallProfile.hiddenSize == 4096)
        #expect(profile.fingerprint != smallProfile.fingerprint)
    }

    @Test func ceilingsBelongToEachRegisteredModel() throws {
        let large = try QwenResidentResourceCeilings(model: .qwen38TwentySevenB)
        #expect(large.maximumManifestPayloadBytes == 16_320_415_757)
        #expect(large.namedStateByteCeiling == 1_616_248_896 && large.maximumNamedStateBytes == 1_616_248_896)
        // The 9B keeps the bounds it was always admitted under: nothing was raised.
        let small = try QwenResidentResourceCeilings(model: .qwen35NineB)
        #expect(small.maximumManifestPayloadBytes == 8 * 1024 * 1024 * 1024)
        #expect(small.namedStateByteCeiling == 768 * 1024 * 1024 && small.maximumNamedStateBytes == 754_188_320)
        #expect(LocalCorrectnessStorage.maximumManifestPayloadBytes == 8 * 1024 * 1024 * 1024)
        #expect(QwenRegistered9BLongPrefillAdmission.namedTensorByteCeiling == 768 * 1024 * 1024)
        // Under the 9B's ceilings the 27B is refused at both: that is why it has its own row.
        let spec = try Self.specification()
        #expect(spec.manifestBytes > small.maximumManifestPayloadBytes)
        #expect(large.maximumNamedStateBytes > small.namedStateByteCeiling)
        // The model's own estimate, recomputed: the registered 8,193-token
        // metadata value and the resident maximum of 8,320 tokens.
        let geometry = try spec.expectedGeometry()
        #expect(try QwenLongPrefillTensorBudget.estimate(geometry: geometry, maximumTokens: 8193, chunkSize: 512)
            .conservativeStateAndBoundaryBytes == spec.namedStateBytes)
        #expect(try QwenLongPrefillTensorBudget.estimate(geometry: geometry, maximumTokens: 8320, chunkSize: 512)
            .conservativeStateAndBoundaryBytes == large.namedStateByteCeiling)
    }

    @Test func registeredMetadataAdmitsOnBothRanksWithOneAgreement() throws {
        let epoch = UUID()
        let leader = try Self.admit(Self.configuration(rank: 0, identity: try Self.identity(epoch: epoch)))
        let follower = try Self.admit(Self.configuration(rank: 1, identity: try Self.identity(epoch: epoch)))
        #expect(leader.jaccl.rank == 0 && follower.jaccl.rank == 1)
        #expect(leader.specification.model == .qwen38TwentySevenB && leader.definition.specification.layers == 64)
        #expect(leader.wireProfile.id == "registered_qwen38_27b_greedy_generation_v1")
        #expect(leader.wireProfile.vocabularySize == 248_320 && leader.profile.hiddenSize == 5120)
        #expect(leader.plan.fingerprint == follower.plan.fingerprint)
        #expect(leader.plan.stages.map(\.sourceRange) == [0..<16, 16..<64])
        // Rank, local path and local uptime are outside the agreement: the two
        // ranks of one epoch must compute the same value before either loads.
        let agreed = try leader.loadAgreementFingerprint()
        #expect(try follower.loadAgreementFingerprint() == agreed)
        // A different epoch, cut or prefill schedule is a different agreement.
        #expect(try Self.admit(Self.configuration(identity: try Self.identity())).loadAgreementFingerprint() != agreed)
        #expect(try Self.admit(Self.configuration(cut: 12, identity: try Self.identity(epoch: epoch)))
            .loadAgreementFingerprint() != agreed)
        #expect(try Self.admit(Self.configuration(schedule: .oneChunkLookahead,
            identity: try Self.identity(epoch: epoch))).loadAgreementFingerprint() != agreed)
        // Every cut of the 64 layers, on both ranks, with a distinct Plan each.
        var plans = Set<String>()
        for cut in Self.cuts { for rank in 0...1 {
            let admission = try Self.admit(Self.configuration(rank: rank, cut: cut, identity: try Self.identity()))
            #expect(admission.plan.stages.map(\.sourceRange) == [0..<cut, cut..<64])
            plans.insert(admission.plan.fingerprint)
        } }
        #expect(plans.count == Self.cuts.count)
        // A request within the profile is admitted under the 27B's profile ID only.
        let reservation = ClusterWorkerReservation(profileID: leader.profile.identifier,
            promptTokenIDs: Array(repeating: 1000, count: 8192), stopTokenIDs: [], outputCount: 128, chunkSize: 512,
            deadlineUptimeNanoseconds: Self.now + 1_000_000, capacityLimitBytes: 1)
        #expect(try leader.request(reservation, id: UUID(), now: Self.now).maximumTokens == 8320)
        #expect(throws: (any Error).self, "the 9B's profile ID on a 27B admission") {
            _ = try leader.request(.init(profileID: QwenResidentAdapterDefinition.profileID,
                promptTokenIDs: [1000], stopTokenIDs: [], outputCount: 1, chunkSize: 1,
                deadlineUptimeNanoseconds: Self.now + 1_000_000, capacityLimitBytes: 1), id: UUID(), now: Self.now)
        }
    }

    /// Each case changes exactly one input of an admission that otherwise
    /// passes (see the test above), so a refusal is attributable to it.
    @Test func admissionRefusesEachDepartureFromTheClosedIdentity() throws {
        let valid = try Self.identity()
        let small = try Self.specification(.qwen35NineB)
        func refuses(_ label: Comment, _ body: () throws -> QwenResidentAdmission) {
            #expect(throws: (any Error).self, label) { _ = try body() }
        }
        _ = try Self.admit(Self.configuration(identity: valid))
        refuses("rank outside 0...1") { try Self.admit(Self.configuration(rank: 2, identity: valid)) }
        for cut in [0, 2, 6, 18, 30, 62, 64, 68, -4] {
            refuses("cut \(cut) is not a whole-interval partition of 64 layers") {
                try Self.admit(Self.configuration(cut: cut, identity: valid))
            }
        }
        refuses("deadline already reached") {
            try Self.admit(Self.configuration(deadline: Self.now, identity: valid))
        }
        refuses("lifetime beyond the closed bound") {
            try Self.admit(Self.configuration(deadline: Self.now + 300_000_000_001, identity: valid))
        }
        refuses("duplicate peer labels") {
            try Self.admit(Self.configuration(identity: try Self.identity(peers: [
                ClusterWorkerPeer(id: "a", buildSHA256: String(repeating: "a", count: 64)),
                ClusterWorkerPeer(id: "a", buildSHA256: String(repeating: "b", count: 64)),
            ])))
        }
        refuses("build pin that is not a SHA-256") {
            try Self.admit(Self.configuration(identity: try Self.identity(peers: [
                ClusterWorkerPeer(id: "a", buildSHA256: "not-a-hash"),
                ClusterWorkerPeer(id: "b", buildSHA256: String(repeating: "b", count: 64)),
            ])))
        }
        // The model ID is a closed choice, and it cannot be crossed with the
        // other registered model's hashes or metadata in either direction.
        refuses("unregistered model ID") {
            try Self.admit(Self.configuration(identity: try Self.identity(model: "qwen38_27b")))
        }
        refuses("public catalog ID in place of the runtime model ID") {
            try Self.admit(Self.configuration(identity: try Self.identity(model: "EigenLabs/Qwen3.8-27B-4bit-mtp")))
        }
        refuses("the 9B's model ID with the 27B's hashes and metadata") {
            try Self.admit(Self.configuration(identity: try Self.identity(
                model: QwenRegisteredDenseModel.qwen35NineB.rawValue)))
        }
        refuses("the 27B's model ID with the 9B's identity hashes") {
            try Self.admit(Self.configuration(identity: try Self.identity(
                configSHA: small.configurationSHA256, artifactSHA: small.artifactSHA256)))
        }
        refuses("the 27B's identity over the 9B's configuration and manifest") {
            try Self.admit(Self.configuration(identity: valid),
                config: try Self.fixture("qwen35-9b", "configuration"), manifest: try Self.fixture("qwen35-9b", "manifest"))
        }
        refuses("the 9B's whole identity over the 27B's configuration and manifest") {
            try Self.admit(Self.configuration(cut: 4, identity: ClusterWorkerIdentity(membershipEpoch: UUID(),
                modelID: QwenRegisteredDenseModel.qwen35NineB.rawValue, artifactSHA256: small.artifactSHA256,
                configurationSHA256: small.configurationSHA256, peers: valid.peers)))
        }
        refuses("the 27B's configuration with the 9B's manifest") {
            try Self.admit(Self.configuration(identity: valid), manifest: try Self.fixture("qwen35-9b", "manifest"))
        }
        refuses("identity configuration hash") {
            try Self.admit(Self.configuration(identity: try Self.identity(
                configSHA: String(repeating: "0", count: 64))))
        }
        refuses("identity artifact hash") {
            try Self.admit(Self.configuration(identity: try Self.identity(
                artifactSHA: String(repeating: "0", count: 64))))
        }
        // The registered hashes pin the metadata bytes themselves.
        var altered = try Self.fixture("configuration")
        altered[altered.count / 2] ^= 1
        refuses("one flipped configuration bit") {
            try Self.admit(Self.configuration(identity: valid), config: altered)
        }
        var alteredManifest = try Self.fixture("manifest")
        alteredManifest[alteredManifest.count / 2] ^= 1
        refuses("one flipped manifest bit") {
            try Self.admit(Self.configuration(identity: valid), manifest: alteredManifest)
        }
        refuses("empty configuration") { try Self.admit(Self.configuration(identity: valid), config: Data()) }
        refuses("oversized configuration") {
            try Self.admit(Self.configuration(identity: valid), config: Data(repeating: 1, count: 1_048_577))
        }
        // Native environment: arithmetic contract, then the JACCL rank binding.
        var missingArithmetic = Self.environment()
        missingArithmetic.removeValue(forKey: "DARKBLOOM_BF16_WEIGHTS")
        refuses("missing arithmetic binding") {
            try Self.admit(Self.configuration(identity: valid), environment: missingArithmetic)
        }
        refuses("JACCL rank differs from the configured rank") {
            try Self.admit(Self.configuration(rank: 0, identity: valid), environment: Self.environment(rank: 1))
        }
        // A 27B-only cut is still refused for the 9B.
        #expect(throws: (any Error).self, "cut 20 on the 9B") {
            _ = try QwenResidentAdmission(configuration: QwenResidentLoadConfiguration(
                    identity: ClusterWorkerIdentity(membershipEpoch: UUID(),
                        modelID: QwenRegisteredDenseModel.qwen35NineB.rawValue, artifactSHA256: small.artifactSHA256,
                        configurationSHA256: small.configurationSHA256, peers: valid.peers),
                    modelDirectory: URL(fileURLWithPath: "/tmp"), rank: 0, stageCut: 20,
                    deadlineUptimeNanoseconds: Self.now + 1_000_000),
                configBytes: try Self.fixture("qwen35-9b", "configuration"),
                manifestBytes: try Self.fixture("qwen35-9b", "manifest"),
                environment: Self.environment(), now: Self.now, read: { _, _ in Self.matrix })
        }
    }

    @Test func capabilityMetadataDescribesTheRegisteredModelItIsGiven() throws {
        let binary = String(repeating: "1", count: 64)
        let spec = try Self.specification()
        let value = try QwenResidentCapabilityMetadata.describe(configuration: try Self.fixture("configuration"),
            manifest: try Self.fixture("manifest"), runtimeBinarySHA256: binary)
        #expect(value.adapterID == ClusterRuntimeAdapter.qwen35Dense.rawValue)
        #expect(value.runtimeModelID == "registered_qwen38_27b")
        #expect(value.profile.id == "registered_qwen38_27b_greedy_generation_v1")
        #expect(value.artifactSHA256 == spec.artifactSHA256 && value.configurationSHA256 == spec.configurationSHA256)
        #expect(value.manifestSHA256 == spec.manifestSHA256)
        #expect(value.supportedPrefillSchedules == [.serial, .oneChunkLookahead])
        #expect(value.partitions.map { $0.stages[0].sourceLayerEnd } == Self.cuts)
        for partition in value.partitions {
            #expect(partition.stages.flatMap { Array($0.sourceLayerStart..<$0.sourceLayerEnd) } == Array(0..<64))
        }
        // The described Plan is the one live admission builds for that cut.
        let admission = try Self.admit(Self.configuration(cut: 16, identity: try Self.identity()))
        #expect(value.partitions[3].planSHA256 == admission.plan.fingerprint)
        #expect(value.profileFingerprint == admission.profile.fingerprint)
        #expect(value.arithmeticPolicySHA256 == admission.arithmeticSHA256)
        // All fifteen partitions fit the protocol's record bound and survive it.
        let encoded = try ClusterRuntimeCapabilityCodec.encode(value)
        #expect(encoded.count < ClusterRuntimeCapabilityCodec.maximumBytes)
        #expect(try ClusterRuntimeCapabilityCodec.decode(encoded) == value)
        // The 9B's description is selected by its own bytes and is unchanged.
        let small = try QwenResidentCapabilityMetadata.describe(configuration: try Self.fixture("qwen35-9b", "configuration"),
            manifest: try Self.fixture("qwen35-9b", "manifest"), runtimeBinarySHA256: binary)
        #expect(small.runtimeModelID == "registered_qwen35_9b" && small.profile.id == QwenResidentAdapterDefinition.profileID)
        #expect(small.partitions.map { $0.stages[0].sourceLayerEnd } == [4, 8, 12, 16])
        #expect(small.partitions[0].planSHA256 == "67bf0b1bf94f229682df58ae1ae10c758e2a386d66d3e1b68146f5c090f6309f")
        #expect(small.profileFingerprint == "73532005bbf8385dc43db4bdb529bcd5d612af7d1055becbefe721b4be2324ff")
        // A configuration is never described with the other model's manifest.
        #expect(throws: (any Error).self, "27B configuration, 9B manifest") {
            _ = try QwenResidentCapabilityMetadata.describe(configuration: try Self.fixture("configuration"),
                manifest: try Self.fixture("qwen35-9b", "manifest"), runtimeBinarySHA256: binary)
        }
        #expect(throws: (any Error).self, "9B configuration, 27B manifest") {
            _ = try QwenResidentCapabilityMetadata.describe(configuration: try Self.fixture("qwen35-9b", "configuration"),
                manifest: try Self.fixture("manifest"), runtimeBinarySHA256: binary)
        }
        #expect(throws: (any Error).self, "changed configuration") {
            _ = try QwenResidentCapabilityMetadata.describe(configuration: try Self.fixture("configuration") + Data([32]),
                manifest: try Self.fixture("manifest"), runtimeBinarySHA256: binary)
        }
        // What a launcher may ask before any load.
        let registered = try #require(QwenResidentCapabilityMetadata.registeredModel(runtimeModelID: "registered_qwen38_27b"))
        #expect(registered.profileID == value.profile.id && registered.supportedCuts == Self.cuts && registered.layerCount == 64)
        #expect(try QwenResidentCapabilityMetadata.registeredModel(configuration: Self.fixture("configuration")) == registered)
        #expect(QwenResidentCapabilityMetadata.registeredModel(runtimeModelID: "registered_qwen35_9b")?.supportedCuts == [4, 8, 12, 16])
        #expect(QwenResidentCapabilityMetadata.registeredModel(runtimeModelID: "registered_qwen4") == nil)
        #expect(throws: (any Error).self) {
            _ = try QwenResidentCapabilityMetadata.registeredModel(configuration: Data("{}".utf8))
        }
    }

    /// The protocol accepts a model and a profile only as one registered pair.
    @Test func capabilityProtocolRefusesACrossedModelAndProfile() throws {
        let encoded = try ClusterRuntimeCapabilityCodec.encode(QwenResidentCapabilityMetadata.describe(
            configuration: try Self.fixture("configuration"), manifest: try Self.fixture("manifest"),
            runtimeBinarySHA256: String(repeating: "1", count: 64)))
        func edited(_ edit: (inout [String: Any]) -> Void) throws -> Data {
            var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            edit(&object)
            var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
            data.append(10)
            return data
        }
        #expect(try ClusterRuntimeCapabilityCodec.decode(edited { _ in }).runtimeModelID == "registered_qwen38_27b")
        #expect(throws: (any Error).self, "27B model with the 9B profile") {
            _ = try ClusterRuntimeCapabilityCodec.decode(edited { object in
                var profile = object["profile"] as! [String: Any]
                profile["id"] = "registered_qwen35_9b_greedy_generation_v1"; object["profile"] = profile
            })
        }
        #expect(throws: (any Error).self, "9B model with the 27B profile") {
            _ = try ClusterRuntimeCapabilityCodec.decode(edited { $0["runtimeModelID"] = "registered_qwen35_9b" })
        }
        #expect(throws: (any Error).self, "unregistered model") {
            _ = try ClusterRuntimeCapabilityCodec.decode(edited { $0["runtimeModelID"] = "registered_qwen4" })
        }
        #expect(throws: (any Error).self, "unregistered profile") {
            _ = try ClusterRuntimeCapabilityCodec.decode(edited { object in
                var profile = object["profile"] as! [String: Any]
                profile["id"] = "registered_qwen38_27b_sampling_v1"; object["profile"] = profile
            })
        }
        let pairs = ClusterRuntimeAdapter.qwen35Dense.registeredProfiles
        #expect(pairs.count == 2 && pairs[0].runtimeModelID == ClusterRuntimeAdapter.qwen35Dense.runtimeModelID
            && pairs[0].profileID == ClusterRuntimeAdapter.qwen35Dense.profileID)
    }
}
