import Foundation

/// Same-model replacement over the existing authenticated pair-control
/// channel. The receiver supplies its own capability, paths and owner rules;
/// the message carries no environment, key or capacity authority.
public struct ClusterAutomaticBatchSetup: Codable, Equatable, Sendable {
    public let previousSHA256: String
    public let configuration: Data

    static func peerHasAdopted(_ status: ClusterServiceStatus, sha256: String) -> Bool {
        ClusterConfigurationSyntax.hash(sha256) && status.localRank == 1 && !status.sessionLeader
            && status.child.running && status.child.solo != true
            && status.child.configurationSHA256 == sha256
    }

    init(previousSHA256: String, configuration: Data) {
        self.previousSHA256 = previousSHA256; self.configuration = configuration
    }
}
