import Foundation
import DarkbloomClusterPlacement
import DarkbloomClusterProtocol

/// What an operator states about a pair before anything is chosen: who the
/// two members are and where their installations are. It names no leader, no
/// rank and no plan; those come from the planner.
public struct ClusterPairDescription: Codable, Sendable, Equatable {
    public static let schemaName = "darkbloom_cluster_pair_description_v1"
    public static let maximumBytes = 16 * 1024

    public struct Member: Codable, Sendable, Equatable {
        public let id: String
        public let host: String
        public let port: Int
        public let user: String
        public let ownerExecutable: String
        public let workerExecutable: String
        public let modelDirectory: String
        public let runtimeBinarySHA256: String
        public let jacclDevice: String
        /// This member's own IPv4 address on the link. The native ranks meet
        /// on rank 0's, so it is used only once the planner has said which
        /// member that is.
        public let linkAddress: String
        /// The SSH trust inputs as they are on this member's own disk.
        public let trust: ClusterConfiguration.Trust
    }

    public let schema: String
    public let clusterID: String
    public let publicModelID: String
    public let capabilitySHA256: String
    public let chunkTokens: Int
    public let requestTimeoutSeconds: Int
    public let coordinatorPort: Int
    public let members: [Member]
    public let tokenizerFiles: [ClusterConfiguration.TokenizerFile]

    public static func decode(_ data: Data) throws -> ClusterPairDescription {
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw ClusterConfigurationError.invalid("Pair description exceeded its byte bound")
        }
        let value = try JSONDecoder().decode(ClusterPairDescription.self, from: data)
        guard value.schema == schemaName, value.members.count == 2, Set(value.members.map(\.id)).count == 2 else {
            throw ClusterConfigurationError.invalid("A pair description names exactly two distinct members")
        }
        return value
    }
}

/// The saved setup of each member, written from a placement instead of typed.
///
/// The planner says which member holds which range; everything a setup fixes
/// about rank follows from that here and nowhere else: the order of `peers`,
/// which member is the leader (rank 0, as the installed path requires), whose
/// link address the ranks meet on, the pinned Plan, the generation mode and
/// the prefill schedule. Each setup is passed through the strict codec, so
/// what is written is exactly what `darkbloom cluster configure` would accept.
/// Nothing is saved and nothing is trusted here; approval stays the
/// operator's, per Mac, as before.
public struct ClusterPlacementSetup: Sendable, Equatable {
    /// The member that starts the session: rank 0.
    public let leaderID: String
    /// Each member's setup, canonical bytes, by member ID.
    public let configurations: [String: Data]
    public let cut: Int
    public let planSHA256: String

    public static func synthesize(description: ClusterPairDescription, capability: ClusterRuntimeCapability,
                                  chosen: ClusterPlacementCandidate) throws -> ClusterPlacementSetup {
        guard chosen.ranks.count == 2, chosen.cuts.count == 1 else {
            throw ClusterConfigurationError.invalid("This build's installed path runs a placement of exactly two ranges")
        }
        let ranked = try chosen.ranks.map { rank -> ClusterPairDescription.Member in
            guard let member = description.members.first(where: { $0.id == rank.device }) else {
                throw ClusterConfigurationError.invalid("The placement names a device, \(rank.device), that the pair description does not")
            }
            return member
        }
        guard Set(ranked.map(\.id)).count == 2 else {
            throw ClusterConfigurationError.invalid("The placement gives both ranges to one member")
        }
        // The Plan a worker loads is identified by its hash, which only the
        // worker can compute; the record lists it for each cut it describes.
        guard let partition = capability.partitions.first(where: { $0.stages.first?.sourceLayerEnd == chosen.cut }) else {
            let described = capability.partitions.compactMap { $0.stages.first?.sourceLayerEnd }.map(String.init).joined(separator: ", ")
            throw ClusterConfigurationError.invalid("The placement cuts after \(chosen.cut) layers, and the worker's capability record describes "
                + "cuts \(described) only. The layout and the record must come from one worker build.")
        }
        try capability.requireSupport(for: chosen.mode)
        try capability.requireSupport(for: chosen.prefillSchedule)
        let peers: [[String: Any]] = ranked.enumerated().map { rank, member in
            ["id": member.id, "rank": rank, "host": member.host, "port": member.port, "user": member.user,
             "ownerExecutable": member.ownerExecutable, "workerExecutable": member.workerExecutable,
             "modelDirectory": member.modelDirectory, "runtimeBinarySHA256": member.runtimeBinarySHA256,
             "jacclDevice": member.jacclDevice]
        }
        var configurations: [String: Data] = [:]
        for (rank, member) in ranked.enumerated() {
            var object: [String: Any] = ["schema": ClusterConfiguration.schemaName, "clusterID": description.clusterID,
                "memberID": member.id, "role": rank == 0 ? "leader" : "follower", "publicModelID": description.publicModelID,
                "capabilitySHA256": description.capabilitySHA256, "selectedPlanSHA256": partition.planSHA256,
                "prefillSchedule": chosen.prefillSchedule.rawValue,
                "chunkTokens": description.chunkTokens, "requestTimeoutSeconds": description.requestTimeoutSeconds,
                "peers": peers, "coordinator": ["address": ranked[0].linkAddress, "port": description.coordinatorPort],
                "trust": ["identityFile": member.trust.identityFile, "knownHostsFile": member.trust.knownHostsFile,
                          "knownHostsSHA256": member.trust.knownHostsSHA256],
                "tokenizerFiles": description.tokenizerFiles.map {
                    ["path": $0.path, "sha256": $0.sha256, "purpose": $0.purpose.rawValue]
                }]
            // The pipeline has one saved spelling, the omitted one.
            if chosen.mode != .pipeline { object["generationMode"] = chosen.mode.rawValue }
            let input = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
            let configuration = try ClusterConfigurationCodec.decode(input, capability: capability,
                                                                     capabilitySHA256: description.capabilitySHA256)
            configurations[member.id] = try ClusterConfigurationCodec.encode(configuration, capability: capability,
                                                                           capabilitySHA256: description.capabilitySHA256)
        }
        return .init(leaderID: ranked[0].id, configurations: configurations, cut: chosen.cut, planSHA256: partition.planSHA256)
    }

    /// What the guided flow says once it has chosen, for the member at this
    /// screen: who leads and where the session is started from.
    public func narration(localMemberID: String) -> [String] {
        let local = leaderID == localMemberID
        return ["Rank order and Plan were chosen by the placement above, not typed: the cut is after \(cut) layers (Plan \(planSHA256.prefix(12))).",
                local ? "This Mac holds the first range, so it leads: the session is started from this Mac."
                      : "The other Mac (\(leaderID)) holds the first range, so it leads: the session is started from that Mac, and this Mac follows.",
                "Each Mac approves its own setup, as before. Nothing has been saved or started."]
    }
}
