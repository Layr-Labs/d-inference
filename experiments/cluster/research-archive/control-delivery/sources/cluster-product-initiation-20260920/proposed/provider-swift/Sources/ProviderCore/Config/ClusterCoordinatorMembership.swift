import Foundation

/// Both users' explicit matching member consent. Signer commitments identify
/// registered member keys; they confer no trust or runtime approval themselves.
public struct ClusterCoordinatorMembership: Codable, Equatable, Sendable {
    public let schema: String
    public let members: [Member]
    public struct Member: Codable, Equatable, Sendable { public let id, signerSHA256: String }
    func validate(_ configuration: ClusterConfiguration) throws {
        guard schema == "darkbloom_cluster_coordinator_membership_v1", members.count == 2,
              members.map(\.id) == configuration.peers.map(\.id), Set(members.map(\.signerSHA256)).count == 2,
              members.allSatisfy({ ClusterConfigurationSyntax.hash($0.signerSHA256) && $0.signerSHA256.contains(where: { $0 != "0" }) }) else {
            throw ClusterConfigurationError.invalid("Mutual coordinator membership must bind both ranked peers and distinct registered signer commitments")
        }
    }
    func intent(configuration: ClusterConfiguration, policy: NativePairMemberPolicy) throws -> NativePairIntent {
        try validate(configuration)
        guard let attachment = configuration.nativeMember, (0..<2).contains(configuration.localRank) else {
            throw ClusterConfigurationError.invalid("Coordinator consent requires a ranked native attachment")
        }
        func bytes(_ hash: String) throws -> Data {
            guard ClusterConfigurationSyntax.hash(hash) else { throw NativePairMemberError.binding }
            let a = Array(hash)
            return Data(stride(from: 0, to: 64, by: 2).map { UInt8(String(a[$0...$0+1]), radix: 16)! })
        }
        return try NativePairIntent(clusterID: configuration.clusterID, approvalID: policy.id,
            policySHA256: bytes(attachment.coordinatorPolicySHA256), memberIDs: members.map(\.id),
            signerSHA256: members.map { try bytes($0.signerSHA256) }, rank: UInt8(configuration.localRank))
    }
    static func validateObject(_ object: [String: Any]) throws {
        guard Set(object.keys) == Set(["schema", "members"]), let members = object["members"] as? [[String: Any]], members.count == 2,
              members.allSatisfy({ Set($0.keys) == Set(["id", "signerSHA256"]) && $0["id"] is String && $0["signerSHA256"] is String }) else {
            throw ClusterConfigurationError.invalid("Unknown or malformed coordinator membership")
        }
    }
}
