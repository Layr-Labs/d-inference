import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
import Foundation

/// Actual registered configuration bytes, CPU budget arithmetic and the real
/// planner. No model payload, sampler, MLX, device index or network is used.
func checkRequestScopes(_ inputs: RetainedQwenInputs, golden: URL, _ checks: PlacementChecks) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("placement-request-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let libraries = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let fixtures = libraries.appendingPathComponent("darkbloom-cluster-worker/Tests/CapabilityChecks/Fixtures")
    let rows = ["qwen35-9b", "qwen38-27b", "qwen35-35b-a3b", "qwen36-35b-a3b",
                "ternary-bonsai-2-27b", "nemotron35-lightning", "gpt-oss-20b", "gemma4-26b", "gemma4-26b-qat-4bit", "gemma4-26b-8bit"]
    for row in rows {
        let configRow = row == "gemma4-26b-8bit" ? "gemma4-26b" : row
        let configuration = try Data(contentsOf: fixtures.appendingPathComponent("registered-\(configRow).configuration.json"))
        try configuration.write(to: root.appendingPathComponent("config.json"))
        try Data(contentsOf: fixtures.appendingPathComponent("registered-\(row).manifest.json"))
            .write(to: root.appendingPathComponent("manifest.json"))
        let short = try ClusterPlacementArtifact.requestedScope(directory: root, promptTokens: 1024, outputTokens: 2048)
        let long = try ClusterPlacementArtifact.requestedScope(directory: root, promptTokens: 16384, outputTokens: 128)
        let boundary = try ClusterPlacementArtifact.requestedScope(directory: root,
            promptTokens: short.maximumPromptTokens, outputTokens: short.maximumOutputTokens)
        checks.require("request scope \(row): completion-heavy, long prompt and full family boundary are admitted",
            short.promptTokens == 1024 && short.outputTokens == 2048 && long.promptTokens == 16384
                && boundary.maximumContextTokens == 65536)
        checks.require("request scope \(row): conservative whole-rank charge grows with context, or family uses only layer accounting",
            row == "gpt-oss-20b" ? short.requestChargeEveryRankBytes == 0 && long.requestChargeEveryRankBytes == 0
                : short.requestChargeEveryRankBytes > 0 && long.requestChargeEveryRankBytes > short.requestChargeEveryRankBytes)
        for (prompt, output) in [(0, 1), (1, 0), (-1, 1), (Int.max, 1), (1, Int.max),
                                 (short.maximumPromptTokens + 1, 1), (1, short.maximumOutputTokens + 1)] {
            checks.refuses("request scope \(row): invalid shape \(prompt)/\(output) refuses before budget arithmetic", because: "request limits") {
                _ = try ClusterPlacementArtifact.requestedScope(directory: root, promptTokens: prompt, outputTokens: output)
            }
        }
        let tool = try ClusterPlacementTool.run(["request-scope", "--model-dir", root.path, "--prompt-tokens", "1024", "--output-tokens", "2048"],
            sampleDevice: { throw ProbeError("A request quote must not sample a device") })
        checks.require("request scope \(row): helper returns exactly the family's metadata quote",
            try ClusterPlacementRequestScope.decode(Data(tool.utf8)) == short)
    }
    try inputs.twentySeven.configuration.write(to: root.appendingPathComponent("config.json"))
    try FileManager.default.removeItem(at: root.appendingPathComponent("manifest.json"))
    let layout = try ClusterPlacementLayouts.layout(configuration: inputs.twentySeven.configuration, tensors: inputs.twentySeven.stored)
    let devices = try [SyntheticMac.idle(128).device("a"), SyntheticMac.idle(256).device("b")]
    // A sparse file supplies authentic header geometry and logical payload
    // length only. No weight bytes are allocated, read, hashed or executed.
    var header: [String: Any] = [:], offset = 0
    for tensor in inputs.twentySeven.stored {
        header[tensor.name] = ["dtype": tensor.dtype, "shape": tensor.shape,
            "data_offsets": [offset, offset + tensor.byteCount]]
        offset += tensor.byteCount
    }
    let headerData = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
    var length = UInt64(headerData.count).littleEndian
    var prefix = Data(bytes: &length, count: 8); prefix.append(headerData)
    let shard = root.appendingPathComponent("model.safetensors")
    try prefix.write(to: shard)
    let handle = try FileHandle(forWritingTo: shard)
    try handle.truncate(atOffset: UInt64(prefix.count + offset)); try handle.close()
    let a = root.appendingPathComponent("a.json"), b = root.appendingPathComponent("b.json")
    try devices[0].profile.encoded().write(to: a); try devices[1].profile.encoded().write(to: b)
    for (prompt, output) in [(1024, 2048), (16384, 128)] {
        let scope = try ClusterPlacementArtifact.requestedScope(directory: root, promptTokens: prompt, outputTokens: output)
        let outputJSON = try ClusterPlacementTool.run(["plan", "--model-dir", root.path,
            "--peer", "a=" + a.path, "--peer", "b=" + b.path, "--prompt-tokens", String(prompt),
            "--output-tokens", String(output), "--json"], sampleDevice: { throw ProbeError("Unexpected device work") })
        let planObject = try JSONSerialization.jsonObject(with: Data(outputJSON.utf8)) as! [String: Any]
        let result = planObject["result"] as? [String: Any]
        checks.require("helper plan uses family scope when either reference axis is exceeded: \(prompt)/\(output)",
            result?["promptTokens"] as? Int == prompt && result?["outputTokens"] as? Int == output)
        var policy = ClusterPlacementPolicy(); policy.promptTokens = prompt; policy.outputTokens = output; policy.modes = [.pipeline]
        checks.refuses("request scope: an older unquoted layout cannot extend to \(prompt)/\(output)", because: "profile's limits") {
            _ = try ClusterPlacementPlanner.plan(devices: devices, layout: layout, policy: policy)
        }
        try scope.apply(to: &policy, layout: layout)
        let plan = try ClusterPlacementPlanner.plan(devices: devices, layout: layout, policy: policy)
        checks.require("request scope: \(prompt)/\(output) plans and charges every rank conservatively",
            plan.chosen?.ranks.allSatisfy { $0.requestNeedBytes >= scope.requestChargeEveryRankBytes } == true)
        policy.outputTokens = output + 1
        checks.refuses("request scope: changing the quoted request is refused", because: "another model or request") {
            try scope.apply(to: &policy, layout: layout)
        }
        policy.outputTokens = output
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(scope)) as! [String: Any]
        object["artifactSHA256"] = String(repeating: "f", count: 64)
        let other = try ClusterPlacementRequestScope.decode(JSONSerialization.data(withJSONObject: object))
        checks.refuses("request scope: changing the artifact is refused", because: "another model or request") {
            try other.apply(to: &policy, layout: layout)
        }
        object["artifactSHA256"] = scope.artifactSHA256; object["requestChargeEveryRankBytes"] = 1 << 40
        let large = try ClusterPlacementRequestScope.decode(JSONSerialization.data(withJSONObject: object))
        try large.apply(to: &policy, layout: layout)
        let cannotFit = try ClusterPlacementPlanner.plan(devices: devices, layout: layout, policy: policy)
        checks.require("request scope: a conservative charge cannot bypass physical memory refusal", cannotFit.chosen == nil)
    }
    var policy = ClusterPlacementPolicy(); policy.promptTokens = Int.max; policy.outputTokens = 1
    policy.largestContextTokens = 65536; policy.requestChargeEveryRankBytes = 0
    checks.refuses("legacy context override: Int.max refuses without overflow", because: "largest context") {
        _ = try ClusterPlacementPlanner.plan(devices: devices, layout: layout, policy: policy)
    }
    let glm = try ClusterModelLayout.decode(Data(contentsOf: golden.appendingPathComponent("layouts/GLM-5.3-Flash-MLX-NVFP4-mtp.json")))
    policy.promptTokens = glm.maximumPromptTokens + 1; policy.outputTokens = 1
    checks.refuses("GLM exact quotes retain adapter scope despite a generic context override", because: "adapter scope") {
        _ = try ClusterPlacementPlanner.rankQuoted(devices: devices, layout: glm, shapes: [], policy: policy)
    }
}
