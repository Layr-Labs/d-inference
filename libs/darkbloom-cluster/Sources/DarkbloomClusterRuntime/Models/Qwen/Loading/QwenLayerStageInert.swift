import MLX
import MLXLMCommon
import MLXNN

/// Stage 0's public hidden-state method constructs a discarded head graph.
/// Accept its real hidden width, but do not retain or evaluate its norm input.
private final class QwenStageDiscardedHead: Linear {
    init(hiddenSize: Int, dtype: DType) {
        super.init(weight: MLXArray.zeros([1, hiddenSize], dtype: dtype))
    }

    override func callAsFunction(_ x: MLXArray) -> MLXArray {
        MLXArray.zeros(Array(x.shape.dropLast()) + [1], dtype: x.dtype)
    }
}

/// This weight exists only for pinned Qwen's metadata-only activation/cache
/// dtype query. Stage 1 must enter through inputEmbedding (raw residual), never
/// token lookup or tied-head fallback. The session checks that contract first.
private final class QwenStageResidualEmbedding: Embedding {
    init(hiddenSize: Int, dtype: DType) {
        super.init(weight: MLXArray.zeros([1, hiddenSize], dtype: dtype))
    }

    override func callAsFunction(_ x: MLXArray) -> MLXArray {
        preconditionFailure("Layer stage 1 requires residual ingress, not token embedding")
    }

    override func asLinear(_ x: MLXArray) -> MLXArray {
        preconditionFailure("Layer-stage inactive embedding is not an output head")
    }
}

/// No checkpoint payload is read or evaluated here. The pinned final norm is
/// not @ModuleInfo: replace its H-element parameter, not its immutable object.
func installQwenStageInertParameters(model: any LanguageModel,
    stage: QwenLayerStagePlan.Stage, hiddenSize: Int, activationDType: DType
) throws -> [QwenStageInertModule] {
    let modules = Dictionary(uniqueKeysWithValues: model.namedModules())
    var replacements: [(String, Module)] = []
    var norm: (String, RMSNorm)?
    for item in stage.inertModules {
        if item.path.hasSuffix(".model.norm") || item.path == "model.norm" {
            guard stage.index == 0, let original = modules[item.path] as? RMSNorm,
                  original.weight.shape == [hiddenSize] else {
                throw ProbeError("Invalid stage-0 inactive final norm")
            }
            norm = (item.path, original)
        } else if item.path.hasSuffix(".lm_head") || item.path == "lm_head" {
            guard stage.index == 0, let original = modules[item.path] as? Linear,
                  original.weight.dim(1) == hiddenSize else {
                throw ProbeError("Invalid stage-0 inactive output head")
            }
            replacements.append((item.path, QwenStageDiscardedHead(
                hiddenSize: hiddenSize, dtype: activationDType)))
        } else if item.path.hasSuffix(".embed_tokens") {
            guard stage.index == 1, let original = modules[item.path] as? Embedding,
                  original.weight.dim(1) == hiddenSize else {
                throw ProbeError("Invalid stage-1 inactive token embedding")
            }
            replacements.append((item.path, QwenStageResidualEmbedding(
                hiddenSize: hiddenSize, dtype: activationDType)))
        } else { throw ProbeError("Unknown inactive stage module: \(item.path)") }
    }
    guard replacements.count == 1, (norm != nil) == (stage.index == 0),
          stage.inertModules.count == (stage.index == 0 ? 2 : 1) else {
        throw ProbeError("Incomplete inactive stage inventory")
    }
    // Validate every replacement before changing the compact model.
    if let (_, norm) = norm {
        try norm.update(parameters: ModuleParameters.unflattened([
            "weight": MLXArray.ones([hiddenSize], dtype: activationDType),
        ]), verify: [.noUnusedKeys, .shapeMismatch])
    }
    try model.update(modules: ModuleChildren.unflattened(replacements), verify: [.noUnusedKeys])
    let actual = Dictionary(uniqueKeysWithValues: model.namedModules())
    return try stage.inertModules.sorted(by: { $0.path < $1.path }).map { item in
        guard let module = actual[item.path] else { throw ProbeError("Inactive stage module disappeared") }
        let parameters = module.parameters().flattened().sorted(by: { $0.0 < $1.0 }).map {
            QwenStageInertParameter(localName: item.path + "." + $0.0,
                shape: $0.1.shape, dtype: String(describing: $0.1.dtype), byteCount: $0.1.nbytes)
        }
        guard parameters.count == 1, parameters[0].shape ==
                (item.path == norm?.0 ? [hiddenSize] : [1, hiddenSize]),
              parameters[0].dtype == String(describing: activationDType) else {
            throw ProbeError("Inactive stage parameters are not explicit bounded placeholders")
        }
        return QwenStageInertModule(path: item.path,
            replacementKind: item.path == norm?.0 ? "parameter-only-replacement" : "module-replacement",
            responsibility: item.responsibility, parameters: parameters)
    }
}
