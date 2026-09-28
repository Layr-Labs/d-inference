import CryptoKit
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN

struct LoadedModel {
    let family: InferenceModelFamily
    let model: any LanguageModel
    let label: String
    let configHash: String
    let vocabularySize: Int
    let layerCount: Int
    let feedForwardKind: String
    let embeddingActivationDType: String
    let ffnScaleDTypes: [String]
    let parameterLayoutSHA256: String
    let bf16ConversionEnabled: Bool
    let directShardLoad: DirectShardLoadReceipt?
    let configurationData: Data
    let partitionPlan: ModelPartitionPlan?
    let partitionStorage: PartitionStorageCommitment?
    var gemmaTrace: GemmaBoundaryTrace? = nil
}

func loadModel(_ options: Options, partitionRank: Int? = nil,
               localCorrectnessInputs: LocalCorrectness.Inputs? = nil) throws -> LoadedModel {
    _qwen35MTPEnabled = false
    MLXRandom.seed(options.seed)
    let data: Data
    if options.localCorrectness {
        guard let localCorrectnessInputs, partitionRank != nil else {
            throw ProbeError("local-correctness requires admitted inputs and a partition rank")
        }
        // Reuse bounded preflight bytes. VerifiedCheckpoint subsequently binds
        // these bytes to the pinned manifest and the actual file descriptor.
        data = localCorrectnessInputs.configurationData
    } else if options.synthetic {
        data = try syntheticConfiguration(options: options)
    } else {
        data = try Data(contentsOf: options.modelDirectory!.appendingPathComponent("config.json"))
    }
    if options.localCorrectness {
        try LocalCorrectness.validateConfiguration(data, options: options, inputs: localCorrectnessInputs!)
    }
    if let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        let modelType = root["model_type"] as? String, ["gemma4", "gemma4_text"].contains(modelType) {
        guard options.ffnOutputPrecision == .native, options.mode != .qwenOutputCheck else {
            throw ProbeError("FFN output precision and output-narrowing checks currently require dense Qwen")
        }
        guard options.executionPath == .ordinary else {
            throw ProbeError("cbv2-contiguous currently requires a dense Qwen model")
        }
        return try loadGemmaModel(options, configurationData: data, partitionRank: partitionRank)
    }
    guard options.ffnBranchPrecision == .native else {
        throw ProbeError("Float32 FFN branch precision is currently supported only by the Gemma adapter")
    }
    guard let config = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        let modelType = config["model_type"] as? String,
        ["qwen3_5", "qwen3_5_text", "qwen3_5_moe", "qwen3_5_moe_text"].contains(modelType)
    else { throw ProbeError("Only Qwen3.5-family dense and MoE models are supported") }
    let text = config["text_config"] as? [String: Any] ?? config
    let isMoE = (text["num_experts"] as? Int ?? 0) > 0
    guard !isMoE || (options.ffnOutputPrecision == .native && options.mode != .qwenOutputCheck) else {
        throw ProbeError("FFN output precision and output-narrowing checks currently require dense Qwen")
    }
    guard options.executionPath == .ordinary || !isMoE else {
        throw ProbeError("cbv2-contiguous currently requires a dense Qwen model")
    }
    guard let vocabulary = text["vocab_size"] as? Int, vocabulary > 3,
        let layers = text["num_hidden_layers"] as? Int, layers > 0,
        let interval = text["full_attention_interval"] as? Int,
        interval > 1, layers >= interval
    else { throw ProbeError("Expected a hybrid Qwen configuration with valid dimensions") }
    let base = try JSONDecoder().decode(BaseConfiguration.self, from: data)
    guard let policy = base.perLayerQuantization else {
        throw ProbeError("An explicit affine W4/G64 quantization policy is required")
    }
    let plan = try partitionRank.map { _ in
        try QwenPartitionPlan(configuration: data, kind: options.partition,
                              attentionOutputPrecision: options.attentionOutputPrecision,
                              ffnOutputPrecision: options.ffnOutputPrecision)
    }
    let constructionData = options.synthetic ? data : plan?.constructionConfiguration ?? data
    var model = try constructQwenModel(constructionData)
    let directReceipt: DirectShardLoadReceipt?
    var storage: PartitionStorageCommitment? = nil
    if let partitionRank, !options.synthetic {
        guard let directory = options.modelDirectory, let plan else {
            throw ProbeError("Direct loading requires a saved checkpoint")
        }
        directReceipt = try loadDirectQwenPartition(model: model, directory: directory,
            originalConfiguration: data, policy: policy, rank: partitionRank, plan: plan,
            localCorrectness: options.localCorrectness,
            expectedAggregateSHA256: options.expectedArtifactAggregateSHA256)
        storage = directReceipt?.partitionStorage
    } else { directReceipt = nil }
    if directReceipt != nil {
        // All arrays already have independent, rank-local storage.
    } else if options.synthetic {
        quantize(model: model, groupSize: 64, bits: 4)
        if options.syntheticDType == "bfloat16" {
            // Match the primary 27B artifact's floating parameter policy, including
            // quantization metadata and A_log. The real 9B artifact keeps A_log F32;
            // this small fixture does not claim to reproduce every artifact profile.
            let parameters = model.parameters().flattened().map { name, value in
                (name, value.dtype == .float32 ? value.asType(.bfloat16) : value)
            }
            try model.update(parameters: ModuleParameters.unflattened(parameters),
                             verify: [.noUnusedKeys, .shapeMismatch])
        }
        model.freeze()
        eval(model)
        if let plan, let partitionRank {
            storage = try syntheticPartitionStorage(model, plan: .qwen(plan))
            model = try copySyntheticPartition(model, plan: plan, rank: partitionRank)
        }
    } else {
        try loadWeights(modelDirectory: options.modelDirectory!, model: model,
                        perLayerQuantization: policy)
        model.freeze()
    }
    // Validate baseline too: comparing different supported quantizations is not this probe's scope.
    let scaleTypes = try validatedQwenFeedForwardScaleTypes(model, layers: layers,
        isMoE: isMoE, requireTwoWaySplit: partitionRank == nil)
    guard let embedding = model.namedModules().first(where: {
        $0.0.hasSuffix(".embed_tokens")
    })?.1 as? Embedding else { throw ProbeError("Missing Qwen token embedding") }
    let activation = embedding(MLXArray([0]).reshaped(1, 1))
    eval(activation)
    if options.synthetic {
        guard String(describing: activation.dtype) == options.syntheticDType else {
            throw ProbeError("Synthetic embedding activation dtype differs from the requested profile")
        }
        for (name, value) in model.parameters().flattened() {
            guard value.dtype == .uint32 || String(describing: value.dtype) == options.syntheticDType else {
                throw ProbeError("Synthetic parameter dtype differs from the requested profile: \(name)")
            }
        }
    }
    let parameterLayout = modelParameterLayout(model)
    if let partitionRank, let storage {
        guard parameterLayout == storage.ranks[partitionRank].parameterLayoutSHA256 else {
            throw ProbeError("Qwen loaded layout differs from its partition commitment")
        }
    }
    let loaded = LoadedModel(
        family: .qwen35, model: model, label: options.synthetic ? "synthetic-qwen35-w4g64-seed-\(options.seed)"
            : options.modelDirectory!.lastPathComponent,
        configHash: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
        vocabularySize: vocabulary, layerCount: layers, feedForwardKind: isMoE ? "moe" : "dense",
        embeddingActivationDType: String(describing: activation.dtype),
        ffnScaleDTypes: scaleTypes, parameterLayoutSHA256: parameterLayout,
        bf16ConversionEnabled: !options.synthetic
            && (ProcessInfo.processInfo.environment["DARKBLOOM_BF16_WEIGHTS"] ?? "1") == "1",
        directShardLoad: directReceipt, configurationData: data, partitionPlan: plan.map(ModelPartitionPlan.qwen),
        partitionStorage: storage)
    if options.executionPath == .cbv2Contiguous {
        // Validate the promised path before worker readiness or rank workload
        // agreement. This inspects local metadata and empty caches only.
        _ = try CBv2RequestGeometry(loaded: loaded, maximumTokens: 1)
    }
    return loaded
}

func constructQwenModel(_ data: Data) throws -> any LanguageModel {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw ProbeError("Model configuration must be an object")
    }
    if object["model_type"] as? String == "qwen3_5_moe" {
        return Qwen35MoEModel(try JSONDecoder().decode(Qwen35Configuration.self, from: data))
    }
    if object["model_type"] as? String == "qwen3_5" {
        return Qwen35Model(try JSONDecoder().decode(Qwen35Configuration.self, from: data))
    }
    return Qwen35TextModel(try JSONDecoder().decode(Qwen35TextConfiguration.self, from: data))
}

private func copySyntheticPartition(_ source: Module, plan: QwenPartitionPlan, rank: Int) throws -> any LanguageModel {
    let target = try constructQwenModel(plan.constructionConfiguration)
    quantize(model: target, groupSize: 64, bits: 4)
    let expected = Dictionary(uniqueKeysWithValues: target.parameters().flattened().map { ($0.0, $0.1.shape) })
    let originals = source.parameters().flattened()
    guard Set(originals.map(\.0)) == Set(expected.keys) else { throw ProbeError("Synthetic partition keys differ") }
    for (name, value) in originals {
        let selected = try copySelectedTensor(value, selection: plan.selection(name: name, shape: value.shape, rank: rank))
        guard selected.shape == expected[name] else { throw ProbeError("Synthetic partition shape mismatch: \(name)") }
        try target.update(parameters: ModuleParameters.unflattened([name: selected]), verify: [.noUnusedKeys, .shapeMismatch])
    }
    target.freeze(); eval(target)
    return target
}

func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func promptTokens(options: Options, vocabularySize: Int) throws -> [Int] {
    let tokens: [Int]
    if let file = options.tokensFile {
        tokens = try JSONDecoder().decode([Int].self, from: Data(contentsOf: file))
    } else {
        tokens = (0..<options.promptCount).map {
            3 + (($0 * 17 + Int(options.seed % UInt64(vocabularySize - 3))) % (vocabularySize - 3))
        }
    }
    guard !tokens.isEmpty, tokens.allSatisfy({ (0..<vocabularySize).contains($0) }) else {
        throw ProbeError("Prompt must contain valid, nonempty token IDs")
    }
    return tokens
}

func teacherTokens(options: Options, vocabularySize: Int) throws -> [Int]? {
    guard let file = options.teacherTokensFile else { return nil }
    let tokens = try JSONDecoder().decode([Int].self, from: Data(contentsOf: file))
    guard tokens.count == options.decodeCount - 1,
        tokens.allSatisfy({ (0..<vocabularySize).contains($0) })
    else { throw ProbeError("Teacher tokens must contain exactly decode-tokens minus one valid IDs") }
    return tokens
}

func agreementFingerprint(_ data: Data) -> [Int32] {
    let digest = Array(SHA256.hash(data: data))
    return stride(from: 0, to: digest.count, by: 2).map {
        Int32(digest[$0]) * 256 + Int32(digest[$0 + 1])
    }
}
