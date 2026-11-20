import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
import Foundation

/// The plan made again after a Mac's load gate refused its share (`ClusterPlacementPolicy.freePagesFirst`). A
/// DevNet pair, 2026-11-15: Gemma 4 26B (the 2026-11-13 revision) in pipeline, the M3 Ultra (256 GB, 139 GiB free)
/// leading and the M5 Max (128 GB) with 12.8 GiB free, about 40 GiB of file cache, and a VM and `fseventsd` holding
/// much of the rest. The planner put 29 of the 30 layers (15.18 GiB) on the M5 Max: its live fit counted the file
/// cache, as the gate does on one sample at normal pressure. The gate withdrew the cache mid-load, once the load had
/// compressed applications, and refused on 3.09 GiB free; the re-plan chose 1 / 29 again, and the pair kept starting
/// it. Both Macs' recorded hardware, the recorded layout, constructed memory samples and speeds: no model, no GPU.
func checkFreePagesFirst(golden: URL, _ checks: PlacementChecks) throws {
    let layout = try ClusterModelLayout.decode(Data(contentsOf: golden.appendingPathComponent(
        "layouts/gemma-4-26b-qat-4bit-2026-11-13-qat-lattice8-r1.json")))
    let ultraFile = golden.appendingPathComponent("profile-mac-a.json"), maxFile = golden.appendingPathComponent("profile-mac-b.json")
    let ultraSpeed = measured(prefill: 900, decode: 45), maxSpeed = measured(prefill: 2_400, decode: 95)
    func pair(ultra: SyntheticMac, max: SyntheticMac) throws -> [ClusterPlacementDevice] {
        [try recorded(ultraFile, label: "ultra", memory: ultra, speed: ultraSpeed),
         try recorded(maxFile, label: "max", memory: max, speed: maxSpeed)]
    }
    var asBefore = ClusterPlacementPolicy()
    asBefore.leader = "ultra"; asBefore.modes = [.pipeline]
    var afterRefusal = asBefore
    afterRefusal.freePagesFirst = true
    func plans(_ devices: [ClusterPlacementDevice]) throws -> (before: ClusterPlacementCandidate?, after: ClusterPlacementCandidate?) {
        (try ClusterPlacementPlanner.plan(devices: devices, layout: layout, policy: asBefore).chosen,
         try ClusterPlacementPlanner.plan(devices: devices, layout: layout, policy: afterRefusal).chosen)
    }
    func layers(_ candidate: ClusterPlacementCandidate?, on device: String) -> Int {
        candidate?.ranks.first { $0.device == device }.map { $0.endLayer - $0.firstLayer } ?? -1
    }
    func onFreePages(_ candidate: ClusterPlacementCandidate?, _ devices: [ClusterPlacementDevice]) -> Bool {
        candidate?.fitsOnFreePages(devices) ?? false
    }

    // The DevNet pair as it was. The plan as before: most layers on the faster M5 Max (29 with its measured speeds, 22
    // with these), which fits "now" only by its file cache; its free pages do not hold the share, and those are all the
    // gate counted when it refused.
    let busy = try pair(ultra: SyntheticMac(physicalGiB: 256, freeGiB: 139, inactiveCacheGiB: 60, wiredGiB: 9),
                        max: SyntheticMac(physicalGiB: 128, freeGiB: 12.8, inactiveCacheGiB: 40, wiredGiB: 7.2, compressorGiB: 14.3))
    let tight = try plans(busy)
    let maxBefore = tight.before?.ranks.first { $0.device == "max" }
    checks.require("free pages first, the DevNet pair as it was: the plan as before puts \(layers(tight.before, on: "max")) of 30 layers on the M5 Max, "
        + "fitting now by its file cache (tier \(tight.before?.tier ?? -1)) but not its 12.8 GiB free",
        layers(tight.before, on: "max") > 15 && tight.before?.tier == 0 && maxBefore.map { !busy[1].profile.memory.admitsOnFreePages($0.needBytes) } == true)
    // Planned again after the refusal: a split each Mac's free pages hold, the M3 Ultra taking the layers the M5 Max's
    // free pages don't, still in the mode the pair serves.
    checks.require("free pages first, the DevNet pair as it was: planned again after the refusal, every rank fits its Mac's free pages "
        + "(M5 Max \(layers(tight.after, on: "max")) layers, M3 Ultra \(layers(tight.after, on: "ultra")))",
        onFreePages(tight.after, busy) && tight.after?.mode == .pipeline
            && layers(tight.after, on: "max") < layers(tight.before, on: "max") && layers(tight.after, on: "max") > 0
            && tight.after?.possible == true && tight.after?.tier == 0)
    // The fastest such split: one layer more on the M5 Max does not fit its free pages.
    if let after = tight.after, after.cut > 1, layout.admittedCuts.contains(after.cut - 1),
       let next = try? ClusterPlacementPlanner.evaluate(devices: busy, cuts: [after.cut - 1], mode: after.mode,
            prefillSchedule: after.prefillSchedule, layout: layout, policy: afterRefusal) {
        checks.require("free pages first, the DevNet pair as it was: the split is the fastest one the free pages hold (cut \(after.cut - 1) does not fit them)",
            !onFreePages(next, busy))
    }

    // The provider's own order, tensor parallel first: a split the free pages hold still goes ahead of a tensor-parallel
    // one they don't (each hardware group is split, and tensor parallel goes first only within its half). With 9 GiB
    // free on the M5 Max, its half of tensor parallel fits only by the cache.
    var tpFirst = ClusterPlacementPolicy()
    tpFirst.leader = "ultra"; tpFirst.tensorParallelFirst = true; tpFirst.tensorParallelAssumesUnmeasuredLink = true
    var tpFirstAfter = tpFirst
    tpFirstAfter.freePagesFirst = true
    let nine = try pair(ultra: SyntheticMac(physicalGiB: 256, freeGiB: 139, inactiveCacheGiB: 60, wiredGiB: 9),
                        max: SyntheticMac(physicalGiB: 128, freeGiB: 9, inactiveCacheGiB: 44, wiredGiB: 7.2, compressorGiB: 14.3))
    let link = linkCosts(reductionMicroseconds: 45)
    let tpBefore = try ClusterPlacementPlanner.plan(devices: nine, layout: layout, policy: tpFirst, link: link).chosen
    let tpAfter = try ClusterPlacementPlanner.plan(devices: nine, layout: layout, policy: tpFirstAfter, link: link).chosen
    let somePipeline = try ClusterPlacementPlanner.plan(devices: nine, layout: layout, policy: afterRefusal, link: link).chosen
    checks.require("free pages first, tensor parallel first: the plan before (\(tpBefore?.mode.rawValue ?? "-")) fits only by the "
        + "cache; planned again, a split the free pages hold goes first (\(tpAfter?.mode.rawValue ?? "-") cut \(tpAfter?.cut ?? -1))",
        tpBefore?.fitsOnFreePages(nine) == false && somePipeline?.fitsOnFreePages(nine) == true
            && tpAfter?.fitsOnFreePages(nine) == true && tpAfter?.possible == true)

    // Free pages hold no split (both Macs' pages are file cache): the order is the one before, and the plan the same.
    let cached = try pair(ultra: SyntheticMac(physicalGiB: 256, freeGiB: 3, inactiveCacheGiB: 200, wiredGiB: 9),
                          max: SyntheticMac(physicalGiB: 128, freeGiB: 3, inactiveCacheGiB: 80, wiredGiB: 7.2))
    let none = try plans(cached)
    checks.require("free pages first: when no split fits both Macs' free pages, the plan is the one before (cut \(none.before?.cut ?? -1))",
        none.before != nil && none.after?.cuts == none.before?.cuts && none.after?.mode == none.before?.mode
            && none.after?.prefillSchedule == none.before?.prefillSchedule && !onFreePages(none.after, cached))
    // Macs at rest: the plan before already fits free pages, and nothing changes.
    let rested = try pair(ultra: .idle(256), max: .idle(128))
    let idle = try plans(rested)
    checks.require("free pages first: Macs at rest get the plan they got before (cut \(idle.before?.cut ?? -1))",
        idle.before != nil && idle.after?.cuts == idle.before?.cuts && idle.after?.mode == idle.before?.mode
            && onFreePages(idle.before, rested))
}
