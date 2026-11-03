import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
import Foundation

/// Gemma 4 26B routes each token to 8 of a layer's 128 experts. The QAT
/// 4-bit layout built here from the artifact's retained real tensor headers
/// (`StageMetadataChecks/Inputs`) must equal its golden layout, routed experts
/// included, and the hardware prior must read 8/128 of those banks per token:
/// 2,424,219,708 bytes, the figure the exact-header audit of 2026-09-20
/// recorded, instead of every layer byte.
func checkGemmaRoutedExperts(golden: URL, _ checks: PlacementChecks) throws {
    let inputs = golden.deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("StageMetadataChecks/Inputs", isDirectory: true)
    var tensors: [ClusterPlacementStoredTensor] = []
    let headers = try FileManager.default.contentsOfDirectory(atPath: inputs.path)
        .filter { $0.hasSuffix(".safetensors.header.json") }.sorted()
    for file in headers {
        let header = try JSONSerialization.jsonObject(with: Data(contentsOf: inputs.appendingPathComponent(file)))
            as? [String: Any] ?? [:]
        for (name, value) in header where name != "__metadata__" {
            guard let entry = value as? [String: Any], let dtype = entry["dtype"] as? String,
                  let shape = entry["shape"] as? [Int], let offsets = entry["data_offsets"] as? [Int],
                  offsets.count == 2, offsets[1] > offsets[0] else {
                throw ProbeError("Malformed retained Gemma header entry: \(name)")
            }
            tensors.append(.init(name: name, byteCount: offsets[1] - offsets[0], dtype: dtype, shape: shape))
        }
    }
    let layout = try ClusterPlacementLayouts.layout(
        configuration: Data(contentsOf: inputs.appendingPathComponent("config.json")), tensors: tensors,
        manifest: Data(contentsOf: inputs.appendingPathComponent("manifest.json")))
    let expected = try ClusterModelLayout.decode(
        Data(contentsOf: golden.appendingPathComponent("layouts/gemma-4-26b-qat-4bit.json")))
    checks.require("Gemma QAT 4-bit: the layout from the retained real headers equals its golden layout, routed experts included",
        headers.count == 3 && layout == expected)
    let experts = layout.routedExperts
    checks.require("Gemma QAT 4-bit routes 8 of 128 experts; its expert banks hold 12,846,366,720 bytes, no tensor-parallel share",
        experts?.routing == ClusterExpertRouting(selected: 8, experts: 128) && experts?.loadedBytes == 12_846_366_720
            && experts?.tensorParallelDividedBytes == nil)
    checks.require("Gemma QAT 4-bit decode reads 2,424,219,708 weight bytes per token (8/128 of the expert banks)",
        ClusterHardwarePrior.decodeBytesPerToken(layout) == 2_424_219_708)
    // The 8-bit artifact's golden layout carries the same routing over its 8-bit banks.
    for name in ["gemma-4-26b-8bit", "gemma-4-26b"] {
        let eight = try ClusterModelLayout.decode(Data(contentsOf: golden.appendingPathComponent("layouts/\(name).json")))
        checks.require("\(name): 8 of 128 routed experts over 24,265,359,360 bytes of 8-bit banks",
            eight.routedExperts?.routing == ClusterExpertRouting(selected: 8, experts: 128)
                && eight.routedExperts?.loadedBytes == 24_265_359_360)
    }
}
