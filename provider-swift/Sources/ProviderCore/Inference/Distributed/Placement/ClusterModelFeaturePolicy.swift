import DarkbloomClusterProtocol

/// Provider admissibility for an existing registered model, not a capability
/// grant. Native artifact/shape/link/memory checks and actual READY remain
/// authoritative. Keep this narrower than the worker's supported-mode list:
/// a loadable text mode need not preserve this model's endpoint features.
enum ClusterModelFeaturePolicy {
    static func requiresQwenMediaAndLogprobs(_ capability: ClusterRuntimeCapability) -> Bool {
        capability.adapterID == ClusterRuntimeAdapter.qwen35Dense.rawValue
            && capability.runtimeModelID == "registered_qwen38_27b"
            && capability.profile.id == "registered_qwen38_27b_greedy_generation_v1"
    }

    static func admissibleModes(_ capability: ClusterRuntimeCapability) -> [ClusterGenerationMode] {
        guard requiresQwenMediaAndLogprobs(capability) else { return capability.supportedGenerationModes }
        return capability.supportedGenerationModes.filter { $0 == .tensorParallel }
    }

    static func requireSelectedMode(_ mode: ClusterGenerationMode, capability: ClusterRuntimeCapability) throws {
        guard !requiresQwenMediaAndLogprobs(capability) || admissibleModes(capability).contains(mode) else {
            throw ClusterConfigurationError.invalid("Qwen3.8 27B requires tensor parallel to retain images, video and committed-token logprobs. Run darkbloom cluster again to replan this saved setup; pipeline cannot preserve those features.")
        }
    }

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

    /// Why the plan leaves the pipeline out, for its reason line (`ClusterPlacementPolicy.modesReason`); nil when
    /// this policy leaves no mode out.
    static func modesReason(_ capability: ClusterRuntimeCapability) -> String? {
        requiresQwenMediaAndLogprobs(capability) ? "Qwen3.8 27B keeps images, video and committed-token logprobs only in tensor parallel" : nil
    }

    static let explanation = "Qwen3.8 27B retains images, video and committed-token logprobs only in tensor parallel. Pipeline modes are ineligible for this model contract; measured speed estimates are unchanged."
    static let unavailable = "No tensor-parallel placement can preserve those features under the current link, shape and memory checks. No reduced-feature setup was saved."
}
