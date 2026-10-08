import Foundation
import DarkbloomClusterProtocol
import Testing
@testable import DarkbloomClusterRuntime

// Resident loading/admission contract coverage. The positive admission path
// requires the authorized Qwen3.5 9B fixture (its registered hashes pin the
// real model); that path is recorded as blocked on model/hardware
// authorization, never simulated. Everything below exercises the refusal
// boundary and the JACCL environment qualification with synthetic inputs.

@Suite("Resident admission contract (synthetic, no model)")
struct ResidentAdmissionTests {
    private func identity(model: String = "qwen35_9b", configSHA: String = "",
                          artifactSHA: String = "") -> ClusterWorkerIdentity {
        ClusterWorkerIdentity(membershipEpoch: UUID(), modelID: model,
            artifactSHA256: artifactSHA, configurationSHA256: configSHA,
            peers: [
                ClusterWorkerPeer(id: "peer-a", buildSHA256: String(repeating: "a", count: 64)),
                ClusterWorkerPeer(id: "peer-b", buildSHA256: String(repeating: "b", count: 64)),
            ])
    }

    private func configuration(rank: Int = 0, cut: Int = 16,
                               schedule: ClusterPrefillSchedule = .serial,
                               deadline: UInt64 = 300_000_000_000,
                               identity: ClusterWorkerIdentity? = nil) -> QwenResidentLoadConfiguration {
        QwenResidentLoadConfiguration(
            identity: identity ?? ClusterWorkerIdentity(membershipEpoch: UUID(), modelID: "fixture",
                artifactSHA256: "", configurationSHA256: "",
                peers: [ClusterWorkerPeer(id: "a", buildSHA256: String(repeating: "a", count: 64)),
                        ClusterWorkerPeer(id: "b", buildSHA256: String(repeating: "b", count: 64))]),
            modelDirectory: URL(fileURLWithPath: "/tmp"), rank: rank, stageCut: cut,
            deadlineUptimeNanoseconds: deadline, prefillSchedule: schedule)
    }

    @Test func adapterDefinitionPinsTheRegisteredProfile() throws {
        #expect(QwenResidentAdapterDefinition.profileID == "registered_qwen35_9b_greedy_generation_v1")
        #expect(QwenResidentAdapterDefinition.maximumRequests == 16)
        #expect(QwenResidentAdapterDefinition.supportedCuts == [4, 8, 12, 16])
        let spec = try #require(QwenDenseRegisteredSpecification.all.first { $0.model == .qwen35NineB })
        let profile = try QwenResidentAdapterDefinition.profile(specification: spec)
        #expect(profile.vocabularySize == 248_320 && profile.activationDType == "bfloat16")
        #expect(profile.maximumContextTokens == 8320 && profile.maximumOutputTokens == 128)
        #expect(profile.fingerprint.count == 64)
    }

    @Test func admissionRefusesOutsideTheClosedIdentity() throws {
        let spec = try #require(QwenDenseRegisteredSpecification.all.first { $0.model == .qwen35NineB })
        let valid = identity(model: "qwen35_9b", configSHA: spec.configurationSHA256,
                             artifactSHA: spec.artifactSHA256)
        let now: UInt64 = 1_000
        let configBytes = Data(repeating: 1, count: 64)
        let manifestBytes = Data(repeating: 2, count: 64)
        func admit(_ configuration: QwenResidentLoadConfiguration) throws {
            _ = try QwenResidentAdmission(configuration: configuration, configBytes: configBytes,
                manifestBytes: manifestBytes, environment: [:], now: now, read: { _, _ in Data() })
        }
        // Wrong rank, unsupported cut, unsupported schedule.
        #expect(throws: ProbeError.self) { try admit(configuration(rank: 2, identity: valid)) }
        #expect(throws: ProbeError.self) { try admit(configuration(cut: 5, identity: valid)) }
        // Deadline already expired, or beyond the closed lifetime.
        #expect(throws: ProbeError.self) { try admit(configuration(deadline: now, identity: valid)) }
        #expect(throws: ProbeError.self) {
            try admit(configuration(deadline: now + 300_000_000_001, identity: valid))
        }
        // Duplicate peers, non-SHA build pins, wrong model family.
        let duplicatePeers = ClusterWorkerIdentity(membershipEpoch: UUID(), modelID: "qwen35_9b",
            artifactSHA256: spec.artifactSHA256, configurationSHA256: spec.configurationSHA256,
            peers: [ClusterWorkerPeer(id: "a", buildSHA256: String(repeating: "a", count: 64)),
                    ClusterWorkerPeer(id: "a", buildSHA256: String(repeating: "b", count: 64))])
        #expect(throws: ProbeError.self) { try admit(configuration(identity: duplicatePeers)) }
        #expect(throws: ProbeError.self) {
            try admit(configuration(identity: identity(model: "qwen35_9b",
                configSHA: spec.configurationSHA256, artifactSHA: spec.artifactSHA256)))
        }
        #expect(throws: ProbeError.self) {
            try admit(configuration(identity: identity(model: "other_model",
                configSHA: spec.configurationSHA256, artifactSHA: spec.artifactSHA256)))
        }
        // The registered hashes pin the real model: arbitrary config/manifest
        // bytes can never satisfy sha256 equality.
        #expect(throws: ProbeError.self) { try admit(configuration(identity: valid)) }
        // Empty or oversized metadata is refused before any identity check.
        #expect(throws: ProbeError.self) {
            _ = try QwenResidentAdmission(configuration: configuration(identity: valid),
                configBytes: Data(), manifestBytes: manifestBytes, environment: [:], now: now,
                read: { _, _ in Data() })
        }
        #expect(throws: ProbeError.self) {
            _ = try QwenResidentAdmission(configuration: configuration(identity: valid),
                configBytes: Data(repeating: 1, count: 1_048_577), manifestBytes: manifestBytes,
                environment: [:], now: now, read: { _, _ in Data() })
        }
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
