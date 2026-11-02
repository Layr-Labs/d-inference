import DarkbloomClusterPlacement
import DarkbloomClusterProtocol

/// The width a request-owned Qwen TP placement saves (`ClusterConfiguration.batchLanes`), so a pair serves concurrent
/// requests from its first load instead of after a drained replacement, and a pair saved for coordinator pairing,
/// which never widens afterwards, serves them at all. The widest of the owner's quoted widths at which the chosen
/// placement, its leader and split unchanged, fits both Macs now under that width's complete LOAD quote: the predicate
/// a replacement is held to (`ClusterPlacementCandidate.admitted`). When none fits, the setup saves no width and keeps
/// the family default.
enum ClusterPlacementTensorWidth {
    /// `result` becomes the widest admitted width's plan and `lanes` that width; both stay as they are when none
    /// fits. Never inlined, so the plans it makes stay off the caller's frame, which a deep planner stack shares.
    @inline(never)
    static func size(_ result: inout ClusterPlacementResult, lanes: inout Int?, quotes: [ClusterPlacementTensorBatchQuote],
                     devices: [ClusterPlacementDevice], layout: ClusterModelLayout, policy: ClusterPlacementPolicy,
                     link: ClusterLinkCosts) throws {
        guard let sized = try widest(result, quotes: quotes, devices: devices, layout: layout, policy: policy, link: link) else { return }
        result = sized.result; lanes = sized.lanes
    }

    static func widest(_ singleton: ClusterPlacementResult, quotes: [ClusterPlacementTensorBatchQuote],
                       devices: [ClusterPlacementDevice], layout: ClusterModelLayout, policy: ClusterPlacementPolicy,
                       link: ClusterLinkCosts) throws -> (lanes: Int, result: ClusterPlacementResult)? {
        // A split the setup can save: equal, or integer weights.
        guard let chosen = singleton.chosen, chosen.mode == .tensorParallel, chosen.shares == nil || chosen.tensorShares != nil,
              policy.tensorParallelBatchQuote?.lanes == 1, let leader = chosen.ranks.first?.device else { return nil }
        for quote in quotes.sorted(by: { $0.lanes > $1.lanes }) {
            var widened = policy
            try quote.applyWidth(to: &widened, layout: layout)
            widened.modes = [.tensorParallel]; widened.schedules = [chosen.prefillSchedule]
            widened.modesReason = widened.modesReason ?? "its concurrent requests are sized on the chosen tensor-parallel placement"
            widened.leader = leader; widened.requiredTensorShares = chosen.tensorShares ?? [1, 1]
            let result = try ClusterPlacementPlanner.plan(devices: devices, layout: layout, policy: widened, link: link)
            guard let wide = result.chosen, wide.mode == .tensorParallel, wide.ranks.map(\.device) == chosen.ranks.map(\.device),
                  wide.tensorShares == chosen.tensorShares, wide.admitted(requireNow: true) else { continue }
            return (quote.lanes, result)
        }
        return nil
    }
}

extension ClusterPlacementCandidate {
    /// Possible and inside the GPU working set and, with `requireNow`, every rank fits what its Mac admits now:
    /// hardware possibility alone is not current admission. A saved width and an automatic replacement
    /// (`DistributedAutomaticBatchPlanner.accepts`) are held to it alike.
    func admitted(requireNow: Bool) -> Bool {
        possible && withinGPUWorkingSet && (!requireNow || ranks.allSatisfy { $0.fit == .now })
    }
}
