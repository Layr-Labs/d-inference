import Foundation
import DarkbloomClusterProtocol

/// Saved operator choices, not an enabled backend or a worker admission.
public struct ClusterConfiguration: Codable, Sendable, Equatable {
    public static let schemaName = "darkbloom_cluster_configuration_v1"
    public let schema: String
    public let clusterID: String
    public let memberID: String
    public let role: Role
    public let publicModelID: String
    public let capabilitySHA256: String
    public let selectedPlanSHA256: String
    /// Omission preserves old saved serial setup. New saves materialize this
    /// choice; null is rejected by the strict codec.
    public private(set) var prefillSchedule: ClusterPrefillSchedule?
    public var selectedPrefillSchedule: ClusterPrefillSchedule { prefillSchedule ?? .serial }
    mutating func makePrefillSelectionExplicit() { prefillSchedule = selectedPrefillSchedule }
    public let chunkTokens: Int
    public let requestTimeoutSeconds: Int
    public let peers: [Peer]
    public let coordinator: Coordinator
    public let trust: Trust
    public let tokenizerFiles: [TokenizerFile]

    public enum Role: String, Codable, Sendable { case leader, follower }
    public struct Peer: Codable, Sendable, Equatable {
        public let id: String
        public let rank: Int
        public let host: String
        public let port: Int
        public let user: String
        public let ownerExecutable: String
        public let workerExecutable: String
        public let modelDirectory: String
        public let runtimeBinarySHA256: String
        public let jacclDevice: String
    }
    public struct Coordinator: Codable, Sendable, Equatable {
        public let address: String
        public let port: Int
    }
    public struct Trust: Codable, Sendable, Equatable {
        public let identityFile: String
        public let knownHostsFile: String
        public let knownHostsSHA256: String
    }
    public struct TokenizerFile: Codable, Sendable, Equatable {
        public enum Purpose: String, Codable, Sendable { case tokenizer, chatTemplate }
        public let path: String
        public let sha256: String
        public let purpose: Purpose
    }

    public var localRank: Int { role == .leader ? 0 : 1 }

    func validate(capability: ClusterRuntimeCapability, rawCapabilitySHA256: String) throws {
        func require(_ value: Bool, _ message: String) throws {
            guard value else { throw ClusterConfigurationError.invalid(message) }
        }
        try require(schema == Self.schemaName, "Unsupported cluster configuration schema")
        try require(ClusterConfigurationSyntax.label(clusterID) && ClusterConfigurationSyntax.label(memberID), "Invalid cluster/member identity")
        try require(!publicModelID.isEmpty && publicModelID.utf8.count <= 512
            && !publicModelID.unicodeScalars.contains(where: { $0.value < 33 || $0.value == 127 }), "Invalid public model identity")
        try require(ClusterConfigurationSyntax.hash(capabilitySHA256) && capabilitySHA256 == rawCapabilitySHA256,
                    "Cluster capability pin differs")
        try require(ClusterConfigurationSyntax.hash(selectedPlanSHA256), "Invalid selected Plan pin")
        _ = try capability.selection(planSHA256: selectedPlanSHA256)
        try capability.requireSupport(for: selectedPrefillSchedule)
        try require((1...capability.profile.maximumChunkTokens).contains(chunkTokens)
            && (1...capability.maxLifetimeSeconds).contains(requestTimeoutSeconds), "Cluster request bounds exceed the runtime capability")
        try require(peers.count == 2 && peers.map(\.rank) == [0, 1]
            && Set(peers.map(\.id)).count == 2, "Expected two distinct peers in rank order")
        try require(peers[localRank].id == memberID, "Leader/follower role does not match the local ranked member")
        try require(peers[0].host != peers[1].host, "Two cluster peers require distinct host identities")
        for peer in peers {
            try require(ClusterConfigurationSyntax.label(peer.id) && ClusterConfigurationSyntax.host(peer.host)
                && ClusterConfigurationSyntax.label(peer.user, maximum: 64) && (1...65535).contains(peer.port), "Invalid SSH peer endpoint")
            try require([peer.ownerExecutable, peer.workerExecutable, peer.modelDirectory].allSatisfy(ClusterConfigurationSyntax.sshPath),
                        "Peer installation paths must be absolute and shell-safe")
            // The first compatibility contract is one installed native build on
            // both hosts. This pin is checked on installation/start, not here.
            try require(peer.runtimeBinarySHA256 == capability.runtimeBinarySHA256, "Peer native build differs from the capability")
            try require(ClusterConfigurationSyntax.label(peer.jacclDevice, maximum: 63), "Invalid JACCL device name")
        }
        try require(ClusterConfigurationSyntax.ipv4(coordinator.address) && (1...65535).contains(coordinator.port), "Invalid JACCL coordinator address")
        try require(ClusterConfigurationSyntax.sshPath(trust.identityFile) && ClusterConfigurationSyntax.sshPath(trust.knownHostsFile)
            && trust.identityFile != trust.knownHostsFile && ClusterConfigurationSyntax.hash(trust.knownHostsSHA256), "Invalid existing SSH trust inputs")
        try require((1...16).contains(tokenizerFiles.count)
            && Set(tokenizerFiles.map(\.path)).count == tokenizerFiles.count
            && tokenizerFiles.contains(where: { $0.purpose == .tokenizer }), "Missing or duplicate tokenizer metadata pins")
        for file in tokenizerFiles {
            try require(ClusterConfigurationSyntax.relativePath(file.path) && ClusterConfigurationSyntax.hash(file.sha256), "Invalid tokenizer/template file pin")
        }
    }
}
