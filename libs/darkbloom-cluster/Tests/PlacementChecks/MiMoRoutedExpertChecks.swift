import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
import Foundation

/// MiMo V2.6 Flash routes each token to 8 of the 256 experts of each of its
/// 47 routed layers. The layout its family builds from the registered tensor
/// headers names those experts, so the hardware prior counts what one decode
/// step reads (10,767,036,288 bytes) rather than every expert's bytes
/// (166,600,109,952). The golden layout carries the same routed experts beside
/// the bytes the real headers recorded. The prior prices tensor parallel only,
/// so a MiMo plan without tensor-parallel facts is unchanged by the routing:
/// the printed plan differs only by the layout it echoes, and without the
/// routed experts it is byte for byte the plan both Macs printed.
func checkMiMoRoutedExperts(golden: URL, _ checks: PlacementChecks) throws {
    struct Header: Decodable { let name: String; let shape: [Int]; let sourceDType: String; let byteCount: Int }
    let libraries = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let fixtures = libraries.appendingPathComponent("darkbloom-cluster-worker/Tests/CapabilityChecks/Fixtures")
    let configuration = try Data(contentsOf: fixtures.appendingPathComponent("registered-mimo-v26-flash-mopd.configuration.json"))
    let headers = try JSONDecoder().decode([Header].self, from: Data(contentsOf:
        fixtures.appendingPathComponent("registered-mimo-v26-flash-mopd.tensor-inventory.json")))
    let family = try MiMoPlacementFamily(configuration: configuration)
    let built = try ClusterModelLayoutBuilder.build(family: family,
        tensors: headers.map { .init(name: $0.name, byteCount: $0.byteCount, dtype: $0.sourceDType, shape: $0.shape) },
        artifactSHA256: family.specification.artifactSHA256, configurationSHA256: family.specification.configurationSHA256)
    let routed = built.routedExperts
    let banks = headers.filter { family.isRoutedExpert(storedTensor: $0.name) }
    checks.require("MiMo routed experts: 8 of 256 in 47 layers, each layer's three packed banks and their scales, all divided by tensor parallel",
        routed?.routing == ClusterExpertRouting(selected: 8, experts: 256) && routed?.tensorParallelDividedBytes == 160_859_947_008
            && banks.count == 47 * 6 && routed?.loadedBytes == 160_859_947_008
            && Set(banks.compactMap { family.layer(ofStoredTensor: $0.name) }) == Set(1..<48)
            && !banks.contains { $0.name.contains(".mlp.gate.") })
    let whole = built.layers.reduce(0) { $0 + $1.weights.loadedBytes } + built.egress.loadedBytes
    checks.require("MiMo prior: a decode step reads 10,767,036,288 bytes, not every expert's (166,600,109,952)",
        ClusterHardwarePrior.decodeBytesPerToken(built) == 10_767_036_288 && whole == 166_600_109_952)

    let file = golden.appendingPathComponent("layouts/mimo-v2.6-flash-mopd-2026-09-28-r1.json")
    let recorded = try ClusterModelLayout.decode(Data(contentsOf: file))
    checks.require("MiMo golden layout: the family's routed experts beside the bytes the real headers recorded",
        recorded.routedExperts == routed && recorded.layers.map(\.weights) == built.layers.map(\.weights)
            && recorded.ingress == built.ingress && recorded.egress == built.egress && recorded.excluded == built.excluded)

    // The golden layout without its tensor-parallel data: the prior prices only tensor parallel, so the routing must
    // leave these pipeline plans as they were recorded before the layout named its routed experts.
    var object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] ?? [:]
    object["tensorParallel"] = nil
    var experts = object["routedExperts"] as? [String: Any] ?? [:]
    experts["tensorParallelDividedBytes"] = nil
    object["routedExperts"] = experts
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("mimo-routing-\(getpid())", isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    let pipeline = scratch.appendingPathComponent("mimo-routed.json")
    try ClusterModelLayout.decode(JSONSerialization.data(withJSONObject: object)).encoded().write(to: pipeline)
    object["routedExperts"] = nil
    let unrouted = scratch.appendingPathComponent("mimo.json")
    try ClusterModelLayout.decode(JSONSerialization.data(withJSONObject: object)).encoded().write(to: unrouted)
    // The golden plans of this layout as both Macs printed them, before it named its routed experts.
    let recordedPlans = [
        "Golden": ["b8e47f8ec25b077706df9be8516a679cf4503960491729e6915e47c6b70e3d1a",
                   "b5ad60578a8438482ea406eac34caf0a4083237335d0a94c6214bfe33d7d0454"],
        "m3ultra-m5ultra": ["e22581c407f9ff352298b646a20f439690e13aa77d98537f1bdbf635009194a7",
                            "e9b228091f6e6ba2204bf938a0ca8b5bf392b1162fc485f1ede5bb3cb708b2ff"],
    ]
    for pair in [golden, golden.appendingPathComponent("pairs/m3ultra-m5ultra", isDirectory: true)] {
        let peers = ["mac-a", "mac-b"].flatMap { ["--peer", "\($0)=" + pair.appendingPathComponent("profile-\($0).json").path] }
        for (index, extra) in [[], ["--hand-off-modes"]].enumerated() {
            func plan(_ layout: URL) throws -> String {
                try ClusterPlacementTool.run(["plan", "--layout", layout.path] + peers + ["--leader", "mac-a", "--json"] + extra,
                    sampleDevice: { throw ProbeError("recorded profiles only") })
            }
            let routedPlan = try plan(pipeline), unroutedPlan = try plan(unrouted)
            var echoed = try JSONSerialization.jsonObject(with: Data(routedPlan.utf8)) as? [String: Any] ?? [:]
            var layout = echoed["layout"] as? [String: Any] ?? [:]
            let echoedRouting = layout.removeValue(forKey: "routedExperts") != nil
            echoed["layout"] = layout
            let plain = try JSONSerialization.jsonObject(with: Data(unroutedPlan.utf8)) as? [String: Any] ?? [:]
            checks.require("MiMo on \(pair.lastPathComponent)\(extra.isEmpty ? "" : " (hand-off opt-in)"): the routed experts change only the echoed layout, and without them the plan is the recorded golden (printed \(sha256(Data((unroutedPlan + "\n").utf8))))",
                echoedRouting && NSDictionary(dictionary: echoed).isEqual(to: plain)
                    && sha256(Data((unroutedPlan + "\n").utf8)) == recordedPlans[pair.lastPathComponent]?[index])
        }
    }
}
