import Foundation

/// Immutable configuration handed to `ProviderLoop` at construction.
///
/// Split out of `ProviderLoop.swift` so the loop file holds the actor and its
/// behavior, not its value-type inputs.
public struct ProviderLoopConfig: Sendable {
    public let coordinatorURL: String
    public let hardware: HardwareInfo
    public let models: [ModelInfo]
    public let config: ProviderConfig
    public let authToken: String?
    public let runtimeHashes: RuntimeHashes?
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

    public init(
        coordinatorURL: String,
        hardware: HardwareInfo,
        models: [ModelInfo],
        config: ProviderConfig,
        authToken: String? = nil,
        runtimeHashes: RuntimeHashes? = nil,
        modelHashes: [String: String] = [:],
        modelHashFingerprints: [String: String] = [:],
        localEndpoint: LocalInferenceHTTPConfig? = nil
    ) {
        self.coordinatorURL = coordinatorURL
        self.hardware = hardware
        self.models = models
        self.config = config
        self.authToken = authToken
        self.runtimeHashes = runtimeHashes
        self.modelHashes = modelHashes
        self.modelHashFingerprints = modelHashFingerprints
        self.localEndpoint = localEndpoint
    }
}
