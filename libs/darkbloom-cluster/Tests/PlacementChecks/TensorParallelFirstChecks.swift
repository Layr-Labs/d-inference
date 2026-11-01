import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
import Foundation

/// Tensor parallel goes first wherever it fits (owner, 2026-10-24: "if tensor fits it will and should always be
/// faster"; `ClusterPlacementPolicy.tensorParallelFirst`, which the provider's placement step sets): on Macs and a
/// link where the speed comparison chooses a pipeline, the rule chooses tensor parallel and its reason line says
/// why, never a gain it does not predict; before a load measured the link it plans on the assumed keyed reduction;
/// a kept pipeline mode does not hold it back; a pipeline that loads now still goes ahead of tensor parallel that
/// does not; and the comparison stays the planner's own default. Constructed Macs and links, the recorded 27B
/// layout: no model, no GPU, no network.
func checkTensorParallelFirst(_ inputs: RetainedQwenInputs, _ checks: PlacementChecks) throws {
    let base = try ClusterPlacementLayouts.layout(configuration: inputs.twentySeven.configuration, tensors: inputs.twentySeven.stored)
    let tensorLayout = try executing(base, [.tensorParallel])
    let speed = modelled(floorMs: 2, bandwidthGBs: 400, weightBytes: tensorLayout.wholeModelLoadedBytes, prefill: 200)
    let devices = try [SyntheticMac.idle(64).device("first", speed: speed), SyntheticMac.idle(64).device("second", speed: speed)]
    var compare = ClusterPlacementPolicy()
    compare.promptTokens = 1024; compare.outputTokens = 128
    var first = compare
    first.tensorParallelFirst = true; first.tensorParallelAssumesUnmeasuredLink = true
    // An automatic replacement: tensor parallel first, but only on the pair's own measured link.
    var replacement = first
    replacement.tensorParallelAssumesUnmeasuredLink = false
    func plan(_ link: ClusterLinkCosts, _ policy: ClusterPlacementPolicy,
              on macs: [ClusterPlacementDevice]? = nil) throws -> ClusterPlacementResult {
        try ClusterPlacementPlanner.plan(devices: macs ?? devices, layout: tensorLayout, policy: policy, link: link)
    }
    func tensor(_ result: ClusterPlacementResult) -> Bool { result.chosen?.mode == .tensorParallel }

    checks.require("TP first: the comparison stays the planner's default", !ClusterPlacementPolicy().tensorParallelFirst)
    // A link slow enough that a pipeline is predicted faster: the comparison takes the pipeline, the rule tensor parallel.
    let slow = linkCosts(reductionMicroseconds: 3_000)
    let compared = try plan(slow, compare), ruled = try plan(slow, first)
    checks.require("TP first: on a link where a pipeline is predicted faster, the comparison chooses the pipeline",
        compared.chosen.map { !$0.mode.usesTensorParallelDecode } == true)
    checks.require("TP first: the rule chooses tensor parallel there (\(ruled.chosen?.mode.rawValue ?? "-"))", tensor(ruled))
    checks.require("TP first: its reason line gives the rule, not a gain it does not predict (\(ClusterPlacementExplanation.deploymentReason(ruled) ?? "-"))",
        ClusterPlacementExplanation.deploymentReason(ruled) == "Tensor parallel: the model fits, so both Macs share every layer of every token.")
    // A fast link: both choose tensor parallel, and a predicted gain is still said as one.
    let fast = linkCosts(reductionMicroseconds: 10)
    let quick = try plan(fast, first)
    checks.require("TP first: where tensor parallel is predicted faster, both choose it and the gain is said",
        tensor(try plan(fast, compare)) && tensor(quick)
            && (ClusterPlacementExplanation.deploymentReason(quick) ?? "").hasPrefix("Tensor parallel: predicted"))
    // Before any load measured the link: the comparison cannot choose tensor parallel, the rule plans it on the
    // assumed keyed reduction, and the router can still price that setup.
    let unmeasured = try plan(.unmeasured, first)
    checks.require("TP first: before a load measured the link, the comparison does not choose tensor parallel",
        !tensor(try plan(.unmeasured, compare)))
    checks.require("TP first: the rule plans tensor parallel on the assumed keyed reduction", tensor(unmeasured))
    checks.require("TP first: an automatic replacement invents no reduction, so before a measurement it does not choose tensor parallel",
        !tensor(try plan(.unmeasured, replacement)))
    checks.require("TP first: an automatic replacement still puts tensor parallel first on a measured link where a pipeline is predicted faster",
        tensor(try plan(slow, replacement)))
    var pricing = first
    pricing.promptTokens = 512; pricing.outputTokens = 64
    let priced = try ClusterPlacementPlanner.evaluate(devices: devices, cuts: [], mode: .tensorParallel,
        prefillSchedule: unmeasured.chosen?.prefillSchedule ?? .serial, layout: tensorLayout, policy: pricing, link: .unmeasured,
        tensorShares: unmeasured.chosen?.tensorShares)
    checks.require("TP first: a tensor-parallel setup chosen before the link was measured is priced as it was planned",
        priced.prediction(.rested).decodeTokensPerSecond > 0)
    // A kept pipeline mode (the pair served it before) does not hold tensor parallel back under the rule.
    var keep = first
    keep.keptMode = .pipeline; keep.keptModeMargin = .infinity; keep.keptModeReason = "kept after the update"
    let kept = try plan(slow, keep)
    checks.require("TP first: a kept pipeline mode does not hold tensor parallel back, and no kept reason is given",
        tensor(kept) && kept.keptModeReason == nil)
    // A pipeline that loads now still goes ahead of tensor parallel that does not (the hardware group comes first).
    var busy = SyntheticMac.idle(64)
    busy.freeGiB = 3
    let pressed = try [SyntheticMac.idle(64).device("first", speed: speed), busy.device("second", speed: speed)]
    let tight = try plan(fast, first, on: pressed)
    if let chosen = tight.chosen, let best = tight.tensorParallel?.tensorParallel, best.hardwareGroup > chosen.hardwareGroup {
        checks.require("TP first: a pipeline that loads now goes ahead of tensor parallel that does not",
            !chosen.mode.usesTensorParallelDecode)
    } else {
        checks.require("TP first: on a Mac too busy for tensor parallel the plan still chooses what loads now",
            tight.chosen.map { $0.ranks.allSatisfy { $0.fit.possible } } ?? true)
    }
}
