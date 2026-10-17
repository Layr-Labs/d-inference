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
        /// The SSH trust inputs as they are on this member's own disk; nil on a
        /// pair reached over the link control channel (`linkControl`), which
        /// has no SSH configuration at all.
        public let trust: ClusterConfiguration.Trust?
        /// This member's own copy of the pairing's edge secret, for a pair
        /// reached over the link control channel.
        public var linkSecretFile: String? = nil
    }

    /// The link control channel both members' setups use instead of SSH: the
    /// pairing's link epoch and edge (S17), and the port the leader listens on.
    public struct LinkControl: Codable, Sendable, Equatable {
        public let port: Int
        public let linkEpoch: String
        public let edgeID: String
        public init(port: Int, linkEpoch: String, edgeID: String) {
            self.port = port; self.linkEpoch = linkEpoch; self.edgeID = edgeID
        }
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
    /// Nil for a pair reached over SSH (a developer harness only).
    public var linkControl: LinkControl? = nil

    public static func decode(_ data: Data) throws -> ClusterPairDescription {
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw ClusterConfigurationError.invalid("Pair description exceeded its byte bound")
        }
        let value = try JSONDecoder().decode(ClusterPairDescription.self, from: data)
        guard value.schema == schemaName, value.members.count == 2, Set(value.members.map(\.id)).count == 2 else {
            throw ClusterConfigurationError.invalid("A pair description names exactly two distinct members")
        }
        try value.requireOneRoute()
        return value
    }

    /// Whether the planner derives the request limits (`chunkTokens` and
    /// `requestTimeoutSeconds` of zero, as the guided flow writes): from the
    /// model's qualification records and the chosen placement's predicted
    /// speed (`ClusterPlacementRequestLimits`). A description that states
    /// them (a developer harness) keeps its values.
    public var derivesRequestLimits: Bool { chunkTokens <= 0 || requestTimeoutSeconds <= 0 }

    /// The same description with the request limits given.
    func withRequestLimits(chunkTokens: Int, requestTimeoutSeconds: Int) -> ClusterPairDescription {
        var value = ClusterPairDescription(schema: schema, clusterID: clusterID, publicModelID: publicModelID, capabilitySHA256: capabilitySHA256,
            chunkTokens: chunkTokens, requestTimeoutSeconds: requestTimeoutSeconds, coordinatorPort: coordinatorPort, members: members,
            tokenizerFiles: tokenizerFiles)
        value.linkControl = linkControl
        return value
    }

    /// Every member is reached the same one way: SSH trust on each (developer
    /// harness), or the link control channel with each member's secret file.
    func requireOneRoute() throws {
        if linkControl != nil {
            guard members.allSatisfy({ $0.trust == nil && $0.linkSecretFile != nil }) else {
                throw ClusterConfigurationError.invalid("A pair reached over the link names each member's link secret and no SSH trust")
            }
        } else {
            guard members.allSatisfy({ $0.trust != nil && $0.linkSecretFile == nil }) else {
                throw ClusterConfigurationError.invalid("A pair reached over SSH names each member's SSH trust")
            }
        }
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
        // A tensor-parallel placement cuts no layer range (every rank holds its share of every layer); any other
        // placement of a pair cuts once.
        let tensorParallel = chosen.mode.usesTensorParallelDecode
        guard chosen.ranks.count == 2, chosen.cuts.count == (tensorParallel ? 0 : 1) else {
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
        // Tensor parallel: the Plan nearest the middle of the model is the load's identity (the worker loads its share of
        // every layer whatever the Plan's cut; the pair checks of the mode ran the same way).
        let described = capability.partitions.compactMap { $0.stages.first?.sourceLayerEnd }
        let layers = capability.partitions.first?.stages.last?.sourceLayerEnd ?? 0
        let cut = tensorParallel ? (described.min { abs(2 * $0 - layers) < abs(2 * $1 - layers) } ?? 0) : chosen.cut
        guard let partition = capability.partitions.first(where: { $0.stages.first?.sourceLayerEnd == cut }) else {
            throw ClusterConfigurationError.invalid("The placement cuts after \(cut) layers, and the worker's capability record describes "
                + "cuts \(described.map(String.init).joined(separator: ", ")) only. The layout and the record must come from one worker build.")
        }
        try capability.requireSupport(for: chosen.mode)
        try capability.requireSupport(for: chosen.prefillSchedule)
        let peers: [[String: Any]] = ranked.enumerated().map { rank, member in
            ["id": member.id, "rank": rank, "host": member.host, "port": member.port, "user": member.user,
             "ownerExecutable": member.ownerExecutable, "workerExecutable": member.workerExecutable,
             "modelDirectory": member.modelDirectory, "runtimeBinarySHA256": member.runtimeBinarySHA256,
             "jacclDevice": member.jacclDevice]
        }
        try description.requireOneRoute()
        var configurations: [String: Data] = [:]
        for (rank, member) in ranked.enumerated() {
            var object: [String: Any] = ["schema": ClusterConfiguration.schemaName, "clusterID": description.clusterID,
                "memberID": member.id, "role": rank == 0 ? "leader" : "follower", "publicModelID": description.publicModelID,
                "capabilitySHA256": description.capabilitySHA256, "selectedPlanSHA256": partition.planSHA256,
                "prefillSchedule": chosen.prefillSchedule.rawValue,
                "chunkTokens": description.chunkTokens, "requestTimeoutSeconds": description.requestTimeoutSeconds,
                "peers": peers, "coordinator": ["address": ranked[0].linkAddress, "port": description.coordinatorPort],
                "tokenizerFiles": description.tokenizerFiles.map {
                    ["path": $0.path, "sha256": $0.sha256, "purpose": $0.purpose.rawValue]
                }]
            if let link = description.linkControl, let secretFile = member.linkSecretFile {
                // Reached over the link control channel: no SSH configuration at all.
                object["linkControl"] = ["schema": ClusterLinkControlAttachment.schemaName, "port": link.port,
                                         "linkEpoch": link.linkEpoch, "edgeID": link.edgeID, "secretFile": secretFile]
            } else if let trust = member.trust {
                object["trust"] = ["identityFile": trust.identityFile, "knownHostsFile": trust.knownHostsFile,
                                   "knownHostsSHA256": trust.knownHostsSHA256]
            }
            // The pipeline has one saved spelling, the omitted one.
            if chosen.mode != .pipeline { object["generationMode"] = chosen.mode.rawValue }
            // Unequal tensor-parallel shares, as the planner chose them; equal shares are the omitted spelling.
            if chosen.mode == .tensorParallel, let shares = chosen.tensorShares { object["tensorShares"] = shares }
            let input = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
            let configuration = try ClusterConfigurationCodec.decode(input, capability: capability,
                                                                     capabilitySHA256: description.capabilitySHA256)
            configurations[member.id] = try ClusterConfigurationCodec.encode(configuration, capability: capability,
                                                                           capabilitySHA256: description.capabilitySHA256)
        }
        return .init(leaderID: ranked[0].id, configurations: configurations, cut: cut, planSHA256: partition.planSHA256)
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
