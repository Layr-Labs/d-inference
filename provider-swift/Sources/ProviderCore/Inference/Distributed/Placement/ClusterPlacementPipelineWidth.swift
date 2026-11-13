import DarkbloomClusterPlacement
import DarkbloomClusterProtocol

/// The width a guided pipeline placement saves (`ClusterConfiguration.batchLanes`) for a family whose guided pipeline
/// lanes are listed in `qualifiedLanesByFamily`, so the pair serves several requests at once from its first load, and a
/// pair saved for coordinator pairing, which never widens afterwards, serves them at all. The widest of 8, 4 and 2 (the
/// pipeline's widths) at which the plain pipeline, led by the chosen placement's leader, fits both Macs now with every
/// lane's whole state at the standard request (`ClusterPlacementPolicy.pipelineLanes`, what its LOAD admits), up to
/// that family's entry. Lanes read prompts one frame at a time, so a sized placement prefills serially; its cut is the
/// one that serves fastest there. For a family not listed, or when no wider width fits, the placement chosen for one
/// request stands: one request at a time, with the one-chunk lookahead where the model has it.
enum ClusterPlacementPipelineWidth {
    /// The widest pipeline width a guided setup of each family saves. None yet. Gemma 4's lanes gave every request
    /// its solo tokens at 2, 4 and 8 on the M5 Ultra pair, but lanes prefill serially, and there a lone prompt's first
    /// token came 1.84 to 1.94 times later at 8K to 64K tokens than with the lookahead. So its guided pipeline keeps
    /// the lookahead and one lane (owner, 2026-11-10). A setup saved with serial prefill and a width still serves that
    /// width, which LOAD admits whole. Listing a family here, such as `.gemma4LayerStage: 8`, sizes its guided setups.
    static let qualifiedLanesByFamily: [ClusterRuntimeAdapter: Int] = [:]

    /// The widest pipeline width a guided setup of this model saves: its family's `qualifiedLanesByFamily` entry, and
    /// one for a family not listed or a pipeline with private images (its owner's default then applies, as before).
    static func qualifiedLanes(adapter: ClusterRuntimeAdapter?, hasPrivateImages: Bool) -> Int {
        guard let adapter, !hasPrivateImages else { return 1 }
        return qualifiedLanesByFamily[adapter] ?? 1
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
