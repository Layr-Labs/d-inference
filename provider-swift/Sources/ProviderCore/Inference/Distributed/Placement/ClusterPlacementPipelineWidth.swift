import DarkbloomClusterPlacement
import DarkbloomClusterProtocol

/// The width a pipeline placement saves (`ClusterConfiguration.batchLanes`), so a pair whose pipeline serves lanes
/// serves several requests at once from its first load, and a pair saved for coordinator pairing, which never widens
/// afterwards, serves them at all. The widest of 8, 4 and 2 (the pipeline's widths) at which the plain pipeline, led by
/// the chosen placement's leader, fits both Macs now with every lane's whole state at the standard request
/// (`ClusterPlacementPolicy.pipelineLanes`, what its LOAD admits), up to what the family has qualified on real Macs
/// (`qualifiedLanes`). Lanes read prompts one frame at a time, so a sized placement prefills serially; its cut is the
/// one that serves fastest there. When no wider width fits, the placement chosen for one request stands: one request
/// at a time, with the one-chunk lookahead where the model has it.
enum ClusterPlacementPipelineWidth {
    /// The widest pipeline width a setup of this model saves: what the family has qualified on real Macs, and one for
    /// a family whose pipeline lanes are not qualified yet (its owner's default then applies, as before). Gemma 4 takes
    /// eight, to be confirmed on the M5 Ultra pair before it ships, and lowered if that pair qualifies less.
    static func qualifiedLanes(adapter: ClusterRuntimeAdapter?, hasPrivateImages: Bool) -> Int {
        adapter == .gemma4LayerStage && !hasPrivateImages ? ClusterServingFeatures.maximumLaneWidth : 1
    }

    /// Replaces `result` with its widest admitted width's plan and sets `lanes`, when its chosen placement is a plain
    /// pipeline and no width is set yet (a batch scope's or a tensor-parallel one). The mode was chosen for one request,
    /// so a sized plan keeps that choice's reasons and comparisons (`deploymentReason`); only its chosen placement is
    /// planned at the width. Never inlined: this frame, not the caller's, holds the sizing's plans.
    @inline(never)
    static func size(_ result: inout ClusterPlacementResult, devices: [ClusterPlacementDevice], layout: ClusterModelLayout,
                     policy: ClusterPlacementPolicy, link: ClusterLinkCosts, maximumLanes: Int, lanes: inout Int?) throws {
        guard lanes == nil, maximumLanes > 1, let chosen = result.chosen, chosen.mode == .pipeline,
              layout.prefillSchedules.contains(.serial), let leader = chosen.ranks.first?.device else { return }
        for width in ClusterPlacementBatchScope.pipelineWidths.sorted(by: >) where width <= maximumLanes {
            var widened = policy
            widened.modes = [.pipeline]; widened.schedules = [.serial]; widened.leader = leader
            widened.pipelineLanes = width
            widened.keptMode = nil; widened.keptModeReason = nil
            var sized = try ClusterPlacementPlanner.plan(devices: devices, layout: layout, policy: widened, link: link)
            guard let wide = sized.chosen, wide.mode == .pipeline, wide.prefillSchedule == .serial,
                  wide.ranks.first?.device == leader, wide.admitted(requireNow: true) else { continue }
            sized.modesReason = result.modesReason; sized.keptModeReason = result.keptModeReason
            sized.tensorParallel = result.tensorParallel; sized.shards = result.shards
            lanes = width
            result = sized
            return
        }
    }

    /// The plan's words for a saved pipeline width: lanes read each prompt serially, and what that costs a lone prompt.
    static let serialPrefillLine = "  Lanes read each prompt one chunk at a time (serial prefill): a long prompt alone starts "
        + "its answer later than with one chunk of lookahead, which serves one request at a time."
}
