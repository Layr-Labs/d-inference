import Foundation

/// A member's cluster claim as it registers it. Mirrors
/// `protocol.ClusterMembership` (darkbloom-platform
/// coordinator/protocol/cluster_membership.go). Two registrations share the
/// field and are told apart by `version`:
///
/// - The rank registration (version omitted or 2) names the cluster, the
///   member's fixed rank and the coordinator runtime policy it installed. Its
///   bytes are unchanged from the first member build unless it carries
///   `resume`.
/// - The roster registration (version 3, N18) carries no rank: the roster of
///   member pins countersigned by every member, this member's pin, its device
///   profile, its links, the models it holds and, per approved cluster policy,
///   the plan the members derived (`ClusterRosterRegistration.swift`).
///
/// The coordinator matches it against the other members and its own approval
/// catalog; the claim grants nothing by itself. The coordinator closes the
/// socket on a malformed value, so this type cannot hold one.
public struct ClusterMembership: Codable, Sendable, Equatable {
    public static let rankVersion = 2
    public static let rosterVersion = 3

    /// 3 for the roster registration; nil (or 2) for the rank registration.
    public let version: Int?
    /// The saved cluster label every member shares.
    public let clusterID: String
    /// Rank registration: 0 owns requests (leader); 1 is the follower. Zero in
    /// a roster registration.
    public let rank: Int
    /// Rank registration: lowercase hex SHA-256 of the installed canonical
    /// coordinator policy. Empty in a roster registration.
    public let policySHA256: String

    // Roster registration only.
    /// This member's pin; one of the roster's members.
    public let memberPin: String?
    public let roster: ClusterRoster?
    public let deviceProfile: ClusterRegisteredDeviceProfile?
    /// Confirmed links, at most one per other member.
    public let edges: [ClusterEdge]?
    /// Catalog models this member holds, with the artifact hash it verified.
    public let inventory: [ClusterModelArtifact]?
    /// Per approved cluster policy, the plan the members derived.
    public let plans: [ClusterPlan]?

    /// The session this member's previous connection belonged to, claimed on
    /// a new connection while that session is in its disconnect grace. A
    /// claim only: the coordinator verifies the member's attested identity.
    public var resume: Resume?

    public struct Resume: Codable, Sendable, Equatable {
        /// The session's epoch, 32 lowercase hex, and membership generation.
        public let epoch: String
        public let generation: UInt64
        public init(epoch: String, generation: UInt64) { self.epoch = epoch; self.generation = generation }
    }

    enum CodingKeys: String, CodingKey {
        case version
        case clusterID = "cluster_id"
        case rank
        case policySHA256 = "policy_sha256"
        case memberPin = "member_pin"
        case roster
        case deviceProfile = "device_profile"
        case edges, inventory, plans, resume
    }

    public var isRosterRegistration: Bool { version == Self.rosterVersion }

    /// This membership with a resume claim, or as it is without one.
    public func resuming(_ claim: Resume?) -> ClusterMembership {
        var value = self; value.resume = claim; return value
    }

    /// The rank registration.
    public init(clusterID: String, rank: Int, policySHA256: String) throws {
        try self.init(rankVersion: nil, clusterID: clusterID, rank: rank, policySHA256: policySHA256)
    }

    private init(rankVersion: Int?, clusterID: String, rank: Int, policySHA256: String) throws {
        guard rankVersion == nil || rankVersion == Self.rankVersion, ClusterConfigurationSyntax.label(clusterID),
              rank == 0 || rank == 1, ClusterConfigurationSyntax.hash(policySHA256) else {
            throw ClusterMemberControlError.invalidMembership
        }
        version = rankVersion
        self.clusterID = clusterID
        self.rank = rank
        self.policySHA256 = policySHA256
        memberPin = nil; roster = nil; deviceProfile = nil; edges = nil; inventory = nil; plans = nil
    }

    /// The roster registration. Empty `edges`, `inventory` or `plans` are
    /// omitted from the wire, as the coordinator's encoder omits them.
    public init(rosterClusterID clusterID: String, memberPin: String, roster: ClusterRoster,
                deviceProfile: ClusterRegisteredDeviceProfile, edges: [ClusterEdge] = [],
                inventory: [ClusterModelArtifact] = [], plans: [ClusterPlan] = [], resume: Resume? = nil) throws {
        version = Self.rosterVersion
        self.clusterID = clusterID; rank = 0; policySHA256 = ""
        self.memberPin = memberPin; self.roster = roster; self.deviceProfile = deviceProfile
        self.edges = edges.isEmpty ? nil : edges
        self.inventory = inventory.isEmpty ? nil : inventory
        self.plans = plans.isEmpty ? nil : plans
        self.resume = resume
        try validateRoster()
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decodeIfPresent(Int.self, forKey: .version)
        let resume = try c.decodeIfPresent(Resume.self, forKey: .resume)
        if version == Self.rosterVersion {
            // Zero and empty, as the coordinator's encoder always writes them.
            guard try c.decodeIfPresent(Int.self, forKey: .rank) ?? 0 == 0,
                  try c.decodeIfPresent(String.self, forKey: .policySHA256)?.isEmpty ?? true else {
                throw ClusterRosterError.invalidMembership
            }
            try self.init(rosterClusterID: c.decode(String.self, forKey: .clusterID),
                memberPin: c.decode(String.self, forKey: .memberPin), roster: c.decode(ClusterRoster.self, forKey: .roster),
                deviceProfile: c.decode(ClusterRegisteredDeviceProfile.self, forKey: .deviceProfile),
                edges: c.decodeIfPresent([ClusterEdge].self, forKey: .edges) ?? [],
                inventory: c.decodeIfPresent([ClusterModelArtifact].self, forKey: .inventory) ?? [],
                plans: c.decodeIfPresent([ClusterPlan].self, forKey: .plans) ?? [], resume: resume)
            return
        }
        // The rank registration stays closed to every roster field.
        for key in [CodingKeys.memberPin, .roster, .deviceProfile, .edges, .inventory, .plans] where c.contains(key) {
            throw ClusterMemberControlError.invalidMembership
        }
        try self.init(rankVersion: version,
            clusterID: c.decode(String.self, forKey: .clusterID),
            rank: c.decode(Int.self, forKey: .rank),
            policySHA256: c.decode(String.self, forKey: .policySHA256))
        try Self.validate(resume)
        self.resume = resume
    }

    /// Mirrors `validateRoster`: the label, this member's pin in a roster
    /// every member signed, the device profile, links to other roster members
    /// only (one each, no Wi-Fi), unique inventory entries, and at most one
    /// well-formed plan per policy naming only roster members.
    private func validateRoster() throws {
        guard version == Self.rosterVersion, ClusterConfigurationSyntax.label(clusterID), rank == 0, policySHA256.isEmpty,
              let memberPin, ClusterConfigurationSyntax.hash(memberPin), let roster, let deviceProfile,
              (inventory ?? []).count <= ClusterRosterSyntax.inventoryLimit,
              (plans ?? []).count <= ClusterRosterSyntax.planLimit else { throw ClusterRosterError.invalidMembership }
        try roster.verify(clusterID: clusterID)
        guard roster.hasMember(memberPin) else { throw ClusterRosterError.invalidMembership }
        try deviceProfile.validate()
        var peers = Set<String>()
        for edge in edges ?? [] {
            guard edge.peerPin != memberPin, roster.hasMember(edge.peerPin), peers.insert(edge.peerPin).inserted,
                  ClusterEdge.transports.contains(edge.transport) else { throw ClusterRosterError.invalidMembership }
        }
        var models = Set<String>()
        for held in inventory ?? [] {
            guard ClusterRosterSyntax.modelName(held.model), models.insert(held.model).inserted,
                  ClusterConfigurationSyntax.hash(held.artifactSHA256) else { throw ClusterRosterError.invalidMembership }
        }
        var policies = Set<String>()
        for plan in plans ?? [] {
            guard policies.insert(plan.policySHA256).inserted else { throw ClusterRosterError.invalidMembership }
            try plan.validate(roster: roster)
        }
        try Self.validate(resume)
    }

    /// An absent claim, or one naming a session by a 16-byte epoch and a
    /// positive generation.
    private static func validate(_ resume: Resume?) throws {
        if let resume, !ClusterRosterSyntax.epoch(resume.epoch) || resume.generation == 0 {
            throw ClusterMemberControlError.invalidMembership
        }
    }

    /// The roster hash of a roster registration, lowercase hex.
    public var rosterSHA256: String? {
        guard isRosterRegistration, let roster, let digest = try? roster.sha256(clusterID: clusterID) else { return nil }
        return ClusterMemberPin.hex(digest)
    }

    /// The plan this member registered for a cluster policy.
    public func plan(for policySHA256: String) -> ClusterPlan? { plans?.first { $0.policySHA256 == policySHA256 } }

    /// The artifact hash this member registered for `model`.
    public func artifact(for model: String) -> String? { inventory?.first { $0.model == model }?.artifactSHA256 }

    /// Whether this member registered a link to `peerPin`.
    public func reaches(_ peerPin: String) -> Bool { edges?.contains { $0.peerPin == peerPin } ?? false }
}
