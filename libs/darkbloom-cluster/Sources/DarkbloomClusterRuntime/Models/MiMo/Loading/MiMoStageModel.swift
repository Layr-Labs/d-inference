import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN

struct MiMoStagePreparedInventory {
    let active: [QwenStageActiveTensor]
    let inert: [QwenStageInertModule]
    let summary: QwenStageStorageSummary
}

/// Stage 1 enters through the residual. This weight exists only so the module
/// tree keeps its shape; a token lookup through it is a programming error.
private final class MiMoStageResidualEmbedding: Embedding {
    init(hiddenSize: Int, dtype: DType) {
        super.init(weight: MLXArray.zeros([1, hiddenSize], dtype: dtype))
    }

    override func callAsFunction(_ x: MLXArray) -> MLXArray {
        preconditionFailure("MiMo layer stage 1 requires residual ingress, not token embedding")
    }

    override func asLinear(_ x: MLXArray) -> MLXArray {
        preconditionFailure("MiMo layer-stage inactive embedding is not an output head")
    }
}

/// Replaces the one module a stage does not own with an explicit bounded
/// placeholder, before any parameter is evaluated. No checkpoint payload is read.
private func installMiMoStageInertParameters(model: MiMoV26TextModel, stage: MiMoLayerStagePlan.Stage,
                                             hiddenSize: Int, activationDType: DType) throws -> [QwenStageInertModule] {
    guard stage.inertModules.count == 1, let item = stage.inertModules.first else {
        throw ProbeError("Incomplete inactive MiMo stage inventory")
    }
    let modules = Dictionary(uniqueKeysWithValues: model.namedModules())
    let kind: String
    switch (stage.index, item.path) {
    case (0, "model.norm"):
        guard let norm = modules[item.path] as? RMSNorm, norm.weight.shape == [hiddenSize] else {
            throw ProbeError("Invalid stage-0 inactive final norm")
        }
        try norm.update(parameters: ModuleParameters.unflattened([
            "weight": MLXArray.ones([hiddenSize], dtype: activationDType),
        ]), verify: [.noUnusedKeys, .shapeMismatch])
        kind = "parameter-only-replacement"
    case (1, "model.embed_tokens"):
        guard let original = modules[item.path] as? Embedding, original.weight.dim(1) == hiddenSize else {
            throw ProbeError("Invalid stage-1 inactive token embedding")
        }
        let replacement: [(String, Module)] = [
            (item.path, MiMoStageResidualEmbedding(hiddenSize: hiddenSize, dtype: activationDType)),
        ]
        try model.update(modules: ModuleChildren.unflattened(replacement), verify: [.noUnusedKeys])
        kind = "module-replacement"
    default: throw ProbeError("Unknown inactive MiMo stage module: \(item.path)")
    }
    guard let module = Dictionary(uniqueKeysWithValues: model.namedModules())[item.path] else {
        throw ProbeError("Inactive MiMo stage module disappeared")
    }
    let parameters = module.parameters().flattened().sorted(by: { $0.0 < $1.0 }).map {
        QwenStageInertParameter(localName: item.path + "." + $0.0, shape: $0.1.shape,
            dtype: String(describing: $0.1.dtype), byteCount: $0.1.nbytes)
    }
    guard parameters.count == 1, parameters[0].shape == (stage.index == 0 ? [hiddenSize] : [1, hiddenSize]),
          parameters[0].dtype == String(describing: activationDType) else {
        throw ProbeError("Inactive MiMo stage parameters are not explicit bounded placeholders")
    }
    return [QwenStageInertModule(path: item.path, replacementKind: kind,
        responsibility: item.responsibility, parameters: parameters)]
}

/// Installs packed module shells for exactly the modules the artifact stores
/// packed, each with the policy its indexed module declares. The shells' lazy
/// initializer parameters are replaced by checkpoint arrays before any evaluation.
private func installMiMoStagePackedModules(model: MiMoV26TextModel,
                                           policies: [String: MiMoV26Quantization.Policy]) throws {
    let leaves = Dictionary(uniqueKeysWithValues: model.leafModules().flattened())
    var parents = Dictionary(uniqueKeysWithValues: model.namedModules())
    parents[""] = model
    var replacements: [String: [(String, Module)]] = [:]
    for path in policies.keys.sorted() {
        let policy = policies[path]!
        guard let leaf = leaves[path], !(leaf is Quantized),
              leaf is Linear || leaf is Embedding || leaf is SwitchLinear,
              let replacement = quantizeSingle(layer: leaf, groupSize: policy.groupSize, bits: policy.bits,
                                               mode: policy.mode == "mxfp4" ? .mxfp4 : .affine) else {
            throw ProbeError("MiMo stage module cannot take its declared packed layout: \(path)")
        }
        // Update from the module that actually contains the leaf.
        var pieces = path.split(separator: ".").map(String.init)
        pieces.removeLast()
        while !pieces.isEmpty && parents[pieces.joined(separator: ".")] == nil { pieces.removeLast() }
        let parent = pieces.joined(separator: ".")
        let relative = parent.isEmpty ? path : String(path.dropFirst(parent.count + 1))
        replacements[parent, default: []].append((relative, replacement))
    }
    for parent in replacements.keys.sorted() {
        try parents[parent]!.update(modules: .unflattened(replacements[parent]!), verify: .noUnusedKeys)
    }
    let installed = Set(model.leafModules().flattened().compactMap { path, module in
        module is Quantized ? path : nil
    })
    guard installed == Set(policies.keys) else {
        throw ProbeError("MiMo stage packed-module closure differs from the artifact's")
    }
}

extension MiMoLayerStagePlan {
    /// The product's own parse of one stage's compact configuration, checked
    /// against its parse of the source: the same geometry, that stage's layer
    /// kinds, and no heads, tower or encoder. The Plan itself reads only the
    /// fields it divides; this is where the product's parser has its say.
    func productConfiguration(stage index: Int) throws -> MiMoV26Configuration {
        guard stages.indices.contains(index) else { throw ProbeError("Unknown MiMo stage") }
        let stage = stages[index], range = stage.sourceRange
        let full = try JSONDecoder().decode(MiMoV26Configuration.self, from: originalConfiguration)
        let compact = try JSONDecoder().decode(MiMoV26Configuration.self, from: stage.constructionConfiguration)
        guard full.numHiddenLayers == layers, !full.tieWordEmbeddings, full.dtype == "bfloat16",
              compact.numHiddenLayers == range.count, compact.dtype == full.dtype,
              compact.hybridLayerPattern == range.map({ full.hybridLayerPattern[$0] }),
              compact.moeLayerFrequency == range.map({ full.moeLayerFrequency[$0] }),
              compact.vision == nil, compact.audio == nil, compact.numNextnPredictLayers == 0,
              compact.tieWordEmbeddings == (index == 0),
              compact.hiddenSize == full.hiddenSize, compact.vocabularySize == full.vocabularySize,
              compact.fullAttention == full.fullAttention, compact.slidingAttention == full.slidingAttention else {
            throw ProbeError("Compact MiMo stage configuration differs from its source geometry")
        }
        return compact
    }
}

/// Constructs one compact stage with the product's text class, lazily, and
/// checks that its parameters are exactly the tensors the Plan assigns to it
/// plus its one placeholder. Nothing is evaluated and no payload is read.
func prepareMiMoStageModel(source: MiMoResidentSource, stage: MiMoLayerStagePlan.Stage,
                           check: () throws -> Void
) throws -> (model: MiMoV26TextModel, inventory: MiMoStagePreparedInventory) {
    let configuration = try source.plan.productConfiguration(stage: stage.index)
    let model = try MiMoV26TextModel(configuration)
    let hidden = source.specification.hidden
    guard model.model.namedModules().filter({ $0.0.hasSuffix(".mlp") }).count == stage.layers.count else {
        throw ProbeError("MiMo layer stage changed the layer topology")
    }
    let inert = try installMiMoStageInertParameters(model: model, stage: stage, hiddenSize: hidden,
                                                    activationDType: source.activationDType)
    let mappings = source.mappings.filter { $0.stage == stage.index }
    let sourceTensors = Dictionary(uniqueKeysWithValues: source.tensors.map { ($0.sourceName, $0) })
    var policies: [String: MiMoV26Quantization.Policy] = [:]
    for mapping in mappings where mapping.localName.hasSuffix(".scales") {
        let local = String(mapping.localName.dropLast(".scales".count))
        let indexed = try source.plan.sourceModulePath(stage: stage.index, localModulePath: local)
        guard indexed + ".scales" == mapping.sourceName, let policy = source.profile.quantization[indexed] else {
            throw ProbeError("MiMo stage packed module has no declared policy: \(local)")
        }
        policies[local] = policy
    }
    try installMiMoStagePackedModules(model: model, policies: policies)
    try check()
    let actual = Dictionary(uniqueKeysWithValues: model.parameters().flattened())
    let inertParameters = inert.flatMap(\.parameters)
    let inertNames = Set(inertParameters.map(\.localName))
    let localNames = Set(mappings.map(\.localName))
    guard localNames.isDisjoint(with: inertNames), Set(actual.keys) == localNames.union(inertNames) else {
        let missing = Set(actual.keys).subtracting(localNames.union(inertNames)).sorted()
        let extra = localNames.union(inertNames).subtracting(actual.keys).sorted()
        throw ProbeError("MiMo stage parameters do not cover the compact constructor; "
            + "unowned=\(missing.prefix(6)), absent=\(extra.prefix(6))")
    }
    var active: [QwenStageActiveTensor] = []
    for mapping in mappings.sorted(by: { $0.localName < $1.localName }) {
        guard let tensor = sourceTensors[mapping.sourceName], let parameter = actual[mapping.localName],
              parameter.shape == tensor.shape,
              stage.activeModuleRoots.contains(where: { mapping.localName.hasPrefix($0 + ".") }) else {
            throw ProbeError("MiMo stage parameter geometry or ownership differs: \(mapping.localName)")
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
    return (model, MiMoStagePreparedInventory(active: active, inert: inert, summary: summary))
}

/// The stage this rank does not load: validated the same way, then released
/// before the stage that will receive payload bytes is constructed.
func inspectOtherMiMoStage(source: MiMoResidentSource, stage: MiMoLayerStagePlan.Stage,
                           check: () throws -> Void) throws -> MiMoStagePreparedInventory {
    weak var retired: Module?
    let inventory = try autoreleasepool {
        let prepared = try prepareMiMoStageModel(source: source, stage: stage, check: check)
        retired = prepared.model
        return prepared.inventory
    }
    guard retired == nil else { throw ProbeError("Unowned compact MiMo metadata model remained retained") }
    return inventory
}
