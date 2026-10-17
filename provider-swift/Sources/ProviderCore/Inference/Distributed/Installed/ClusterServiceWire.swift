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
        /// While it runs: its process, when that process started (seconds since 1970, as the process table reads it, so
        /// a recycled process number never passes for it), and whether it is the solo server (degraded serving alone).
        public var pid: Int32? = nil
        public var startedAt: Double? = nil
        public var solo: Bool? = nil
        /// While it runs: `ClusterLocalServing.notice` when this part (rank 0) serves on its local API only because the
        /// coordinator cannot take the cluster member role; nil when it serves publicly or is not rank 0.
        public var notice: String? = nil
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
    /// The derived control leader as this Mac knows it: the leader's name, the term, and what this Mac runs, in words.
    public var control: Control? = nil
    /// The cluster service that published this status (a status left by a service that ended is not current).
    public var servicePID: Int32? = nil
    /// Set while the control leader sets the cluster up again by itself after a Darkbloom update (its line).
    public var updating: String? = nil
    /// This Mac's record says the cluster serves locally only (`ClusterServingScope`); the leader sends the start again
    /// to a member whose answer differs from its own. Nil from an older build.
    public var localOnly: Bool? = nil
    /// In the answer to a `status` command: the ports of `ClusterLocalServing.servingPorts` free on this Mac (those
    /// its own API, relay or solo server holds count as free), so rank 0 takes a port free on both Macs. Nil from an
    /// older build.
    public var freePorts: [Int]? = nil
    public struct Control: Codable, Sendable, Equatable {
        public var leaderID: String
        public var leaderName: String
        public var term: UInt64
        public var reason: String
        public var leads: Bool
        /// `ClusterControlWords.line` for this Mac's mode.
        public var line: String
        /// "cluster", "following", "confirming", "idle", "waiting", "alone" or "cannotServe".
        public var mode: String
        /// This Mac leads and its claim is confirmed (or no member was reachable within the window): it may act as the leader.
        public var confirmed: Bool? = nil
        /// "waiting": seconds until this Mac serves alone (owner decision 6's absence grace).
        public var soloInSeconds: Int? = nil
    }
}

/// One command from the leader to a member's cluster service.
public struct ClusterServiceCommand: Codable, Sendable, Equatable {
    /// `cacheSettings`: the leader's cache settings for the member to apply
    /// (`cache`). `unpair`: the leader is leaving the pair named `clusterID`;
    /// the member reclaims that pair's prefix-tier records. `sendModel`: the
    /// leader asks this Mac to send it a model (folder `model`, aggregate
    /// digest `text`) over the cable. `lease`: the control leader's renewal or
    /// hand-over (control listener only). `control`: a `darkbloom cluster`
    /// command forwarded from any member to the control leader. `teardown`:
    /// this Mac's verify-teardown summary. A member whose build predates an
    /// operation refuses the command (it cannot decode it).
    public enum Operation: String, Codable, Sendable {
        case serve, stop, status, prompt, cacheSettings, unpair, sendModel, lease, control, teardown
    }
    public var op: Operation
    public var model: String?
    public var text: String?
    public var cache: ClusterCacheSettingsSync?
    public var clusterID: String?
    /// The sender's control claim: a serve or stop from a Mac whose claim is superseded is refused.
    public var claim: ClusterControlClaim?
    /// `lease`: whether the leader runs the cluster now (members run their parts only then).
    public var running: Bool?
    public var facts: [ClusterControlMember]?
    /// `lease`: the plan (selected plan SHA-256) the facts' alone verdicts are for; verdicts for another plan are dropped.
    public var alonePlan: String?
    public var control: ClusterControlRequest?
    /// `lease`: the leader's serving intent (its record's `leadership.serving`), recorded by a Mac that accepts the lease
    /// (`ClusterControlIntent`), so a start or stop survives control moving to another Mac. Nil from an older build.
    public var serving: Bool?
    /// `serve`: the leader's deployment line for `model` (mode and each Mac's share), recorded by the member so it shows
    /// the same line when it leads (`ClusterOnboardingDeployment.recorded`). Nil from an older build.
    public var deployment: String?
    /// `serve`: how the leader serves (`ClusterServingScope`), recorded by the member so the scope holds when control
    /// moves to it: true for local only, with the API's address in `bind`. Nil from an older build (nothing recorded).
    public var localOnly: Bool?
    public var bind: String?
    /// `serve`, local only: the pair's local API key (`LocalEndpoint.loadOrCreateClusterToken`), kept by the member
    /// so the key stays the same whichever Mac runs the API. Only inside the keyed link control session; never logged.
    public var localToken: String?
    public init(op: Operation, model: String? = nil, text: String? = nil, cache: ClusterCacheSettingsSync? = nil,
                clusterID: String? = nil, claim: ClusterControlClaim? = nil, running: Bool? = nil,
                facts: [ClusterControlMember]? = nil, alonePlan: String? = nil, control: ClusterControlRequest? = nil,
                serving: Bool? = nil, deployment: String? = nil, scope: ClusterServingScope? = nil) {
        self.op = op; self.model = model; self.text = text; self.cache = cache; self.clusterID = clusterID
        self.claim = claim; self.running = running; self.facts = facts
        self.alonePlan = alonePlan; self.control = control; self.serving = serving; self.deployment = deployment
        self.localOnly = scope.map(\.isLocalOnly); self.bind = scope?.bind
    }

    /// The scope a `serve` carries; nil when the sender's build sends none or its address is not one the API takes.
    public var scope: ClusterServingScope? { ClusterServingScope.carried(localOnly: localOnly, bind: bind) }
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
