import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
import Foundation

/// GLM-5.3 Flash as a pipeline on two equal M5 Ultra 256 GB (the recorded M5
/// Ultra, `Golden/pairs/m3ultra-m5ultra/profile-mac-b.json`, its memory sampled
/// idle): the pipeline the mode question offers, and the start loads, splits the
/// layers about evenly, never one layer on one Mac and 44 on the other.
/// Recorded inputs and constructed samples only: no model, no GPU.
func checkGLMUltraPipeline(golden: URL, _ checks: PlacementChecks) throws {
    let layout = try ClusterModelLayout.decode(Data(contentsOf: golden.appendingPathComponent("layouts/GLM-5.3-Flash-MLX-NVFP4-mtp.json")))
    let p = try ClusterDeviceProfile.decode(Data(contentsOf: golden.appendingPathComponent("pairs/m3ultra-m5ultra/profile-mac-b.json")))
    func mac(_ label: String) throws -> ClusterPlacementDevice {
        let sample = SyntheticMac.idle(Double(p.physicalMemoryBytes >> 30))
        let profile = try ClusterDeviceProfile(chip: p.chip, performanceCores: p.performanceCores, efficiencyCores: p.efficiencyCores,
            gpuCores: p.gpuCores, osVersion: p.osVersion, osBuild: p.osBuild, physicalMemoryBytes: p.physicalMemoryBytes,
            gpuRecommendedWorkingSetBytes: p.gpuRecommendedWorkingSetBytes, gpuMaximumBufferBytes: p.gpuMaximumBufferBytes,
            allocatorLimitBytes: p.allocatorLimitBytes, memory: .gate(sample.observation, now: SyntheticMac.now), power: p.power,
            wiredLimitBytes: p.wiredLimitBytes)
        return .init(label: label, profile: profile, speed: .assumedEqual)
    }
    let pair = try ["ultra-a", "ultra-b"].map { try mac($0) }
    var policy = ClusterPlacementPolicy(); policy.tensorParallelFirst = true; policy.tensorParallelAssumesUnmeasuredLink = true
    policy.forcedMode = .pipeline
    let result = try ClusterPlacementPlanner.plan(devices: pair, layout: layout, policy: policy)
    let chosen = result.chosen
    let layers = chosen?.ranks.map { $0.endLayer - $0.firstLayer } ?? []
    FileHandle.standardError.write(Data(("glm ultra pipeline: " + (chosen.map { c in
        "\(c.mode.rawValue) cut \(c.cut) " + c.ranks.map {
            "[\($0.device) layers \($0.endLayer - $0.firstLayer) need \($0.needBytes) fit \($0.fit) gpu \($0.withinGPUWorkingSet) serving \($0.servingContextTokens ?? -1)]"
        }.joined(separator: " ")
    } ?? "none") + "\n").utf8))
    checks.require("glm ultra, 2x M5 Ultra 256 GB, pipeline: the split is about even, never 1 / 44 (\(layers))",
        chosen?.mode.usesTensorParallelDecode == false && layers.count == 2 && layers.allSatisfy { $0 >= 18 })
}
