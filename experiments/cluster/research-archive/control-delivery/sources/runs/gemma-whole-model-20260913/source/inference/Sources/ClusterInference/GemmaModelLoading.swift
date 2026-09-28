import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN

func constructGemmaModel(_ data: Data) throws -> any LanguageModel {
    let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    if root?["model_type"] as? String == "gemma4" {
        return Gemma4Model(try JSONDecoder().decode(Gemma4Configuration.self, from: data))
    }
    return Gemma4TextModel(try JSONDecoder().decode(Gemma4TextConfiguration.self, from: data))
}

func loadGemmaModel(_ options: Options, configurationData data: Data, partitionRank: Int?) throws -> LoadedModel {
    guard options.partition == .ffn, options.attentionOutputPrecision == .native,
        options.mode != .localParity, options.mode != .loaderParity else {
        throw ProbeError("Gemma requires its own FFN adapter and native precision; Qwen-only local/loader oracles are unsupported")
    }
    // Planning verifies geometry/policies without allocating a full-size model.
    let gemma = try GemmaPartitionPlan(configuration: data)
    let plan = ModelPartitionPlan.gemma(gemma)
    guard let policy = try JSONDecoder().decode(BaseConfiguration.self, from: data).perLayerQuantization else {
        throw ProbeError("Gemma requires explicit quantization")
    }
    var model = try constructGemmaModel(options.synthetic ? data
        : partitionRank.map { try gemma.constructionConfiguration(rank: $0) } ?? data)
    var receipt: DirectShardLoadReceipt?
    var storage: PartitionStorageCommitment?
    if options.synthetic {
        quantize(model: model) { path, _ in policy.quantization(layer: path)?.asTuple }
        var parameters = Dictionary(uniqueKeysWithValues: model.parameters().flattened())
        for (name, value) in parameters {
            if name.hasSuffix("per_layer_model_projection.weight") {
                parameters[name] = MLXRandom.normal(value.shape) * 0.01
            } else if name.hasSuffix("router.per_expert_scale") {
                parameters[name] = MLXArray((0..<value.size).map { 0.7 + Float($0) * 0.3 })
            } else if name.hasSuffix("post_feedforward_layernorm_1.weight") {
                parameters[name] = MLXArray((0..<value.size).map { 0.7 + Float($0) * 0.6 / Float(value.size - 1) })
            } else if name.hasSuffix("post_feedforward_layernorm_2.weight") {
                parameters[name] = MLXArray((0..<value.size).map { 1.3 - Float($0) * 0.6 / Float(value.size - 1) })
            }
        }
        let dtype: DType = options.syntheticDType == "bfloat16" ? .bfloat16 : .float32
        parameters = parameters.mapValues { [.float16, .float32, .bfloat16].contains($0.dtype) ? $0.asType(dtype) : $0 }
        try model.update(parameters: ModuleParameters.unflattened(parameters), verify: [.all])
        model.freeze(); eval(model)
        let shapes = Dictionary(uniqueKeysWithValues: model.parameters().flattened().map { ($0.0, $0.1.shape) })
        guard shapes == gemma.expectedSourceShapes else { throw ProbeError("Gemma source constructor differs from adapter layout") }
        if let rank = partitionRank {
            storage = try syntheticPartitionStorage(model, plan: plan)
            let target = try constructGemmaModel(gemma.constructionConfiguration(rank: rank))
            quantize(model: target) { path, _ in policy.quantization(layer: path)?.asTuple }
            let expected = Dictionary(uniqueKeysWithValues: target.parameters().flattened().map { ($0.0, $0.1.shape) })
            for (name, value) in model.parameters().flattened() {
                let selected = try copySelectedTensor(value, selection: gemma.selection(name: name, shape: value.shape, rank: rank))
                guard selected.shape == expected[name] else { throw ProbeError("Gemma selected shape differs from rank constructor") }
                try target.update(parameters: ModuleParameters.unflattened([name: selected]), verify: [.noUnusedKeys, .shapeMismatch])
            }
            target.freeze(); eval(target); model = target
        }
    } else if let rank = partitionRank, let directory = options.modelDirectory {
        receipt = try loadDirectGemmaPartition(model: model, directory: directory,
            originalConfiguration: data, policy: policy, rank: rank, plan: gemma)
        storage = receipt?.partitionStorage
    } else {
        try loadWeights(modelDirectory: options.modelDirectory!, model: model, perLayerQuantization: policy)
        model.freeze(); eval(model)
    }
    let layout = modelParameterLayout(model)
    if let rank = partitionRank, let storage {
        guard layout == storage.ranks[rank].parameterLayoutSHA256 else {
            throw ProbeError("Gemma rank layout differs from its partition commitment")
        }
    }
    let parameters = model.parameters().flattened()
    let scales = Set(parameters.filter { gemma.isFeedForwardTensor(name: $0.0) && $0.0.hasSuffix(".scales") }
        .map { String(describing: $0.1.dtype) }).sorted()
    guard !scales.isEmpty, let embedding = model.namedModules().first(where: {
        $0.0.hasSuffix(".embed_tokens")
    })?.1 as? Embedding else { throw ProbeError("Missing Gemma embedding or FFN metadata") }
    let activation = embedding(MLXArray([0]).reshaped(1, 1)); eval(activation)
    if options.synthetic {
        guard String(describing: activation.dtype) == options.syntheticDType,
            parameters.allSatisfy({ $0.1.dtype == .uint32 || String(describing: $0.1.dtype) == options.syntheticDType }) else {
            throw ProbeError("Gemma synthetic parameter/activation dtype contract differs")
        }
    }
    let fixturePolicy = options.syntheticProfile == "gemma-moe-w8" ? "w8g64" : "mixed-w4w8g64"
    guard let vocabulary = (model as? Gemma4Model)?.vocabularySize ?? (model as? Gemma4TextModel)?.vocabularySize else {
        throw ProbeError("Gemma constructor returned an unsupported model type")
    }
    return LoadedModel(family: .gemma4, model: model,
        label: options.synthetic ? "synthetic-gemma4-\(fixturePolicy)-seed-\(options.seed)" : options.modelDirectory!.lastPathComponent,
        configHash: sha256(data), vocabularySize: vocabulary,
        layerCount: gemma.layers, feedForwardKind: gemma.isMoE ? "moe" : "dense",
        embeddingActivationDType: String(describing: activation.dtype), ffnScaleDTypes: scales,
        parameterLayoutSHA256: layout, bf16ConversionEnabled: !options.synthetic
            && (ProcessInfo.processInfo.environment["DARKBLOOM_BF16_WEIGHTS"] ?? "1") == "1",
        directShardLoad: receipt, configurationData: data,
        partitionPlan: partitionRank == nil ? nil : plan, partitionStorage: storage)
}
