import Foundation
import DarkbloomClusterProtocol
import Testing
@testable import DarkbloomClusterRuntime

// GPT-OSS 20B as a resident model on its own adapter. This reads only the
// registered configuration and manifest (byte-exact copies of the artifact's
// own files), never weights. Loading a stage and running a request need the
// full artifact and are recorded as real runs, never simulated here. The
// stage plan, tensor inventory and capability record have their own MLX-free
// check under Tests/GPTOSSStageChecks.

@Suite("Resident admission contract, registered GPT-OSS 20B (registered metadata, no model)")
struct GPTOSSResidentAdmissionTests {
    private static let now: UInt64 = 1_000
    private static let matrix = Data(#"[[null,"tb5-a"],["tb5-b",null]]"#.utf8)

    private static func fixture(_ name: String) throws -> Data {
        // Tests/DarkbloomClusterRuntimeTests -> libs, then the worker's fixtures.
        let libraries = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: libraries.appendingPathComponent(
            "darkbloom-cluster-worker/Tests/CapabilityChecks/Fixtures/registered-gpt-oss-20b.\(name).json"))
    }

    private static func environment(rank: Int = 0) -> [String: String] {
        // What the pair driver sets for every rank, plus this rank's transport.
        ["DARKBLOOM_CBV2_ATTN_QUERY_BLOCK": "128", "DARKBLOOM_BF16_WEIGHTS": "1", "MLX_ENABLE_TF32": "1",
         "JACCL_RANK": String(rank), "JACCL_IBV_DEVICES": "/opt/cluster/matrix.json",
         "JACCL_COORDINATOR": "10.0.0.5:4499"]
    }

    private static func specification() throws -> GPTOSSRegisteredSpecification {
        try GPTOSSRegisteredSpecification.specification(runtimeModelID: GPTOSSRegisteredModel.twentyB.rawValue)
    }

    private static func identity(epoch: UUID = UUID(), model: String = GPTOSSRegisteredModel.twentyB.rawValue,
                                 configSHA: String? = nil, artifactSHA: String? = nil) throws -> ClusterWorkerIdentity {
        let spec = try specification()
        return ClusterWorkerIdentity(membershipEpoch: epoch, modelID: model,
            artifactSHA256: artifactSHA ?? spec.artifactSHA256,
            configurationSHA256: configSHA ?? spec.configurationSHA256,
            peers: [ClusterWorkerPeer(id: "peer-a", buildSHA256: String(repeating: "a", count: 64)),
                    ClusterWorkerPeer(id: "peer-b", buildSHA256: String(repeating: "b", count: 64))])
    }

    private static func admit(rank: Int = 0, cut: Int = 8, schedule: ClusterPrefillSchedule = .serial,
                              deadline: UInt64 = now + 300_000_000_000, identity: ClusterWorkerIdentity,
                              config: Data? = nil, manifest: Data? = nil,
                              environment: [String: String]? = nil) throws -> GPTOSSResidentAdmission {
        try GPTOSSResidentAdmission(configuration: .init(identity: identity, modelDirectory: URL(fileURLWithPath: "/tmp"),
                rank: rank, stageCut: cut, deadlineUptimeNanoseconds: deadline, prefillSchedule: schedule),
            configBytes: try config ?? fixture("configuration"), manifestBytes: try manifest ?? fixture("manifest"),
            environment: environment ?? Self.environment(rank: rank), now: now, read: { _, _ in matrix })
    }

    @Test func theFixturesAreTheRegisteredMetadata() throws {
        let spec = try Self.specification()
        #expect(sha256(try Self.fixture("configuration")) == spec.configurationSHA256)
        #expect(sha256(try Self.fixture("manifest")) == spec.manifestSHA256)
        #expect(spec.catalogModelID == "gpt-oss-20b" && spec.catalogVersion == "2026-05-25-r1")
    }

    @Test func registeredMetadataAdmitsOnBothRanksWithOneAgreement() throws {
        let identity = try Self.identity()
        for cut in try Self.specification().supportedCuts {
            let ranks = try (0...1).map { try Self.admit(rank: $0, cut: cut, identity: identity) }
            #expect(ranks[0].plan.fingerprint == ranks[1].plan.fingerprint)
            #expect(ranks[0].arithmeticSHA256 == ranks[1].arithmeticSHA256)
            #expect(ranks[0].profile.identifier == "registered_gpt_oss_20b_greedy_generation_v1")
            #expect(ranks[0].profile.vocabularySize == 201_088 && ranks[0].profile.hiddenSize == 2880)
            for mode in [QwenResidentGenerationMode.pipeline, .pipelineCompactDecode] {
                #expect(try ranks[0].loadAgreementFingerprint(mode: mode, transport: .jaccl)
                        == ranks[1].loadAgreementFingerprint(mode: mode, transport: .jaccl))
            }
            // What the ranks were told differently must separate them before either loads.
            #expect(try ranks[0].loadAgreementFingerprint(mode: .pipeline, transport: .jaccl)
                    != ranks[1].loadAgreementFingerprint(mode: .pipelineCompactDecode, transport: .jaccl))
            #expect(try ranks[0].loadAgreementFingerprint(mode: .pipeline, transport: .jaccl)
                    != ranks[1].loadAgreementFingerprint(mode: .pipeline, transport: .localSocketTest))
        }
        let serial = try Self.admit(identity: identity)
        let lookahead = try Self.admit(schedule: .oneChunkLookahead, identity: identity)
        #expect(try serial.loadAgreementFingerprint(mode: .pipeline, transport: .jaccl)
                != lookahead.loadAgreementFingerprint(mode: .pipeline, transport: .jaccl))
        let other = try Self.admit(cut: 10, identity: identity)
        #expect(other.plan.fingerprint != serial.plan.fingerprint)
    }

    @Test func admissionRefusesEachDepartureFromTheClosedIdentity() throws {
        let identity = try Self.identity()
        func refuses(_ label: Comment, _ body: () throws -> GPTOSSResidentAdmission) {
            #expect(throws: (any Error).self, label) { _ = try body() }
        }
        refuses("a cut outside the row") { try Self.admit(cut: 4, identity: identity) }
        refuses("a cut outside the model") { try Self.admit(cut: 24, identity: identity) }
        refuses("a third rank") { try Self.admit(rank: 2, identity: identity) }
        refuses("a dense model ID") { try Self.admit(identity: try Self.identity(model: "registered_qwen35_9b")) }
        refuses("another artifact") { try Self.admit(identity: try Self.identity(artifactSHA: String(repeating: "0", count: 64))) }
        refuses("another configuration hash") { try Self.admit(identity: try Self.identity(configSHA: String(repeating: "0", count: 64))) }
        refuses("a lifetime beyond the bound") { try Self.admit(deadline: Self.now + 300_000_000_001, identity: identity) }
        refuses("an expired deadline") { try Self.admit(deadline: Self.now, identity: identity) }
        refuses("changed configuration bytes") { try Self.admit(identity: identity, config: try Self.fixture("configuration") + Data(" ".utf8)) }
        refuses("changed manifest bytes") { try Self.admit(identity: identity, manifest: try Self.fixture("manifest") + Data(" ".utf8)) }
        refuses("a rank that differs from JACCL") { try Self.admit(rank: 0, identity: identity, environment: Self.environment(rank: 1)) }
        for (name, value) in [("DARKBLOOM_GPTOSS_FUSED_GATE_UP", "0"), ("DARKBLOOM_GPTOSS_COMPILED_EXPERTS", "1"),
                              ("MLX_COMPILED_DECODE", "0"), ("MLX_SDPA_BLOCKS", "2")] {
            refuses("an arithmetic switch") {
                var environment = Self.environment(); environment[name] = value
                return try Self.admit(identity: identity, environment: environment)
            }
        }
        refuses("no TF32 declaration") {
            var environment = Self.environment(); environment["MLX_ENABLE_TF32"] = nil
            return try Self.admit(identity: identity, environment: environment)
        }
    }

    @Test func aRequestIsHeldToTheProfile() throws {
        let admission = try Self.admit(identity: try Self.identity())
        func reservation(prompt: [Int], output: Int = 8, chunk: Int = 512, profile: String? = nil) -> ClusterWorkerReservation {
            .init(profileID: profile ?? admission.profile.identifier, promptTokenIDs: prompt, stopTokenIDs: [200_002],
                  outputCount: output, chunkSize: chunk, deadlineUptimeNanoseconds: Self.now + 1_000_000, capacityLimitBytes: 1)
        }
        let request = try admission.request(reservation(prompt: Array(repeating: 1, count: 1200)), id: UUID(), now: Self.now)
        #expect(request.prefillFrameCount == 3 && request.forwardCount == 3 + 8 - 1 && request.maximumTokens == 1208)
        #expect(throws: (any Error).self) { _ = try admission.request(reservation(prompt: [201_088]), id: UUID(), now: Self.now) }
        #expect(throws: (any Error).self) { _ = try admission.request(reservation(prompt: [1], output: 129), id: UUID(), now: Self.now) }
        #expect(throws: (any Error).self) { _ = try admission.request(reservation(prompt: [1], chunk: 513), id: UUID(), now: Self.now) }
        #expect(throws: (any Error).self) {
            _ = try admission.request(reservation(prompt: [1], profile: "registered_qwen35_9b_greedy_generation_v1"), id: UUID(), now: Self.now)
        }
        #expect(throws: (any Error).self) {
            _ = try admission.request(reservation(prompt: Array(repeating: 1, count: 8193)), id: UUID(), now: Self.now)
        }
    }

    @Test func theRequestAllowanceIsEachRanksOwnLedger() throws {
        let admission = try Self.admit(identity: try Self.identity())
        for rank in 0...1 {
            let small = try GPTOSSRequestStateBudget.estimate(specification: admission.specification,
                layers: admission.plan.stages[rank].layers, rank: rank, maximumTokens: 94, chunkSize: 30, bound: { $0 })
            let large = try GPTOSSRequestStateBudget.estimate(specification: admission.specification,
                layers: admission.plan.stages[rank].layers, rank: rank, maximumTokens: 8320, chunkSize: 512,
                bound: { ($0 + 16_383) / 16_384 * 16_384 })
            #expect(small.reservedBytes > 0 && small.reservedBytes < large.reservedBytes)
            #expect(large.fullAttentionLayers == (rank == 0 ? 4 : 8) && large.slidingLayers == large.fullAttentionLayers)
        }
    }

    @Test func theCapabilityRecordIsThisAdaptersOwn() throws {
        let spec = try Self.specification()
        let capability = try GPTOSSResidentCapabilityMetadata.describe(configuration: try Self.fixture("configuration"),
            manifest: try Self.fixture("manifest"), runtimeBinarySHA256: String(repeating: "c", count: 64))
        #expect(capability.adapterID == ClusterRuntimeAdapter.gptossLayerStage.rawValue)
        #expect(capability.runtimeModelID == spec.model.rawValue && capability.profile.id == spec.profileID)
        #expect(capability.partitions.map { $0.stages[0].sourceLayerEnd } == [6, 8, 10, 12])
        #expect(capability.supportedGenerationModes == [.pipeline, .pipelineCompactDecode])
        #expect(capability.maxLifetimeSeconds == 300 && capability.maxRequests == 16)
        // The dense catalog does not know this model, and this adapter does not know a dense one.
        #expect(QwenResidentCapabilityMetadata.registeredModel(runtimeModelID: spec.model.rawValue) == nil)
        #expect(GPTOSSResidentCapabilityMetadata.registeredModel(runtimeModelID: "registered_qwen35_9b") == nil)
        #expect(GPTOSSResidentCapabilityMetadata.registeredModel(runtimeModelID: spec.model.rawValue)?.supportedCuts == [6, 8, 10, 12])
        #expect(throws: (any Error).self) {
            _ = try QwenResidentCapabilityMetadata.describe(configuration: try Self.fixture("configuration"),
                manifest: try Self.fixture("manifest"), runtimeBinarySHA256: String(repeating: "c", count: 64))
        }
    }
}
