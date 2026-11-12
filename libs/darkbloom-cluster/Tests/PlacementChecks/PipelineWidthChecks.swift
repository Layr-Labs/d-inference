import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
import Foundation

/// A saved pipeline width (`ClusterPlacementPolicy.pipelineLanes`) on the Gemma 4 QAT 4-bit golden layout: each lane
/// after the first adds the family's whole request state at the planned request to every rank's request need (what
/// the rank's LOAD admits for the width), whatever request the speed is predicted for, and nothing else changes:
/// weights, load need, the prompt frame's transient and the predicted speed. One request plans byte for byte as
/// before. A width is refused beside any mode but the plain pipeline, any schedule but serial prefill, or for a family
/// that admits requests only on arrival (GLM's pipeline). Constructed Macs and golden layouts; no model, no GPU.
func checkPipelineWidths(golden: URL, _ checks: PlacementChecks) throws {
    let file = golden.appendingPathComponent("layouts/gemma-4-26b-qat-4bit.json")
    let layout = try ClusterModelLayout.decode(Data(contentsOf: file))
    // The same layout with a whole-model charge of 4 GiB a request, so the gate's floor never hides a lane's charge.
    var object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] ?? [:]
    object["requestChargeEveryRankBytes"] = 4 * gib; object["requestChargeEveryRankBytesPerToken"] = nil
    let charged = try ClusterModelLayout.decode(JSONSerialization.data(withJSONObject: object))
    let big = try [SyntheticMac.idle(256).device("a"), SyntheticMac.idle(256).device("b")]
    var serial = ClusterPlacementPolicy()
    serial.modes = [.pipeline]; serial.schedules = [.serial]; serial.leader = "a"
    func plan(_ lanes: Int?, layout: ClusterModelLayout, prompt: Int? = nil, output: Int? = nil,
              macs: [ClusterPlacementDevice]? = nil) throws -> ClusterPlacementResult {
        var policy = serial; policy.pipelineLanes = lanes; policy.promptTokens = prompt; policy.outputTokens = output
        return try ClusterPlacementPlanner.plan(devices: macs ?? big, layout: layout, policy: policy)
    }
    let single = try plan(nil, layout: charged)
    guard let one = single.chosen, one.ranks.count == 2 else {
        return checks.require("pipeline width: one Gemma request is placed on two idle 256 GB Macs", false)
    }
    for width in [2, 4, 8] {
        let sized = try plan(width, layout: charged).chosen
        checks.require("pipeline width \(width): every rank's request need grows by \(width - 1) whole request states at the planned request (4 GiB each), and nothing else moves",
            sized?.cuts == one.cuts && sized?.prefillSchedule == .serial && sized.map { zip($0.ranks, one.ranks).allSatisfy { new, old in
                new.requestNeedBytes - old.requestNeedBytes == (width - 1) * 4 * gib && new.weightsBytes == old.weightsBytes
                    && new.loadNeedBytes == old.loadNeedBytes && new.transientBytes == old.transientBytes
            } } == true)
        checks.require("pipeline width \(width): the predicted speed stays one request's",
            sized?.rested == one.rested && sized?.sustained == one.sustained)
    }
    // A short reference request predicts its own speed; the width is still priced at the planned request.
    let four = try plan(4, layout: charged).chosen
    let short = try plan(4, layout: charged, prompt: 128, output: 128).chosen
    let shortAlone = try plan(nil, layout: charged, prompt: 128, output: 128).chosen
    checks.require("pipeline width: priced at the planned request whatever request the speed is predicted for",
        short?.ranks.map(\.requestNeedBytes) == four?.ranks.map(\.requestNeedBytes)
            && short?.rested == shortAlone?.rested && short?.rested != one.rested)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    checks.require("pipeline width: one request (nil or 1) plans byte for byte as before",
        try encoder.encode(plan(1, layout: charged)) == encoder.encode(single))
    // The widest width two idle Macs hold now: at the family's own charge (the golden layout's planned request), and at
    // 4 GiB a request, where two idle 48 GB Macs hold fewer than eight and more than one.
    func widest(_ macs: [ClusterPlacementDevice], _ layout: ClusterModelLayout) -> Int {
        [8, 4, 2].first { width in (try? plan(width, layout: layout, macs: macs).chosen?.ranks.allSatisfy { $0.fit == .now }) == true } ?? 1
    }
    let small = try [SyntheticMac.idle(48).device("a"), SyntheticMac.idle(48).device("b")]
    let smallWidest = widest(small, charged)
    checks.require("pipeline width: two idle 256 GB Macs hold eight Gemma lanes now; at 4 GiB a request two idle 48 GB Macs hold \(smallWidest)",
        widest(big, layout) == 8 && widest(big, charged) == 8 && (2...4).contains(smallWidest))
    let refusals: [(String, (inout ClusterPlacementPolicy) -> Void)] = [
        ("beside tensor parallel", { $0.modes = [.pipeline, .tensorParallel] }), ("for every mode", { $0.modes = nil }),
        ("with the one-chunk lookahead", { $0.schedules = [.oneChunkLookahead] }), ("of nine lanes", { $0.pipelineLanes = 9 }),
        ("of no lanes", { $0.pipelineLanes = 0 })]
    for (name, adjust) in refusals {
        var policy = serial; policy.pipelineLanes = 4; adjust(&policy)
        checks.refuses("pipeline width: refused \(name)", because: "A pipeline width needs the plain pipeline alone") {
            _ = try ClusterPlacementPlanner.plan(devices: big, layout: charged, policy: policy)
        }
    }
    var lanes = ClusterPlacementPolicy(); lanes.pipelineLanes = 4
    checks.refuses("pipeline width: an explicit evaluation of the speculative pipeline is refused a width", because: "A pipeline width needs") {
        _ = try ClusterPlacementPlanner.evaluate(devices: big, cuts: one.cuts, mode: .pipelineMTP, prefillSchedule: .serial,
            layout: charged, policy: lanes)
    }
    let evaluated = try ClusterPlacementPlanner.evaluate(devices: big, cuts: one.cuts, mode: .pipeline, prefillSchedule: .serial,
        layout: charged, policy: lanes)
    checks.require("pipeline width: an explicit evaluation of the plain pipeline prices the width as the planner does",
        evaluated.ranks.map(\.requestNeedBytes) == four?.ranks.map(\.requestNeedBytes))
    let glm = try ClusterModelLayout.decode(Data(contentsOf: golden.appendingPathComponent("layouts/GLM-5.3-Flash-MLX-NVFP4-mtp.json")))
    var glmLanes = serial; glmLanes.pipelineLanes = 2
    checks.refuses("pipeline width: a family that admits requests only on arrival (GLM's pipeline) prices no width",
        because: "A pipeline width needs") {
        _ = try ClusterPlacementPlanner.plan(devices: big, layout: glm, policy: glmLanes)
    }
}
