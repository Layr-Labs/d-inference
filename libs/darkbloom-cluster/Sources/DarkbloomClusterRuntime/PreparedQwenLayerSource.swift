import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN

/// Pinned descriptors and scalar metadata only. In particular this value does
/// not retain the full metadata model or any of its lazy parameter arrays.
struct PreparedQwenLayerSource {
    let prepared: PreparedQwenCheckpoint
    let tensors: [QwenStageSourceTensor]
    let mappings: [QwenLayerStagePlan.Parameter]
    let quantization: [String: BaseConfiguration.Quantization]
    let activationDType: DType
    let hiddenSize: Int
    let vocabularySize: Int
    let bf16ConversionEnabled: Bool
    let sourceBytes: Int
    let largestSourceBytes: Int
    let sourceTensorManifestSHA256: String
    let sourceParameterLayoutSHA256: String
}

/// Scalar-record assembly after registered descriptor validation. Does not
/// read payload tensors or authorize loading.
func finishPreparedQwenLayerSource(prepared: PreparedQwenCheckpoint, model: any LanguageModel,
    plan: QwenLayerStagePlan, policy: BaseConfiguration.PerLayerQuantization,
    convert: Bool, validated: QwenDenseSourceReadPlan, root: [String: Any],
    hidden: Int, vocabulary: Int, check: () throws -> Void
) throws -> PreparedQwenLayerSource {
    let bytes = validated.sourceBytes, largest = validated.largestSourceBytes
    var tensors: [QwenStageSourceTensor] = []
    for record in validated.tensors {
        let name = record.canonical.name, tensor = prepared.canonical[name]!
        let part = tensor.parts[0]
        tensors.append(QwenStageSourceTensor(sourceName: name, canonicalPartName: part.name,
            file: part.tensor.file.path, offset: part.tensor.offset, shape: tensor.shape,
            sourceDType: String(describing: tensor.dtype),
            loadedDType: record.loadedDType, byteCount: tensor.byteCount))
    }
    let mappings = try plan.parameters(canonicalSourceNames: tensors.map(\.sourceName))
    guard bytes > 0, mappings.count == tensors.count,
          Set(mappings.map(\.sourceName)) == Set(tensors.map(\.sourceName)) else {
        throw ProbeError("Every canonical source tensor must have exactly one layer-stage owner")
    }
    var resolved: [String: BaseConfiguration.Quantization] = [:]
    for (path, module) in model.leafModules().flattened()
    where prepared.canonical[path + ".scales"] != nil {
        guard let actual = module as? any Quantized, actual.mode == .affine,
              let declared = resolveQuantization(path: path, perLayerQuantization: policy,
                  aliasing: model as? QuantizationPathAliasing),
              declared.mode == actual.mode, declared.bits == actual.bits,
              declared.groupSize == actual.groupSize else {
            throw ProbeError("Layer stages require the exact declared affine projection: \(path)")
        }
        resolved[path] = declared
    }
    let embeddingPath = (root["model_type"] as? String == "qwen3_5" ? "language_model." : "")
        + "model.embed_tokens"
    let activation = try qwenStageSourceActivation(prepared, path: embeddingPath, convert: convert)
    try check()
    try prepared.checkpoint.checkUnchanged()
    return PreparedQwenLayerSource(prepared: prepared, tensors: tensors, mappings: mappings,
        quantization: resolved, activationDType: activation, hiddenSize: hidden,
        vocabularySize: vocabulary, bf16ConversionEnabled: convert, sourceBytes: bytes,
        largestSourceBytes: largest, sourceTensorManifestSHA256: sha256(try canonicalJSONData(tensors)),
        sourceParameterLayoutSHA256: qwenStageLayout(tensors.map {
            "\($0.sourceName):\($0.loadedDType):\($0.shape)"
        }))
}

func validateQwenStageDenseModel(_ model: any LanguageModel, layerCount: Int) throws {
    guard model is Qwen35Model || model is Qwen35TextModel,
          let mtp = model as? any MTPCapable, !mtp.hasMTPHead else {
        throw ProbeError("Layer stages require public dense Qwen without an attached MTP head")
    }
    let mlps = model.namedModules().filter { $0.0.hasSuffix(".mlp") }
    guard mlps.count == layerCount,
          mlps.allSatisfy({ String(describing: type(of: $0.1)) == "Qwen3NextMLP" }) else {
        throw ProbeError("Layer stage changed the original dense Qwen MLP topology")
    }
}

func qwenStageLoadedDType(_ dtype: DType, convert: Bool) -> DType {
    convert && dtype == .float16 ? .bfloat16 : dtype
}

func qwenStageLayout(_ entries: [String]) -> String {
    sha256(Data(entries.sorted().joined(separator: "\n").utf8))
}

private func qwenStageSourceActivation(_ prepared: PreparedQwenCheckpoint,
    path: String, convert: Bool
) throws -> DType {
    guard let weight = prepared.canonical[path + ".weight"] else {
        throw ProbeError("Layer-stage source embedding is missing")
    }
    let dtype: DType
    if weight.dtype == .uint32 {
        guard let scales = prepared.canonical[path + ".scales"],
              let biases = prepared.canonical[path + ".biases"],
              qwenStageLoadedDType(scales.dtype, convert: convert)
                == qwenStageLoadedDType(biases.dtype, convert: convert) else {
            throw ProbeError("Layer-stage embedding has incompatible affine metadata dtypes")
        }
        dtype = qwenStageLoadedDType(scales.dtype, convert: convert)
    } else { dtype = qwenStageLoadedDType(weight.dtype, convert: convert) }
    guard [.float16, .bfloat16, .float32].contains(dtype) else {
        throw ProbeError("Layer-stage source embedding has unsupported activation dtype")
    }
    return dtype
}
