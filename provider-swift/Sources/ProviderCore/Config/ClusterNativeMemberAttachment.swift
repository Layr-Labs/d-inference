import Foundation
import DarkbloomClusterProtocol

/// What a Mac must have saved to be offered a pair by the coordinator: the
/// reviewed approval entry and where this Mac installed the files it pins.
/// These are saved expectations, never a grant, a runtime approval or serving
/// capacity. Omitting the attachment keeps the setup and its saved bytes as
/// they were; such a member registers no cluster membership.
public struct ClusterNativeMemberAttachment: Codable, Sendable, Equatable {
    public static let schemaName = "darkbloom_cluster_native_member_v1"
    /// The roster registration (v3): a cluster approval, the roster both
    /// members countersigned, and the members' pins in rank order.
    public static let rosterSchemaName = "darkbloom_cluster_native_member_v2"
    public let schema: String
    /// SHA-256 of this Mac's installed owner executable (`peers[local].ownerExecutable`).
    public let ownerSHA256: String
    /// Installed files whose digests the approval pins.
    public let metallibPath: String
    public let resourceLibraryPath: String
    /// v1: the pair approval.
    public let approval: ClusterPairApproval?
    /// v2: the cluster approval this member derives its plan for.
    public let clusterApproval: ClusterRuntimeApproval?
    /// v2: every member's pin, Secure Enclave key and signature over the
    /// roster's canonical bytes. The coordinator forms a cluster only from
    /// members that registered byte-equal rosters.
    public let roster: ClusterRoster?
    /// v2: the roster pins in this setup's rank order (`peers[rank]`).
    public let memberPins: [String]?
    /// v2: the links this member confirmed to other roster members, keyed by
    /// their pins (the link setup's measured rate and round trip).
    public let edges: [ClusterEdge]?

    static let fields: Set<String> = ["schema", "ownerSHA256", "metallibPath", "resourceLibraryPath", "approval"]
    static let rosterFields: Set<String> = ["schema", "ownerSHA256", "metallibPath", "resourceLibraryPath",
        "clusterApproval", "roster", "memberPins", "edges"]

    public init(ownerSHA256: String, metallibPath: String, resourceLibraryPath: String, approval: ClusterPairApproval) {
        schema = Self.schemaName; self.ownerSHA256 = ownerSHA256; self.metallibPath = metallibPath
        self.resourceLibraryPath = resourceLibraryPath; self.approval = approval
        clusterApproval = nil; roster = nil; memberPins = nil; edges = nil
    }

    /// Whether this setup registers the roster registration (v3).
    var isRoster: Bool { schema == Self.rosterSchemaName }

    /// The canonical coordinator policy this member installed.
    var policyBytes: Data {
        get throws {
            if let approval { return try approval.canonicalPolicy() }
            guard let clusterApproval else { throw ClusterConfigurationError.invalid("Saved native member attachment has no approval") }
            return try clusterApproval.canonicalPolicy()
        }
    }

    func validate(configuration: ClusterConfiguration, capability: ClusterRuntimeCapability) throws {
        let local = configuration.peers[configuration.localRank]
        guard [Self.schemaName, Self.rosterSchemaName].contains(schema), ClusterConfigurationSyntax.hash(ownerSHA256),
              [metallibPath, resourceLibraryPath].allSatisfy(ClusterConfigurationSyntax.sshPath),
              Set([metallibPath, resourceLibraryPath, local.workerExecutable, local.ownerExecutable]).count == 4,
              isRoster ? (approval == nil && clusterApproval != nil && roster != nil && memberPins != nil)
                       : (approval != nil && clusterApproval == nil && roster == nil && memberPins == nil && edges == nil) else {
            throw ClusterConfigurationError.invalid("Saved native member attachment has unsupported or ambiguous inputs")
        }
        let policy = try NativePairMemberPolicy(policyBytes)
        let hashes = policy.hashes.map { $0.map { String(format: "%02x", $0) }.joined() }
        // Plan, artifact, native runtime, capability and profile are the saved
        // setup's own pins; the metallib, resource library and resource policy
        // digests exist only in the approval and are checked against the
        // installed files when the member starts. A cluster approval fixes no
        // plan: its first digest is the placement policy, and the plan is the
        // one this member derives (`selectedPlanSHA256`) and registers.
        guard policy.model == configuration.publicModelID,
              policy.cluster != nil || hashes[0] == configuration.selectedPlanSHA256,
              hashes[1] == capability.artifactSHA256,
              hashes[2] == capability.runtimeBinarySHA256, hashes[5] == configuration.capabilitySHA256,
              hashes[7] == capability.profileFingerprint,
              policy.schedule == (configuration.selectedPrefillSchedule == .serial ? 1 : 2) else {
            throw ClusterConfigurationError.invalid("Saved pair approval differs from the model, runtime, Plan, profile or schedule")
        }
        guard isRoster else { return }
        guard let roster, let memberPins, let terms = policy.cluster else {
            throw ClusterConfigurationError.invalid("Saved roster registration needs a cluster approval")
        }
        do { try roster.verify(clusterID: configuration.clusterID) }
        catch { throw ClusterConfigurationError.invalid("Saved roster is not signed by every member it lists") }
        guard memberPins.count == configuration.peers.count, Set(memberPins).count == memberPins.count,
              memberPins.allSatisfy(roster.hasMember), roster.members.count == memberPins.count,
              (terms.minimumMembers...terms.maximumMembers).contains(memberPins.count),
              (edges ?? []).allSatisfy({ $0.peerPin != memberPins[configuration.localRank] && roster.hasMember($0.peerPin)
                  && ClusterEdge.transports.contains($0.transport) }),
              Set((edges ?? []).map(\.peerPin)).count == (edges ?? []).count else {
            throw ClusterConfigurationError.invalid("Saved roster pins differ from the setup's members, the approval's bounds or the saved links")
        }
    }

    static func validateObject(_ object: [String: Any]) throws {
        if object["schema"] as? String == rosterSchemaName {
            guard Set(object.keys).isSubset(of: rosterFields),
                  Set(object.keys).isSuperset(of: rosterFields.subtracting(["edges"])),
                  let approval = object["clusterApproval"] as? [String: Any],
                  Set(approval.keys) == ClusterRuntimeApproval.fields else {
                throw ClusterConfigurationError.invalid("Unknown or missing native member attachment fields")
            }
            return
        }
        guard Set(object.keys) == fields, let approval = object["approval"] as? [String: Any],
              Set(approval.keys) == ClusterPairApproval.fields else {
            throw ClusterConfigurationError.invalid("Unknown or missing native member attachment fields")
        }
    }
}
