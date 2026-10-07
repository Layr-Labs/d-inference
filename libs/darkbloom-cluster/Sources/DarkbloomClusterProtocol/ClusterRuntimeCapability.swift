import Foundation

/// Names understood by this protocol revision, not a second artifact catalog.
/// Artifact, configuration, profile and Plan hashes come from the native adapter.
public enum ClusterRuntimeAdapter: String, Sendable {
    case qwen35Dense = "qwen35-dense-layer-stage"
    public var version: Int { 1 }
    public var runtimeModelID: String { "registered_qwen35_9b" }
    public var profileID: String { "registered_qwen35_9b_greedy_generation_v1" }
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
                supportedPrefillSchedules: [ClusterPrefillSchedule] = [.serial]) throws {
        self.runtimeBinarySHA256 = runtimeBinarySHA256; self.adapterID = adapterID; self.adapterVersion = adapterVersion
        self.runtimeModelID = runtimeModelID; self.artifactSHA256 = artifactSHA256
        self.configurationSHA256 = configurationSHA256; self.manifestSHA256 = manifestSHA256
        self.profile = profile; self.profileFingerprint = profileFingerprint; self.partitions = partitions
        self.arithmeticPolicyID = arithmeticPolicyID; self.arithmeticPolicySHA256 = arithmeticPolicySHA256
        self.maxLifetimeSeconds = maxLifetimeSeconds; self.maxRequests = maxRequests
        self.supportedPrefillSchedules = supportedPrefillSchedules
        try ClusterRuntimeCapabilityValidation.check(self)
    }

    public func requireSupport(for schedule: ClusterPrefillSchedule) throws {
        try workerRequire(supportedPrefillSchedules.contains(schedule), "Prefill schedule is not advertised by this runtime")
    }

    public func selection(planSHA256: String) throws -> ClusterRuntimePartition {
        guard let selected = partitions.first(where: { $0.planSHA256 == planSHA256 }) else {
            throw ClusterWorkerProtocolError.invalid("Unknown installed runtime partition")
        }
        return selected
    }
}
