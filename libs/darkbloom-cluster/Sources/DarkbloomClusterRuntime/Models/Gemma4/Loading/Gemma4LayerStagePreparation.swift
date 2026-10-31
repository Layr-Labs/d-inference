import Foundation
import MLX
import MLXLMCommon
import MLXNN

/// Constructs one stage lazily, gives every projection the quantization its
/// original module has, and records what the loader will read into it. No
/// tensor payload is read here, and a Gemma stage has no inactive module.
func prepareGemma4LayerStageModel(source: Gemma4ResidentSource, stage: QwenLayerStagePlan.Stage,
    check: () throws -> Void
) throws -> (model: Gemma4LayerStageModel, inventory: QwenStagePreparedInventory) {
    let model = try Gemma4LayerStageModel(configuration: source.textConfiguration, rank: stage.index,
        sourceLayerRange: stage.sourceRange, fuseWeightedUnsort: source.fuseWeightedUnsort)
    let prepared = source.source
    let sourceTensors = Dictionary(uniqueKeysWithValues: prepared.tensors.map { ($0.sourceName, $0) })
    let mappings = prepared.mappings.filter { $0.stage == stage.index }
    let localToSource = Dictionary(uniqueKeysWithValues: mappings.map { ($0.localName, $0.sourceName) })
    var policies: [String: BaseConfiguration.Quantization] = [:]
    for (path, _) in model.leafModules().flattened() {
        guard let sourceName = localToSource[path + ".scales"] else { continue }
        // The module of the whole model this local module is.
        let sourcePath = sourceName.split(separator: ".").dropLast().joined(separator: ".")
        guard let original = prepared.quantization[sourcePath] else {
            throw ProbeError("Gemma stage module has no original quantization: \(path)")
        }
        policies[path] = original
    }
    quantize(model: model) { path, _ in policies[path]?.asTuple }
    try check()
    let actual = Dictionary(uniqueKeysWithValues: model.parameters().flattened())
    guard Set(actual.keys) == Set(localToSource.keys) else {
        let missing = Set(actual.keys).subtracting(localToSource.keys).sorted()
        let extra = Set(localToSource.keys).subtracting(actual.keys).sorted()
        throw ProbeError("Gemma stage parameters do not cover its constructor; missing=\(missing.prefix(8)), extra=\(extra.prefix(8))")
    }
    var active: [QwenStageActiveTensor] = []
    for mapping in mappings.sorted(by: { $0.localName < $1.localName }) {
        guard let tensor = sourceTensors[mapping.sourceName], let parameter = actual[mapping.localName],
              parameter.shape == tensor.shape,
              (parameter.dtype == .uint32) == (tensor.sourceDType == String(describing: DType.uint32)),
              stage.activeModuleRoots.contains(where: { mapping.localName.hasPrefix($0 + ".") }) else {
            throw ProbeError("Gemma stage full-width parameter geometry/class differs: \(mapping.localName)")
        }
        active.append(.init(sourceName: mapping.sourceName, localName: mapping.localName, shape: tensor.shape,
            sourceDType: tensor.sourceDType, loadedDType: tensor.loadedDType, byteCount: tensor.byteCount))
    }
    let layout = active.map { "\($0.localName):\($0.loadedDType):\($0.shape)" }
    let summary = QwenStageStorageSummary(stageIndex: stage.index,
        constructionConfigurationSHA256: sha256(stage.constructionConfiguration),
        stagePlanSHA256: stage.fingerprint, activeMappingSHA256: sha256(try canonicalJSONData(active)),
        activeParameterLayoutSHA256: qwenStageLayout(layout), parameterLayoutSHA256: qwenStageLayout(layout),
        loadedTensorBytes: try QwenLongPrefillCheckedBytes.sum(active.map(\.byteCount)),
        activeTensorCount: active.count, inertTensorBytes: 0, inertTensorCount: 0)
    return (model, .init(active: active, inert: [], summary: summary))
}

/// Validates the stage this rank does not load, then releases all its lazy
/// defaults before the stage that will receive payload bytes is constructed.
func inspectOtherGemma4LayerStage(source: Gemma4ResidentSource, stage: QwenLayerStagePlan.Stage,
    check: () throws -> Void
) throws -> QwenStagePreparedInventory {
    weak var retired: Module?
    let inventory = try autoreleasepool {
        let prepared = try prepareGemma4LayerStageModel(source: source, stage: stage, check: check)
        retired = prepared.model
        return prepared.inventory
    }
    guard retired == nil else { throw ProbeError("Unowned Gemma stage metadata model remained retained") }
    return inventory
}

/// The commitment both ranks derive. Every text tensor has one owner except
/// the tied embedding's three, which both ranks hold: its bytes are counted
/// once as source and once more as the replica.
func gemma4LayerStageStorageCommitment(source: PreparedQwenLayerSource, originalConfiguration: Data,
    plan: QwenLayerStagePlan, inventories: [QwenStagePreparedInventory]
) throws -> QwenLayerStageStorageCommitment {
    let coverage = inventories.flatMap(\.active)
    let embedding = Gemma4LayerStagePlanning.embeddingModule + "."
    let replicas = source.tensors.filter { $0.sourceName.hasPrefix(embedding) }
    var owners: [String: Int] = [:]
    for entry in coverage { owners[entry.sourceName, default: 0] += 1 }
    guard inventories.map(\.summary.stageIndex) == [0, 1], replicas.count == 3,
          Set(owners.keys) == Set(source.tensors.map(\.sourceName)),
          owners.allSatisfy({ $0.value == ($0.key.hasPrefix(embedding) ? 2 : 1) }),
          try QwenLongPrefillCheckedBytes.sum(coverage.map(\.byteCount))
            == QwenLongPrefillCheckedBytes.sum([source.sourceBytes] + replicas.map(\.byteCount)) else {
        throw ProbeError("Gemma stage inventories do not conserve source storage and the tied embedding replica")
    }
    return .init(schemaVersion: 1, verifiedAggregateSHA256: source.verifiedAggregateSHA256,
        sourceConfigurationSHA256: sha256(originalConfiguration), planSHA256: plan.fingerprint,
        sourceTensorManifestSHA256: source.sourceTensorManifestSHA256,
        sourceModelTensorBytes: source.sourceBytes, largestSourceTensorBytes: source.largestSourceBytes,
        sourceTensorCount: source.sourceTensorCount, canonicalTensorCount: source.tensors.count,
        bf16ConversionEnabled: source.bf16ConversionEnabled, stages: inventories.map(\.summary))
}
