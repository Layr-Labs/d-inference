import Foundation
import DarkbloomClusterProtocol

/// What a Mac must have saved to be offered a pair by the coordinator: the
/// reviewed approval entry and where this Mac installed the files it pins.
/// These are saved expectations, never a grant, a runtime approval or serving
/// capacity. Omitting the attachment keeps the setup and its saved bytes as
/// they were; such a member registers no cluster membership.
public struct ClusterNativeMemberAttachment: Codable, Sendable, Equatable {
    public static let schemaName = "darkbloom_cluster_native_member_v1"
    public let schema: String
    /// SHA-256 of this Mac's installed owner executable (`peers[local].ownerExecutable`).
    public let ownerSHA256: String
    /// Installed files whose digests the approval pins.
    public let metallibPath: String
    public let resourceLibraryPath: String
    public let approval: ClusterPairApproval

    static let fields: Set<String> = ["schema", "ownerSHA256", "metallibPath", "resourceLibraryPath", "approval"]

    /// The canonical coordinator policy this member installed.
    var policyBytes: Data { get throws { try approval.canonicalPolicy() } }

    func validate(configuration: ClusterConfiguration, capability: ClusterRuntimeCapability) throws {
        let local = configuration.peers[configuration.localRank]
        guard schema == Self.schemaName, ClusterConfigurationSyntax.hash(ownerSHA256),
              [metallibPath, resourceLibraryPath].allSatisfy(ClusterConfigurationSyntax.sshPath),
              Set([metallibPath, resourceLibraryPath, local.workerExecutable, local.ownerExecutable]).count == 4 else {
            throw ClusterConfigurationError.invalid("Saved native member attachment has unsupported or ambiguous inputs")
        }
        let policy = try NativePairMemberPolicy(policyBytes)
        let hashes = policy.hashes.map { $0.map { String(format: "%02x", $0) }.joined() }
        // Plan, artifact, native runtime, capability and profile are the saved
        // setup's own pins; the metallib, resource library and resource policy
        // digests exist only in the approval and are checked against the
        // installed files when the member starts.
        guard policy.model == configuration.publicModelID,
              hashes[0] == configuration.selectedPlanSHA256, hashes[1] == capability.artifactSHA256,
              hashes[2] == capability.runtimeBinarySHA256, hashes[5] == configuration.capabilitySHA256,
              hashes[7] == capability.profileFingerprint,
              policy.schedule == (configuration.selectedPrefillSchedule == .serial ? 1 : 2) else {
            throw ClusterConfigurationError.invalid("Saved pair approval differs from the model, runtime, Plan, profile or schedule")
        }
    }

    static func validateObject(_ object: [String: Any]) throws {
        guard Set(object.keys) == fields, let approval = object["approval"] as? [String: Any],
              Set(approval.keys) == ClusterPairApproval.fields else {
            throw ClusterConfigurationError.invalid("Unknown or missing native member attachment fields")
        }
    }
}
