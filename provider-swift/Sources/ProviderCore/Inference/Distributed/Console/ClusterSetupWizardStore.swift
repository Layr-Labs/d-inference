import Foundation
import DarkbloomClusterProtocol

/// Where the setup wizard keeps what only it knows, in an owner-only
/// directory of its own: `~/.darkbloom/cluster-setup/`.
public struct ClusterSetupPaths: Sendable, Equatable {
    public let directory: URL
    /// The wizard's progress: the pair it was given, codes confirmed, setups sent, checks passed.
    public var record: URL { directory.appendingPathComponent("wizard.json") }
    /// A setup the leader sent, waiting for this Mac's approval.
    public var inboxSetup: URL { directory.appendingPathComponent("inbox-setup.json") }
    public var inboxCapability: URL { directory.appendingPathComponent("inbox-capability.json") }

    public init(paths: ClusterUserPaths) {
        directory = paths.homeDirectory.appendingPathComponent(".darkbloom/cluster-setup", isDirectory: true)
    }
}

/// The wizard's persisted progress. It records what a person did on the
/// screen (confirmed a code) and what the wizard did (sent a setup, saw a
/// check pass), so that running `darkbloom cluster` again resumes at the
/// first step that is not done. It is never an approval: trust is the saved
/// setup's, and a start checks everything again.
public struct ClusterSetupRecord: Codable, Sendable, Equatable {
    public static let schemaName = "darkbloom_cluster_setup_wizard_v1"
    static let maximumBytes = 64 * 1024
    /// Entries kept per list; older ones are dropped.
    static let kept = 8

    /// The pair the wizard was opened with, so a later run needs no options.
    public struct Pair: Codable, Sendable, Equatable {
        public var description: String
        public var capability: String
        public var capabilitySHA256: String
        public var memberID: String

        public init(description: String, capability: String, capabilitySHA256: String, memberID: String) {
            self.description = description; self.capability = capability
            self.capabilitySHA256 = capabilitySHA256; self.memberID = memberID
        }
    }

    /// A pairing code the person saw on both screens, with the cluster it was confirmed for.
    public struct Confirmation: Codable, Sendable, Equatable {
        public var code: String
        public var clusterID: String?
        public var at: String
    }

    public struct Sent: Codable, Sendable, Equatable {
        public var clusterID: String
        public var memberID: String
        public var configurationSHA256: String
        public var at: String
    }

    public struct CheckPass: Codable, Sendable, Equatable {
        public var configurationSHA256: String
        public var at: String
        public var readySeconds: Double
        public var firstTokenMilliseconds: Int?
        public var tokensPerSecond: Double?
    }

    public var schema = ClusterSetupRecord.schemaName
    public var pair: Pair?
    public var confirmed: [Confirmation] = []
    public var sent: [Sent] = []
    public var checks: [CheckPass] = []
    /// The folder that holds this Mac's model folders, as the guided flow was
    /// told once (`--model-dir`); nil until then.
    public var modelsDirectory: String? = nil
    /// Who leads this cluster, as `darkbloom cluster` settled it at pairing:
    /// the Mac where onboarding started leads. Nil before pairing.
    public var leadership: ClusterOnboardingLeadership? = nil
    /// The derived control leader as this Mac's cluster service last knew it (claim and term, the members' facts,
    /// the plan's rank order), so a restart re-forms the same way. Nil until the service first derives it.
    public var control: ClusterControlRecord? = nil
    /// The members the planner said hold the adopted model alone (written where the plan is adopted, learned by
    /// the others from the leader's lease).
    public var aloneHolders: [String]? = nil
    /// The plan (the saved setup's selected plan SHA-256) `aloneHolders` is for: verdicts for any other plan never count.
    public var aloneHoldersPlan: String? = nil

    public init(pair: Pair? = nil) { self.pair = pair }

    public func confirmed(code: String) -> Confirmation? {
        confirmed.last { $0.code == code }
    }

    public func checkPassed(configurationSHA256: String) -> CheckPass? {
        checks.last { $0.configurationSHA256 == configurationSHA256 }
    }

    public func sentSetup(clusterID: String, memberID: String) -> Sent? {
        sent.last { $0.clusterID == clusterID && $0.memberID == memberID }
    }

    mutating func add(_ value: Confirmation) {
        confirmed.removeAll { $0.code == value.code }
        confirmed = Array((confirmed + [value]).suffix(Self.kept))
    }

    mutating func add(_ value: Sent) {
        sent.removeAll { $0.clusterID == value.clusterID && $0.memberID == value.memberID }
        sent = Array((sent + [value]).suffix(Self.kept))
    }

    mutating func add(_ value: CheckPass) {
        checks.removeAll { $0.configurationSHA256 == value.configurationSHA256 }
        checks = Array((checks + [value]).suffix(Self.kept))
    }
}

/// Who leads the cluster, settled once at pairing by `darkbloom cluster`: the
/// Mac where onboarding started (it waited on the cable) leads; the Mac that
/// joined it is a member. Kept until an explicit transfer or a new pairing.
public struct ClusterOnboardingLeadership: Codable, Sendable, Equatable {
    /// "leader" or "member".
    public var role: String
    /// The leader's pairing pin (this Mac's own on the leader).
    public var leaderPin: String
    /// The other Mac's pin and the name it showed at pairing (its chip and memory, never a host name).
    public var peerPin: String
    public var peerName: String
    public var since: String
    /// The leader asked the cluster to serve: each Mac's cluster service runs its part while this is set.
    public var serving: Bool = false
    /// The model the leader chose, for the screen.
    public var modelName: String?
    /// How the chosen model is served, in one line from the adopted plan ("Serving … across both Macs: pipeline, …").
    public var deployment: String?
    /// How the cluster serves (`ClusterServingScope`), kept until the person changes it: true after
    /// `darkbloom cluster local`, with the local API's address in `localBind` (nil: every interface). Nil or false:
    /// through the coordinator, as before. A member records the leader's choice from its start command.
    public var localOnly: Bool?
    public var localBind: String?

    public init(role: String, leaderPin: String, peerPin: String, peerName: String, since: String) {
        self.role = role; self.leaderPin = leaderPin; self.peerPin = peerPin; self.peerName = peerName; self.since = since
    }

    public var scope: ClusterServingScope {
        get { ClusterServingScope(localOnly: localOnly, bind: localBind) }
        set { localOnly = newValue.isLocalOnly ? true : nil; localBind = newValue.bind }
    }
}

/// Reads and changes the record and the inbox. Every write is an atomic,
/// owner-only replace under the configuration files' own lock.
public struct ClusterSetupStore: Sendable {
    public let paths: ClusterSetupPaths

    public init(paths: ClusterSetupPaths) { self.paths = paths }

    /// The record, or an empty one when there is none yet. A record that
    /// cannot be read is reported, not replaced.
    public func readRecord() throws -> ClusterSetupRecord {
        guard FileManager.default.fileExists(atPath: paths.record.path) else { return .init() }
        let data = try ClusterConfigurationFiles.read(paths.record, maximum: ClusterSetupRecord.maximumBytes, privateMode: true)
        let value = try JSONDecoder().decode(ClusterSetupRecord.self, from: data)
        guard value.schema == ClusterSetupRecord.schemaName else {
            throw ClusterConfigurationError.invalid("The setup wizard's record has another schema")
        }
        return value
    }

    /// Applies `change` to the record as it is on disk now and writes the result.
    @discardableResult
    public func updateRecord(_ change: (inout ClusterSetupRecord) throws -> Void) throws -> ClusterSetupRecord {
        try ClusterConfigurationFiles.ensureDirectory(paths.directory, create: true, privateMode: true)
        var result = ClusterSetupRecord()
        try ClusterConfigurationFiles.update(paths.record, maximum: ClusterSetupRecord.maximumBytes) { current in
            var record = try current.map { try JSONDecoder().decode(ClusterSetupRecord.self, from: $0) } ?? .init()
            guard record.schema == ClusterSetupRecord.schemaName else {
                throw ClusterConfigurationError.invalid("The setup wizard's record has another schema")
            }
            try change(&record)
            result = record
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
            return try encoder.encode(record)
        }
        return result
    }

    // MARK: - Inbox

    /// What a leader sends: the follower's setup and the capability record it pins.
    public struct Delivery: Codable, Sendable, Equatable {
        public static let schemaName = "darkbloom_cluster_setup_delivery_v1"
        public static let maximumBytes = 512 * 1024
        public var schema = Delivery.schemaName
        /// Base64 of the setup's bytes, as `cluster configure --input` takes them.
        public var configuration: String
        /// Base64 of the capability record's exact bytes.
        public var capability: String
        public var capabilitySHA256: String

        public init(configuration: Data, capability: Data, capabilitySHA256: String) {
            self.configuration = configuration.base64EncodedString()
            self.capability = capability.base64EncodedString()
            self.capabilitySHA256 = capabilitySHA256
        }
    }

    /// The inbox as a candidate for the existing approval, when a setup waits there.
    public var inboxCandidate: ClusterConsoleCandidate? {
        guard FileManager.default.fileExists(atPath: paths.inboxSetup.path),
              FileManager.default.fileExists(atPath: paths.inboxCapability.path),
              let capability = try? ClusterConfigurationFiles.read(paths.inboxCapability,
                  maximum: ClusterRuntimeCapabilityCodec.maximumBytes, privateMode: true) else { return nil }
        return .init(configurationInput: paths.inboxSetup, capabilityInput: paths.inboxCapability,
            capabilitySHA256: ClusterConfigurationCodec.sha256(capability))
    }

    /// Takes a delivery: it must decode as a setup for this Mac with the
    /// store's strict codec against the capability it carries. It is written
    /// to the inbox and nothing else happens: this Mac's person approves it,
    /// or does not. Returns the digest saving it would produce.
    @discardableResult
    public func receive(_ data: Data) throws -> String {
        guard !data.isEmpty, data.count <= Delivery.maximumBytes else {
            throw ClusterConfigurationError.invalid("The setup sent to this Mac is empty or too large")
        }
        let delivery = try JSONDecoder().decode(Delivery.self, from: data)
        guard delivery.schema == Delivery.schemaName,
              let configuration = Data(base64Encoded: delivery.configuration),
              let capability = Data(base64Encoded: delivery.capability) else {
            throw ClusterConfigurationError.invalid("The setup sent to this Mac is not a setup delivery this build reads")
        }
        guard ClusterConfigurationSyntax.hash(delivery.capabilitySHA256),
              ClusterConfigurationCodec.sha256(capability) == delivery.capabilitySHA256 else {
            throw ClusterConfigurationError.invalid("The capability record sent to this Mac differs from its digest")
        }
        let record = try ClusterRuntimeCapabilityCodec.decode(capability)
        var decoded = try ClusterConfigurationCodec.decode(configuration, capability: record, capabilitySHA256: delivery.capabilitySHA256)
        decoded.makePrefillSelectionExplicit()
        let digest = ClusterConfigurationCodec.sha256(try ClusterConfigurationCodec.encode(decoded,
            capability: record, capabilitySHA256: delivery.capabilitySHA256))
        try ClusterConfigurationFiles.ensureDirectory(paths.directory, create: true, privateMode: true)
        // Capability first: a setup in the inbox always has the record it pins beside it.
        try ClusterConfigurationFiles.update(paths.inboxCapability, maximum: ClusterRuntimeCapabilityCodec.maximumBytes) { _ in capability }
        try ClusterConfigurationFiles.update(paths.inboxSetup, maximum: ClusterConfigurationCodec.maximumBytes) { _ in configuration }
        return digest
    }

    /// Empties the inbox once its setup is saved.
    public func clearInbox() {
        _ = unlink(paths.inboxSetup.path)
        _ = unlink(paths.inboxCapability.path)
    }
}
