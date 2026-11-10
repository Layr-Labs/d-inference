import DarkbloomClusterPlacement
import DarkbloomClusterProtocol

/// The width a tensor-parallel placement saves (`ClusterConfiguration.batchLanes`), so a pair serves concurrent requests
/// from its first load instead of after a drained replacement, and a pair saved for coordinator pairing, which never
/// widens afterwards, serves them at all. The widest width at which the chosen placement, its leader and split
/// unchanged, fits both Macs now under that width's complete LOAD charge: the predicate a replacement is held to
/// (`ClusterPlacementCandidate.admitted`), and never wider than the family has qualified on real Macs
/// (`qualifiedLanes`). Two families of owners are sized:
/// - a request-owned Qwen TP row, at each width its owner quotes natively (`tensorWidthQuotes`);
/// - a family whose layout states a lane charge (`ClusterTensorParallelFamilyPlan.laneBytes`, Gemma 4 and GLM), at 8,
///   6, 4 and 2 lanes, each lane after the first adding that charge, as its LOAD reserves the width.
///
/// When no wider width fits, the setup saves none and serves one request at a time.
enum ClusterPlacementTensorWidth {
    /// The widest width a tensor-parallel setup of this model saves: what the family has qualified on real Macs (one
    /// for a family whose owner saves no width). The Qwen TP rows keep the eight they saved before (the M5 Ultra pair
    /// serves the 27B at eight). GLM takes eight, which it served on every pair before (the M5 Ultra pair gave each of
    /// its lanes its solo tokens at 2, 4, 6 and 8, 2026-11-10). Gemma 4 takes its row's `gemmaQualifiedLanes`, and
    /// none for a row not listed.
    static func qualifiedLanes(adapter: ClusterRuntimeAdapter?, runtimeModelID: String) -> Int {
        guard let adapter, adapter.savesTensorParallelWidth(runtimeModelID: runtimeModelID) else { return 1 }
        guard adapter == .gemma4LayerStage else { return ClusterServingFeatures.maximumLaneWidth }
        return gemmaQualifiedLanes[runtimeModelID] ?? 1
    }

    /// Gemma 4 tensor parallel's cap, by the rows the M5 Ultra pair qualified (2026-11-10): QAT 4-bit, whose every
    /// lane gave its solo tokens and logprobs at 2, 4 and 8 there, but which served a request fastest at 2: 95.5 tok/s
    /// in all and 77 a request, against 96.2 and 48.5 at 4 and 60.8 and 14.5 at 8, where the last of eight 8K prompts
    /// sent at once waited 63.7 s for its first token (7.7 s alone). The 8-bit rows run the same lanes on 8-bit
    /// kernels, which neither the pair nor the synthetic lane checks (4-bit) ran, so they serve one request at a time.
    static let gemmaQualifiedLanes = ["registered_gemma4_26b_qat_4bit": 2]

    /// The plan `ClusterPlacementFlow.decide` keeps: `ClusterPlacementPlanner.plan`'s, or the widest admitted width's
    /// (`widest`). `maximumLanes` caps the width (`qualifiedLanes`); a width already set (`lanes`, a batch scope's)
    /// is kept. Never inlined, and only `widest`'s frame holds the sizing's plans: the caller's frame, which a deep
    /// planner stack shares, holds just the one plan it keeps.
    @inline(never)
    static func plan(devices: [ClusterPlacementDevice], layout: ClusterModelLayout, policy: ClusterPlacementPolicy,
                     link: ClusterLinkCosts, quotes: [ClusterPlacementTensorBatchQuote], maximumLanes: Int,
                     lanes: inout Int?) throws -> ClusterPlacementResult {
        let widths = Self.widths(layout: layout, policy: policy, quotes: quotes, maximumLanes: maximumLanes, lanes: lanes)
        guard !widths.isEmpty else {
            return try ClusterPlacementPlanner.plan(devices: devices, layout: layout, policy: policy, link: link)
        }
        return try widest(devices: devices, layout: layout, policy: policy, link: link, widths: widths, lanes: &lanes)
    }

    /// One width to try, and how it prices the policy.
    private typealias Width = (lanes: Int, price: (inout ClusterPlacementPolicy) throws -> Void)

    /// The widths wider than one, up to `maximumLanes`, that extend the way the singleton was priced, each priced as
    /// its owner's LOAD reserves it:
    /// - a Qwen TP row's native quotes (`tensorWidthQuotes`), where its owner's singleton quote priced the singleton;
    /// - a family's lane charge (`ClusterTensorParallelFamilyPlan.laneBytes`), where nothing else priced it: no quote
    ///   of its owner, no width already set (`lanes`, a batch scope's) and no width in the policy.
    ///
    /// None otherwise (a batch scope's quote, or a family without either), and the plan is then left as it is.
    private static func widths(layout: ClusterModelLayout, policy: ClusterPlacementPolicy,
                               quotes: [ClusterPlacementTensorBatchQuote], maximumLanes: Int, lanes: Int?) -> [Width] {
        func wider(_ width: Int) -> Bool { width > 1 && width <= maximumLanes }
        if !quotes.isEmpty {
            guard policy.tensorParallelBatchQuote?.lanes == 1 else { return [] }
            return quotes.filter { wider($0.lanes) }.map { quote -> Width in
                (quote.lanes, { widened in try quote.applyWidth(to: &widened, layout: layout) })
            }
        }
        guard lanes == nil, layout.tensorParallel?.family.laneBytes != nil, policy.tensorParallelBatchQuote == nil,
              (policy.tensorParallelLanes ?? 1) == 1 else { return [] }
        return ClusterPlacementBatchScope.tensorParallelWidths.filter(wider).map { width -> Width in
            (width, { widened in widened.tensorParallelLanes = width })
        }
    }

    /// The singleton plan or, when a wider width is admitted now, the widest one's plan, with `lanes` set to it. Each
    /// of `widths` prices the policy at its width. The mode was chosen for one request, so a sized plan keeps that
    /// choice's reasons and comparisons (`deploymentReason`); only its chosen placement is priced at the width.
    @inline(never)
    private static func widest(devices: [ClusterPlacementDevice], layout: ClusterModelLayout, policy: ClusterPlacementPolicy,
                               link: ClusterLinkCosts, widths: [Width], lanes: inout Int?) throws
        -> ClusterPlacementResult {
        let singleton = try ClusterPlacementPlanner.plan(devices: devices, layout: layout, policy: policy, link: link)
        // A split the setup can save: equal, or integer weights.
        guard let chosen = singleton.chosen, chosen.mode == .tensorParallel,
              chosen.shares == nil || chosen.tensorShares != nil, let leader = chosen.ranks.first?.device else { return singleton }
        for width in widths.sorted(by: { $0.lanes > $1.lanes }) {
            var widened = policy
            try width.price(&widened)
            widened.modes = [.tensorParallel]; widened.schedules = [chosen.prefillSchedule]
            widened.leader = leader; widened.requiredTensorShares = chosen.tensorShares ?? [1, 1]
            var sized = try ClusterPlacementPlanner.plan(devices: devices, layout: layout, policy: widened, link: link)
            guard let wide = sized.chosen, wide.mode == .tensorParallel, wide.ranks.map(\.device) == chosen.ranks.map(\.device),
                  wide.tensorShares == chosen.tensorShares, wide.admitted(requireNow: true) else { continue }
            sized.modesReason = singleton.modesReason; sized.keptModeReason = singleton.keptModeReason
            sized.tensorParallel = singleton.tensorParallel; sized.shards = singleton.shards
            lanes = width.lanes
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
