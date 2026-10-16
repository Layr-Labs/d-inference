import Foundation

/// Immutable configuration handed to `ProviderLoop` at construction.
///
/// Split out of `ProviderLoop.swift` so the loop file holds the actor and its
/// behavior, not its value-type inputs.
public struct ProviderLoopConfig: Sendable {
    public let coordinatorURL: String
    public let hardware: HardwareInfo
    public let models: [ModelInfo]
    /// Verified cached candidates, separate from ordinary serving permission.
    public let autopilotInventory: [ModelInfo]
    public let config: ProviderConfig
    /// The running CLI's resolved config; nil for embedded/test instances.
    public let configPath: URL?
    public let authToken: String?
    public let runtimeHashes: RuntimeHashes?
    public let runtimeCapabilities: Set<ProviderRuntimeCapability>
    public let modelHashes: [String: String]
    /// Snapshot fingerprints captured at the same time as `modelHashes` (see
    /// `WeightHasher.snapshotFingerprint`). Seeding these lets the first
    /// `ensureModelLoaded` skip a full re-read of weights that were already
    /// hashed at startup; without them the first load re-hashes every byte.
    public let modelHashFingerprints: [String: String]
    /// When set, the provider also serves a local OpenAI-compatible HTTP
    /// endpoint off the SAME loaded models it serves to the coordinator
    /// (unified mode). nil = coordinator-only (the default).
    public let localEndpoint: LocalInferenceHTTPConfig?
    /// Restrictive registration role. The default stays ordinary solo; the
    /// control-only cluster member role is reachable only by an explicit
    /// configuration that also constructs the member control owner. It grants
    /// no trust or model capability by itself.
    public let executionRole: ProviderExecutionRole
    /// Whether an accepted member connection that later drops ends the loop
    /// (true) or permits a reconnect (false). Read only in member mode.
    public let clusterMemberStopsOnDisconnect: Bool
    /// Cluster member only: the models whose pair-serving grant this Mac's
    /// rank has passed (`ClusterMemberPreparation.prepare`).
    /// A member serves no solo inference, so for these models the single-Mac
    /// requirements, which a pair is not judged by, do not keep them out of
    /// the member's registration and pair approval. Ignored in every other role.
    public let pairServingGrantedModelIDs: Set<String>

    public init(
        coordinatorURL: String,
        hardware: HardwareInfo,
        models: [ModelInfo],
        config: ProviderConfig,
        authToken: String? = nil,
        runtimeHashes: RuntimeHashes? = nil,
        runtimeCapabilities: Set<ProviderRuntimeCapability> = [],
        modelHashes: [String: String] = [:],
        modelHashFingerprints: [String: String] = [:],
        localEndpoint: LocalInferenceHTTPConfig? = nil,
        configPath: URL? = nil,
        autopilotInventory: [ModelInfo] = [],
        executionRole: ProviderExecutionRole = .solo,
        clusterMemberStopsOnDisconnect: Bool = true,
        pairServingGrantedModelIDs: Set<String> = []
    ) {
        self.coordinatorURL = coordinatorURL
        self.hardware = hardware
        self.models = models
        self.autopilotInventory = autopilotInventory
        self.config = config
        self.configPath = configPath
        self.authToken = authToken
        self.runtimeHashes = runtimeHashes
        self.runtimeCapabilities = runtimeCapabilities
        self.modelHashes = modelHashes
        self.modelHashFingerprints = modelHashFingerprints
        self.localEndpoint = localEndpoint
        self.executionRole = executionRole
        self.clusterMemberStopsOnDisconnect = clusterMemberStopsOnDisconnect
        self.pairServingGrantedModelIDs = pairServingGrantedModelIDs
    }

    /// Whether this configuration admits a model: by the single-Mac
    /// requirements, or, for a cluster member only, by the pair-serving grant
    /// its rank passed for that model.
    func admitsModel(_ modelID: String) -> Bool {
        (executionRole == .clusterMember && pairServingGrantedModelIDs.contains(modelID))
            || ModelRuntimeRequirements.isEligible(modelID: modelID, available: runtimeCapabilities)
    }
}
