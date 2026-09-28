import Foundation

struct QwenObservedStageFixture {
    var active: [QwenStageActiveTensor]
    var inert: [QwenStageInertModule]
    var summary: QwenStageStorageSummary
}

/// Invented constructor records derived from retained CPU metadata. Reusing the
/// existing Codable types does not turn these fixtures into actual load proof.
func fixtureStage(_ profile: QwenRegisteredDenseModelProfile, plan: QwenLayerStagePlan,
                  stageIndex: Int) throws -> QwenObservedStageFixture {
    let tensors = Dictionary(uniqueKeysWithValues: profile.canonicalTensors.map { ($0.name, $0) })
    let dtype = ["U32": "uint32", "F32": "float32", "BF16": "bfloat16", "F16": "float16"]
    let stage = plan.stages[stageIndex]
    let active = try plan.parameters(canonicalSourceNames: profile.canonicalTensors.map(\.name))
        .filter { $0.stage == stageIndex }.sorted { $0.localName < $1.localName }.map { mapping in
            let tensor = tensors[mapping.sourceName]!
            return QwenStageActiveTensor(sourceName: mapping.sourceName, localName: mapping.localName,
                shape: tensor.shape, sourceDType: dtype[tensor.sourceDType]!,
                loadedDType: tensor.sourceDType == "F16" ? "bfloat16" : dtype[tensor.sourceDType]!, byteCount: tensor.byteCount)
        }
    let inert = stage.inertModules.sorted { $0.path < $1.path }.map { item in
        let norm = item.path.hasSuffix(".model.norm") || item.path == "model.norm"
        return QwenStageInertModule(path: item.path,
            replacementKind: norm ? "parameter-only-replacement" : "module-replacement",
            responsibility: item.responsibility, parameters: [.init(localName: item.path + ".weight",
                shape: norm ? [profile.geometry.hiddenSize] : [1, profile.geometry.hiddenSize], dtype: "bfloat16",
                byteCount: profile.geometry.hiddenSize * 2)])
    }
    return try .init(active: active, inert: inert, summary: fixtureStageSummary(active: active, inert: inert, stage: stage))
}
func fixtureStageSummary(active: [QwenStageActiveTensor], inert: [QwenStageInertModule],
                         stage: QwenLayerStagePlan.Stage) throws -> QwenStageStorageSummary {
    let activeLayout = active.map { "\($0.localName):\($0.loadedDType):\($0.shape)" }
    let inertParameters = inert.flatMap(\.parameters)
    let inertLayout = inertParameters.map { "\($0.localName):\($0.dtype):\($0.shape)" }
    func layout(_ entries: [String]) -> String { sha256(Data(entries.sorted().joined(separator: "\n").utf8)) }
    return QwenStageStorageSummary(stageIndex: stage.index,
        constructionConfigurationSHA256: sha256(stage.constructionConfiguration), stagePlanSHA256: stage.fingerprint,
        activeMappingSHA256: sha256(try canonicalJSONData(active)), activeParameterLayoutSHA256: layout(activeLayout),
        parameterLayoutSHA256: layout(activeLayout + inertLayout), loadedTensorBytes: active.reduce(0) { $0 + $1.byteCount },
        activeTensorCount: active.count, inertTensorBytes: inertParameters.reduce(0) { $0 + $1.byteCount }, inertTensorCount: inertParameters.count)
}
