import Foundation

/// The follower rank is reached over the link control channel instead of SSH
/// (PROD-PLAN S08). Present only on a setup saved for it; such a setup has no
/// SSH trust at all (`trust` is absent), and the peers' host, user and port
/// are labels that nothing dials.
///
/// The leader listens on its link interface at `port`; the follower member
/// (`darkbloom cluster link-follower`) dials the leader's link address (the
/// native coordinator address of the setup) and serves the sessions the leader
/// opens. The edge key is derived from the secret in `secretFile`, bound to
/// `linkEpoch` and `edgeID` (the link control channel's qualification keying):
/// a private file of this user, never an argument. Production keying from the
/// native agreement or the pairing pins replaces only the key source.
public struct ClusterLinkControlAttachment: Codable, Sendable, Equatable {
    public static let schemaName = "darkbloom_cluster_link_control_v1"
    public let schema: String
    public let port: Int
    public let linkEpoch: String
    public let edgeID: String
    public let secretFile: String

    static let fields: Set<String> = ["schema", "port", "linkEpoch", "edgeID", "secretFile"]

    static func validateObject(_ object: [String: Any]) throws {
        guard Set(object.keys) == fields, object["schema"] as? String == schemaName,
              let port = object["port"] as? Int, (1024...65535).contains(port),
              object["linkEpoch"] is String, object["edgeID"] is String, object["secretFile"] is String else {
            throw ClusterConfigurationError.invalid("Malformed link control attachment")
        }
    }

    func validate() throws {
        guard schema == Self.schemaName, (1024...65535).contains(port),
              let epoch = UUID(uuidString: linkEpoch), epoch.uuidString.lowercased() == linkEpoch,
              let edge = UUID(uuidString: edgeID), edge.uuidString.lowercased() == edgeID, epoch != edge,
              ClusterConfigurationSyntax.sshPath(secretFile) else {
            throw ClusterConfigurationError.invalid("Saved link control attachment has unsupported values")
        }
    }

    public var linkEpochUUID: UUID { UUID(uuidString: linkEpoch)! }
    public var edgeUUID: UUID { UUID(uuidString: edgeID)! }
}
