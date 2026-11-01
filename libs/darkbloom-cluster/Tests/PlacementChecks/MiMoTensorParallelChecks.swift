import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
import Foundation

/// MiMo V2.6 Flash's row lists `tensor_parallel_v1` (its resident runtime
/// serves it) while its placement family states no tensor-parallel facts, so
/// the layout built from the registered row's own metadata (configuration and
/// 1,732-tensor inventory) carries no tensor-parallel block, and no policy
/// places MiMo in tensor parallel: not tensor parallel first on a fast keyed
/// link nor on an unmeasured one, not the comparison, and the developer's
/// forced mode is refused. The facts arrive with the fastest-plan rule.
/// Registered metadata and constructed Macs only.
func checkMiMoTensorParallelUnplaced(_ checks: PlacementChecks) throws {
    let libraries = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let fixtures = libraries.appendingPathComponent("darkbloom-cluster-worker/Tests/CapabilityChecks/Fixtures")
    struct Tensor: Decodable { let name: String; let shape: [Int]; let sourceDType: String; let byteCount: Int }
    let configuration = try Data(contentsOf: fixtures.appendingPathComponent("registered-mimo-v26-flash-mopd.configuration.json"))
    let inventory = try JSONDecoder().decode([Tensor].self,
        from: Data(contentsOf: fixtures.appendingPathComponent("registered-mimo-v26-flash-mopd.tensor-inventory.json")))
    let layout = try ClusterPlacementLayouts.layout(configuration: configuration, tensors: inventory.map {
        ClusterPlacementStoredTensor(name: $0.name, byteCount: $0.byteCount, dtype: $0.sourceDType, shape: $0.shape)
    })
    checks.require("mimo tp: the registered row lists tensor_parallel_v1, and its layout states no tensor-parallel facts",
        layout.runtimeModelID == "registered_mimo_v26_flash_mopd" && layout.generationModes.contains(.tensorParallel)
            && layout.tensorParallel == nil)
    let speed = modelled(floorMs: 2, bandwidthGBs: 800, weightBytes: layout.wholeModelLoadedBytes, prefill: 300)
    let devices = try [SyntheticMac.idle(256).device("first", speed: speed), SyntheticMac.idle(256).device("second", speed: speed)]
    var compare = ClusterPlacementPolicy()
    compare.promptTokens = 1024; compare.outputTokens = 128
    var first = compare
    first.tensorParallelFirst = true; first.tensorParallelAssumesUnmeasuredLink = true
    let fast = linkCosts(reductionMicroseconds: 10)
    for (label, policy, link) in [("tensor parallel first on a fast keyed link", first, fast),
                                  ("tensor parallel first on an unmeasured link", first, ClusterLinkCosts.unmeasured),
                                  ("the comparison on a fast keyed link", compare, fast)] {
        let result = try ClusterPlacementPlanner.plan(devices: devices, layout: layout, policy: policy, link: link)
        checks.require("mimo tp: \(label): a pipeline mode, never tensor parallel (\(result.chosen?.mode.rawValue ?? "-"))",
            result.chosen.map { !$0.mode.usesTensorParallelDecode } == true && result.tensorParallel == nil)
    }
    var forced = compare
    forced.forcedMode = .tensorParallel
    checks.refuses("mimo tp: the developer's forced tensor parallel is refused without the facts",
                   because: "no tensor parallel mode") {
        _ = try ClusterPlacementPlanner.plan(devices: devices, layout: layout, policy: forced, link: fast)
    }
}
