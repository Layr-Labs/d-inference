import Foundation
func require(_ ok: Bool, _ reason: String) throws { if !ok { throw ProbeError(reason) } }
func run(_ label: String, configPath: String, namesPath: String, layers: Int, tensorCount: Int) throws {
    let config = try Data(contentsOf: URL(fileURLWithPath: configPath))
    let names = try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: namesPath)))
    if label == "9B" { try checkQwenLayerStageCandidates(configuration: config, canonicalSourceNames: names) }
    let gates = try checkQwenStageOutputGateMetadata(configuration: config, ranges: [0..<(layers/2), (layers/2)..<layers])
    let candidates = try QwenLayerStageCandidates.enumerate(configuration: config, canonicalSourceNames: names)
    try require(names.count == tensorCount && candidates.map(\.cut) == Array(stride(from: 4, to: layers, by: 4)), "Retained artifact metadata coverage differs")
    for candidate in candidates {
        let parameters = candidate.ownership.flatMap(\.parameters)
        try require(candidate.plan.originalConfiguration == config && parameters.count == tensorCount
            && Set(parameters.map(\.sourceName)) == Set(names)
            && Set(parameters.map { "\($0.stage):\($0.localName)" }).count == tensorCount
            && candidate.ownership.flatMap(\.state).flatMap(\.components).count == layers / 4 * 9
            && candidate.computeCostStatus == .unknown, "Candidate did not conserve original metadata ownership")
        if label == "27B" {
            for stage in candidate.plan.stages {
                let root = try JSONSerialization.jsonObject(with: stage.constructionConfiguration) as! [String: Any]
                try require((root["text_config"] as! [String: Any])["output_gate_type"] as? String == "swish", "Registered spelling was removed or normalized")
            }
        }
    }
    let rows: [[String: Any]] = candidates.map { ["cut": $0.cut, "parameters": $0.ownership.map { $0.parameters.count }, "stateComponents": $0.ownership.map { $0.state.flatMap(\.components).count }, "computeCostStatus": $0.computeCostStatus.rawValue] }
    let data = try JSONSerialization.data(withJSONObject: ["model": label, "passed": true, "configurationSHA256": sha256(config), "canonicalNames": names.count, "candidates": rows, "gateAcceptedCases": gates.acceptedCases, "gateRejectedCases": gates.rejectedCases, "modelExecutionQualified": false], options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}
try run("9B", configPath: CommandLine.arguments[1], namesPath: CommandLine.arguments[3], layers: 32, tensorCount: 927)
try run("27B", configPath: CommandLine.arguments[2], namesPath: CommandLine.arguments[4], layers: 64, tensorCount: 1847)
