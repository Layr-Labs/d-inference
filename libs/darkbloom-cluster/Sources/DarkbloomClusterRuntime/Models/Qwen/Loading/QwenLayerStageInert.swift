import Foundation
import MLX
import MLXLLM
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
///
/// One exception, used only by a decoding rank that runs the speculative head
/// (`Models/Qwen/MTP`): the public forwards that also return the trunk's hidden
/// state take token IDs and nothing else. For the length of one such call the
/// caller names the residual this stage must start from, and the lookup hands
/// it back unchanged. The residual is kept outside the module, so the module's
/// parameters, and with them every stage receipt, are what they always were.
final class QwenStageResidualEmbedding: Embedding {
    private final class Pending: @unchecked Sendable {
        private let lock = NSLock()
        private var residuals: [ObjectIdentifier: MLXArray] = [:]
        func set(_ value: MLXArray?, for key: ObjectIdentifier) { lock.withLock { residuals[key] = value } }
        func value(for key: ObjectIdentifier) -> MLXArray? { lock.withLock { residuals[key] } }
    }
    private static let pending = Pending()

    init(hiddenSize: Int, dtype: DType) {
        super.init(weight: MLXArray.zeros([1, hiddenSize], dtype: dtype))
    }

    /// Runs `body`, whose one token lookup on this stage returns `residual`.
    func withResidual<T>(_ residual: MLXArray, _ body: () throws -> T) rethrows -> T {
        let key = ObjectIdentifier(self)
        precondition(Self.pending.value(for: key) == nil, "Layer stage 1 residual ingress is not reentrant")
        Self.pending.set(residual, for: key)
        defer { Self.pending.set(nil, for: key) }
        return try body()
    }

    override func callAsFunction(_ x: MLXArray) -> MLXArray {
        guard let residual = Self.pending.value(for: ObjectIdentifier(self)),
              residual.ndim == 3, x.ndim == 2, residual.dim(0) == x.dim(0), residual.dim(1) == x.dim(1) else {
            preconditionFailure("Layer stage 1 requires residual ingress, not token embedding")
        }
        return residual
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
    if model is NemotronHModel {
        return try NemotronStageConstruction.installInertParameters(model: model, stage: stage,
            hiddenSize: hiddenSize, activationDType: activationDType)
    }
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
