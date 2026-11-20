import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN

/// The artifact aggregate binds the original tensor bytes. The configuration,
/// loaded layout and conversion flag describe their deterministic transformation;
/// this is not a separate digest of every resident parameter's content.
struct VerifiedQwenDiagnosticReceipt: Codable {
    let schemaVersion: Int
    let verifiedAggregateSHA256: String
    let configurationSHA256: String
    let sourceModelTensorBytes: Int
    let loadedTensorBytes: Int
    let largestHostTensorBytes: Int
    let tensorCount: Int
    let sourceTensorCount: Int
    let parameterLayoutSHA256: String
    let bf16ConversionEnabled: Bool
}

/// Full, unpartitioned dense Qwen loading for a bounded diagnostic. All reads use
/// verified pinned descriptors; neither config nor weights are reopened by path.
/// The caller must discard the model if loading throws after an update.
func loadVerifiedQwenDiagnostic(
    model: any LanguageModel, directory: URL, originalConfiguration: Data,
    policy: BaseConfiguration.PerLayerQuantization, expectedAggregateSHA256: String
) throws -> VerifiedQwenDiagnosticReceipt {
    let layers = try validateDiagnosticQwen(model: model, configuration: originalConfiguration,
                                            policy: policy)
    return try MLX.withError { error in
        let prepared = try PreparedQwenCheckpoint(model: model, directory: directory,
            originalConfiguration: originalConfiguration, policy: policy,
            expectedAggregateSHA256: expectedAggregateSHA256,
            maximumPayloadBytes: LocalCorrectnessStorage.maximumManifestPayloadBytes)
        try error.check()
        let convertBF16 = (ProcessInfo.processInfo.environment["DARKBLOOM_BF16_WEIGHTS"] ?? "1") == "1"
        let budget = try DiagnosticQwenStorage(prepared: prepared, model: model, convertBF16: convertBF16)
        // Validate the complete quantized topology before the first tensor read.
        _ = try validatedQwenFeedForwardScaleTypes(model, layers: layers,
            isMoE: false, requireTwoWaySplit: false)
        try error.check()
        var loadedBytes = 0, largestHostBytes = 0
        for name in prepared.canonical.keys.sorted() {
            let tensor = prepared.canonical[name]!
            try autoreleasepool {
                let read = try tensor.read(.all)
                let sanitized = model.sanitize(weights: [name: read.array])
                guard sanitized.count == 1, var array = sanitized[name],
                      array.shape == prepared.expectedShapes[name], array.dtype == tensor.dtype else {
                    throw ProbeError("Verified diagnostic loader produced the wrong shape, dtype or key: \(name)")
                }
                if convertBF16 && array.dtype == .float16 { array = array.asType(.bfloat16) }
                eval(array)
                try error.check()
                guard array.nbytes == read.copiedBytes else {
                    throw ProbeError("Verified diagnostic conversion changed the stored byte width")
                }
                try model.update(parameters: ModuleParameters.unflattened([name: array]),
                                 verify: [.noUnusedKeys, .shapeMismatch])
                try error.check()
                loadedBytes += read.copiedBytes
                largestHostBytes = max(largestHostBytes, read.largestHostTensorBytes)
            }
        }
        try prepared.checkpoint.checkUnchanged()
        model.freeze()
        eval(model)
        try error.check()
        try prepared.checkpoint.checkUnchanged()
        let layout = modelParameterLayout(model)
        guard loadedBytes == budget.sourceBytes, largestHostBytes == budget.largestSourceBytes,
              layout == budget.expectedLayout else {
            throw ProbeError("Verified diagnostic loader byte accounting or loaded layout differs")
        }
        return VerifiedQwenDiagnosticReceipt(schemaVersion: 1,
            verifiedAggregateSHA256: prepared.checkpoint.aggregate,
            configurationSHA256: sha256(originalConfiguration),
            sourceModelTensorBytes: budget.sourceBytes, loadedTensorBytes: loadedBytes,
            largestHostTensorBytes: largestHostBytes, tensorCount: prepared.canonical.count,
            sourceTensorCount: prepared.sourceTensorCount, parameterLayoutSHA256: layout,
            bf16ConversionEnabled: convertBF16)
    }
}

private struct DiagnosticQwenStorage {
    let sourceBytes: Int
    let largestSourceBytes: Int
    let expectedLayout: String

    init(prepared: PreparedQwenCheckpoint, model: Module, convertBF16: Bool) throws {
        let validated = try QwenDenseObservedSourceValidation.validateLegacy(
            observedQwenDenseSource(prepared, model: model), convertBF16: convertBF16, purpose: .diagnostic)
        sourceBytes = validated.sourceBytes; largestSourceBytes = validated.largestSourceBytes
        expectedLayout = validated.expectedLayoutSHA256
    }
}

private func validateDiagnosticQwen(model: any LanguageModel, configuration: Data,
                                    policy: BaseConfiguration.PerLayerQuantization) throws -> Int {
    guard let object = try JSONSerialization.jsonObject(with: configuration) as? [String: Any],
          let modelType = object["model_type"] as? String,
          ["qwen3_5", "qwen3_5_text"].contains(modelType),
          model is Qwen35Model || model is Qwen35TextModel,
          let mtp = model as? any MTPCapable, !mtp.hasMTPHead else {
        throw ProbeError("Verified diagnostic loading requires an unpartitioned dense Qwen model without MTP")
    }
    let text = object["text_config"] as? [String: Any] ?? object
    guard (text["num_experts"] as? Int ?? 0) == 0,
          let layers = text["num_hidden_layers"] as? Int, layers > 0 else {
        throw ProbeError("Verified diagnostic loading does not support MoE or an empty model")
    }
    let ffns = model.namedModules().filter { $0.0.hasSuffix(".mlp") }
    guard ffns.count == layers,
          ffns.allSatisfy({ String(describing: type(of: $0.1)) == "Qwen3NextMLP" }) else {
        throw ProbeError("Verified diagnostic requires each original dense Qwen MLP")
    }
    let base = try JSONDecoder().decode(BaseConfiguration.self, from: configuration)
    guard let retained = base.perLayerQuantization,
          sameDiagnosticPolicy(policy.quantization, retained.quantization),
          Set(policy.perLayerQuantization.keys) == Set(retained.perLayerQuantization.keys) else {
        throw ProbeError("Verified diagnostic policy differs from the retained configuration")
    }
    for (path, option) in policy.perLayerQuantization {
        switch (option, retained.perLayerQuantization[path]!) {
        case (.skip, .skip): break
        case (.quantize(let left), .quantize(let right)):
            guard sameDiagnosticPolicy(left, right) else {
                throw ProbeError("Verified diagnostic policy differs from retained configuration: \(path)")
            }
        default: throw ProbeError("Verified diagnostic policy differs from retained configuration: \(path)")
        }
    }
    return layers
}

private func sameDiagnosticPolicy(_ left: BaseConfiguration.Quantization?,
                                  _ right: BaseConfiguration.Quantization?) -> Bool {
    switch (left, right) {
    case (nil, nil): return true
    case (.some(let left), .some(let right)):
        return left.bits == right.bits && left.groupSize == right.groupSize && left.mode == right.mode
    default: return false
    }
}
