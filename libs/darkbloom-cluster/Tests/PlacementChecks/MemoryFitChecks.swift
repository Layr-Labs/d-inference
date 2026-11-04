import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
import Foundation

/// A recorded Mac's hardware (chip, GPU working set, allocator and buffer limits, as its golden profile printed
/// them) with the memory of `memory` (an idle Mac of its size by default), and `iogpu.wired_limit_mb` when set.
func recorded(_ file: URL, label: String, memory: SyntheticMac? = nil, wiredLimitBytes: Int? = nil,
              speed: ClusterDeviceSpeed = measured(prefill: 400, decode: 40)) throws -> ClusterPlacementDevice {
    let p = try ClusterDeviceProfile.decode(Data(contentsOf: file))
    let sample = memory ?? SyntheticMac.idle(Double(p.physicalMemoryBytes) / Double(gib))
    let profile = try ClusterDeviceProfile(chip: p.chip, performanceCores: p.performanceCores, efficiencyCores: p.efficiencyCores,
        gpuCores: p.gpuCores, osVersion: p.osVersion, osBuild: p.osBuild, physicalMemoryBytes: p.physicalMemoryBytes,
        gpuRecommendedWorkingSetBytes: p.gpuRecommendedWorkingSetBytes, gpuMaximumBufferBytes: p.gpuMaximumBufferBytes,
        allocatorLimitBytes: p.allocatorLimitBytes, memory: .gate(sample.observation, now: SyntheticMac.now), power: p.power,
        wiredLimitBytes: wiredLimitBytes)
    return .init(label: label, profile: profile, speed: speed)
}

/// MiMo V2.6 Flash as the product prices it: the registered row's own metadata, the tensor-parallel reserve at the
/// allocator's bound, and the speculative rounds on every tensor-parallel rank (`mimoWithRounds`).
func mimoProductLayout() throws -> ClusterModelLayout {
    let libraries = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let fixtures = libraries.appendingPathComponent("darkbloom-cluster-worker/Tests/CapabilityChecks/Fixtures")
    struct Tensor: Decodable { let name: String; let shape: [Int]; let sourceDType: String; let byteCount: Int }
    let configuration = try Data(contentsOf: fixtures.appendingPathComponent("registered-mimo-v26-flash-mopd.configuration.json"))
    let tensors = try JSONDecoder().decode([Tensor].self,
        from: Data(contentsOf: fixtures.appendingPathComponent("registered-mimo-v26-flash-mopd.tensor-inventory.json"))).map {
            ClusterPlacementStoredTensor(name: $0.name, byteCount: $0.byteCount, dtype: $0.sourceDType, shape: $0.shape)
        }
    let priced = try ClusterPlacementLayouts.layout(configuration: configuration, tensors: tensors,
        tensorParallelAllocationBound: { $0 + 16_384 })
    return try mimoWithRounds(priced, configuration: configuration, allocationBound: { $0 + 16_384 })
}

/// One truth for "fits": the planner's at-rest ceiling is the load gate's own (it counts all file cache), the live
/// gate's answer no longer offers a split the GPU cannot keep resident, and a member whose gate counts no file cache
/// (pressure above normal) is not offered as fitting on cache the gate will not count. Recorded M5 Max
/// (128 GB, 107.52 GiB working set) and M3 Ultra (256 GB, 222.72 GiB) hardware, constructed memory samples.
func checkMemoryFit(golden: URL, _ checks: PlacementChecks) throws {
    let m5 = golden.appendingPathComponent("profile-mac-b.json"), m3 = golden.appendingPathComponent("profile-mac-a.json")
    let link = linkCosts(reductionMicroseconds: 45)
    var tpFirst = ClusterPlacementPolicy(); tpFirst.tensorParallelFirst = true; tpFirst.tensorParallelAssumesUnmeasuredLink = true
    let mimo = try mimoProductLayout()

    // (a) MiMo on two 128 GB Macs, default GPU limit. A Mac with 40 GiB of applications open is not one that
    // cannot hold its half: closed, a 128 GiB Mac's gate admits far more than the 89-100 GiB any split asks for.
    let busy = SyntheticMac(physicalGiB: 128, freeGiB: 60, inactiveCacheGiB: 12, wiredGiB: 7.7)
    let busyMaxes = try [recorded(m5, label: "a", memory: busy), recorded(m5, label: "b", memory: busy)]
    let busyPlan = try ClusterPlacementPlanner.plan(devices: busyMaxes, layout: mimo, policy: tpFirst, link: link)
    checks.require("memory fit (a): MiMo on two busy 128 GB Macs is offered with 'quit apps first', not refused as too large even with every application closed",
        busyPlan.chosen?.possible == true && busyPlan.refusal == nil
            && busyPlan.chosen?.ranks.allSatisfy { $0.fit.tier == 2 && $0.hardwareFits == true } == true)
    let idleMaxes = try [recorded(m5, label: "a"), recorded(m5, label: "b")]
    for (mode, cuts) in [(ClusterGenerationMode.pipeline, [24]), (.pipelineMTP, [24]), (.tensorParallel, [])] {
        let candidate = try ClusterPlacementPlanner.evaluate(devices: idleMaxes, cuts: cuts, mode: mode, prefillSchedule: .serial,
            layout: mimo, policy: tpFirst, link: link)
        checks.require("memory fit (a): MiMo \(mode.rawValue) on two 128 GB Macs fits the gate at rest and the default 107.52 GiB GPU limit on both",
            candidate.possible && candidate.ranks.allSatisfy { $0.hardwareFits == true && $0.withinGPUWorkingSet })
    }

    // (a) A model whose half exceeds a 128 GB Mac's default GPU limit (macOS's working set) but not its ceiling.
    let big = try syntheticLayout(layers: 48, layerGiB: 4.5, modes: [.pipeline])
    let offered = try ClusterPlacementPlanner.plan(devices: idleMaxes, layout: big, link: link)
    checks.require("memory fit (a): a split whose GPU part exceeds the default GPU limit is never offered, however much is free now",
        offered.chosen.map { $0.possible && $0.ranks.allSatisfy(\.withinGPUWorkingSet) } ?? true)

    // (b) The same Macs with `iogpu.wired_limit_mb` at the ceiling: it is placed, within the GPU limit, and the gate
    // admits each rank's need on the idle Mac.
    // `ClusterGPUMemoryLimit.ceilingBytes` of a 128 GiB Mac.
    let ceiling = 112 << 30
    let raisedMaxes = try [recorded(m5, label: "a", wiredLimitBytes: ceiling), recorded(m5, label: "b", wiredLimitBytes: ceiling)]
    let raisedPlan = try ClusterPlacementPlanner.plan(devices: raisedMaxes, layout: big, link: link)
    checks.require("memory fit (b): after the raise to 112 GiB the split fits (hardware, GPU limit) and each Mac's gate admits its need",
        raisedPlan.chosen.map { chosen in
            chosen.possible && chosen.ranks.allSatisfy { rank in
                rank.hardwareFits == true && rank.withinGPUWorkingSet
                    && raisedMaxes.first { $0.label == rank.device }!.profile.memory.admits(rank.needBytes)
            }
        } == true)

    // (c) Qwen3.8 27B's tensor-parallel share on the 128 GB member, 2026-11-03 (49.08 GiB, the worker's own refusal):
    // 0.17 GiB free, as the refusal reported. At normal pressure the gate counts the file cache and admits the share,
    // so the plan says it fits now. The refusal was the gate's compression limit at normal pressure: the part start
    // had read the model into the file cache, the load took memory from it page by page while applications were
    // compressed, and 515 MiB compressed since the load's first check (limit 512 MiB) withdrew the cache. No plan's
    // sample can foresee that; dropping the model's cache before the load is the remedy. Separately, above normal
    // pressure the gate counts no cache at all, so the plan must not call the cache the kernel would give room.
    let share = Int((49.08 * Double(gib)).rounded(.up))
    var member = SyntheticMac(physicalGiB: 128, freeGiB: 0.17, inactiveCacheGiB: 70, activeCacheGiB: 25, wiredGiB: 7.7, compressorGiB: 6.2)
    let normal = ClusterDeviceMemory.gate(member.observation, now: SyntheticMac.now)
    checks.require("memory fit (c): at normal pressure the member's gate admits the 49.08 GiB share on its file cache, and the plan says it fits now",
        normal.admits(share) && normal.fit(share) == .now)
    var compressed = member
    compressed.compressionPages = 515 * 1_048_576 / SyntheticMac.page; compressed.liveCompressionPages = compressed.compressionPages
    let refusal = try QwenDenseStageLoadPolicy.decide(compressed.observation, requiredBytes: share, purpose: "Tensor-parallel shard load",
        now: SyntheticMac.now, since: QwenDenseStageLoadBaseline(member.observation))
    checks.require("memory fit (c): the member's refusal was the compression limit at normal pressure, in the worker's words, which the plan's own sample cannot foresee",
        !refusal.admitted && refusal.stoppedByCompressionOrSwap && refusal.pressureLevel == QwenDenseStageLoadPolicy.normalPressureLevel
            && refusal.refusal?.hasSuffix("free plus no file cache: 515 MiB was compressed and 0 MiB swapped out since its first check "
                + "(limits 512 and 64 MiB), so the kernel is taking anonymous memory") == true
            && ClusterDeviceMemory.gate(compressed.observation, now: SyntheticMac.now).fit(share) == .now)
    member.pressure = 2
    let warning = ClusterDeviceMemory.gate(member.observation, now: SyntheticMac.now)
    checks.require("memory fit (c): separately, above normal pressure the gate counts no file cache and refuses; the plan says quit apps, not 'fits'",
        !warning.admits(share) && warning.countedFileCacheBytes == 0
            && { if case .afterApplicationsRelease = warning.fit(share) { return true } else { return false } }())

    // (d) A mixed pair: M3 Ultra 256 GB and M5 Max 128 GB, a model (298 GiB) the M3 Ultra cannot hold alone and no even
    // split fits. With the M5 Max busy (60 GiB free and cached now) it is offered with 'quit apps first' and split
    // unevenly, each rank within its own Mac's at-rest and GPU limits, the M5 Max at its real capacity: beyond the
    // 75.6 GiB the planner allowed a 128 GiB Mac until 2026-11-03, which refused the pair as too large.
    let large = try syntheticLayout(layers: 48, layerGiB: 6.2, modes: [.pipeline])
    let mixed = try [recorded(m3, label: "ultra"),
                     recorded(m5, label: "max", memory: SyntheticMac(physicalGiB: 128, freeGiB: 50, inactiveCacheGiB: 10, wiredGiB: 7.7))]
    var leaderUltra = ClusterPlacementPolicy(); leaderUltra.leader = "ultra"
    let lopsided = try ClusterPlacementPlanner.plan(devices: mixed, layout: large, policy: leaderUltra, link: link)
    let maxRank = lopsided.chosen?.ranks.first { $0.device == "max" }, ultraRank = lopsided.chosen?.ranks.first { $0.device == "ultra" }
    checks.require("memory fit (d): M3 Ultra 256 GB + M5 Max 128 GB split unevenly, each rank within its own Mac's limits",
        lopsided.chosen?.possible == true && (ultraRank?.weightsBytes ?? 0) > (maxRank?.weightsBytes ?? .max)
            && lopsided.chosen?.ranks.allSatisfy { $0.hardwareFits == true && $0.withinGPUWorkingSet } == true)
    checks.require("memory fit (d): the M5 Max holds more than the 75.6 GiB the old at-rest ceiling allowed, once memory is freed there",
        (maxRank?.weightsBytes ?? 0) > Int(75.6 * Double(gib)) && maxRank?.fit.possible == true && maxRank?.fit != .now)

    // A bench cap (`cappedForBench`) plans a large Mac as one that can give a model only the cap. The at-rest ceiling
    // is the host side of `hardwareFits`, so the cap bounds it too: memory the Mac may not give never counts as
    // fitting, even when the share's GPU part is within the capped GPU limit.
    let uncapped = try SyntheticMac.idle(256).profile(), benchCap = 96 * gib
    let capped = try uncapped.cappedForBench(admissibleBytes: benchCap)
    func holds(_ profile: ClusterDeviceProfile) -> Bool {
        profile.hardwareFits(needBytes: benchCap + gib, weightsBytes: gib, largestTensorBytes: 0, gpuResidentBytes: benchCap / 2)
    }
    checks.require("memory fit (bench cap): a capped Mac's at-rest ceiling is within the cap, so a need beyond it is not hardware-fit, whatever its GPU part",
        capped.atRestAdmissibleBytes <= benchCap && !holds(capped) && uncapped.atRestAdmissibleBytes == 240 * gib && holds(uncapped))
}
