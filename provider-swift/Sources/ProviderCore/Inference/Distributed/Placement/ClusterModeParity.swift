import DarkbloomClusterPlacement
import DarkbloomClusterProtocol

/// Feature parity (owner, 2026-11-01: "no compromise in security stack, caching behaviors or anything else"): a mode
/// may be chosen only if it keeps every feature and caching behavior of the mode it would replace. Each mode's
/// features are the worker's own (`ClusterRuntimeCapability.modeFeatures`), never a table here. The mode tensor
/// parallel would replace is the one the plan chooses without it; where no other mode places, every other mode the
/// plan could place. A tensor-parallel mode that drops any feature of it is left out of the policy's modes before the
/// planner ranks anything, so no ordering (the margin, the evidence hold, a kept mode, a better hardware group) brings
/// it back. What it adds (its logprobs, wider lanes) never counts against it.
///
/// Applied to the families whose plan is chosen only where faster (`ClusterTensorParallelChoice.fastest`: Gemma 4 and
/// MiMo V2.6). The tensor-parallel-first families (Qwen, GLM) keep their plans: their records declare no features,
/// and what the rule would change for them is the owner's decision (docs/architecture/inference.md).
enum ClusterModeParity {
    struct Hold: Equatable {
        /// The tensor-parallel modes left out.
        let modes: [ClusterGenerationMode]
        /// What they would replace: the mode the plan places without them, or every other mode when none places.
        let replaced: [ClusterGenerationMode]
        /// The plan places another mode without them.
        let otherModePlaces: Bool
        /// What they would drop of it, in plain words; nil when the worker declares no features to compare.
        let dropped: [String]?

        /// "prompt-prefix reuse and the SSD prefix tier that the pipeline keeps"; nil when nothing is declared.
        private var drops: String? {
            dropped.map { list($0) + " that "
                + (replaced.count == 1 ? ClusterModeParity.words(replaced[0]) + " keeps" : "the model's other modes keep") }
        }

        /// The plan's reason (`ClusterPlacementPolicy.tensorParallelHeldForFeatures`).
        var reason: String {
            drops.map { "tensor parallel would drop \($0); held back until it keeps them" }
                ?? "this worker build declares no serving features for its modes, so tensor parallel is held back until it does"
        }

        /// Where tensor parallel is the only mode that places.
        var refusal: String {
            "Only tensor parallel fits these Macs, and "
                + (drops.map { "it would drop " + $0 } ?? "this worker build declares no serving features for its modes")
                + ". No reduced-feature setup was saved."
        }

        /// Where a developer's forced mode places tensor parallel anyway.
        var forcedLine: String {
            "Developer setting: tensor parallel is placed because it is forced; "
                + (drops.map { "it drops " + $0 }
                    ?? "this worker build declares no serving features for its modes, so what it drops is not known")
                + "."
        }
    }

    /// The hold for `policy` as the caller would plan it, or nil when every tensor-parallel mode keeps every feature
    /// of the mode it would replace, or the rule does not apply. `plan` plans a policy as the caller would.
    static func hold(capability: ClusterRuntimeCapability, layout: ClusterModelLayout, policy: ClusterPlacementPolicy,
                     plan: (ClusterPlacementPolicy) throws -> ClusterPlacementResult) -> Hold? {
        guard layout.tensorParallel?.family.choosesFastest == true else { return nil }
        let listed = layout.generationModes.filter { (policy.modes?.contains($0) ?? true) && (policy.handOffModes || !$0.isHandOff) }
        let tensor = listed.filter(\.usesTensorParallelDecode), others = listed.filter { !$0.usesTensorParallelDecode }
        guard !tensor.isEmpty, !others.isEmpty else { return nil }
        var without = policy
        without.modes = others; without.forcedMode = nil
        let placed = (try? plan(without))?.chosen?.mode
        let replaced = placed.map { [$0] } ?? others
        let kept = replaced.compactMap { capability.modeFeatures?[$0] }, candidates = tensor.compactMap { capability.modeFeatures?[$0] }
        // A mode the record does not name has no declared features: nothing shows it keeps them.
        guard kept.count == replaced.count, candidates.count == tensor.count else {
            return Hold(modes: tensor, replaced: replaced, otherModePlaces: placed != nil, dropped: nil)
        }
        var dropped: [String] = []
        for candidate in candidates {
            for reference in kept { dropped += reference.dropped(by: candidate).filter { !dropped.contains($0) } }
        }
        return dropped.isEmpty ? nil : Hold(modes: tensor, replaced: replaced, otherModePlaces: placed != nil, dropped: dropped)
    }

    /// The rule applied to `policy` as `ClusterPlacementFlow.decide` plans it: tensor parallel's modes leave the policy
    /// where they would drop a feature, unless a developer forced the mode; where tensor parallel is the only mode that
    /// places, the plan refuses rather than save a reduced setup (owner, 2026-11-01), and `modesReason` says so.
    /// Not inlined into `decide`: the planner runs below `decide` on a cooperative thread's fixed-size stack.
    @inline(never)
    static func apply(to policy: inout ClusterPlacementPolicy, capability: ClusterRuntimeCapability, layout: ClusterModelLayout,
                      forced: Bool, plan: (ClusterPlacementPolicy) throws -> ClusterPlacementResult) -> (hold: Hold?, refusal: String?) {
        guard let hold = hold(capability: capability, layout: layout, policy: policy, plan: plan) else { return (nil, nil) }
        guard !forced else { return (hold, nil) }
        var refusal: String?
        if !hold.otherModePlaces, let only = (try? plan(policy))?.chosen, hold.modes.contains(only.mode) {
            refusal = hold.refusal
            policy.modesReason = policy.modesReason ?? hold.refusal
        }
        policy.modes = (policy.modes ?? layout.generationModes).filter { !hold.modes.contains($0) }
        policy.tensorParallelHeldForFeatures = hold.reason
        return (hold, refusal)
    }

    /// The rule, as a plan of a family it applies to says it.
    static let ruleLine = "A mode is chosen only where it keeps every feature and caching behavior of the mode it would "
        + "replace, as this worker build declares them: prompt-prefix and SSD reuse, speculative rounds, batch lanes, "
        + "media, penalties and logit bias, stop handling and logprobs."
    /// The mode a plan would place instead, in words.
    private static func words(_ mode: ClusterGenerationMode) -> String {
        switch mode {
        case .pipeline: "the pipeline"
        case .pipelineCompactDecode: "the compact-decode pipeline"
        case .pipelineMTP: "the speculative pipeline"
        case .phaseSplit: "the phase split"
        case .phaseSplitMTP: "the speculative phase split"
        case .tensorParallel: "tensor parallel"
        case .pipelinePrefillTensorDecode: "the pipeline-prefill, tensor-decode hybrid"
        }
    }

    private static func list(_ items: [String]) -> String {
        items.count <= 2 ? items.joined(separator: " and ") : items.dropLast().joined(separator: ", ") + " and " + items.last!
    }
}
