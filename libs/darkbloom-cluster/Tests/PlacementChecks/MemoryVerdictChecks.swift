import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
import Foundation

/// The verdict the setup presents (`ClusterPlacementMemoryVerdict`): fits, needs these Macs' GPU limits raised
/// (each to physical memory less the macOS reserve), or does not fit; and the raise's own question.
func checkMemoryVerdict(golden: URL, _ checks: PlacementChecks) throws {
    let m5 = golden.appendingPathComponent("profile-mac-b.json"), m3 = golden.appendingPathComponent("profile-mac-a.json")
    let link = linkCosts(reductionMicroseconds: 45)
    checks.require("memory verdict: the GPU limit ceiling is physical memory less 16 GiB (114,688 MiB of 128 GiB; 245,760 MiB of 256 GiB, the production GLM hosts' setting), less a sixteenth from 512 GiB",
        ClusterGPUMemoryLimit.ceilingMegabytes(physicalMemoryBytes: 128 << 30) == 114_688
            && ClusterGPUMemoryLimit.ceilingMegabytes(physicalMemoryBytes: 256 << 30) == 245_760
            && ClusterGPUMemoryLimit.ceilingMegabytes(physicalMemoryBytes: 512 << 30) == 491_520
            && ClusterGPUMemoryLimit.ceilingMegabytes(physicalMemoryBytes: 16 << 30) == 0)
    let idleMaxes = try [recorded(m5, label: "a"), recorded(m5, label: "b")]
    func verdict(_ devices: [ClusterPlacementDevice], _ layout: ClusterModelLayout,
                 policy: ClusterPlacementPolicy = .init()) throws -> (verdict: ClusterPlacementMemoryVerdict, result: ClusterPlacementResult) {
        try ClusterPlacementMemoryVerdict.assess(devices: devices) {
            try ClusterPlacementPlanner.plan(devices: $0, layout: layout, policy: policy, link: link)
        }
    }
    var tpFirst = ClusterPlacementPolicy(); tpFirst.tensorParallelFirst = true; tpFirst.tensorParallelAssumesUnmeasuredLink = true
    let mimo = try mimoProductLayout()
    checks.require("memory verdict: MiMo fits two 128 GB Macs as they are (default GPU limit)",
        try verdict(idleMaxes, mimo, policy: tpFirst).verdict == .fits)

    let big = try syntheticLayout(layers: 48, layerGiB: 4.5, modes: [.pipeline])
    let raise = try verdict(idleMaxes, big)
    let expected = (115_448_725_504, 114_688)
    if case .needsGPULimitRaise(let macs) = raise.verdict {
        checks.require("memory verdict (a): beyond the default GPU limit on both 128 GB Macs it needs both raised to 114,688 MiB, with the plan that holds then",
            macs.map(\.device).sorted() == ["a", "b"]
                && macs.allSatisfy { $0.defaultLimit && $0.currentLimitBytes == expected.0 && $0.raiseToMegabytes == expected.1
                    && $0.gpuNeedBytes > expected.0 && $0.gpuNeedBytes <= $0.raiseToBytes }
                && raise.result.chosen?.possible == true)
        checks.require("memory verdict (a): the raise's question names the need, macOS's default and the ceiling in GB of the Mac's own size",
            macs.first.map { mac in
                mac.question(model: "Big", mac: "this Mac")
                    == "Big needs \((mac.gpuNeedBytes + (1 << 30) - 1) >> 30) GB of GPU memory on this Mac; macOS allows 107 GB by default. "
                        + "Allow Darkbloom to raise it to 112 GB? (one password prompt; kept after a restart)"
            } == true)
    } else {
        checks.require("memory verdict (a): beyond the default GPU limit it needs the limits raised (got \(raise.verdict))", false)
    }
    let ceiling = ClusterGPUMemoryLimit.ceilingBytes(physicalMemoryBytes: 128 << 30)
    let raisedMaxes = try [recorded(m5, label: "a", wiredLimitBytes: ceiling), recorded(m5, label: "b", wiredLimitBytes: ceiling)]
    checks.require("memory verdict (b): once both limits are at the ceiling it fits, and no further raise is offered",
        try verdict(raisedMaxes, big).verdict == .fits && (try raisedMaxes[0].profile.withGPUMemoryLimitRaised()) == nil)
    let huge = try syntheticLayout(layers: 48, layerGiB: 4.9, modes: [.pipeline])
    checks.require("memory verdict: a model beyond both Macs' ceilings does not fit, raised or not",
        try verdict(idleMaxes, huge).verdict == .doesNotFit)
    var leaderUltra = ClusterPlacementPolicy(); leaderUltra.leader = "ultra"
    checks.require("memory verdict (d): the mixed pair fits it unevenly without a raise",
        try verdict([recorded(m3, label: "ultra"), recorded(m5, label: "max")], syntheticLayout(layers: 48, layerGiB: 6.2, modes: [.pipeline]),
                    policy: leaderUltra).verdict == .fits)
    if ProcessInfo.processInfo.environment["PLACEMENT_MEMORY_TABLE"] == "1" {
        try printMiMoBudgets(golden: golden, layout: mimo, link: link)
    }
}

/// MiMo's per-Mac budget from the planner's own figures, for the report (`PLACEMENT_MEMORY_TABLE=1`).
private func printMiMoBudgets(golden: URL, layout: ClusterModelLayout, link: ClusterLinkCosts) throws {
    let m5 = golden.appendingPathComponent("profile-mac-b.json"), m3 = golden.appendingPathComponent("profile-mac-a.json")
    func g(_ bytes: Int) -> String { String(format: "%.2f", Double(bytes) / Double(gib)) }
    for (name, devices) in [("2 x 128 GB (M5 Max)", try [recorded(m5, label: "a"), recorded(m5, label: "b")]),
                            ("2 x 256 GB (M3 Ultra)", try [recorded(m3, label: "a"), recorded(m3, label: "b")]),
                            ("256 GB + 128 GB", try [recorded(m3, label: "ultra"), recorded(m5, label: "max")])] {
        for (mode, cuts) in [(ClusterGenerationMode.pipeline, [24]), (.pipelineMTP, [24]), (.tensorParallel, [])] {
            let c = try ClusterPlacementPlanner.evaluate(devices: devices, cuts: cuts, mode: mode, prefillSchedule: .serial,
                layout: layout, policy: ClusterPlacementPolicy(), link: link)
            for r in c.ranks {
                let p = devices.first { $0.label == r.device }!.profile, gpu = r.gpuResidentBytes ?? 0
                print("| \(name) | \(mode.rawValue) | \(r.rank) [\(r.firstLayer),\(r.endLayer)) | \(g(r.weightsBytes)) | "
                    + "\(g(gpu - r.weightsBytes - (r.transientBytes ?? 0))) | \(g(r.transientBytes ?? 0)) | \(g(gpu)) | "
                    + "\(g(p.residentCapacityBytes)) | \(g(p.residentCapacityBytes - gpu)) | \(g(r.needBytes)) | \(g(p.atRestAdmissibleBytes)) |")
            }
        }
    }
}
