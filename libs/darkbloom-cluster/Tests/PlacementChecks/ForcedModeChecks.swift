import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
import Foundation

/// DEVELOPER ONLY: a forced deployment mode (`ClusterPlacementPolicy.forcedMode`,
/// set by the provider from `DARKBLOOM_CLUSTER_FORCE_MODE` in a debug build).
/// On a new pair the planner can never choose tensor parallel by itself: no
/// load has measured the link yet and no shard has a measured speed. A forced
/// family is the only one considered, an unmeasured reduction is assumed (and
/// labelled so), and memory fit, the model's own mode list and the
/// qualification shapes still decide: a forced family that cannot be placed is
/// refused with the reason, never swapped for another family. Constructed Macs
/// and the 27B's real header layout; no model, no GPU: not a hardware pass.
func checkForcedMode(_ inputs: RetainedQwenInputs, _ checks: PlacementChecks) throws {
    let big = try ClusterPlacementLayouts.layout(configuration: inputs.twentySeven.configuration, tensors: inputs.twentySeven.stored)
    let layout = try executing(big, [.tensorParallel])
    var request = ClusterPlacementPolicy()
    request.promptTokens = 1024; request.outputTokens = 128
    // Two new M4 Max Macs: nothing measured, no link probe.
    let pair = [try SyntheticMac.idle(128).device("mac-one", chip: "Apple M4 Max"),
                try SyntheticMac.idle(128).device("mac-two", chip: "Apple M4 Max")]
    let plain = try ClusterPlacementPlanner.plan(devices: pair, layout: layout, policy: request)
    checks.require("forced mode: unset, a new pair (no link measured) is never planned tensor parallel",
        plain.chosen.map { !$0.mode.usesTensorParallelDecode } == true && plain.tensorParallel?.verdict == .reductionNotMeasured)
    var forceTP = request; forceTP.forcedMode = .tensorParallel
    let forced = try ClusterPlacementPlanner.plan(devices: pair, layout: layout, policy: forceTP)
    checks.require("forced mode: tensor parallel forced on a new pair is chosen, placed and possible",
        forced.chosen?.mode == .tensorParallel && forced.chosen?.possible == true && forced.chosen?.cuts.isEmpty == true
            && forced.tensorParallel?.verdict == .chosen)
    checks.require("forced mode: every alternative is in the forced family",
        forced.alternatives.allSatisfy { $0.mode == .tensorParallel })
    checks.require("forced mode: the link stays unmeasured in the plan's basis (the reduction is only assumed)",
        forced.basis.linkCostsMeasured == false && forced.tensorParallel?.reductionKeyed == true)
    checks.require("forced mode: the words name each family", ClusterForcedMode.tensorParallel.words == "tensor parallel"
        && ClusterForcedMode.pipeline.words == "pipeline")
    // A measured fast keyed link on Macs where tensor parallel wins: forcing the pipeline keeps the pipeline.
    let weights = big.wholeModelLoadedBytes
    let ultras = [try SyntheticMac.idle(192).device("a", speed: modelled(floorMs: 20, bandwidthGBs: 800, weightBytes: weights, prefill: 260), chip: "Apple M2 Ultra"),
                  try SyntheticMac.idle(192).device("b", speed: modelled(floorMs: 20, bandwidthGBs: 800, weightBytes: weights, prefill: 260), chip: "Apple M2 Ultra")]
    let fast = ClusterLinkCosts(probe: rdmaProbe(allSumLargeMicroseconds: 2_100), measuredUTC: "t")!
    var long = request; long.outputTokens = min(512, layout.maximumOutputTokens)
    let byItself = try ClusterPlacementPlanner.plan(devices: ultras, layout: layout, policy: long, link: fast)
    var forcePP = long; forcePP.forcedMode = .pipeline
    let piped = try ClusterPlacementPlanner.plan(devices: ultras, layout: layout, policy: forcePP, link: fast)
    checks.require("forced mode: pipeline forced where the planner would choose tensor parallel stays in the pipeline family",
        byItself.chosen?.mode == .tensorParallel && piped.chosen.map { !$0.mode.usesTensorParallelDecode && !$0.mode.isHandOff } == true
            && piped.alternatives.allSatisfy { !$0.mode.usesTensorParallelDecode })
    // Adapter support still decides: a runtime that executes no tensor-parallel mode refuses the force.
    do {
        _ = try ClusterPlacementPlanner.plan(devices: pair, layout: try notExecuting(big), policy: forceTP)
        checks.require("forced mode: a model whose runtime lists no tensor-parallel mode refuses the force", false)
    } catch {
        checks.require("forced mode: a model whose runtime lists no tensor-parallel mode refuses the force, saying so",
            "\(error)".contains("tensor parallel forced") && "\(error)".contains("no tensor parallel mode"))
    }
    // Memory still decides: two small Macs that cannot hold the model in any tensor-parallel split.
    let small = [try SyntheticMac.idle(8).device("s1", chip: "Apple M4"), try SyntheticMac.idle(8).device("s2", chip: "Apple M4")]
    do {
        _ = try ClusterPlacementPlanner.plan(devices: small, layout: layout, policy: forceTP)
        checks.require("forced mode: a forced family that does not fit is refused", false)
    } catch {
        checks.require("forced mode: a forced family that does not fit is refused with the memory reason",
            "\(error)".contains("tensor parallel forced") && "\(error)".contains("memory"))
    }
    // The qualification shapes still decide: a record rule that admits no tensor-parallel shape refuses the force.
    var unqualified = forceTP
    unqualified.admitsShape = { _, _, mode in !mode.usesTensorParallelDecode }
    do {
        _ = try ClusterPlacementPlanner.plan(devices: pair, layout: layout, policy: unqualified)
        checks.require("forced mode: a forced family no qualification admits is refused", false)
    } catch {
        checks.require("forced mode: a forced family no qualification admits is refused, naming the records",
            "\(error)".contains("tensor parallel forced") && "\(error)".contains("qualification"))
    }
}
