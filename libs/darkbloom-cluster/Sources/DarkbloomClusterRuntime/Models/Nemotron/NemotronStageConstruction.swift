import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN

/// Stage 0 never computes logits: its frames end at the residual before
/// `norm_f`. The head keeps a bounded placeholder weight and no arithmetic.
private final class NemotronStageAbsentHead: Linear {
    init(hiddenSize: Int, dtype: DType) {
        super.init(weight: MLXArray.zeros([1, hiddenSize], dtype: dtype))
    }

    override func callAsFunction(_ x: MLXArray) -> MLXArray {
        preconditionFailure("Nemotron layer stage 0 has no output head")
    }
}

/// Stage 1 enters through the residual, never through a token lookup. The
/// pinned model still asks its embedding for one token's row when it derives
/// its activation and KV dtypes, in a lazy graph through private caches that
/// is never evaluated; this answers that question in the checkpoint's
/// activation dtype and refuses everything else.
private final class NemotronStageResidualEmbedding: Embedding {
    private let hiddenSize: Int
    private let dtype: DType

    init(hiddenSize: Int, dtype: DType) {
        self.hiddenSize = hiddenSize; self.dtype = dtype
        super.init(weight: MLXArray.zeros([1, hiddenSize], dtype: dtype))
    }

    override func callAsFunction(_ x: MLXArray) -> MLXArray {
        precondition(x.size == 1, "Nemotron layer stage 1 requires residual ingress, not token embedding")
        return MLXArray.zeros(x.shape + [hiddenSize], dtype: dtype)
    }

    override func asLinear(_ x: MLXArray) -> MLXArray {
        preconditionFailure("Layer-stage inactive embedding is not an output head")
    }
}

/// Construction of the pinned Nemotron class for a complete configuration or
/// for one stage's, and what a stage replaces before any payload is read.
enum NemotronStageConstruction {
    static func accepts(_ object: [String: Any]) -> Bool { NemotronStageMetadata.accepts(object) }

    static func model(_ data: Data) throws -> any LanguageModel {
        NemotronH35Model(try JSONDecoder().decode(NemotronH35Configuration.self, from: data))
    }

    /// The constructor built exactly the blocks its block list names, each
    /// with the pinned mixer, and attached no speculative head. The mixers are
    /// internal to the pinned package, so they are checked by type name.
    static func validate(_ model: any LanguageModel, layerCount: Int) throws {
        guard let lightning = model as? NemotronH35Model else {
            throw ProbeError("Nemotron layer stages require the pinned Lightning model class")
        }
        let pattern = Array(lightning.lightningConfiguration.target.hybridOverridePattern)
        let modules = Dictionary(uniqueKeysWithValues: model.namedModules())
        guard pattern.count == layerCount,
              !modules.keys.contains(where: { $0 == "mtp" || $0.hasPrefix("mtp.") || $0.hasSuffix(".mtp") }),
              modules.keys.filter({ $0.hasPrefix(NemotronStageMetadata.layerPrefix) && $0.hasSuffix(".mixer") }).count == layerCount else {
            throw ProbeError("Nemotron layer stage differs from its block list or carries a speculative head")
        }
        for (layer, symbol) in pattern.enumerated() {
            let base = NemotronStageMetadata.layerPrefix + "\(layer).mixer"
            func typeName(_ path: String) -> String { modules[path].map { String(describing: type(of: $0)) } ?? "" }
            let expected: [String: String]
            switch symbol {
            case "M": expected = [base: "NemotronHMamba2Mixer", base + ".norm": "NemotronHRMSNormGated"]
            case "*": expected = [base: "NemotronHAttention"]
            case "E": expected = [base: "NemotronHMoE", base + ".gate": "NemotronHMoEGate",
                                  base + ".switch_mlp": "NemotronHSwitchMLP", base + ".shared_experts": "NemotronHMLP"]
            default: throw ProbeError("Nemotron layer stage has an unsupported block")
            }
            guard expected.allSatisfy({ typeName($0.key) == $0.value }) else {
                throw ProbeError("Nemotron layer stage changed the pinned mixer topology at block \(layer)")
            }
        }
    }

    /// No checkpoint payload is read or evaluated here. The final norm keeps
    /// its module and takes a unit weight; the head and the embedding are
    /// replaced by bounded placeholders.
    static func installInertParameters(model: any LanguageModel, stage: QwenLayerStagePlan.Stage,
                                       hiddenSize: Int, activationDType: DType) throws -> [QwenStageInertModule] {
        let modules = Dictionary(uniqueKeysWithValues: model.namedModules())
        var replacements: [(String, Module)] = []
        var norm: (String, RMSNorm)?
        for item in stage.inertModules {
            switch item.path {
            case NemotronStageMetadata.finalNormPath:
                guard stage.index == 0, let original = modules[item.path] as? RMSNorm,
                      original.weight.shape == [hiddenSize] else {
                    throw ProbeError("Invalid stage-0 inactive final norm")
                }
                norm = (item.path, original)
            case NemotronStageMetadata.headPath:
                guard stage.index == 0, let original = modules[item.path] as? Linear,
                      original.weight.dim(1) == hiddenSize else {
                    throw ProbeError("Invalid stage-0 inactive output head")
                }
                replacements.append((item.path, NemotronStageAbsentHead(hiddenSize: hiddenSize, dtype: activationDType)))
            case NemotronStageMetadata.embeddingPath:
                guard stage.index == 1, let original = modules[item.path] as? Embedding,
                      original.weight.dim(1) == hiddenSize else {
                    throw ProbeError("Invalid stage-1 inactive token embedding")
                }
                replacements.append((item.path, NemotronStageResidualEmbedding(hiddenSize: hiddenSize, dtype: activationDType)))
            default: throw ProbeError("Unknown inactive stage module: \(item.path)")
            }
        }
        guard replacements.count == 1, (norm != nil) == (stage.index == 0),
              stage.inertModules.count == (stage.index == 0 ? 2 : 1) else {
            throw ProbeError("Incomplete inactive stage inventory")
        }
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
}
