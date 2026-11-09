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

    /// Why the plan leaves the pipeline out, for its reason line (`ClusterPlacementPolicy.modesReason`); nil when
    /// this policy leaves no mode out.
    static func modesReason(_ capability: ClusterRuntimeCapability) -> String? {
        requiresQwenMediaAndLogprobs(capability) ? "Qwen3.8 27B keeps images, video and committed-token logprobs only in tensor parallel" : nil
    }

    static let explanation = "Qwen3.8 27B retains images, video and committed-token logprobs only in tensor parallel. Pipeline modes are ineligible for this model contract; measured speed estimates are unchanged."
    static let unavailable = "No tensor-parallel placement can preserve those features under the current link, shape and memory checks. No reduced-feature setup was saved."

    /// Whether a pair serving `mode` captures committed-token logprobs, as its
    /// resident runtime does (`NativeWorkerRuntime.capturesLogprobs`): GLM,
    /// Gemma 4 and MiMo V2.6 text tensor parallel, and every Qwen
    /// tensor-parallel row's lanes. No pipeline mode captures them.
    static func capturesLogprobs(_ capability: ClusterRuntimeCapability, mode: ClusterGenerationMode) -> Bool {
        guard mode == .tensorParallel, let adapter = ClusterRuntimeAdapter(rawValue: capability.adapterID) else { return false }
        return adapter == .glm5NextLayerStage || adapter == .gemma4LayerStage || adapter == .mimoV26LayerStage
            || adapter.servesQwenTensorLanes(runtimeModelID: capability.runtimeModelID)
    }

    /// The requests a cluster serving `mode` takes within the capability's
    /// profile, as its resident runtime admits them: the whole profile in
    /// tensor parallel, which charges a request beyond the memory plan at its
    /// own context when a rank reserves it, and in the pipeline of an adapter
    /// whose stages do the same (`ClusterRuntimeAdapter.pipelineServesWholeProfile`,
    /// the rule the worker's stages read too: Gemma 4); the memory plan's
    /// request (`ClusterWorkerProfile.memoryScope`) in every other mode, whose
    /// LOAD gates size it and whose ranks refuse a longer reservation
    /// (`requireWithinServedProfile`, GLM's pipeline admission). The same for
    /// every profile within the standard request.
    ///
    /// What a pair advertises is what it serves: its slot's request limits,
    /// both local `/v1/models` lists, the bridge's cut of `max_tokens` and the
    /// engine's refusals all read this (`DistributedResidentExecutionProfile.served`).
    static func servedProfile(_ capability: ClusterRuntimeCapability, mode: ClusterGenerationMode) -> ClusterWorkerProfile {
        let wholeProfile = mode == .tensorParallel || (mode == .pipeline
            && ClusterRuntimeAdapter(rawValue: capability.adapterID)?.pipelineServesWholeProfile == true)
        return wholeProfile ? capability.profile : capability.profile.memoryScope
    }

    /// What the plan says when its two sharded families keep different
    /// endpoint features and neither is required (Gemma 4 and MiMo V2.6:
    /// committed-token logprobs in tensor parallel only); nil when they keep
    /// the same, or when a model contract already rules a family out (`modesReason`).
    static func modeFeatureNote(_ capability: ClusterRuntimeCapability) -> String? {
        let modes = admissibleModes(capability)
        guard modesReason(capability) == nil, modes.contains(.tensorParallel), modes.contains(.pipeline),
              capturesLogprobs(capability, mode: .tensorParallel) != capturesLogprobs(capability, mode: .pipeline) else { return nil }
        return "Committed-token logprobs are captured in tensor parallel only; a pipeline pair refuses requests for them."
    }
}
