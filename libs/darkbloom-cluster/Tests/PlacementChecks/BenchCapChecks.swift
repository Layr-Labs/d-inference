import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
import Foundation

/// The developer bench cap (`ClusterDeviceProfile.cappedForBench`): a test-only
/// lowering of what the planner believes a Mac can give a model, so that a pair
/// of large Macs is planned the way a pair of smaller Macs would be. Constructed
/// Macs only; the real load gate is not involved and is never changed.
func checkBenchCap(_ checks: PlacementChecks) throws {
    // A 48-layer model of about 154 GiB, every cut admitted, pipeline and phase split listed.
    let layout = try syntheticLayout(layers: 48, layerGiB: 3.2, modes: [.pipeline, .pipelineCompactDecode, .phaseSplit])
    let big = SyntheticMac.idle(256)
    let a = try big.device("mac-a", speed: measured(prefill: 1000, decode: 30))
    let b = try big.device("mac-b", speed: measured(prefill: 4000, decode: 45))

    // Uncapped: one 256 GiB Mac holds the whole model, so a phase split (or that Mac alone) is possible.
    let open = try ClusterPlacementPlanner.plan(devices: [a, b], layout: layout)
    checks.require("bench cap: uncapped, a 256 GiB Mac holds the 154 GiB model alone",
        open.alone.contains { $0.fit == .now })

    // Capped to 96 GiB each, as two 96 GiB Macs: neither holds it whole, so the planner must split it, near evenly.
    let cap = 96 * gib
    let capped = try [a, b].map { device in
        ClusterPlacementDevice(label: device.label, profile: try device.profile.cappedForBench(admissibleBytes: cap), speed: device.speed)
    }
    let split = try ClusterPlacementPlanner.plan(devices: capped, layout: layout)
    checks.require("bench cap: capped to 96 GiB, neither Mac holds the model alone", split.alone.allSatisfy { !$0.fit.possible })
    checks.require("bench cap: capped to 96 GiB, the chosen placement is a pipeline in which no rank holds every layer",
        split.chosen.map { !$0.mode.isPhaseSplit && $0.ranks.count == 2 } == true)
    let shareFloor = layout.layerCount * 2 / 5
    let ranks: [ClusterPlacementRank] = split.chosen?.ranks ?? []
    let shared = !ranks.isEmpty && ranks.allSatisfy { (rank: ClusterPlacementRank) -> Bool in
        rank.endLayer - rank.firstLayer >= shareFloor && rank.needBytes <= cap
    }
    checks.require("bench cap: capped to 96 GiB, each rank holds at least 40 % of the layers and needs no more than the cap", shared)
    checks.require("bench cap: every rank of the capped plan fits now", split.chosen?.ranks.allSatisfy { $0.fit == .now } == true)

    // The capped profile is still a valid profile, says nothing more than the cap, and keeps what it observed.
    let original = try big.profile(chip: "Apple M3 Ultra")
    let lowered = try original.cappedForBench(admissibleBytes: cap)
    checks.require("bench cap: a capped profile survives its own encoding",
        try ClusterDeviceProfile.decode(lowered.encoded()) == lowered)
    let m = lowered.memory
    checks.require("bench cap: admissible, kernel-would-give, with-applications-closed and after-restart are all at most the cap",
        m.admissibleNowBytes <= cap && m.kernelWouldGiveBytes <= cap && m.withApplicationsClosedBytes <= cap && m.afterRestartBytes <= cap)
    checks.require("bench cap: the GPU working set, the resident capacity and the allocator limit are at most the cap",
        lowered.gpuRecommendedWorkingSetBytes <= cap && lowered.residentCapacityBytes <= cap && lowered.allocatorLimitBytes <= cap)
    checks.require("bench cap: physical memory, chip, OS build and the gate's constants are kept as observed",
        lowered.physicalMemoryBytes == original.physicalMemoryBytes && lowered.chip == original.chip && lowered.osBuild == original.osBuild
            && m.minimumAdmissibleBytes == original.memory.minimumAdmissibleBytes && m.loadingHeadroomBytes == original.memory.loadingHeadroomBytes
            && m.gatePolicy == original.memory.gatePolicy && m.wiredBytes == original.memory.wiredBytes)
    checks.require("bench cap: beyond the cap a capped Mac answers never, not after applications release",
        { if case .never = m.fit(cap + gib) { return true } else { return false } }())
    checks.require("bench cap: within the cap a capped idle Mac still answers now", m.fit(cap - 8 * gib) == .now)
    var indexed = original
    indexed.speedIndex = .init(chip: original.chip, osBuild: original.osBuild, benchmark: "qmm_h4096_b4_g64_x16_v1",
        prefillIndex: 4.8e5, decodeIndex: 3.2e4)
    checks.require("bench cap: the speed index is carried unchanged",
        try indexed.cappedForBench(admissibleBytes: cap).speedIndex == indexed.speedIndex)

    // The cap only ever lowers: a Mac smaller than the cap is left exactly as it was.
    let small = try SyntheticMac.idle(64).profile(chip: "Apple M2 Max")
    checks.require("bench cap: a cap above what a Mac has leaves its profile unchanged",
        try small.cappedForBench(admissibleBytes: 128 * gib) == small)
    // Different Macs under one cap: the 64 GiB Mac is untouched, the 192 GiB Mac is lowered.
    let mid = try SyntheticMac.idle(192).profile(chip: "Apple M4 Max")
    let both = try [small, mid].map { try $0.cappedForBench(admissibleBytes: 96 * gib) }
    checks.require("bench cap: one cap over Macs of different sizes lowers only the larger",
        both[0] == small && both[1].memory.admissibleNowBytes <= 96 * gib && both[1].memory.admissibleNowBytes < mid.memory.admissibleNowBytes)
    // A file-cache-heavy sample: counted cache and cache above the minimum are clamped with the free pages.
    var cached = SyntheticMac.idle(256); cached.freeGiB = 40; cached.inactiveCacheGiB = 150
    let cachedProfile = try cached.profile(chip: "Apple M5 Ultra")
    let cachedLowered = try cachedProfile.cappedForBench(admissibleBytes: 64 * gib)
    checks.require("bench cap: a sample full of file cache is clamped consistently",
        try ClusterDeviceProfile.decode(cachedLowered.encoded()) == cachedLowered
            && cachedLowered.memory.kernelWouldGiveBytes <= 64 * gib
            && cachedLowered.memory.admissibleNowBytes <= cachedProfile.memory.admissibleNowBytes
            && cachedLowered.memory.countedFileCacheBytes <= cachedLowered.memory.fileCacheAboveReserveBytes)

    // Nonsense caps are refused rather than guessed at.
    checks.refuses("bench cap: a cap below the gate's own minimum is refused", because: "below the load gate's minimum") {
        _ = try original.cappedForBench(admissibleBytes: original.memory.minimumAdmissibleBytes - 1)
    }
    checks.refuses("bench cap: a zero or negative cap is refused", because: "below the load gate's minimum") {
        _ = try original.cappedForBench(admissibleBytes: 0)
    }
}
