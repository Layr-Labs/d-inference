import DarkbloomClusterProtocol

/// The serving half of `ClusterModelFeaturePolicy`: it reads the pair's
/// readiness, so it lives apart from the placement half that the
/// configuration checks compile without the distributed runtime.
extension ClusterModelFeaturePolicy {
    static func requireReady(_ ready: DistributedResidentReadiness?, identity: DistributedResidentIdentity,
                             profile: DistributedResidentExecutionProfile) throws {
        guard identity.modelID == "registered_qwen38_27b" else { return }
        guard profile.id == "registered_qwen38_27b_greedy_generation_v1", profile.supportsLogprobs,
              let ready, ready.identity == identity, ready.profileID == profile.id,
              ready.media == ClusterQwenMedia.contract else {
            throw DistributedEngineError.invalidConfiguration("Qwen3.8 27B requires matching native media readiness and committed-token logprobs before serving")
        }
    }
}
