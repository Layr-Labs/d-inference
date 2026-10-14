import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
import Foundation

/// A model whose qualification records restrict shapes (`policy.admitsShape`):
/// the planner chooses, ranks and offers only shapes the gate admits, says how
/// many possible placements it left out, and refuses in its own words, never
/// as a memory refusal, when it leaves out every one. Constructed Macs of
/// several sizes and chips, two to three members; no model, no GPU.
func checkQualifiedShapes(_ big: ClusterModelLayout, _ checks: PlacementChecks) throws {
    let a = try SyntheticMac.idle(256).device("a", chip: "Chip One Ultra")
    let b = try SyntheticMac.idle(128).device("b", chip: "Chip Two Max")
    let c = try SyntheticMac.idle(64).device("c", chip: "Chip Three Pro")
    var policy = ClusterPlacementPolicy()
    policy.modes = [.pipeline]
    let free = try ClusterPlacementPlanner.plan(devices: [a, b], layout: big, policy: policy)
    checks.require("qualified shapes: without a gate nothing is left out and nothing is reported",
        free.unqualifiedPossible == nil && free.chosen != nil)
    let freeCut = free.chosen?.cut ?? 0
    // A gate that admits one cut, in one order, other than the free choice.
    let only = freeCut == 40 ? 24 : 40
    policy.admitsShape = { chips, cuts, mode in chips == ["Chip One Ultra", "Chip Two Max"] && cuts == [only] && mode == .pipeline }
    let gated = try ClusterPlacementPlanner.plan(devices: [a, b], layout: big, policy: policy)
    checks.require("qualified shapes: the chosen placement is the one shape the records admit",
        gated.chosen?.cut == only && gated.chosen?.ranks.map(\.device) == ["a", "b"] && gated.chosen?.mode == .pipeline)
    checks.require("qualified shapes: no alternative has a shape the records do not admit",
        gated.alternatives.allSatisfy { $0.cut == only && $0.ranks.map(\.device) == ["a", "b"] })
    checks.require("qualified shapes: the possible placements left out are counted",
        (gated.unqualifiedPossible ?? 0) > 0 && gated.candidatesConsidered == free.candidatesConsidered)
    let gatedLines = ClusterPlacementExplanation.describe(gated, devices: [a, b], layout: big)
    checks.require("qualified shapes: the plan says placements were left out because a check diverged at their shape",
        gatedLines.contains { $0.contains("were left out: a cross-cable check diverged at their shape on these chips") })
    // The order matters: the same cut led by the other Mac is not admitted.
    policy.admitsShape = { chips, cuts, _ in chips == ["Chip Two Max", "Chip One Ultra"] && cuts == [only] }
    let mirrored = try ClusterPlacementPlanner.plan(devices: [a, b], layout: big, policy: policy)
    checks.require("qualified shapes: a shape names each rank's chip in rank order",
        mirrored.chosen?.ranks.map(\.device) == ["b", "a"] && mirrored.chosen?.cut == only)
    // Nothing admitted: no placement is chosen, the refusal is not a memory refusal, and each Mac alone still shows.
    policy.admitsShape = { _, _, _ in false }
    let none = try ClusterPlacementPlanner.plan(devices: [a, b], layout: big, policy: policy)
    checks.require("qualified shapes: with no shape admitted nothing is chosen or offered",
        none.chosen == nil && none.alternatives.isEmpty && none.chosenForOtherRegime == nil)
    checks.require("qualified shapes: and it is not reported as a memory refusal",
        none.refusal == nil && (none.unqualifiedPossible ?? 0) > 0 && none.bestStructural != nil)
    let noneLines = ClusterPlacementExplanation.describe(none, devices: [a, b], layout: big)
    checks.require("qualified shapes: the refusal says every placement that fits diverged on these chips",
        noneLines.contains("Refused: every placement these Macs can hold diverged in a cross-cable check on these chips")
            && !noneLines.contains { $0.hasPrefix("Refused: no division of this model") })
    // Three members of three sizes: a gate admitting a pair of two of them keeps the planner to that pair.
    policy.admitsShape = { chips, cuts, _ in chips == ["Chip Three Pro", "Chip One Ultra"] && cuts == [8] }
    let three = try ClusterPlacementPlanner.plan(devices: [a, b, c], layout: big, policy: policy)
    checks.require("qualified shapes: of three Macs, only the admitted pair and cut are planned",
        three.chosen?.ranks.map(\.device) == ["c", "a"] && three.chosen?.cut == 8
            && three.alternatives.allSatisfy { $0.ranks.map(\.device) == ["c", "a"] && $0.cut == 8 })
    // Memory still refuses first: a gate cannot make a placement that does not fit possible.
    let pair64 = [try SyntheticMac.idle(64).device("x", chip: "Chip One Ultra"), try SyntheticMac.idle(64).device("y", chip: "Chip Two Max")]
    policy.admitsShape = { _, _, _ in true }
    policy.modes = nil
    let small = try ClusterPlacementPlanner.plan(devices: pair64, layout: try surveyedMiMoLayout(), policy: policy)
    checks.require("qualified shapes: an admitting gate leaves a memory refusal a memory refusal",
        small.chosen == nil && small.refusal != nil && small.unqualifiedPossible == 0)
}
