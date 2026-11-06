import Foundation
import CryptoKit
import DarkbloomClusterProtocol
import DarkbloomClusterSecurity

/// Exact local experiment configuration, not a coordinator grant. The caller
/// must independently verify the installed executable/owner/resources and the
/// complete saved descriptor before constructing this value. Acceptance still
/// requires the same committed start and completed authenticated bootstrap.
public struct ClusterOwnerProtectedReady: Sendable {
    public static let operationalChargeBytes = 196_788_480
    public static let resourcePolicySHA256 = "dc910813838e3d06a7fcdc1a93ee3b2e8529247839048bff84f50353fb052db5"
    private let start: Data
    private let identity: ClusterWorkerIdentity
    private let profile: ClusterWorkerProfile
    private let rank: Int
    private let plan: String

    public init(verifiedDescription: Data, expectedDescriptionSHA256: String,
                start: ClusterNativeAuthorizationStart, identity: ClusterWorkerIdentity,
                profile: ClusterWorkerProfile) throws {
        func hex(_ b: Data) -> String { b.map { String(format: "%02x", $0) }.joined() }
        guard verifiedDescription.count <= 32 * 1024,
              hex(Data(SHA256.hash(data: verifiedDescription))) == expectedDescriptionSHA256,
              let o = try JSONSerialization.jsonObject(with: verifiedDescription) as? [String: Any],
              o["schema"] as? String == "qwen9b_protected_runtime_description_v1",
              o["staticProfile"] as? String == "qwen9b_short_records_experiment_v1",
              o["bootstrapProfile"] as? String == ClusterOwnerBootstrapProfile.nativeKeyPreludeMesh2.rawValue,
              o["prefillSchedule"] as? String == "serial_v1", o["stageCut"] as? Int == 16,
              o["promptTokens"] as? Int == 32, o["chunkTokens"] as? Int == 16, o["outputTokens"] as? Int == 2,
              (o["stopTokenIDs"] as? [Int]) == [],
              o["runtimeBinarySHA256"] as? String == hex(start.common.nativeRuntimeSHA256),
              o["capabilitySHA256"] as? String == hex(start.common.capabilitySHA256),
              o["selectedPlanSHA256"] as? String == hex(start.common.planSHA256),
              o["profileFingerprint"] as? String == hex(start.common.profileSHA256),
              o["resourcePolicySHA256"] as? String == Self.resourcePolicySHA256,
              hex(start.common.resourcePolicySHA256) == Self.resourcePolicySHA256,
              let resourceBase64=o["resourcePolicyBase64"] as? String, let resource=Data(base64Encoded:resourceBase64),
              resource.base64EncodedString()==resourceBase64, hex(Data(SHA256.hash(data:resource)))==Self.resourcePolicySHA256,
              start.common.schedule == .serial, start.common.maximumTransportFrameBytes == 131_112,
              start.common.limits.maximumPlaintextBytes == 131_072,
              start.common.limits.maximumRecordsPerDirection == 1024, start.common.limits.maximumCumulativePlaintextBytesPerDirection == 16_777_216,
              identity.membershipEpoch == start.common.epoch, identity.artifactSHA256 == hex(start.common.artifactSHA256),
              identity.peers.count == 2, identity.peers.allSatisfy({ $0.buildSHA256 == hex(start.common.nativeRuntimeSHA256) }),
              profile.id == "registered_qwen35_9b_greedy_generation_v1", profile.vocabularySize == 248_320,
              profile.maximumPromptTokens == 8192, profile.maximumOutputTokens == 128,
              profile.maximumChunkTokens == 512, profile.maximumContextTokens == 8320 else {
            throw ClusterOwnerStateError.invalid("Protected experiment readiness configuration differs")
        }
        self.start = start.canonicalBytes; self.identity = identity; self.profile = profile
        rank = start.rank; plan = hex(start.common.planSHA256)
    }
    func require(start: ClusterNativeAuthorizationStart, profile: ClusterOwnerBootstrapProfile) throws {
        guard profile == .nativeKeyPreludeMesh2, start.canonicalBytes == self.start else {
            throw ClusterOwnerStateError.invalid("Protected Ready changed its committed owner")
        }
    }
    public func validate(_ ready: ClusterWorkerReady) throws {
        guard ready.identity == identity, ready.rank == rank, ready.profile == profile,
              ready.executionPlanSHA256 == plan,
              ready.requestCapacityBytes > Self.operationalChargeBytes,
              ready.requestCapacityBytes <= ClusterWorkerLimits.capacityBytes else {
            throw ClusterOwnerStateError.invalid("Protected Ready lacks its actual ordinary plus operational allowance")
        }
    }
}
