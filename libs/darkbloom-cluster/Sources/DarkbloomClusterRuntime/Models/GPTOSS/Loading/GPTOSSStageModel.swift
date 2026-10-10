import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN

/// Stage 0 ends before the final norm. The product class applies `model.norm`
/// at the end of its trunk, so the stage replaces that module with one that
/// returns its input: the trunk's own forward then yields the residual.
final class GPTOSSStageIdentityNorm: RMSNorm {
    init() { super.init(dimensions: 1) }
    override func callAsFunction(_ x: MLXArray) -> MLXArray { x }
}

/// Stage 0 produces no logits; its head holds no weights and must never run.
final class GPTOSSStageDiscardedHead: Linear {
    init(hiddenSize: Int, dtype: DType) {
        super.init(weight: MLXArray.zeros([1, hiddenSize], dtype: dtype))
    }
    override func callAsFunction(_ x: MLXArray) -> MLXArray {
        preconditionFailure("GPT-OSS layer stage 0 has no output head")
    }
}

/// Stage 1 enters through the incoming residual, never through a token lookup.
final class GPTOSSStageResidualEmbedding: Embedding {
    init(hiddenSize: Int, dtype: DType) {
        super.init(weight: MLXArray.zeros([1, hiddenSize], dtype: dtype))
    }
    override func callAsFunction(_ x: MLXArray) -> MLXArray {
        preconditionFailure("GPT-OSS layer stage 1 requires residual ingress, not token embedding")
    }
    override func asLinear(_ x: MLXArray) -> MLXArray {
        preconditionFailure("GPT-OSS layer-stage inactive embedding is not an output head")
    }
}

struct GPTOSSStagePreparedInventory {
    let active: [QwenStageActiveTensor]
    let inert: [QwenStageInertModule]
    let summary: QwenStageStorageSummary
}

/// Constructs one stage's product model lazily, replaces its inactive modules
/// and installs the artifact's quantized modules, without reading or
/// evaluating a tensor. The model is the product class constructed from the
/// stage's own configuration; its experts keep the split gate and up
/// projections the class constructs and the artifact stores.
func prepareGPTOSSStageModel(source: GPTOSSResidentSource, stage: GPTOSSLayerStagePlan.Stage,
                             check: () throws -> Void
) throws -> (model: GPTOSSModel, inventory: GPTOSSStagePreparedInventory) {
    let spec = source.specification
    let configuration = try JSONDecoder().decode(GPTOSSConfiguration.self, from: stage.constructionConfiguration)
    guard configuration.hiddenLayers == stage.layers.count, configuration.layerTypes == stage.layers.map(\.kind),
          configuration.hiddenSize == spec.hidden, configuration.vocabularySize == spec.vocabulary,
          configuration.localExperts == spec.experts, configuration.slidingWindow == spec.slidingWindow else {
        throw ProbeError("GPT-OSS stage configuration differs from its Plan")
    }
    let model = GPTOSSModel(configuration)
    guard model.cbv2LayerKinds.count == stage.layers.count,
          zip(model.cbv2LayerKinds, stage.layers).allSatisfy({ kind, layer in
              kind.hasSinks && kind.kvHeads == spec.keyValueHeads && kind.headDim == spec.headDimension
                  && (kind.attention == .full) == (layer.kind == GPTOSSRegisteredSpecification.fullAttention)
          }) else { throw ProbeError("GPT-OSS stage model attention structure differs from its Plan") }

    // Inactive modules first, so no checkpoint policy is ever applied to them.
    let replacements: [(String, Module)] = stage.index == 0
        ? [(GPTOSSLayerStagePlan.norm, GPTOSSStageIdentityNorm()),
           (GPTOSSLayerStagePlan.head, GPTOSSStageDiscardedHead(hiddenSize: spec.hidden, dtype: source.activationDType))]
        : [(GPTOSSLayerStagePlan.embedding,
            GPTOSSStageResidualEmbedding(hiddenSize: spec.hidden, dtype: source.activationDType))]
    guard replacements.map(\.0).sorted() == stage.inertModules.map(\.path).sorted() else {
        throw ProbeError("GPT-OSS stage inactive module inventory differs from its Plan")
    }
    try model.update(modules: ModuleChildren.unflattened(replacements), verify: [.noUnusedKeys])
    let modules = Dictionary(uniqueKeysWithValues: model.namedModules())
    guard stage.index != 0 || (modules[GPTOSSLayerStagePlan.norm] is GPTOSSStageIdentityNorm
            && modules[GPTOSSLayerStagePlan.head] is GPTOSSStageDiscardedHead),
          stage.index != 1 || modules[GPTOSSLayerStagePlan.embedding] is GPTOSSStageResidualEmbedding else {
        throw ProbeError("GPT-OSS stage inactive modules were not installed")
    }

    let sourceTensors = Dictionary(uniqueKeysWithValues: source.tensors.map { ($0.sourceName, $0) })
    let mappings = source.mappings.filter { $0.stage == stage.index }
    let localToSource = Dictionary(uniqueKeysWithValues: mappings.map { ($0.localName, $0.sourceName) })
    // The stage configuration's own policy, read the way the product loader
    // reads it, must give each stored module the registered policy.
    let base = try JSONDecoder().decode(BaseConfiguration.self, from: stage.constructionConfiguration)
    guard let policy = base.perLayerQuantization else { throw ProbeError("GPT-OSS stage configuration lost its quantization") }
    let inactive = Set(stage.inertModules.map(\.path))
    var policies: [String: BaseConfiguration.Quantization] = [:]
    for (path, _) in model.leafModules().flattened() {
        if inactive.contains(path) { continue }
        guard let sourceScales = localToSource[path + ".scales"] else { continue }
        let sourcePath = String(sourceScales.dropLast(".scales".count))
        guard let registered = source.plan.quantization[sourcePath],
              let local = policy.quantization(layer: path),
              local.mode.rawValue == registered.mode, local.bits == registered.bits,
              local.groupSize == registered.groupSize else {
            throw ProbeError("GPT-OSS stage quantization differs from the registered policy: \(path)")
        }
        policies[path] = local
    }
    guard policies.count == localToSource.keys.filter({ $0.hasSuffix(".scales") }).count else {
        throw ProbeError("GPT-OSS stage has stored quantized modules the model does not construct")
    }
    quantize(model: model) { path, _ in policies[path]?.asTuple }
    try check()

    let actual = Dictionary(uniqueKeysWithValues: model.parameters().flattened())
    var inert: [QwenStageInertModule] = []
    for item in stage.inertModules.sorted(by: { $0.path < $1.path }) {
        let prefix = item.path + "."
        let parameters = actual.filter { $0.key.hasPrefix(prefix) }.sorted { $0.key < $1.key }.map {
            QwenStageInertParameter(localName: $0.key, shape: $0.value.shape,
                dtype: String(describing: $0.value.dtype), byteCount: $0.value.nbytes)
        }
        guard parameters.count == 1, parameters[0].shape == (item.path == GPTOSSLayerStagePlan.norm ? [1] : [1, spec.hidden]) else {
            throw ProbeError("GPT-OSS inactive stage parameters are not explicit bounded placeholders")
        }
        inert.append(QwenStageInertModule(path: item.path, replacementKind: "module-replacement",
            responsibility: item.responsibility, parameters: parameters))
    }
    let inertParameters = inert.flatMap(\.parameters)
    let inertNames = Set(inertParameters.map(\.localName))
    guard Set(localToSource.keys).isDisjoint(with: inertNames),
          Set(actual.keys) == Set(localToSource.keys).union(inertNames) else {
        let missing = Set(localToSource.keys).union(inertNames).subtracting(actual.keys).sorted()
        let extra = Set(actual.keys).subtracting(localToSource.keys).subtracting(inertNames).sorted()
        throw ProbeError("GPT-OSS stage parameters do not cover the compact constructor; missing=\(missing.prefix(6)), extra=\(extra.prefix(6))")
    }
    var active: [QwenStageActiveTensor] = []
    for mapping in mappings.sorted(by: { $0.localName < $1.localName }) {
        guard let tensor = sourceTensors[mapping.sourceName], let parameter = actual[mapping.localName],
              parameter.shape == tensor.shape,
              // Packed words and exponent bytes keep their exact integer type;
              // a floating parameter takes the stored floating dtype at load.
              parameter.dtype == DType.uint32 || parameter.dtype == DType.uint8
                  ? String(describing: parameter.dtype) == tensor.sourceDType
                  : tensor.sourceDType == String(describing: source.activationDType),
              stage.activeModuleRoots.contains(where: { mapping.localName.hasPrefix($0 + ".") }) else {
            throw ProbeError("GPT-OSS stage parameter geometry or class differs: \(mapping.localName)")
        }
        active.append(QwenStageActiveTensor(sourceName: mapping.sourceName, localName: mapping.localName,
            shape: tensor.shape, sourceDType: tensor.sourceDType, loadedDType: tensor.loadedDType,
            byteCount: tensor.byteCount))
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
    guard summary.loadedTensorBytes == (try source.plan.tensorBytes(stage: stage.index)) else {
        throw ProbeError("GPT-OSS stage inventory differs from its Plan's byte share")
    }
    return (model, GPTOSSStagePreparedInventory(active: active, inert: inert, summary: summary))
}

/// Validates the stage this rank does not own, then releases all its lazy
/// defaults before the owned stage is constructed.
func inspectOtherGPTOSSStage(source: GPTOSSResidentSource, stage: GPTOSSLayerStagePlan.Stage,
                             check: () throws -> Void) throws -> GPTOSSStagePreparedInventory {
    weak var retired: Module?
    let inventory = try autoreleasepool {
        let prepared = try prepareGPTOSSStageModel(source: source, stage: stage, check: check)
        retired = prepared.model
        return prepared.inventory
    }
    guard retired == nil else { throw ProbeError("Unowned compact GPT-OSS metadata model remained retained") }
    return inventory
}
