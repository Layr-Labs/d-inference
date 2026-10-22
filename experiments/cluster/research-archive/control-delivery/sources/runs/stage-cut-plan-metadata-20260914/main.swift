import Foundation
let config = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let names = try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
let candidates = try QwenLayerStageCandidates.enumerate(configuration: config, canonicalSourceNames: names).filter { [12, 16].contains($0.cut) }
guard candidates.map(\.cut) == [12, 16], names.count == 927 else { throw ProbeError("Unexpected metadata input") }
let plans: [[String: Any]] = try candidates.map { candidate in
    let stages: [[String: Any]] = try candidate.ownership.map { owner in
        let stage = candidate.plan.stages[owner.stageIndex]
        return ["stage": stage.index, "sourceLayerStart": stage.sourceRange.lowerBound, "sourceLayerEnd": stage.sourceRange.upperBound,
            "stageSHA256": stage.fingerprint, "constructionConfigurationSHA256": sha256(stage.constructionConfiguration),
            "constructionConfigurationBase64": stage.constructionConfiguration.base64EncodedString(),
            "activeModuleRoots": stage.activeModuleRoots,
            "inertModules": try JSONSerialization.jsonObject(with: JSONEncoder().encode(stage.inertModules)),
            "parameters": try JSONSerialization.jsonObject(with: JSONEncoder().encode(owner.parameters)),
            "state": owner.state.map { ["globalLayer": $0.layer.globalIndex, "localLayer": $0.layer.localIndex, "kind": $0.layer.kind, "components": $0.components.map(\.rawValue)] as [String: Any] }]
    }
    return ["cut": candidate.cut, "planSHA256": candidate.plan.fingerprint, "stages": stages]
}
let data = try JSONSerialization.data(withJSONObject: ["kind": "qwen_stage_cut_expected_plan_metadata", "sourceConfigurationSHA256": sha256(config), "cpuMetadataOnly": true, "nativeModelExecution": false, "plans": plans], options: [.sortedKeys, .prettyPrinted])
FileHandle.standardOutput.write(data); print("")
