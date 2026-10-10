import Foundation
import DarkbloomClusterProtocol
import Testing
@testable import DarkbloomClusterRuntime

// Resident loading/admission contract coverage. Admission reads only the
// registered configuration and manifest metadata (5.8 KB, byte-exact, shared
// with the worker capability checks), never weights, so the positive path runs
// here. Loading the model and running a request still need the full artifact
// and two Macs; those are recorded as blocked, never simulated.

@Suite("Resident admission contract (registered metadata, no model)")
struct ResidentAdmissionTests {
    private static let now: UInt64 = 1_000
    private static let matrix = Data(#"[[null,"tb5-a"],["tb5-b",null]]"#.utf8)

    private static func fixture(_ name: String) throws -> Data {
        // Tests/DarkbloomClusterRuntimeTests -> libs, then the worker's fixtures.
        let libraries = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: libraries.appendingPathComponent(
            "darkbloom-cluster-worker/Tests/CapabilityChecks/Fixtures/registered-qwen35-9b.\(name).json"))
    }

    private static func environment(rank: Int = 0) -> [String: String] {
        ["DARKBLOOM_CBV2_ATTN_QUERY_BLOCK": "128", "DARKBLOOM_BF16_WEIGHTS": "1", "MLX_ENABLE_TF32": "1",
         "JACCL_RANK": String(rank), "JACCL_IBV_DEVICES": "/opt/cluster/matrix.json",
         "JACCL_COORDINATOR": "10.0.0.5:4499"]
    }

    private static func specification() throws -> QwenDenseRegisteredSpecification {
        try #require(QwenDenseRegisteredSpecification.all.first { $0.model == .qwen35NineB })
    }

    private static func identity(epoch: UUID = UUID(),
                                 model: String = QwenRegisteredDenseModel.qwen35NineB.rawValue,
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

    private static func configuration(rank: Int = 0, cut: Int = 4,
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

    @Test func adapterDefinitionPinsTheRegisteredProfile() throws {
        #expect(QwenResidentAdapterDefinition.profileID == "registered_qwen35_9b_greedy_generation_v1")
        #expect(QwenResidentAdapterDefinition.maximumRequests == 16)
        #expect(QwenResidentAdapterDefinition.supportedCuts == [4, 8, 12, 16])
        let profile = try QwenResidentAdapterDefinition.profile(specification: try Self.specification())
        #expect(profile.vocabularySize == 248_320 && profile.activationDType == "bfloat16")
        #expect(profile.maximumContextTokens == 8320 && profile.maximumOutputTokens == 128)
        #expect(profile.fingerprint.count == 64)
    }

    @Test func registeredMetadataAdmitsOnBothRanksWithOneAgreement() throws {
        let epoch = UUID()
        let leader = try Self.admit(Self.configuration(rank: 0, identity: try Self.identity(epoch: epoch)))
        let follower = try Self.admit(Self.configuration(rank: 1, identity: try Self.identity(epoch: epoch)))
        #expect(leader.jaccl.rank == 0 && follower.jaccl.rank == 1)
        #expect(leader.wireProfile.vocabularySize == 248_320)
        // Rank, local path and local uptime are outside the agreement: the two
        // ranks of one epoch must compute the same value before either loads.
        #expect(try leader.loadAgreementFingerprint() == follower.loadAgreementFingerprint())
        // A different epoch, cut or prefill schedule is a different agreement.
        let agreed = try leader.loadAgreementFingerprint()
        #expect(try Self.admit(Self.configuration(identity: try Self.identity())).loadAgreementFingerprint() != agreed)
        #expect(try Self.admit(Self.configuration(cut: 8, identity: try Self.identity(epoch: epoch)))
            .loadAgreementFingerprint() != agreed)
        #expect(try Self.admit(Self.configuration(schedule: .oneChunkLookahead,
            identity: try Self.identity(epoch: epoch))).loadAgreementFingerprint() != agreed)
        for cut in QwenResidentAdapterDefinition.supportedCuts {
            _ = try Self.admit(Self.configuration(cut: cut, identity: try Self.identity()))
        }
    }

    /// Each case changes exactly one input of an admission that otherwise
    /// passes (see the test above), so a refusal is attributable to it.
    @Test func admissionRefusesEachDepartureFromTheClosedIdentity() throws {
        let valid = try Self.identity()
        let spec = try Self.specification()
        func refuses(_ label: Comment, _ body: () throws -> QwenResidentAdmission) {
            #expect(throws: (any Error).self, label) { _ = try body() }
        }
        refuses("rank outside 0...1") { try Self.admit(Self.configuration(rank: 2, identity: valid)) }
        refuses("unsupported cut") { try Self.admit(Self.configuration(cut: 5, identity: valid)) }
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
        refuses("unregistered model ID") {
            try Self.admit(Self.configuration(identity: try Self.identity(model: "qwen35_9b")))
        }
        refuses("the other registered model") {
            try Self.admit(Self.configuration(identity: try Self.identity(
                model: QwenRegisteredDenseModel.qwen38TwentySevenB.rawValue)))
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
        var overridden = Self.environment()
        overridden["MLX_SDPA_BLOCKS"] = ""
        refuses("present-but-empty arithmetic override") {
            try Self.admit(Self.configuration(identity: valid), environment: overridden)
        }
        refuses("JACCL rank differs from the configured rank") {
            try Self.admit(Self.configuration(rank: 0, identity: valid), environment: Self.environment(rank: 1))
        }
        #expect(spec.manifestSHA256.count == 64)
    }

    @Test func jacclEnvironmentQualificationIsClosed() throws {
        let matrix = #"[[null,"tb5-a"],["tb5-b",null]]"#
        let matrixBytes = Data(matrix.utf8)
        func env(_ overrides: [String: String?] = [:]) -> [String: String] {
            var values = ["JACCL_RANK": "0", "JACCL_IBV_DEVICES": "/opt/cluster/matrix.json",
                          "JACCL_COORDINATOR": "10.0.0.5:4499"]
            for (key, value) in overrides {
                if let value { values[key] = value } else { values.removeValue(forKey: key) }
            }
            return values
        }
        func admit(_ values: [String: String]) throws {
            _ = try QwenResidentJACCLConfiguration.admit(environment: values,
                read: { _, limit in
                    #expect(limit == QwenResidentJACCLConfiguration.maximumMatrixBytes)
                    return matrixBytes
                })
        }
        // A fully qualified synthetic environment admits with an exact receipt.
        let configuration = try QwenResidentJACCLConfiguration.admit(environment: env(),
            read: { _, _ in matrixBytes })
        #expect(configuration.rank == 0)
        #expect(configuration.receipt.backend == "jaccl" && configuration.receipt.topology == "mesh")
        #expect(configuration.receipt.worldSize == 2 && configuration.receipt.localDevice == "tb5-a")
        #expect(configuration.receipt.physicalDeviceIdentityVerified == false)
        #expect(configuration.receipt.physicalTransferQualified == false)
        #expect(configuration.receipt.deviceMatrixSHA256.count == 64)
        // Alias conflicts, missing values, ring overrides.
        #expect(throws: ProbeError.self) {
            try admit(env(["MLX_RANK": "1"]))
        }
        #expect(throws: ProbeError.self) { try admit(env(["JACCL_RANK": nil, "MLX_RANK": nil])) }
        #expect(throws: ProbeError.self) { try admit(env(["JACCL_RING": "1"])) }
        #expect(throws: ProbeError.self) { try admit(env(["MLX_JACCL_RING": "1"])) }
        // Rank must be exactly 0 or 1.
        #expect(throws: ProbeError.self) { try admit(env(["JACCL_RANK": "2"])) }
        #expect(throws: ProbeError.self) { try admit(env(["JACCL_RANK": "rank0"])) }
        // Matrix path must be a bounded normalized absolute path.
        #expect(throws: ProbeError.self) { try admit(env(["JACCL_IBV_DEVICES": "relative/path"])) }
        #expect(throws: ProbeError.self) { try admit(env(["JACCL_IBV_DEVICES": "/opt/../etc/passwd"])) }
        // Coordinator must be a canonical unicast IPv4 endpoint with a real port.
        #expect(throws: ProbeError.self) { try admit(env(["JACCL_COORDINATOR": "localhost:4499"])) }
        #expect(throws: ProbeError.self) { try admit(env(["JACCL_COORDINATOR": "10.0.0.5:0"])) }
        #expect(throws: ProbeError.self) { try admit(env(["JACCL_COORDINATOR": "10.0.0.5:70000"])) }
        #expect(throws: ProbeError.self) { try admit(env(["JACCL_COORDINATOR": "0.0.0.0:4499"])) }
        #expect(throws: ProbeError.self) { try admit(env(["JACCL_COORDINATOR": "224.0.0.1:4499"])) }
        #expect(throws: ProbeError.self) { try admit(env(["JACCL_COORDINATOR": "10.0.0.256:4499"])) }
        // Matrix shape: exactly two ranks, null diagonal, bounded device names.
        #expect(throws: ProbeError.self) {
            _ = try QwenResidentJACCLConfiguration.admit(environment: env(),
                read: { _, _ in Data(#"[[null,"a"]]"#.utf8) })
        }
        #expect(throws: ProbeError.self) {
            _ = try QwenResidentJACCLConfiguration.admit(environment: env(),
                read: { _, _ in Data(#"[["x","a"],["b","y"]]"#.utf8) })
        }
        #expect(throws: ProbeError.self) {
            _ = try QwenResidentJACCLConfiguration.admit(environment: env(),
                read: { _, _ in Data(#"[[null,"bad name!"],["b",null]]"#.utf8) })
        }
        #expect(throws: ProbeError.self) {
            _ = try QwenResidentJACCLConfiguration.admit(environment: env(), read: { _, _ in Data() })
        }
        #expect(throws: ProbeError.self) {
            _ = try QwenResidentJACCLConfiguration.admit(environment: env(),
                read: { _, _ in Data(repeating: 0, count: 4097) })
        }
        // Drift detection around native initialization.
        try configuration.requireUnchanged(environment: env(), read: { _, _ in matrixBytes })
        #expect(throws: ProbeError.self) {
            try configuration.requireUnchanged(environment: env(["JACCL_RANK": "1"]),
                read: { _, _ in matrixBytes })
        }
        #expect(throws: ProbeError.self) {
            try configuration.requireUnchanged(environment: env(), read: { _, _ in Data("changed".utf8) })
        }
        // Initialized identity must match exactly; no rank/world substitution.
        try configuration.requireInitialized(rank: 0, worldSize: 2, transport: .jaccl)
        #expect(throws: ProbeError.self) { try configuration.requireInitialized(rank: 1, worldSize: 2, transport: .jaccl) }
        #expect(throws: ProbeError.self) { try configuration.requireInitialized(rank: 0, worldSize: 1, transport: .jaccl) }
        #expect(throws: ProbeError.self) { try configuration.requireInitialized(rank: 0, worldSize: 2, transport: .loopbackTest) }
    }
}
