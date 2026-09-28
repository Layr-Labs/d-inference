import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN

/// Reusable saved tiny fixture. Construction/evaluation happens only when the
/// root native self-check calls this initializer under its MLX error scope.
/// Load baseline and stages before deleting this owned directory; later session
/// checks consume resident arrays and need no checkpoint files.
struct QwenLayerStageFixture {
    let directory: URL
    let savedOptions: Options
    let baseline: LoadedModel
    let fixture: LoaderFixture
    let plan: QwenLayerStagePlan
    let syntheticDType: String
    let wrapped: Bool
    let fp16FFNMetadata: Bool

    init(options: Options, directory: URL, fp16FFNMetadata: Bool,
         wrapped: Bool = false, prefillProfile: QwenLayerStagePrefillProfile? = nil,
         check: () throws -> Void = {}) throws {
        guard !FileManager.default.fileExists(atPath: directory.path),
              options.seed == 7, options.syntheticProfile == "tiny",
              ["float32", "bfloat16"].contains(options.syntheticDType),
              options.attentionOutputPrecision == .native,
              options.ffnOutputPrecision == .native, options.ffnBranchPrecision == .native else {
            throw ProbeError("Layer-stage fixture requires a new owned directory, seed 7, tiny F32/BF16, and native arithmetic")
        }
        let generated = try makeQwenLayerStageSyntheticModel(options: options, wrapped: wrapped,
            prefillProfile: prefillProfile, check: check)
        let fixture = try writeLoaderFixture(generated, directory: directory, fp16FFNMetadata: fp16FFNMetadata)
        try check()
        guard fixture.sourceTensorCount == 237, fixture.parameters.count == 237,
              fixture.sourcePartsPerTensor.values.allSatisfy({ $0 == 1 }),
              fixture.fp16MetadataTensorCount == (fp16FFNMetadata ? 124 : 0) else {
            throw ProbeError("Tiny layer-stage checkpoint did not preserve its complete dense tensor fixture")
        }
        var savedOptions = options
        savedOptions.synthetic = false
        savedOptions.modelDirectory = directory
        savedOptions.mode = .baseline
        savedOptions.localCorrectness = false
        savedOptions.executionPath = .cbv2Contiguous
        let baseline = try loadModel(savedOptions)
        try check()
        guard baseline.configurationData == generated.configurationData,
              baseline.layerCount == 8, baseline.feedForwardKind == "dense",
              baseline.partitionPlan == nil, baseline.directShardLoad == nil,
              baseline.embeddingActivationDType == options.syntheticDType else {
            throw ProbeError("Ordinary saved stage-fixture baseline changed configuration or activation dtype")
        }
        if fp16FFNMetadata {
            guard baseline.bf16ConversionEnabled else {
                throw ProbeError("F16 stage fixture requires the ordinary F16-to-BF16 loader policy")
            }
            let actual = Dictionary(uniqueKeysWithValues: baseline.model.parameters().flattened())
            guard fixture.parameters.filter({ $0.value.dtype == .float16 }).allSatisfy({
                actual[$0.key]?.dtype == .bfloat16
            }) else { throw ProbeError("Ordinary fixture reload did not convert every stored F16 metadata tensor") }
        }
        self.directory = directory
        self.savedOptions = savedOptions
        self.baseline = baseline
        self.fixture = fixture
        self.plan = try QwenLayerStagePlan(configuration: baseline.configurationData, ranges: [0..<4, 4..<8])
        self.syntheticDType = options.syntheticDType
        self.wrapped = wrapped
        self.fp16FFNMetadata = fp16FFNMetadata
    }
}

/// Produces ordinary LoadedModel metadata for the existing writeLoaderFixture.
/// The default retains the existing tiny8/interval4 bytes. The explicit tiny12
/// case supports the separate unequal-cut check; both keep interval4. This does
/// not call loadModel(synthetic:) because that entry preserves its 4-layer
/// historical configuration. No transformer forward or prompt decoding occurs here.
func makeQwenLayerStageSyntheticModel(options: Options, wrapped: Bool,
    prefillProfile: QwenLayerStagePrefillProfile? = nil, layerCount: Int = 8, check: () throws -> Void = {}
) throws -> LoadedModel {
    guard options.seed == 7, options.syntheticProfile == "tiny", [8, 12].contains(layerCount),
          layerCount == 8 || prefillProfile == nil,
          ["float32", "bfloat16"].contains(options.syntheticDType),
          var text = try JSONSerialization.jsonObject(with: syntheticConfiguration(options: options)) as? [String: Any]
    else { throw ProbeError("Unsupported layer-stage synthetic fixture options") }
    if let prefillProfile {
        // The explicit profiled fixture reserves the first output position too.
        // Omitting the profile preserves every byte of the historical fixture.
        text["max_position_embeddings"] = prefillProfile.maximumPromptCount + 1
        text["cluster_fixture_profile"] = "tiny-" + prefillProfile.rawValue
    }
    if layerCount == 12 { text["cluster_fixture_profile"] = "tiny-layer-stage-12x4" }
    text["num_hidden_layers"] = layerCount
    text["full_attention_interval"] = 4
    text["layer_types"] = (0..<layerCount).map { ($0 + 1) % 4 == 0 ? "full_attention" : "linear_attention" }
    let root: [String: Any]
    if wrapped {
        guard let quantization = text.removeValue(forKey: "quantization") else {
            throw ProbeError("Tiny fixture lost its explicit quantization")
        }
        root = ["model_type": "qwen3_5", "text_config": text, "quantization": quantization]
    } else { root = text }
    let configuration = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    let plan = try QwenLayerStagePlan(configuration: configuration, ranges: [0..<4, 4..<layerCount])
    _qwen35MTPEnabled = false
    MLXRandom.seed(7)
    let model = try constructQwenModel(configuration)
    quantize(model: model, groupSize: 64, bits: 4)
    if options.syntheticDType == "bfloat16" {
        let parameters = model.parameters().flattened().map { name, array in
            (name, array.dtype == .float32 ? array.asType(.bfloat16) : array)
        }
        try model.update(parameters: ModuleParameters.unflattened(parameters), verify: [.noUnusedKeys, .shapeMismatch])
    }
    model.freeze()
    eval(model)
    try check()
    let parameters = model.parameters().flattened()
    _ = try plan.parameters(canonicalSourceNames: parameters.map { $0.0 })
    guard (layerCount != 8 || parameters.count == 237), parameters.allSatisfy({
        $0.1.dtype == .uint32 || String(describing: $0.1.dtype) == options.syntheticDType
    }), let embedding = model.namedModules().first(where: { $0.0.hasSuffix(".embed_tokens") })?.1 as? Embedding else {
        throw ProbeError("Generated stage fixture changed its full canonical tensor dtype/inventory")
    }
    let activation = embedding(MLXArray([0]).reshaped(1, 1))
    eval(activation)
    try check()
    guard String(describing: activation.dtype) == options.syntheticDType else {
        throw ProbeError("Generated stage fixture embedding dtype differs")
    }
    let scales = try validatedQwenFeedForwardScaleTypes(model, layers: layerCount, isMoE: false, requireTwoWaySplit: true)
    return LoadedModel(family: .qwen35, model: model,
        label: "synthetic-qwen35-layer-stage-\(layerCount)x4-seed-7-" + options.syntheticDType + (wrapped ? "-wrapped" : "-direct"),
        configHash: sha256(configuration), vocabularySize: 512, layerCount: layerCount, feedForwardKind: "dense",
        embeddingActivationDType: String(describing: activation.dtype), ffnScaleDTypes: scales,
        parameterLayoutSHA256: modelParameterLayout(model), bf16ConversionEnabled: false,
        directShardLoad: nil, configurationData: configuration, partitionPlan: nil, partitionStorage: nil)
}
