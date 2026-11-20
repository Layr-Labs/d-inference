import Foundation
import MLX
@_spi(Cluster) import MLXLLM
import MLXLMCommon
import MLXNN

/// Test-only fabricated weights and metadata. Never a registered source receipt.
enum MTPTinyModel {
    static let width = 64, vocabulary = 128

    static func configuration(layers: Int = 8, mtpLayers: Int = 1) throws -> Data {
        let text: [String: Any] = ["model_type": "qwen3_5_text", "hidden_size": width,
            "num_hidden_layers": layers, "intermediate_size": 128, "num_attention_heads": 1,
            "num_key_value_heads": 1, "linear_num_value_heads": 1, "linear_num_key_heads": 1,
            "linear_key_head_dim": 32, "linear_value_head_dim": 32, "linear_conv_kernel_dim": 4,
            "vocab_size": vocabulary, "head_dim": 64, "full_attention_interval": 4,
            "num_experts": 0, "num_experts_per_tok": 0, "mtp_num_hidden_layers": mtpLayers,
            "tie_word_embeddings": false, "max_position_embeddings": 32768,
            "mtplx_mtp": ["included": true, "prefix": "mtp.", "block_size": 3],
            "mtplx_mtp_quantization": ["group_size": 64, "bits": 4, "mode": "affine"]]
        return try JSONSerialization.data(withJSONObject: text, options: [.sortedKeys])
    }

    static func target(check: () throws -> Void) throws -> LoadedQwenLayerStage {
        let configuration = try Self.configuration()
        let plan = try QwenLayerStagePlan(configuration: configuration, ranges: [0..<4, 4..<8])
        let stage = plan.stages[1], model = try constructQwenModel(stage.constructionConfiguration)
        let values = model.parameters().flattened().sorted { $0.0 < $1.0 }.map { name, old -> (String, MLXArray) in
            let salt = name.utf8.reduce(0) { ($0 + Int($1)) % 31 }
            let data = (0..<old.size).map { i -> Float in
                if name.hasSuffix("A_log") { return -1 }
                if name.contains("norm") { return 1 + Float((i + salt) % 5) * 0.02 }
                return Float((i + salt) % 17 - 8) * 0.003
            }
            return (name, MLXArray(data).reshaped(old.shape))
        }
        try model.update(parameters: ModuleParameters.unflattened(values), verify: [.all])
        let inert = try installQwenStageInertParameters(model: model, stage: stage,
            hiddenSize: width, activationDType: .float32)
        model.freeze(); eval(model); try check()
        let layout = modelParameterLayout(model), fake = sha256(Data("fabricated-tiny-MTP-source".utf8))
        let bytes = model.parameters().flattened().reduce(0) { $0 + $1.1.nbytes }
        let storage = QwenLayerStageStorageCommitment(schemaVersion: 1, verifiedAggregateSHA256: fake,
            sourceConfigurationSHA256: sha256(configuration), planSHA256: plan.fingerprint,
            sourceTensorManifestSHA256: fake, sourceModelTensorBytes: bytes, largestSourceTensorBytes: bytes,
            sourceTensorCount: values.count, canonicalTensorCount: values.count,
            bf16ConversionEnabled: false, stages: [])
        let receipt = QwenLayerStageLoadReceipt(schemaVersion: 1, stageIndex: 1,
            verifiedAggregateSHA256: fake, sourceConfigurationSHA256: sha256(configuration),
            constructionConfigurationSHA256: sha256(stage.constructionConfiguration),
            planSHA256: plan.fingerprint, stagePlanSHA256: stage.fingerprint,
            sourceTensorManifestSHA256: fake, sourceParameterLayoutSHA256: layout,
            parameterLayoutSHA256: layout, activeParameterLayoutSHA256: layout, activeMappingSHA256: fake,
            embeddingActivationDType: "float32", bf16ConversionEnabled: false,
            sourceModelTensorBytes: bytes, loadedTensorBytes: bytes, largestHostTensorBytes: bytes,
            activeTensors: [], inertModules: inert, inertTensorBytes: width * 4,
            storageCommitment: storage, storageCommitmentSHA256: sha256(try canonicalJSONData(storage)),
            selectedPayloadReadAccounting: nil)
        return .init(model: model, plan: plan, stageIndex: 1, receipt: receipt,
            activationDType: .float32, vocabularySize: vocabulary)
    }

    static func assistant(target: LoadedQwenLayerStage, check: () throws -> Void) throws -> Qwen35InlineMTPAssistant {
        let embedding = Embedding(weight: MLXArray((0..<(vocabulary * width)).map {
            Float(($0 * 7) % 29 - 14) * 0.004
        }).reshaped([vocabulary, width]))
        var names: Set<String> = ["pre_fc_norm_hidden.weight", "pre_fc_norm_embedding.weight", "norm.weight",
            "layers.0.input_layernorm.weight", "layers.0.post_attention_layernorm.weight",
            "layers.0.self_attn.q_norm.weight", "layers.0.self_attn.k_norm.weight"]
        for module in ["fc", "layers.0.self_attn.q_proj", "layers.0.self_attn.k_proj",
            "layers.0.self_attn.v_proj", "layers.0.self_attn.o_proj", "layers.0.mlp.gate_proj",
            "layers.0.mlp.up_proj", "layers.0.mlp.down_proj"] {
            for suffix in ["weight", "scales", "biases"] { names.insert(module + "." + suffix) }
        }
        let text = try JSONSerialization.jsonObject(with: configuration()) as! [String: Any]
        let assistantConfiguration = try JSONSerialization.data(withJSONObject: [
            "model_type": "qwen3_5", "text_config": text,
            "mtplx_mtp": text["mtplx_mtp"]!,
            "mtplx_mtp_quantization": text["mtplx_mtp_quantization"]!
        ], options: [.sortedKeys])
        return try Qwen35InlineMTPAssistant.loadVerifiedInline(configuration: assistantConfiguration,
            target: target.model, inputEmbedding: embedding, parameterNames: names, verificationMode: .serialTarget,
            read: { name, shape, dtype in
                let count = shape.reduce(1, *)
                if dtype == .uint32 {
                    return MLXArray((0..<count).map { UInt32(0x76543210) &+ UInt32($0 % 2) * 0x11111111 }).reshaped(shape)
                }
                let base: Float = name.hasSuffix("scales") ? 0.015 : (name.hasSuffix("biases") ? -0.08 : 1)
                return MLXArray((0..<count).map { base + Float($0 % 3) * 0.001 }).reshaped(shape).asType(.bfloat16)
            }, check: check)
    }
}
