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

func prepareVerifiedQwenLayerSource(directory: URL, originalConfiguration: Data,
    plan: QwenLayerStagePlan, expectedAggregateSHA256: String, check: () throws -> Void
) throws -> PreparedQwenLayerSource {
    guard !_qwen35MTPEnabled, originalConfiguration == plan.originalConfiguration,
          plan.stages.count == 2 else {
        throw ProbeError("Layer-stage source requires exact retained configuration and MTP disabled")
    }
    // Reconstruct the pure plan rather than trusting an unrelated caller's
    // stage metadata. This performs no model construction or tensor IO.
    let rebuilt = try QwenLayerStagePlan(configuration: originalConfiguration,
        ranges: plan.stages.map(\.sourceRange), activeMTP: false)
    guard rebuilt.fingerprint == plan.fingerprint,
          zip(rebuilt.stages, plan.stages).allSatisfy({ pair in
              pair.0.fingerprint == pair.1.fingerprint
                && pair.0.constructionConfiguration == pair.1.constructionConfiguration
          }), let root = try JSONSerialization.jsonObject(with: originalConfiguration) as? [String: Any] else {
        throw ProbeError("Layer-stage source plan identity differs")
    }
    let text = root["text_config"] as? [String: Any] ?? root
    let hidden = try QwenStageMetadata.integer(text, "hidden_size", limit: 8192)
    let vocabulary = try QwenStageMetadata.integer(text, "vocab_size", limit: 262144)
    let convert = (ProcessInfo.processInfo.environment["DARKBLOOM_BF16_WEIGHTS"] ?? "1") == "1"
    let base = try JSONDecoder().decode(BaseConfiguration.self, from: originalConfiguration)
    let policy = base.perLayerQuantization ?? .init(perLayerQuantization: [:])
    weak var retiredMetadataModel: Module?
    let result = try autoreleasepool { () throws -> PreparedQwenLayerSource in
        let model = try constructQwenModel(originalConfiguration)
        retiredMetadataModel = model
        try validateQwenStageDenseModel(model, layerCount: plan.layers)
        let prepared = try PreparedQwenCheckpoint(model: model, directory: directory,
            originalConfiguration: originalConfiguration, policy: policy,
            expectedAggregateSHA256: expectedAggregateSHA256,
            maximumPayloadBytes: LocalCorrectnessStorage.maximumManifestPayloadBytes)
        try check()
        let validated = try QwenDenseObservedSourceValidation.validateLegacy(
            observedQwenDenseSource(prepared, model: model), convertBF16: convert, purpose: .layerStage)
        return try finishPreparedQwenLayerSource(prepared: prepared, model: model,
            plan: plan, policy: policy, convert: convert, validated: validated,
            root: root, hidden: hidden, vocabulary: vocabulary, check: check)
    }
    // Neither descriptor preparation nor quantization called eval(model). Do
    // not proceed if an unexpected Swift reference retains the full constructor.
    guard retiredMetadataModel == nil else { throw ProbeError("Full metadata model remained retained") }
    return result
}


/// Shared scalar-record assembly after the caller's legacy or registered
/// descriptor validation. Does not read payload tensors or authorize loading.
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
