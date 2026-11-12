import Foundation
let config = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let names = try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
try checkQwenLayerStageCandidates(configuration: config, canonicalSourceNames: names)
let candidates = try QwenLayerStageCandidates.enumerate(configuration: config, canonicalSourceNames: names)
let rows: [[String: Any]] = candidates.map { ["cut": $0.cut, "parameters": $0.ownership.map { $0.parameters.count }, "stateComponents": $0.ownership.map { $0.state.flatMap(\.components).count }, "computeCostStatus": $0.computeCostStatus.rawValue] }
let data = try JSONSerialization.data(withJSONObject: ["passed": true, "configurationSHA256": sha256(config), "canonicalNames": names.count, "candidates": rows], options: [.sortedKeys])
print(String(decoding: data, as: UTF8.self))
