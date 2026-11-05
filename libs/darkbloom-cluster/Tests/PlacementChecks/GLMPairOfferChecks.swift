import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
import Foundation

/// GLM-5.3 Flash's modes on each pair the product meets, as the mode question offers them: the planner's sharded
/// options that run (`ClusterShardOption.Verdict` chosen, slower or faster on the prior only, with a placement), one
/// per family. Each offered placement must fit every Mac's GPU limit and its memory at rest, so it loads. When none
/// fits, the memory verdict raises only the GPU limits Darkbloom raises (`darkbloom cluster gpu-limit`: M5 Macs with
/// 128 or 256 GB), so "needs gpu-limit" is said only where running it makes the model fit, and "needs more memory"
/// otherwise. Recorded M5 Max, M3 Ultra and M5 Ultra hardware; the M4 Max is that 128 GB hardware under its own chip
/// name, at the GPU limit macOS 26.2 reports for it (107.52 GiB) and at lower defaults. No model, no GPU.
func checkGLMPairOffer(golden: URL, _ checks: PlacementChecks) throws {
    let layout = try ClusterModelLayout.decode(Data(contentsOf: golden.appendingPathComponent("layouts/GLM-5.3-Flash-MLX-NVFP4-mtp.json")))
    let m5max = try ClusterDeviceProfile.decode(Data(contentsOf: golden.appendingPathComponent("profile-mac-b.json")))
    let m3ultra = try ClusterDeviceProfile.decode(Data(contentsOf: golden.appendingPathComponent("profile-mac-a.json")))
    let m5ultra = try ClusterDeviceProfile.decode(Data(contentsOf: golden.appendingPathComponent("pairs/m3ultra-m5ultra/profile-mac-b.json")))
    // The recorded M5 Ultra runs the production GLM limit (240 GiB); its macOS default is 87 % of memory.
    let ultraDefault = 222_720 << 20
    func mac(_ label: String, _ p: ClusterDeviceProfile, chip: String? = nil, defaultGPU: Int? = nil, raised: Bool = false) throws
        -> ClusterPlacementDevice {
        let sample = SyntheticMac.idle(Double(p.physicalMemoryBytes >> 30))
        let limit = raised ? ClusterGPUMemoryLimit.ceilingBytes(physicalMemoryBytes: p.physicalMemoryBytes) : nil
        let profile = try ClusterDeviceProfile(chip: chip ?? p.chip, performanceCores: p.performanceCores, efficiencyCores: p.efficiencyCores,
            gpuCores: p.gpuCores, osVersion: p.osVersion, osBuild: p.osBuild, physicalMemoryBytes: p.physicalMemoryBytes,
            gpuRecommendedWorkingSetBytes: limit ?? defaultGPU ?? p.gpuRecommendedWorkingSetBytes,
            gpuMaximumBufferBytes: p.gpuMaximumBufferBytes, allocatorLimitBytes: p.allocatorLimitBytes,
            memory: .gate(sample.observation, now: SyntheticMac.now), power: p.power, wiredLimitBytes: limit)
        return .init(label: label, profile: profile, speed: .assumedEqual)
    }
    var product = ClusterPlacementPolicy(); product.tensorParallelFirst = true; product.tensorParallelAssumesUnmeasuredLink = true
    func plan(_ devices: [ClusterPlacementDevice]) throws -> ClusterPlacementResult {
        try ClusterPlacementPlanner.plan(devices: devices, layout: layout, policy: product)
    }
    // The mode question's rule (`ClusterSetupPlanning.modes`), and the placement each offered family would load.
    func offered(_ result: ClusterPlacementResult, _ devices: [ClusterPlacementDevice]) throws -> [String: ClusterPlacementCandidate] {
        let runs: Set<ClusterShardOption.Verdict> = [.chosen, .slower, .predictedFasterOnPriorOnly, .reductionNotMeasured]
        var families = [String: ClusterPlacementCandidate]()
        for option in result.shards?.options ?? [] where runs.contains(option.verdict) {
            guard let mode = option.mode, let family = ClusterForcedMode.allCases.first(where: { $0.admits(mode) }),
                  families[family.rawValue] == nil else { continue }
            var forced = product; forced.forcedMode = family
            families[family.rawValue] = try ClusterPlacementPlanner.plan(devices: devices, layout: layout, policy: forced).chosen
        }
        return families
    }
    func loads(_ c: ClusterPlacementCandidate?, _ devices: [ClusterPlacementDevice]) -> Bool {
        guard let c else { return false }
        return c.possible && c.ranks.allSatisfy { rank in
            let profile = devices.first { $0.label == rank.device }!.profile
            return (rank.gpuResidentBytes ?? .max) <= profile.residentCapacityBytes && rank.hardwareFits == true
        }
    }
    func verdict(_ devices: [ClusterPlacementDevice]) throws -> ClusterPlacementMemoryVerdict {
        try ClusterPlacementMemoryVerdict.assess(devices: devices, plan: plan).verdict
    }
    let pipeline = ClusterForcedMode.pipeline.rawValue, tensor = ClusterForcedMode.tensorParallel.rawValue
    let pairs: [(String, [ClusterPlacementDevice], Set<String>)] = try [
        ("M4 Max 128 + M5 Max 128", [mac("m4max", m5max, chip: "Apple M4 Max"), mac("m5max", m5max)], [pipeline]),
        ("M4 Max 128 + M5 Max 128 after gpu-limit on the M5 Max", [mac("m4max", m5max, chip: "Apple M4 Max"), mac("m5max", m5max, raised: true)], [pipeline]),
        ("M5 Max 128 x 2", [mac("max-a", m5max), mac("max-b", m5max)], [pipeline]),
        ("M5 Max 128 x 2 after gpu-limit on both", [mac("max-a", m5max, raised: true), mac("max-b", m5max, raised: true)], [pipeline]),
        ("M3 Ultra 256 + M5 Max 128", [mac("m3ultra", m3ultra), mac("m5max", m5max)], [pipeline]),
        ("M3 Ultra 256 + M5 Max 128 after gpu-limit on the M5 Max", [mac("m3ultra", m3ultra), mac("m5max", m5max, raised: true)], [pipeline]),
        ("M5 Ultra 256 x 2", [mac("ultra-a", m5ultra, defaultGPU: ultraDefault), mac("ultra-b", m5ultra, defaultGPU: ultraDefault)], [tensor, pipeline]),
        ("M5 Ultra 256 x 2 after gpu-limit on both", [mac("ultra-a", m5ultra, raised: true), mac("ultra-b", m5ultra, raised: true)], [tensor, pipeline]),
    ]
    for (name, devices, expected) in pairs {
        let result = try plan(devices)
        let modes = try offered(result, devices)
        checks.require("glm offer, \(name): exactly \(expected.sorted()) offered (got \(modes.keys.sorted()))", Set(modes.keys) == expected)
        checks.require("glm offer, \(name): each offered mode's placement fits every Mac's GPU limit and its memory at rest",
            modes.values.allSatisfy { loads($0, devices) })
        checks.require("glm offer, \(name): the memory verdict is fits", try verdict(devices) == .fits)
    }

    // An M4 Max whose macOS default keeps less (75 % of 128 GiB on earlier macOS; 101 GiB): Darkbloom cannot raise
    // its limit, so the M4 Max side is held to it.
    let m4At = { (gib: Int) in try mac("m4max", m5max, chip: "Apple M4 Max", defaultGPU: gib << 30) }
    // 101 GiB: no split fits as the Macs are, and one fits once the M5 Max's limit is raised (the M5 Max takes the
    // larger GPU part): the M5 Max alone needs `gpu-limit`, and that placement loads.
    let tight = try [m4At(101), mac("m5max", m5max)]
    checks.require("glm offer, M4 Max (101 GiB GPU) + M5 Max 128: nothing is offered as the Macs are", try offered(plan(tight), tight).isEmpty)
    if case .needsGPULimitRaise(let raises) = try verdict(tight) {
        let after = try plan([tight[0], mac("m5max", m5max, raised: true)])
        checks.require("glm offer, M4 Max (101 GiB GPU) + M5 Max 128: it needs gpu-limit on the M5 Max alone (got \(raises.map(\.device)))",
            raises.map(\.device) == ["m5max"])
        let m5Part = after.chosen?.ranks.first { $0.device == "m5max" }?.gpuResidentBytes ?? 0
        checks.require("glm offer, M4 Max (101 GiB GPU) + M5 Max 128: after gpu-limit on the M5 Max a pipeline loads, its M5 Max part above that Mac's default limit",
            loads(after.chosen, [tight[0], try mac("m5max", m5max, raised: true)]) && after.chosen?.mode == .pipeline
                && m5Part > m5max.gpuRecommendedWorkingSetBytes)
    } else {
        checks.require("glm offer, M4 Max (101 GiB GPU) + M5 Max 128: it needs gpu-limit on the M5 Max (got \(try verdict(tight)))", false)
    }
    // 96 GiB: even with the M5 Max raised no split fits, and the M4 Max's limit is one Darkbloom never raises.
    for (name, devices) in try [("M4 Max (96 GiB GPU) + M5 Max 128", [m4At(96), mac("m5max", m5max)]),
                                ("M4 Max (96 GiB GPU) + M5 Max 128 after gpu-limit", [m4At(96), mac("m5max", m5max, raised: true)]),
                                ("2 x M4 Max (101 GiB GPU)", [m4At(101), mac("m4-b", m5max, chip: "Apple M4 Max", defaultGPU: 101 << 30)])] {
        checks.require("glm offer, \(name): nothing is offered, and the verdict is does not fit, not a raise Darkbloom cannot make (got \(try verdict(devices)))",
            try offered(plan(devices), devices).isEmpty && verdict(devices) == .doesNotFit)
    }
    checks.require("glm offer: Darkbloom raises the GPU limit only on M5 Macs with 128 or 256 GB, read from the chip's own name",
        [("Apple M5 Max", 128), ("Apple M5 Ultra", 256), ("Apple M5", 128), ("Apple M5 Pro", 128)].allSatisfy {
            ClusterGPUMemoryLimit.raisedByDarkbloom(chipName: $0.0, physicalMemoryBytes: $0.1 << 30)
        } && ![("Apple M4 Max", 128), ("Apple M3 Ultra", 256), ("Apple M5 Max", 64), ("Apple M5 Ultra", 512),
               ("Apple M5 (Virtual)", 128), ("Apple M55 Max", 128), ("", 128)].contains {
            ClusterGPUMemoryLimit.raisedByDarkbloom(chipName: $0.0, physicalMemoryBytes: $0.1 << 30)
        })
}
