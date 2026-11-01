import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
import Foundation

/// Metadata-only planning must not require a pipeline cut or a model load to
/// discover that TP is supported, or why it is unavailable. Constructed inputs,
/// never a claim of model or hardware qualification.
func checkTensorParallelFeasibility(_ inputs: RetainedQwenInputs, _ checks: PlacementChecks) throws {
    let base = try ClusterPlacementLayouts.layout(configuration: inputs.twentySeven.configuration,
        tensors: inputs.twentySeven.stored)
    let layout = try executing(base, [.tensorParallel])
    let speed = modelled(floorMs: 2, bandwidthGBs: 400, weightBytes: layout.wholeModelLoadedBytes, prefill: 200)
    let devices = try [SyntheticMac.idle(64).device("first", speed: speed),
                       SyntheticMac.idle(64).device("second", speed: speed)]
    var policy = ClusterPlacementPolicy()
    policy.promptTokens = 1024; policy.outputTokens = 128
    let link = linkCosts(reductionMicroseconds: 45)

    func changed(_ edit: (inout [String: Any]) -> Void) throws -> ClusterModelLayout {
        var object = try JSONSerialization.jsonObject(with: layout.encoded()) as! [String: Any]
        edit(&object)
        return try ClusterModelLayout.decode(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
    }
    let noCuts = try changed { $0["admittedCuts"] = []; $0["structuralCuts"] = [] }
    let independent = try ClusterPlacementPlanner.plan(devices: devices, layout: noCuts, policy: policy, link: link)
    checks.require("TP feasibility: a TP-capable model without pipeline cuts selects TP with no layer cuts",
        independent.chosen?.mode == .tensorParallel && independent.chosen?.cuts == []
            && independent.chosen?.ranks.count == 2 && independent.tensorParallel?.verdict == .chosen)

    // A two-rank TP-only search has two orders, regardless of layer count.
    // Use a family with no explicit weighted alternatives to make that bound exact.
    let equalOnly = try changed {
        var tp = $0["tensorParallel"] as! [String: Any]
        var family = tp["family"] as! [String: Any]
        family.removeValue(forKey: "shareOptions"); family.removeValue(forKey: "shareUnits")
        tp["family"] = family; $0["tensorParallel"] = tp
    }
    var bounded = policy; bounded.modes = [.tensorParallel]; bounded.maximumCandidates = 2
    do {
        let result = try ClusterPlacementPlanner.plan(devices: devices, layout: equalOnly, policy: bounded, link: link)
        checks.require("TP feasibility: TP-only planning counts two device orders, not pipeline cut combinations",
            result.chosen?.mode == .tensorParallel && result.candidatesConsidered == 2)
    } catch {
        checks.require("TP feasibility: TP-only planning must not exhaust its budget on unused pipeline cuts: \(error)", false)
    }

    let unsupported = try ClusterPlacementPlanner.plan(devices: devices, layout: try notExecuting(layout), policy: policy)
    checks.require("TP feasibility: an unsupported runtime falls back to pipeline before requiring link measurements",
        unsupported.chosen?.mode == .pipeline && unsupported.tensorParallel?.verdict == .notExecutedByRuntime
            && unsupported.tensorParallel?.tensorParallel == nil)
    checks.require("TP feasibility: CLI explanation reports unsupported runtime without claiming an unmeasured speedup",
        ClusterPlacementExplanation.deploymentReason(unsupported)?.contains("does not execute tensor parallel") == true
            && ClusterPlacementExplanation.deploymentReason(unsupported)?.contains("predicted faster") == false)

    let threeRanks = try changed {
        var tp = $0["tensorParallel"] as! [String: Any]
        var family = tp["family"] as! [String: Any]
        family["ranks"] = [3]; family.removeValue(forKey: "shareOptions"); family.removeValue(forKey: "shareUnits")
        tp["family"] = family; $0["tensorParallel"] = tp
    }
    let wrongRanks = try ClusterPlacementPlanner.plan(devices: devices, layout: threeRanks, policy: policy)
    checks.require("TP feasibility: unsupported rank counts fall back before requiring link measurements",
        wrongRanks.chosen?.mode == .pipeline && wrongRanks.tensorParallel?.verdict == .notExecutedByRuntime
            && wrongRanks.tensorParallel?.tensorParallel == nil)
    checks.require("TP feasibility: CLI explanation names unsupported rank counts without asking for a link probe",
        ClusterPlacementExplanation.deploymentReason(wrongRanks)?.contains("supports rank counts 3") == true)

    let noLink = try ClusterPlacementPlanner.plan(devices: devices, layout: layout, policy: policy)
    checks.require("TP feasibility: a compatible runtime without measured keyed reductions falls back without inventing a speedup",
        noLink.chosen?.mode == .pipeline && noLink.tensorParallel?.verdict == .reductionNotMeasured
            && noLink.tensorParallel?.tensorParallel == nil)

    var pipelineOnly = policy; pipelineOnly.modes = [.pipeline]
    let excluded = try ClusterPlacementPlanner.plan(devices: devices, layout: layout, policy: pipelineOnly)
    checks.require("TP feasibility: an explicit pipeline-only policy does not ask for a link probe or claim a failed cable qualification",
        excluded.chosen?.mode == .pipeline && excluded.tensorParallel?.verdict == .notQualified
            && excluded.tensorParallel?.reason.contains("placement policy excludes") == true)
    checks.require("TP feasibility: CLI explanation preserves the actual policy exclusion",
        ClusterPlacementExplanation.deploymentReason(excluded)?.contains("placement policy excludes") == true)

    let weighted = try changed {
        $0["admittedCuts"] = []; $0["structuralCuts"] = []
        var tp = $0["tensorParallel"] as! [String: Any]
        var family = tp["family"] as! [String: Any]
        family["shareOptions"] = [[1, 2], [2, 1]]; family.removeValue(forKey: "shareUnits")
        tp["family"] = family; $0["tensorParallel"] = tp
    }
    checks.refuses("TP feasibility: explicit weighted shares count against the candidate bound even without pipeline cuts",
        because: "more than 2 candidates") {
        _ = try ClusterPlacementPlanner.plan(devices: devices, layout: weighted, policy: bounded, link: link)
    }
    bounded.maximumCandidates = 6
    let weights = try ClusterPlacementPlanner.plan(devices: devices, layout: weighted, policy: bounded, link: link)
    checks.require("TP feasibility: both device orders and their equal plus weighted options fit the exact six-candidate bound",
        weights.chosen?.mode == .tensorParallel && weights.candidatesConsidered == 6)
}
