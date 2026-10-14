import Foundation

// The cluster service's wire over the link control channel (leader -> member
// commands and the member's answers). Plain values: the cluster service
// (`Onboarding/ClusterService.swift`) and the model-free check runners that
// drive the real link exchange on loopback share them.

/// What one Mac's cluster service reports to its leader.
public struct ClusterServiceStatus: Codable, Sendable, Equatable {
    public struct Child: Codable, Sendable, Equatable {
        public var running: Bool
        public var starts: Int
        /// How the last run ended ("exit 1", "signal 15"), nil before the first end.
        public var lastEnd: String?
        /// Seconds until the next start while it waits after an end.
        public var restartInSeconds: Int?
        /// The last error line this Mac's part printed (its log), when its last run ended.
        public var lastError: String?
    }
    public struct Session: Codable, Sendable, Equatable {
        public var observed: Bool
        public var ready: Bool
        public var readyRanks: Int
        public var ranks: Int
        public var port: Int?
        public var detail: String?
    }
    public var role: String?
    public var serving: Bool
    public var modelName: String?
    /// This Mac's saved setup runs rank 0 and the serving API.
    public var sessionLeader: Bool
    public var localRank: Int?
    public var setup: String?
    public var child: Child
    /// Only on the Mac that runs rank 0.
    public var session: Session?
    /// On a member: the digest (`ClusterMemberCacheControl.digest`) of the
    /// leader's cache settings it applied, nil when it applied none. The
    /// leader sends its settings again whenever this differs from its own.
    public var cacheSync: String? = nil
}

/// One command from the leader to a member's cluster service.
public struct ClusterServiceCommand: Codable, Sendable, Equatable {
    /// `cacheSettings`: the leader's cache settings for the member to apply
    /// (`cache`). `unpair`: the leader is leaving the pair named `clusterID`;
    /// the member reclaims that pair's prefix-tier records. A member whose
    /// build predates an operation refuses the command (it cannot decode it).
    public enum Operation: String, Codable, Sendable { case serve, stop, status, prompt, cacheSettings, unpair, sendModel }
    public var op: Operation
    public var model: String?
    public var text: String?
    public var cache: ClusterCacheSettingsSync?
    public var clusterID: String?
    public init(op: Operation, model: String? = nil, text: String? = nil, cache: ClusterCacheSettingsSync? = nil,
                clusterID: String? = nil) {
        self.op = op; self.model = model; self.text = text; self.cache = cache; self.clusterID = clusterID
    }
}

/// A test request's answer, sent back over the link.
public struct ClusterServicePromptAnswer: Codable, Sendable, Equatable {
    public var text: String
    public var tokens: Int
    public var firstTokenMilliseconds: Int?
    public var tokensPerSecond: Double?
    public var finishReason: String?
    public var error: String?
}
