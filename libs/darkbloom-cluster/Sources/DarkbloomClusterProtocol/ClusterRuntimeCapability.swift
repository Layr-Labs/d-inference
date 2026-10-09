import Foundation

/// Names understood by this protocol revision, not a second artifact catalog.
/// Artifact, configuration, profile and Plan hashes come from the native adapter.
public enum ClusterRuntimeAdapter: String, Sendable, CaseIterable {
    case qwen35Dense = "qwen35-dense-layer-stage"
    /// The same two-stage layer pipeline for Qwen3.5-architecture models whose
    /// feed-forward is a routed bank of experts beside a shared expert.
    case qwen35RoutedExperts = "qwen35-routed-expert-layer-stage"
    public var version: Int { 1 }
    /// The adapter's original pair: the first row of `registeredProfiles`.
    public var runtimeModelID: String { registeredProfiles[0].runtimeModelID }
    public var profileID: String { registeredProfiles[0].profileID }
    /// Every model/profile pair this adapter revision executes, the original
    /// pair first. A capability naming any other pair, or a model from one row
    /// with the profile of another, is refused.
    public var registeredProfiles: [(runtimeModelID: String, profileID: String)] {
        switch self {
        case .qwen35Dense:
            [("registered_qwen35_9b", "registered_qwen35_9b_greedy_generation_v1"),
             ("registered_qwen38_27b", "registered_qwen38_27b_greedy_generation_v1")]
        case .qwen35RoutedExperts:
            [("registered_qwen35_35b_a3b", "registered_qwen35_35b_a3b_greedy_generation_v1")]
        }
    }
    /// The one arithmetic policy a capability of this adapter may name. An
    /// adapter whose arithmetic depends on more of the process environment
    /// names its own policy, so a rank started under another one is refused.
    public var arithmeticPolicyID: String {
        switch self {
        case .qwen35Dense: "qwen_cbv2_query128_bf16_tf32_default_v1"
        case .qwen35RoutedExperts: "qwen_cbv2_query128_bf16_tf32_expert_tiles_v1"
        }
    }
    /// The adapter that registers a runtime model, or nil for an unregistered ID.
    public static func registering(runtimeModelID: String) -> ClusterRuntimeAdapter? {
        allCases.first { $0.registeredProfiles.contains { $0.runtimeModelID == runtimeModelID } }
    }
}

public struct ClusterRuntimeStage: Equatable, Sendable {
    public let rank: Int
    public let sourceLayerStart: Int
    public let sourceLayerEnd: Int
    public let stagePlanSHA256: String
    public let constructionConfigurationSHA256: String
    public init(rank: Int, sourceLayerStart: Int, sourceLayerEnd: Int,
                stagePlanSHA256: String, constructionConfigurationSHA256: String) {
        self.rank = rank; self.sourceLayerStart = sourceLayerStart; self.sourceLayerEnd = sourceLayerEnd
        self.stagePlanSHA256 = stagePlanSHA256
        self.constructionConfigurationSHA256 = constructionConfigurationSHA256
    }
}

/// Opaque native Plan identity plus explicit complete rank ownership. Decoding
/// checks consistency; it does not recreate the adapter's Plan/hash algorithms.
public struct ClusterRuntimePartition: Equatable, Sendable {
    public let kind: String
    public let planSHA256: String
    public let stages: [ClusterRuntimeStage]
    public init(kind: String = "contiguousWholeLayers", planSHA256: String, stages: [ClusterRuntimeStage]) {
        self.kind = kind; self.planSHA256 = planSHA256; self.stages = stages
    }
}

/// Installed software description only: no membership epoch, device identity,
/// readiness, memory capacity or authority to construct a model/request.
public struct ClusterRuntimeCapability: Equatable, Sendable {
    public static let schema = "darkbloom_cluster_runtime_capability_v1"
    public let workerProtocolVersion = ClusterWorkerLimits.version
    public let ownerProtocolVersion = 1
    public let bootstrapABIVersion = 1
    public let runtimeBinarySHA256: String
    public let adapterID: String
    public let adapterVersion: Int
    public let runtimeModelID: String
    public let artifactSHA256: String
    public let configurationSHA256: String
    public let manifestSHA256: String
    public let profile: ClusterWorkerProfile
    public let profileFingerprint: String
    public let partitions: [ClusterRuntimePartition]
    public let arithmeticPolicyID: String
    public let arithmeticPolicySHA256: String
    public let stateSemantics = "requestOwnedKVAndRecurrent"
    public let rankCount = 2
    public let batchSize = 1
    public let maxActiveRequests = 1
    public let maxLifetimeSeconds: Int
    public let maxRequests: Int
    /// Requests remain serialized even when adjacent prefill stages overlap.
    public let schedulingPolicy = "serial"
    public let supportedPrefillSchedules: [ClusterPrefillSchedule]
    /// How a request may be divided between the ranks. The pipeline is always
    /// first; a runtime that executes nothing else advertises only that.
    public let supportedGenerationModes: [ClusterGenerationMode]
    public let selectionPolicy = "greedy"
    public let modality = "text"
    public let stopPolicy = "selectedTokenIDs"
    public let speculation = "off"
    public let prefixReuse = false

    public init(runtimeBinarySHA256: String, adapterID: String, adapterVersion: Int,
                runtimeModelID: String, artifactSHA256: String, configurationSHA256: String,
                manifestSHA256: String, profile: ClusterWorkerProfile, profileFingerprint: String,
                partitions: [ClusterRuntimePartition], arithmeticPolicyID: String,
                arithmeticPolicySHA256: String, maxLifetimeSeconds: Int, maxRequests: Int,
                supportedPrefillSchedules: [ClusterPrefillSchedule] = [.serial],
                supportedGenerationModes: [ClusterGenerationMode] = [.pipeline]) throws {
        self.runtimeBinarySHA256 = runtimeBinarySHA256; self.adapterID = adapterID; self.adapterVersion = adapterVersion
        self.runtimeModelID = runtimeModelID; self.artifactSHA256 = artifactSHA256
        self.configurationSHA256 = configurationSHA256; self.manifestSHA256 = manifestSHA256
        self.profile = profile; self.profileFingerprint = profileFingerprint; self.partitions = partitions
        self.arithmeticPolicyID = arithmeticPolicyID; self.arithmeticPolicySHA256 = arithmeticPolicySHA256
        self.maxLifetimeSeconds = maxLifetimeSeconds; self.maxRequests = maxRequests
        self.supportedPrefillSchedules = supportedPrefillSchedules
        self.supportedGenerationModes = supportedGenerationModes
        try ClusterRuntimeCapabilityValidation.check(self)
    }

    public func requireSupport(for schedule: ClusterPrefillSchedule) throws {
        try workerRequire(supportedPrefillSchedules.contains(schedule), "Prefill schedule is not advertised by this runtime")
    }

    public func requireSupport(for mode: ClusterGenerationMode) throws {
        try workerRequire(supportedGenerationModes.contains(mode), "Generation mode is not advertised by this runtime")
    }

    public func selection(planSHA256: String) throws -> ClusterRuntimePartition {
        guard let selected = partitions.first(where: { $0.planSHA256 == planSHA256 }) else {
            throw ClusterWorkerProtocolError.invalid("Unknown installed runtime partition")
        }
        return selected
    }
}
