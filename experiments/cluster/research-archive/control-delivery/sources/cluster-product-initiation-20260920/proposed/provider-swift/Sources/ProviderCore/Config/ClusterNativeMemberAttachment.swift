import Foundation
import DarkbloomClusterProtocol

/// Saved expectations, not a grant, runtime approval or serving capacity. The
/// actual WSS member session must receive B's matching committed start later.
public struct ClusterNativeMemberAttachment: Codable, Sendable, Equatable {
    public static let schemaName = "darkbloom_cluster_native_member_v1"
    public static let protectedProfile = "qwen9b_short_records_experiment_v1"
    public let schema: String
    public let bootstrapProfile: String
    public let workerProfile: String
    public let ownerSHA256: String
    public let metallib: PinnedFile
    public let resourceLibrary: PinnedFile
    public let resourcePolicySHA256: String
    public let coordinatorPolicyBase64: String
    public let coordinatorPolicySHA256: String
    public let protectedRuntimeDescriptionSHA256: String
    /// Explicit local private correctness output, never a coordinator payload
    /// or request-time destination. Omitted for the unchanged smoke path.
    public let numericalEvidenceDirectory: String?
    public let coordinatorMembership: ClusterCoordinatorMembership?

    public struct PinnedFile: Codable, Sendable, Equatable {
        public let path: String
        public let sha256: String
    }

    var policyBytes: Data {
        get throws {
            guard coordinatorPolicyBase64.utf8.count <= 10_924,
                  let bytes = Data(base64Encoded: coordinatorPolicyBase64), bytes.count <= 8192,
                  bytes.base64EncodedString() == coordinatorPolicyBase64,
                  ClusterConfigurationCodec.sha256(bytes) == coordinatorPolicySHA256 else {
                throw ClusterConfigurationError.invalid("Saved native coordinator policy differs")
            }
            return bytes
        }
    }

    func validate(configuration: ClusterConfiguration, capability: ClusterRuntimeCapability) throws {
        try coordinatorMembership?.validate(configuration)
        if let path = numericalEvidenceDirectory {
            guard path.utf8.count <= 1024, ClusterConfigurationSyntax.sshPath(path),
                  ![metallib.path, resourceLibrary.path,
                    configuration.peers[configuration.localRank].workerExecutable,
                    configuration.peers[configuration.localRank].ownerExecutable].contains(path) else {
                throw ClusterConfigurationError.invalid("Numerical evidence requires a separate absolute local directory")
            }
        }
        guard schema == Self.schemaName, bootstrapProfile == "native_key_prelude_mesh2_v1",
              workerProfile == Self.protectedProfile,
              [ownerSHA256, metallib.sha256, resourceLibrary.sha256, resourcePolicySHA256,
               coordinatorPolicySHA256, protectedRuntimeDescriptionSHA256].allSatisfy(ClusterConfigurationSyntax.hash),
              [metallib.path, resourceLibrary.path].allSatisfy(ClusterConfigurationSyntax.sshPath),
              Set([metallib.path, resourceLibrary.path, configuration.peers[configuration.localRank].workerExecutable,
                   configuration.peers[configuration.localRank].ownerExecutable]).count == 4 else {
            throw ClusterConfigurationError.invalid("Saved native member attachment has unsupported or ambiguous inputs")
        }
        let policy = try NativePairMemberPolicy(policyBytes)
        let expected = [configuration.selectedPlanSHA256, capability.artifactSHA256,
            capability.runtimeBinarySHA256, metallib.sha256, resourceLibrary.sha256,
            configuration.capabilitySHA256, resourcePolicySHA256, capability.profileFingerprint]
        guard policy.model == configuration.publicModelID,
              policy.maximumPlaintext == 131_072, policy.maximumFrame == 131_112,
              policy.maximumRecords == 1024, policy.maximumCumulative == 16_777_216,
              policy.hashes.map({ $0.map { String(format: "%02x", $0) }.joined() }) == expected,
              policy.schedule == (configuration.selectedPrefillSchedule == .serial ? 1 : 2) else {
            throw ClusterConfigurationError.invalid("Saved native policy differs from the model, runtime, Plan or profile")
        }
        // The current protected experiment is explicitly short and serial.
        // Native metadata independently enforces its own payload/resource scope.
        let partition = try capability.selection(planSHA256: configuration.selectedPlanSHA256)
        guard configuration.selectedPrefillSchedule == .serial, configuration.chunkTokens == 16,
              configuration.requestTimeoutSeconds <= 300,
              partition.stages.map(\.sourceLayerStart) == [0,16],
              partition.stages.map(\.sourceLayerEnd) == [16,32] else {
            throw ClusterConfigurationError.invalid("Saved setup exceeds the closed protected experiment scope")
        }
    }

    static func validateObject(_ object: [String: Any]) throws {
        let expected: Set<String> = ["schema", "bootstrapProfile", "workerProfile", "ownerSHA256", "metallib",
            "resourceLibrary", "resourcePolicySHA256", "coordinatorPolicyBase64", "coordinatorPolicySHA256",
            "protectedRuntimeDescriptionSHA256"]
        guard Set(object.keys).isSuperset(of: expected), Set(object.keys).isSubset(of: expected.union(["numericalEvidenceDirectory", "coordinatorMembership"])),
              (object["coordinatorMembership"] == nil || object["coordinatorMembership"] is [String: Any]),
              (object["numericalEvidenceDirectory"] == nil || object["numericalEvidenceDirectory"] is String),
              let metal = object["metallib"] as? [String: Any],
              let resource = object["resourceLibrary"] as? [String: Any],
              Set(metal.keys) == Set(["path", "sha256"]), Set(resource.keys) == Set(["path", "sha256"]) else {
            throw ClusterConfigurationError.invalid("Unknown or missing native member attachment fields")
        }
        if let membership = object["coordinatorMembership"] as? [String: Any] { try ClusterCoordinatorMembership.validateObject(membership) }
    }
}
