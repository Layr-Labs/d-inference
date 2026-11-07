import Foundation

// The cluster service's wire over the link control channel (leader -> member
// commands and the member's answers). Plain values: the cluster service
// (`Onboarding/ClusterService.swift`) and the model-free check runners that
// drive the real link exchange on loopback share them.

/// What one Mac's cluster service reports to its leader.
public struct ClusterServiceStatus: Codable, Sendable, Equatable {
    /// The file each cluster service publishes its status in every tick, in its setup folder (`ClusterService`); another
    /// build reads production's, read only (`ClusterMachineDeviceLock.productionPairStatus`).
    static let fileName = "service-status.json"
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
        /// How long this Mac's last part ran before it ended by itself (seconds; a stop this service made leaves it
        /// as it was), nil before the first such end and from an older build.
        public var lastRunSeconds: Double? = nil
        public var solo: Bool? = nil
        /// While it runs: `ClusterLocalServing.notice` when this part (rank 0) serves on its local API only because the
        /// coordinator cannot take the cluster member role; nil when it serves publicly or is not rank 0.
        public var notice: String? = nil
        /// Exact immutable setup this running child was launched for. Unlike
        /// the service's selected setup, it changes only after restart or an
        /// acknowledged same-listener handoff. Used to fence automatic replans.
        public var configurationSHA256: String? = nil
        /// While a coordinator-paired part runs: its pair's latest progress line without its prefix
        /// (`ClusterOnboardingPairReport.text`: "starting", "serving …", "stopped (…)"); nil before any, for any other
        /// part, and from an older build.
        public var pair: String? = nil
        /// While a coordinator-paired part runs: whether the coordinator's latest trust status for it carries a current
        /// App Attest serving authorization, which pair membership requires; nil when it has sent none yet.
        public var appAttest: Bool? = nil
        /// Without App Attest: Unix seconds when this Mac's local key-generation safeguard lets the provider make a new
        /// key (`AppAttestKeyState.generationBlockedUntil`); nil when nothing blocks it or nothing is known.
        public var appAttestRetryAt: Double? = nil
    }
    public struct Session: Codable, Sendable, Equatable {
        public var observed: Bool
        public var ready: Bool
        public var readyRanks: Int
        public var ranks: Int
        public var port: Int?
        public var detail: String?
        /// The ranks whose part is ready, when known (the start's per-Mac rows); nil from an older build.
        public var readyRankList: [Int]? = nil
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
    /// This Mac's record says the pair serves Both, me first (`ClusterServingScope.publicServingWithLocalAPI`); compared
    /// as `localOnly` is. Nil from an older build.
    public var localAPI: Bool? = nil
    /// In the answer to a `status` command: the ports of `ClusterLocalServing.servingPorts` free on this Mac (those
    /// its own API, relay or solo server holds count as free), so rank 0 takes a port free on both Macs. Nil from an
    /// older build.
    public var freePorts: [Int]? = nil
    /// In the answer to a `status` command, from the Mac whose part runs rank 0: the port the pair's local API listens
    /// on, on every address, once bound (its part's discovery record), Both or local only. Every other Mac's relay
    /// passes there (`ClusterLocalRelay`). Nil otherwise, and from an older build (its local only session's port then).
    public var pairAPIPort: Int? = nil
    /// This Mac's coordinator-paired parts that ended in a row right after starting (`ClusterApprovalCheck`); the
    /// control leader makes the pair serve locally when either Mac's count reaches the solo server's limit. Nil from an
    /// older build.
    public var memberQuickEnds: Int? = nil
    /// The ID of the cluster approval this Mac's saved setup carries, "" for none. Absent (nil) from a build that does
    /// not report it, which the control leader never reads as "none" (`ClusterApprovalCheck.peerApprovalID`). The
    /// leader compares it with its own on each check and gives this Mac its own, or none, when they differ.
    public var approvalID: String? = nil
    /// This Mac's part in the pair's coordinated update, as its cluster service supervisor writes it. Nil from an
    /// older build, which cannot coordinate one.
    public var pairUpdate: ClusterPairUpdateProgress? = nil
    /// This Mac has a Darkbloom login (`darkbloom login`): the coordinator pairs only logged-in Macs. Nil from an
    /// older build, which the leader never reads as "not logged in".
    public var loggedIn: Bool? = nil
    /// This Mac's cluster service starts by itself at login (`ClusterServiceAgent.startsAtLogin`): what the other Mac
    /// reads before it says the pair starts at login on both Macs. Nil from an older build: unknown.
    public var startsAtLogin: Bool? = nil
    /// A single-Mac provider serving on this Mac (`ProviderInstanceHolder`): it holds this Mac's one serving lock and
    /// never ends by itself, so this Mac's part doesn't start beside it and the other Mac's start names it. Nil when
    /// none, and from an older build.
    public var soloServing: SoloServing? = nil
    /// Why this Mac's part can't start now, for a reason that doesn't clear by itself (single-Mac serving here, or the
    /// other Darkbloom app holding this Mac's GPU): the leading Mac's part waits for it to change instead of starting and
    /// ending again. Nil when none, and from an older build.
    public var heldBack: String? = nil
    /// Whether the pair actually runs on this Mac (`ClusterPairWatch`): `serving` is only the saved intent, which stays
    /// on for a Mac whose other Mac stopped taking part. Nil from an older build (read the intent then).
    public var pairRunning: Bool? = nil
    /// While the intent is on but the pair doesn't run: why, in plain words, with the one command to serve this Mac
    /// alone (`ClusterPairWatch.line`). Nil otherwise, and from an older build.
    public var pairNotRunning: String? = nil
    public struct SoloServing: Codable, Sendable, Equatable {
        /// Its process, nil when its lock record names none.
        public var pid: Int32?
        public init(pid: Int32?) { self.pid = pid }
    }
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
    /// this Mac's verify-teardown summary. `approval`: the cluster approval the
    /// leader fetched for the saved setup (`approval`, nil: save the setup
    /// without one), which the member checks against its own files before it
    /// saves it. `stopSolo`: stop this Mac's single-Mac serving, which blocks the pair.
    /// A member whose build predates an operation refuses the command
    /// (it cannot decode it).
    public enum Operation: String, Codable, Sendable {
        case serve, stop, status, prompt, cacheSettings, unpair, sendModel, lease, control, teardown, batchSetup, approval
        /// Stop single-Mac serving on this Mac (`darkbloom stop --solo`), as the person chose on the other Mac's screen.
        case stopSolo
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
    /// `serve`: true for Both, me first, with the local API's address in `bind`. Nil from an older build.
    public var localAPI: Bool?
    /// `serve`, local only or Both: the pair's local API key (`LocalEndpoint.loadOrCreateClusterToken`), kept by the member
    /// so the key stays the same whichever Mac runs the API. Only inside the keyed link control session; never logged.
    public var localToken: String?
    /// A drained same-model replacement from the currently saved rank-0
    /// member. Validated independently of control-leadership preference.
    public var batchSetup: ClusterAutomaticBatchSetup? = nil
    /// `approval`: the entry to save, and the link the member registers to the sender (its pin names the sender).
    /// Claims only: the member derives every pin it saves from its own files and pairing.
    public var approval: ClusterRuntimeApproval? = nil
    public var approvalEdge: ClusterEdge? = nil
    public init(op: Operation, model: String? = nil, text: String? = nil, cache: ClusterCacheSettingsSync? = nil,
                clusterID: String? = nil, claim: ClusterControlClaim? = nil, running: Bool? = nil,
                facts: [ClusterControlMember]? = nil, alonePlan: String? = nil, control: ClusterControlRequest? = nil,
                serving: Bool? = nil, deployment: String? = nil, scope: ClusterServingScope? = nil) {
        self.op = op; self.model = model; self.text = text; self.cache = cache; self.clusterID = clusterID
        self.claim = claim; self.running = running; self.facts = facts
        self.alonePlan = alonePlan; self.control = control; self.serving = serving; self.deployment = deployment
        self.localOnly = scope.map(\.isLocalOnly); self.bind = scope?.localAPIBind
        self.localAPI = scope?.addsLocalAPI == true ? true : nil
    }

    /// The scope a `serve` carries; nil when the sender's build sends none or its address is not one the API takes.
    public var scope: ClusterServingScope? { ClusterServingScope.carried(localOnly: localOnly, localAPI: localAPI, bind: bind) }
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
