import Foundation
import MLX
import MLXLMCommon
import MLXNN

struct QwenStagePreparedInventory {
    let active: [QwenStageActiveTensor]
    let inert: [QwenStageInertModule]
    let summary: QwenStageStorageSummary
}

/// Construct/quantize lazily after replacing inactive parameters. Both stages'
/// inventories are inspected before the loader reads any tensor payload.
func prepareQwenLayerStageModel(source: PreparedQwenLayerSource,
    stage: QwenLayerStagePlan.Stage, check: () throws -> Void
) throws -> (model: any LanguageModel, inventory: QwenStagePreparedInventory) {
    let model = try constructQwenModel(stage.constructionConfiguration)
    try validateQwenStageDenseModel(model, layerCount: stage.layers.count)
    let inert = try installQwenStageInertParameters(model: model, stage: stage,
        hiddenSize: source.hiddenSize, activationDType: source.activationDType)
    let sourceTensors = Dictionary(uniqueKeysWithValues: source.tensors.map { ($0.sourceName, $0) })
    let mappings = source.mappings.filter { $0.stage == stage.index }
    let localToGlobal = Dictionary(uniqueKeysWithValues: mappings.map { ($0.localName, $0.sourceName) })
    let base = try JSONDecoder().decode(BaseConfiguration.self, from: stage.constructionConfiguration)
    let policy = base.perLayerQuantization ?? .init(perLayerQuantization: [:])
    let inactive = Set(inert.map(\.path))
    var policies: [String: BaseConfiguration.Quantization] = [:]
    for (path, _) in model.leafModules().flattened() {
        if inactive.contains(path) {
            guard resolveQuantization(path: path, perLayerQuantization: policy,
                aliasing: model as? QuantizationPathAliasing) == nil else {
                throw ProbeError("Inactive layer-stage module inherits a quantization policy: \(path)")
            }
            continue
        }
        guard let sourceName = localToGlobal[path + ".scales"] else { continue }
        let sourcePath = sourceName.split(separator: ".").dropLast().joined(separator: ".")
        guard let original = source.quantization[sourcePath],
              let local = resolveQuantization(path: path, perLayerQuantization: policy,
                  aliasing: model as? QuantizationPathAliasing),
              local.mode == original.mode, local.bits == original.bits,
              local.groupSize == original.groupSize else {
            throw ProbeError("Layer-stage local quantization differs from its original projection: \(path)")
        }
        policies[path] = local
    }
    quantize(model: model) { path, _ in policies[path]?.asTuple }
    try check()
    let actual = Dictionary(uniqueKeysWithValues: model.parameters().flattened())
    let inertParameters = inert.flatMap(\.parameters)
    let inertNames = Set(inertParameters.map(\.localName))
    guard Set(localToGlobal.keys).isDisjoint(with: inertNames),
          Set(actual.keys) == Set(localToGlobal.keys).union(inertNames) else {
        throw ProbeError("Layer-stage active/inactive parameters do not cover the compact constructor")
    }
    var active: [QwenStageActiveTensor] = []
    for mapping in mappings.sorted(by: { $0.localName < $1.localName }) {
        guard let tensor = sourceTensors[mapping.sourceName], let parameter = actual[mapping.localName],
              parameter.shape == tensor.shape,
              (parameter.dtype == .uint32) == (tensor.sourceDType == String(describing: DType.uint32)),
              stage.activeModuleRoots.contains(where: {
                  mapping.localName.hasPrefix($0 + ".")
              }) else {
            throw ProbeError("Layer-stage full-width parameter geometry/class differs: \(mapping.localName)")
        }
        active.append(QwenStageActiveTensor(sourceName: mapping.sourceName, localName: mapping.localName,
            shape: tensor.shape, sourceDType: tensor.sourceDType, loadedDType: tensor.loadedDType,
            byteCount: tensor.byteCount))
    }
    for parameter in inertParameters {
        guard let value = actual[parameter.localName], value.shape == parameter.shape,
              String(describing: value.dtype) == parameter.dtype, value.nbytes == parameter.byteCount else {
            throw ProbeError("Quantization altered an inactive stage parameter")
        }
    }
    let activeLayout = active.map { "\($0.localName):\($0.loadedDType):\($0.shape)" }
    let inertLayout = inertParameters.map { "\($0.localName):\($0.dtype):\($0.shape)" }
    let summary = QwenStageStorageSummary(stageIndex: stage.index,
        constructionConfigurationSHA256: sha256(stage.constructionConfiguration),
        stagePlanSHA256: stage.fingerprint, activeMappingSHA256: sha256(try canonicalJSONData(active)),
        activeParameterLayoutSHA256: qwenStageLayout(activeLayout),
        parameterLayoutSHA256: qwenStageLayout(activeLayout + inertLayout),
        loadedTensorBytes: active.reduce(0) { $0 + $1.byteCount }, activeTensorCount: active.count,
        inertTensorBytes: inertParameters.reduce(0) { $0 + $1.byteCount },
        inertTensorCount: inertParameters.count)
    return (model, QwenStagePreparedInventory(active: active, inert: inert, summary: summary))
}

/// Validate the non-owning stage too, then release all its lazy defaults before
/// constructing the stage that will receive payload bytes.
func inspectOtherQwenLayerStage(source: PreparedQwenLayerSource,
    stage: QwenLayerStagePlan.Stage, check: () throws -> Void
) throws -> QwenStagePreparedInventory {
    weak var retiredModel: Module?
    let inventory = try autoreleasepool {
        let prepared = try prepareQwenLayerStageModel(source: source, stage: stage, check: check)
        retiredModel = prepared.model
        return prepared.inventory
    }
    guard retiredModel == nil else { throw ProbeError("Unowned compact metadata model remained retained") }
    return inventory
}
