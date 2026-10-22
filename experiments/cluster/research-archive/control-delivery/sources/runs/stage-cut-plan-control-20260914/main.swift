import Foundation
let config = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let plan = try QwenLayerStagePlan(configuration: config, ranges: [0..<12, 12..<32])
func json<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) }
let stages: [[String: Any]] = try plan.stages.map { stage in
    ["index": stage.index, "sourceLayerStart": stage.sourceRange.lowerBound, "sourceLayerEnd": stage.sourceRange.upperBound,
     "layers": try json(stage.layers), "fingerprint": stage.fingerprint,
     "constructionConfigurationSHA256": sha256(stage.constructionConfiguration),
     "constructionConfigurationUTF8": String(decoding: stage.constructionConfiguration, as: UTF8.self),
     "activeModuleRoots": stage.activeModuleRoots, "inertModules": try json(stage.inertModules),
     "quantizationMappings": try json(stage.quantizationMappings), "excludedQuantizationPaths": stage.excludedQuantizationPaths]
}
let data = try JSONSerialization.data(withJSONObject: ["kind": "qwen_stage_cut_plan_control", "cpuMetadataOnly": true, "nativeModelExecution": false,
    "sourceConfigurationSHA256": sha256(config), "planSHA256": plan.fingerprint, "layers": plan.layers, "interval": plan.interval, "stages": stages], options: [.sortedKeys, .prettyPrinted])
FileHandle.standardOutput.write(data); print("")
