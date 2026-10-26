import DarkbloomClusterProtocol

/// The serving half of `ClusterModelFeaturePolicy`: the pair's readiness and
/// the media a placement serves name the distributed runtime's and the
/// media contracts' types, so they live apart from the placement half that
/// the configuration checks compile without them.
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

    /// The media contract a placement's ranks bind into every load and report as ready
    /// (`ClusterWorkerReady.media`): GLM-5.3-Flash's and Qwen3.8 27B's tensor-parallel runtimes serve images and
    /// video; every other placement (the pipeline modes, other models) serves text only. Nil: the pair serves no
    /// media, so neither its registration nor its slot may claim any, whatever the artifact's configuration
    /// declares.
    static func mediaContract(capability: ClusterRuntimeCapability, mode: ClusterGenerationMode) -> String? {
        guard mode == .tensorParallel else { return nil }
        if capability.runtimeModelID == ClusterGLMImageCandidate.runtimeModelID,
           capability.profile.id == ClusterGLMImageCandidate.textProfileID {
            return ClusterGLMMedia.contract
        }
        return requiresQwenMediaAndLogprobs(capability) ? ClusterQwenMedia.contract : nil
    }
}
