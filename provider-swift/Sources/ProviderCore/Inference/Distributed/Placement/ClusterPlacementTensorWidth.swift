import DarkbloomClusterPlacement
import DarkbloomClusterProtocol

/// The width a request-owned Qwen TP placement saves (`ClusterConfiguration.batchLanes`), so a pair serves concurrent
/// requests from its first load instead of after a drained replacement, and a pair saved for coordinator pairing,
/// which never widens afterwards, serves them at all. The widest of the owner's quoted widths at which the chosen
/// placement, its leader and split unchanged, fits both Macs now under that width's complete LOAD quote: the predicate
/// a replacement is held to (`ClusterPlacementCandidate.admitted`). When none fits, the setup saves no width and keeps
/// the family default.
enum ClusterPlacementTensorWidth {
    /// The plan `ClusterPlacementFlow.decide` keeps: `ClusterPlacementPlanner.plan`'s or, given width quotes,
    /// `widest`'s. Never inlined, and only `widest`'s frame holds the sizing's plans: the caller's frame, which a deep
    /// planner stack shares, holds just the one plan it keeps.
    @inline(never)
    static func plan(devices: [ClusterPlacementDevice], layout: ClusterModelLayout, policy: ClusterPlacementPolicy,
                     link: ClusterLinkCosts, quotes: [ClusterPlacementTensorBatchQuote], lanes: inout Int?) throws
        -> ClusterPlacementResult {
        guard !quotes.isEmpty else {
            return try ClusterPlacementPlanner.plan(devices: devices, layout: layout, policy: policy, link: link)
        }
        return try widest(devices: devices, layout: layout, policy: policy, link: link, quotes: quotes, lanes: &lanes)
    }

    /// The singleton plan or, when the widest admitted width exists, that width's plan, with `lanes` set to it. Only a
    /// placement priced by its owner's singleton quote is sized: a batch scope's quote, or none, leaves the plan as it
    /// is. The mode was chosen for one request, so a sized plan keeps that choice's reasons and comparisons
    /// (`deploymentReason`); only its chosen placement is priced at the width.
    @inline(never)
    static func widest(devices: [ClusterPlacementDevice], layout: ClusterModelLayout, policy: ClusterPlacementPolicy,
                       link: ClusterLinkCosts, quotes: [ClusterPlacementTensorBatchQuote], lanes: inout Int?) throws
        -> ClusterPlacementResult {
        let singleton = try ClusterPlacementPlanner.plan(devices: devices, layout: layout, policy: policy, link: link)
        // A split the setup can save: equal, or integer weights.
        guard let chosen = singleton.chosen, chosen.mode == .tensorParallel, chosen.shares == nil || chosen.tensorShares != nil,
              policy.tensorParallelBatchQuote?.lanes == 1, let leader = chosen.ranks.first?.device else { return singleton }
        for quote in quotes.sorted(by: { $0.lanes > $1.lanes }) {
            var widened = policy
            try quote.applyWidth(to: &widened, layout: layout)
            widened.modes = [.tensorParallel]; widened.schedules = [chosen.prefillSchedule]
            widened.leader = leader; widened.requiredTensorShares = chosen.tensorShares ?? [1, 1]
            var sized = try ClusterPlacementPlanner.plan(devices: devices, layout: layout, policy: widened, link: link)
            guard let wide = sized.chosen, wide.mode == .tensorParallel, wide.ranks.map(\.device) == chosen.ranks.map(\.device),
                  wide.tensorShares == chosen.tensorShares, wide.admitted(requireNow: true) else { continue }
            sized.modesReason = singleton.modesReason; sized.keptModeReason = singleton.keptModeReason
            sized.tensorParallel = singleton.tensorParallel; sized.shards = singleton.shards
            lanes = quote.lanes
            return sized
        }
        return singleton
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
