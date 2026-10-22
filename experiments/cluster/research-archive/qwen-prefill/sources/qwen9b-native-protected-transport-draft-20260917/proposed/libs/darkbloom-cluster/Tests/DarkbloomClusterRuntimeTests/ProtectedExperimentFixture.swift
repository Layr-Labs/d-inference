import CryptoKit
import DarkbloomClusterBootstrap
import DarkbloomClusterProtocol
import DarkbloomClusterSecurity
import Foundation
import XCTest
@testable import DarkbloomClusterRuntime

enum ProtectedExperimentFixture {
    static let runtimeHash = String(repeating: "c", count: 64)
    static func metadata() throws -> (Data, Data) {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let fixtures = package.deletingLastPathComponent().appendingPathComponent(
            "darkbloom-cluster-worker/Tests/CapabilityChecks/Fixtures")
        return try (Data(contentsOf: fixtures.appendingPathComponent("registered-qwen35-9b.configuration.json")),
            Data(contentsOf: fixtures.appendingPathComponent("registered-qwen35-9b.manifest.json")))
    }
    static func admission(rank: Int = 0, cut: Int = 16, schedule: ClusterPrefillSchedule = .serial,
                          allocator: QwenResidentAllocatorPolicy = .disableFreedBufferCache) throws -> QwenResidentAdmission {
        let (config, manifest) = try metadata()
        let specification = try XCTUnwrap(QwenDenseRegisteredSpecification.all.first { $0.model == .qwen35NineB })
        let configuration = QwenResidentLoadConfiguration(identity: .init(membershipEpoch: UUID(),
            modelID: specification.model.rawValue, artifactSHA256: specification.artifactSHA256,
            configurationSHA256: specification.configurationSHA256,
            peers: [.init(id: "fixture0", buildSHA256: runtimeHash), .init(id: "fixture1", buildSHA256: runtimeHash)]),
            modelDirectory: URL(fileURLWithPath: "/fixture/no-payload"), rank: rank,
            stageCut: cut, deadlineUptimeNanoseconds: 1_000_000, allocatorPolicy: allocator, prefillSchedule: schedule)
        return try .init(configuration: configuration, configBytes: config, manifestBytes: manifest,
            environment: QwenLongPrefillArithmeticEnvironment.requiredValues.merging([
                "MLX_RANK": String(rank), "MLX_IBV_DEVICES": "/fixture/devices.json",
                "MLX_JACCL_COORDINATOR": "169.254.1.1:15000",
            ], uniquingKeysWith: { _, new in new }), now: 100,
            read: { _, _ in Data("[[null,\"rdma_en1\"],[\"rdma_en1\",null]]".utf8) })
    }
    static func start(_ a: QwenResidentAdmission, overrides: [String: Data] = [:],
                      frame: Int? = nil, limits: ClusterRecordLimits? = nil,
                      schedule: ClusterNativePrefillSchedule = .serial) throws -> ClusterNativeAuthorizationStart {
        func hash(_ name: String, _ value: String) throws -> Data {
            if let bytes = overrides[name] { return bytes }
            return try collectiveRecordDigest(value)
        }
        let capability = try QwenResidentCapabilityMetadata.describe(configuration: a.configBytes,
            manifest: a.manifestBytes, runtimeBinarySHA256: runtimeHash)
        let common = try ClusterNativeAuthorizationCommon(epoch: a.configuration.identity.membershipEpoch,
            membershipGeneration: 1, nativePolicyGeneration: 1,
            membershipTranscriptSHA256: Data(repeating: 1, count: 32),
            approvedNativeBindingSHA256: Data(repeating: 2, count: 32),
            planSHA256: hash("plan", a.plan.fingerprint), artifactSHA256: hash("artifact", a.specification.artifactSHA256),
            nativeRuntimeSHA256: hash("native", runtimeHash),
            capabilitySHA256: hash("capability", sha256(ClusterRuntimeCapabilityCodec.encode(capability))),
            resourcePolicySHA256: hash("resources", sha256(QwenResidentProtectedExperiment.resourcePolicyBytes())),
            profileSHA256: hash("profile", a.profile.fingerprint), schedule: schedule,
            maximumTransportFrameBytes: frame ?? QwenResidentProtectedExperiment.maximumFrameBytes,
            limits: limits ?? QwenResidentProtectedExperiment.limits())
        return try .init(common: common, rank: a.configuration.rank,
            ownerIncarnation: UUID(), leaseID: UUID(), launchID: UUID())
    }
    static func require(_ s: ClusterNativeAuthorizationStart, _ a: QwenResidentAdmission,
                        identity: ClusterBootstrapIdentity? = nil, deadline: UInt64 = 500_000) throws {
        try QwenProtectedStartValidation.require(s, admission: a,
            bootstrapIdentity: identity ?? .init(membershipEpoch: s.common.epoch, rank: s.rank),
            bootstrapDeadline: deadline)
    }
}

/// Actual codec calls, with no native buffer or model implementation substituted.
final class ProtectedBudgetSink: ClusterRecordByteIO {
    let localRank = 0, worldSize = 2
    let maximumFrameBytes = QwenResidentProtectedExperiment.maximumFrameBytes
    private(set) var frames = [Data]()
    func sendCompleted(_ bytes: Data, check: () throws -> Void) throws { try check(); frames.append(bytes); try check() }
    func receiveCompleted(byteCount: Int, check: () throws -> Void) throws -> Data { throw ClusterRecordTransferError.inactive }
    func transport() throws -> ClusterAuthenticatedRecordTransport {
        try .init(sessionKey: .init(data: Data(repeating: 9, count: 32)),
            binding: .init(epoch: UUID(), planSHA256: Data(repeating: 3, count: 32),
                membershipTranscriptSHA256: Data(repeating: 4, count: 32)),
            limits: QwenResidentProtectedExperiment.limits(), io: self)
    }
    func expectation(_ count: Int) throws -> ClusterRecordTransferExpectation {
        try .init(context: .init(requestID: nil, type: .loadAgreement, expectationSHA256: Data(repeating: 5, count: 32)),
            length: .exact(count))
    }
}
