import Foundation
import DarkbloomClusterProtocol
import DarkbloomClusterProcess
import DarkbloomClusterRemote

/// Installed choices and exact capability values. There is deliberately no
/// Ready value or capacity field until both native children report readiness.
struct DistributedInstalledPlan: Sendable {
    let configuration: ClusterConfiguration
    let capability: ClusterRuntimeCapability
    let partition: ClusterRuntimePartition
    let paths: ClusterUserPaths

    init(saved: ClusterConfigurationStore.Saved, paths: ClusterUserPaths) throws {
        configuration = saved.configuration; capability = saved.capability; self.paths = paths
        partition = try capability.selection(planSHA256: configuration.selectedPlanSHA256)
        try capability.requireSupport(for: configuration.selectedPrefillSchedule)
        guard capability.arithmeticPolicyID == "qwen_cbv2_query128_bf16_tf32_default_v1",
              capability.stateSemantics == "requestOwnedKVAndRecurrent",
              capability.schedulingPolicy == "serial", capability.selectionPolicy == "greedy",
              configuration.peers.allSatisfy({ $0.jacclDevice.utf8.count <= 63 }) else {
            throw ClusterConfigurationError.invalid("Installed worker policy or device geometry differs")
        }
    }

    var localPeer: ClusterConfiguration.Peer { configuration.peers[configuration.localRank] }
    var maximumLifetimeNanoseconds: UInt64 { UInt64(capability.maxLifetimeSeconds) * 1_000_000_000 }
    var configurationURL: URL { URL(fileURLWithPath: localPeer.modelDirectory).appendingPathComponent("config.json") }
    var manifestURL: URL { URL(fileURLWithPath: localPeer.modelDirectory).appendingPathComponent("manifest.json") }

    func identity(epoch: UUID) -> ClusterWorkerIdentity {
        .init(membershipEpoch: epoch, modelID: capability.runtimeModelID,
            artifactSHA256: capability.artifactSHA256, configurationSHA256: capability.configurationSHA256,
            peers: configuration.peers.map { .init(id: $0.id, buildSHA256: $0.runtimeBinarySHA256) })
    }

    func binding(epoch: UUID, lease: UUID, incarnation: UUID) throws -> ClusterOwnerBinding {
        try .init(clusterID: configuration.clusterID, ownerIncarnation: incarnation, leaseID: lease,
            identity: identity(epoch: epoch), profile: capability.profile, rank: configuration.localRank,
            executionPlanSHA256: partition.planSHA256)
    }

    func matrix() throws -> Data {
        let names = configuration.peers.map(\.jacclDevice)
        let rows: [[Any]] = [[NSNull(), names[0]], [names[1], NSNull()]]
        var result = try JSONSerialization.data(withJSONObject: rows,
            options: [.sortedKeys, .withoutEscapingSlashes])
        result.append(10)
        guard result.count <= 4096 else { throw ClusterConfigurationError.invalid("Installed matrix exceeds its bound") }
        return result
    }

    func nativeEnvironment(matrix: URL) -> [String: String] {
        ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C",
         "DARKBLOOM_CBV2_ATTN_QUERY_BLOCK": "128", "DARKBLOOM_BF16_WEIGHTS": "1", "MLX_ENABLE_TF32": "1",
         "JACCL_RANK": String(configuration.localRank), "JACCL_IBV_DEVICES": matrix.path,
         "JACCL_COORDINATOR": "\(configuration.coordinator.address):\(configuration.coordinator.port)"]
    }

    func nativeArguments(binding: ClusterOwnerBinding, deadline: UInt64,
                         attachment: ClusterOwnerBootstrapAttachment) throws -> [String] {
        guard binding.identity == identity(epoch: binding.identity.membershipEpoch),
              binding.rank == configuration.localRank, binding.profile == capability.profile,
              binding.executionPlanSHA256 == partition.planSHA256,
              deadline > DispatchTime.now().uptimeNanoseconds else {
            throw ClusterConfigurationError.invalid("Native launch differs from installed owner binding")
        }
        let id = binding.identity
        return ["--model-dir", localPeer.modelDirectory, "--rank", String(binding.rank),
            "--stage-cut", String(partition.stages[0].sourceLayerEnd),
            "--membership-epoch", id.membershipEpoch.uuidString.lowercased(), "--model-id", id.modelID,
            "--artifact-sha256", id.artifactSHA256, "--configuration-sha256", id.configurationSHA256,
            "--peer0-id", id.peers[0].id, "--peer0-build-sha256", id.peers[0].buildSHA256,
            "--peer1-id", id.peers[1].id, "--peer1-build-sha256", id.peers[1].buildSHA256,
            "--deadline-uptime-nanoseconds", String(deadline)]
            + (try DistributedInstalledPrefillSelection.workerArguments(capability: capability,
                schedule: configuration.selectedPrefillSchedule)) + attachment.workerArguments
    }
}
