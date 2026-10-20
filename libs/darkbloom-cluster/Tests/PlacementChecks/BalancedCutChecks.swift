import DarkbloomClusterPlacement
import Foundation

/// Cuts the predicted request time cannot tell apart are decided by the
/// hardware, not by which Mac has more free memory at the moment of planning
/// (two M5 Ultra 256 GB planned 11/34 and then 5/40 of GLM's 45 layers,
/// 2026-10-19, because the earliest cut the second Mac's live memory held won
/// an exact tie). Constructed Macs only.
func checkBalancedCut(_ big: ClusterModelLayout, _ checks: PlacementChecks) throws {
    let layers = big.layerCount
    var policy = ClusterPlacementPolicy(); policy.modes = [.pipeline]; policy.schedules = [.serial]
    // The same Mac twice: one idle, one with other programs and file cache taking
    // most of its memory right now. Neither speed nor hardware tells them apart.
    let idle = SyntheticMac.idle(256)
    let busy = SyntheticMac(physicalGiB: 256, freeGiB: 120, inactiveCacheGiB: 60, wiredGiB: 8)
    func balanced(_ cut: Int?) -> Bool { cut.map { abs($0 - layers / 2) <= 1 } ?? false }
    for (name, speed) in [("assumed equal", ClusterDeviceSpeed.assumedEqual),
                          ("measured equal", measured(prefill: 2_000, decode: 60))] {
        let pair = [try idle.device("a", speed: speed), try busy.device("b", speed: speed)]
        let plan = try ClusterPlacementPlanner.plan(devices: pair, layout: big, policy: policy)
        checks.require("identical Macs (\(name)) split the layers evenly, whatever each has free now", balanced(plan.chosen?.cut))
        let swapped = try ClusterPlacementPlanner.plan(devices: pair.reversed(), layout: big, policy: policy)
        checks.require("identical Macs (\(name)) split evenly whichever Mac is named first", swapped.chosen == plan.chosen)
        for leader in ["a", "b"] {
            var led = policy; led.leader = leader
            let restricted = try ClusterPlacementPlanner.plan(devices: pair, layout: big, policy: led)
            checks.require("identical Macs (\(name)) split evenly when \(leader) must lead", balanced(restricted.chosen?.cut))
        }
    }
    // Unequal memory, equal speed: the tie goes to the cut that leaves each Mac the
    // largest share of its own hardware capacity, so the bigger Mac takes more layers.
    let pair = [try SyntheticMac.idle(256).device("big"), try SyntheticMac.idle(128).device("small")]
    var led = policy; led.leader = "big"
    let unequal = try ClusterPlacementPlanner.plan(devices: pair, layout: big, policy: led)
    checks.require("with equal speed a 256 GB Mac takes more layers than a 128 GB Mac",
        (unequal.chosen?.cut ?? 0) > layers / 2 && (unequal.chosen?.cut ?? layers) < layers - 1)
    // A real speed difference still decides: the tie-break never moves a faster cut.
    let fastPair = [try idle.device("slow", speed: measured(prefill: 300, decode: 28)),
                    try idle.device("fast", speed: measured(prefill: 900, decode: 28))]
    let fast = try ClusterPlacementPlanner.plan(devices: fastPair, layout: big, policy: policy)
    let even = try ClusterPlacementPlanner.evaluate(devices: fastPair, cuts: [layers / 2], mode: .pipeline,
        prefillSchedule: .serial, layout: big, policy: policy)
    checks.require("a faster split is never traded for balance",
        (fast.chosen?.prediction(.rested).requestSeconds ?? .infinity) < even.prediction(.rested).requestSeconds)
}
