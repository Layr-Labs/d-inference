// Copyright © 2026 Eigen Labs.

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
import MLXVLM
import Testing

@testable import ProviderCore

private func qwenTargetFixtureJSON(
    modelType: String = "qwen3_5_moe",
    mtpLayers: Int = 1,
    fullAttentionInterval: Int = 1
) -> Data {
    Data(
        """
        {
          "model_type": "\(modelType)",
          "mtp_num_hidden_layers": \(mtpLayers),
          "text_config": {
            "model_type": "qwen3_5_text",
            "hidden_size": 64,
            "num_hidden_layers": 2,
            "intermediate_size": 128,
            "num_attention_heads": 1,
            "num_key_value_heads": 1,
            "head_dim": 64,
            "linear_num_value_heads": 1,
            "linear_num_key_heads": 1,
            "linear_key_head_dim": 64,
            "linear_value_head_dim": 64,
            "linear_conv_kernel_dim": 4,
            "vocab_size": 64,
            "full_attention_interval": \(fullAttentionInterval),
            "num_experts": 0,
            "num_experts_per_tok": 0,
            "mtp_num_hidden_layers": \(mtpLayers)
          },
          "vision_config": {
            "model_type": "\(modelType)",
            "depth": 1,
            "hidden_size": 64,
            "intermediate_size": 128,
            "out_hidden_size": 64,
            "num_heads": 1,
            "patch_size": 16,
            "spatial_merge_size": 1,
            "temporal_patch_size": 1,
            "num_position_embeddings": 8
          }
        }
        """.utf8)
}

private func qwenTargetFixtureDirectory(configData: Data) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("qwen-target-extraction-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try configData.write(to: directory.appendingPathComponent("config.json"))
    return directory
}

private struct QwenExtractionProcessorError: Error {}

private struct QwenExtractionProcessor: UserInputProcessor {
    func prepare(input: UserInput) async throws -> LMInput {
        throw QwenExtractionProcessorError()
    }
}

private final class QwenPrefixCacheConstructionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0

    func record() { lock.withLock { _calls += 1 } }
    var calls: Int { lock.withLock { _calls } }
}

@Suite("Qwen VLM target-only extraction", .serialized)
struct QwenVLMTargetExtractionTests {
    @Test("Qwen config decodes through MLXLLM and target skeleton omits inline MTP")
    func qwenConfigBuildsTargetOnlySkeleton() throws {
        let previousMTPState = _qwen35MTPEnabled
        _qwen35MTPEnabled = true
        defer { _qwen35MTPEnabled = previousMTPState }
        let config = try EngineV2VLMTextExtraction.decodeQwenConfiguration(
            configData: qwenTargetFixtureJSON(mtpLayers: 1))
        let target = Qwen35MoEModel(config)

        #expect(target.parameters().flattened().contains { $0.0.contains("mtp.") } == false)
        #expect(target.vocabularySize == 64)
    }

    @Test("Qwen wrapper dispatches to a strict, weight-sharing MLXLLM target")
    func qwenWrapperDispatchAndStrictUpdate() throws {
        let configData = qwenTargetFixtureJSON(mtpLayers: 1)
        let wrapperConfig = try JSONDecoder.json5().decode(
            MLXVLM.Qwen35Configuration.self, from: configData)
        let wrapper = MLXVLM.Qwen35MoE(wrapperConfig)
        let directory = try qwenTargetFixtureDirectory(configData: configData)
        defer { try? FileManager.default.removeItem(at: directory) }

        let extraction = try EngineV2VLMTextExtraction.extractTextModel(
            from: wrapper,
            modelDirectory: directory,
            environment: [EngineV2VLMTextExtraction.parityCheckFlag: "0"])

        #expect(extraction.family == .qwen35MoE)
        #expect(extraction.servingModel is Qwen35MoEModel)
        #expect(extraction.parityMaxAbsLogitDiff == nil)
        #expect(
            extraction.servingModel.parameters().flattened().contains {
                $0.0.hasPrefix("vision_tower.") || $0.0.hasPrefix("mtp.")
            } == false)
        let sourceParameters = Dictionary(
            uniqueKeysWithValues: wrapper.parameters().flattened().filter {
                $0.0.hasPrefix("language_model.")
            })
        for (key, targetArray) in extraction.servingModel.parameters().flattened() {
            let sourceArray = try #require(sourceParameters[key], "missing source array for \(key)")
            // Module.update keeps the target's Swift MLXArray wrapper stable and
            // repoints its core array context via _updateInternal. Object identity
            // is therefore intentionally different even though no tensor payload
            // is copied. The mapping test below pins source-handle identity before
            // update; this loop pins the strict installed parameter set.
            #expect(targetArray.shape == sourceArray.shape, "shape drift for \(key)")
            #expect(targetArray.dtype == sourceArray.dtype, "dtype drift for \(key)")
            #expect(
                MLX.all(targetArray .== sourceArray).item(Bool.self),
                "installed value drift for \(key)")
        }
    }

    @Test("Qwen key mapping retains only live language target arrays")
    func qwenTargetKeyMapping() throws {
        let config = try EngineV2VLMTextExtraction.decodeQwenConfiguration(
            configData: qwenTargetFixtureJSON())
        let target = Qwen35MoEModel(config)
        let language = MLXArray([Float(1), Float(2)])
        let mapped = EngineV2VLMTextExtraction.reKeyedQwenTargetWeights(
            flattenedWeights: [
                ("language_model.model.norm.weight", language),
                ("mtp.norm.weight", MLXArray([Float(3)])),
                ("vision_tower.blocks.0.weight", MLXArray([Float(4)])),
            ],
            sanitizer: target)

        #expect(mapped.keys.sorted() == ["language_model.model.norm.weight"])
        #expect(mapped["language_model.model.norm.weight"] === language)
        #expect(mapped["language_model.model.norm.weight"]?.asArray(Float.self) == [1, 2])
    }

    @Test("Qwen mixed quantization lookup uses the undoubled wrapper path")
    func qwenMixedQuantizationSelection() throws {
        let defaultQuantization = BaseConfiguration.Quantization(groupSize: 64, bits: 4)
        let override = BaseConfiguration.Quantization(groupSize: 32, bits: 8)
        let table = BaseConfiguration.PerLayerQuantization(
            quantization: defaultQuantization,
            perLayerQuantization: [
                "language_model.model.layers.1.self_attn.q_proj": .quantize(override),
                "language_model.model.layers.0.linear_attn.in_proj_qkv": .skip,
            ])

        let qwenOverride = EngineV2VLMTextExtraction.quantization(
            targetPath: "language_model.model.layers.1.self_attn.q_proj",
            family: .qwen35MoE,
            perLayerQuantization: table)
        #expect(qwenOverride?.groupSize == 32)
        #expect(qwenOverride?.bits == 8)
        #expect(
            EngineV2VLMTextExtraction.quantization(
                targetPath: "language_model.model.layers.0.linear_attn.in_proj_qkv",
                family: .qwen35MoE,
                perLayerQuantization: table) == nil)
        #expect(
            EngineV2VLMTextExtraction.quantization(
                targetPath: "language_model.lm_head",
                family: .qwen35MoE,
                perLayerQuantization: table)?.bits == 4)

    }

    @Test("Qwen skeleton reproduces default, override, and skipped quantized modules")
    func qwenMixedQuantizationStructure() throws {
        let config = try EngineV2VLMTextExtraction.decodeQwenConfiguration(
            configData: qwenTargetFixtureJSON(fullAttentionInterval: 1))
        let target = Qwen35MoEModel(config)
        let overridePath = "language_model.model.layers.0.self_attn.q_proj"
        let skippedPath = "language_model.model.layers.1.self_attn.q_proj"
        let defaultPath = "language_model.lm_head"
        let table = BaseConfiguration.PerLayerQuantization(
            quantization: .init(groupSize: 64, bits: 4),
            perLayerQuantization: [
                overridePath: .quantize(.init(groupSize: 32, bits: 8)),
                skippedPath: .skip,
            ])

        try EngineV2VLMTextExtraction.applyQuantizationStructure(
            skeleton: target,
            weights: [
                "\(overridePath).scales": MLXArray.ones([1]),
                "\(skippedPath).scales": MLXArray.ones([1]),
                "\(defaultPath).scales": MLXArray.ones([1]),
            ],
            family: .qwen35MoE,
            perLayerQuantization: table)

        let override = try #require(
            target.namedModules().first { $0.0 == overridePath }?.1 as? QuantizedLinear)
        #expect(override.groupSize == 32)
        #expect(override.bits == 8)
        #expect(
            (target.namedModules().first { $0.0 == skippedPath }?.1 is QuantizedLinear)
                == false)
        let defaultModule = try #require(
            target.namedModules().first { $0.0 == defaultPath }?.1 as? QuantizedLinear)
        #expect(defaultModule.groupSize == 64)
        #expect(defaultModule.bits == 4)
    }

    @Test("dense Qwen wrapper dispatches to the shared CBv2 target seam")
    func denseQwenWrapperDispatches() throws {
        let configData = qwenTargetFixtureJSON(modelType: "qwen3_5")
        let wrapperConfig = try JSONDecoder.json5().decode(
            MLXVLM.Qwen35Configuration.self, from: configData)
        let directory = try qwenTargetFixtureDirectory(configData: configData)
        defer { try? FileManager.default.removeItem(at: directory) }

        let extraction = try EngineV2VLMTextExtraction.extractTextModel(
            from: MLXVLM.Qwen35(wrapperConfig),
            modelDirectory: directory,
            environment: [EngineV2VLMTextExtraction.parityCheckFlag: "0"])

        #expect(extraction.family == .qwen35Dense)
        #expect(extraction.servingModel is Qwen35Model)
        #expect((extraction.servingModel is Qwen35MoEModel) == false)
        #expect(extraction.parityMaxAbsLogitDiff == nil)
    }

    @Test("benchmark resolution uses the same extracted Qwen target")
    func benchmarkServingModelUsesQwenExtraction() throws {
        let configData = qwenTargetFixtureJSON()
        let wrapperConfig = try JSONDecoder.json5().decode(
            MLXVLM.Qwen35Configuration.self, from: configData)
        let directory = try qwenTargetFixtureDirectory(configData: configData)
        defer { try? FileManager.default.removeItem(at: directory) }

        let serving = try EngineV2Factory.benchmarkServingModel(
            model: MLXVLM.Qwen35MoE(wrapperConfig),
            isVLM: true,
            modelDirectory: directory,
            environment: [EngineV2VLMTextExtraction.parityCheckFlag: "0"])
        #expect(serving is Qwen35MoEModel)
    }

    @Test("production factory accepts dense and MoE through one Qwen target seam")
    func factoryAcceptance() throws {
        let config = try EngineV2VLMTextExtraction.decodeQwenConfiguration(
            configData: qwenTargetFixtureJSON(fullAttentionInterval: 2))
        let target = Qwen35MoEModel(config)
        let prepared = try EngineV2Factory.prepareProductionBackend(
            model: target,
            kvBytesCapacity: 1 << 20,
            maxConcurrentRequests: 2,
            kvBackend: EngineV2KVBackendSelection.contiguous)

        #expect(prepared.kind == EngineV2KVBackendKind.contiguous)
        #expect(prepared.layerKinds.count == 1)
        #expect(prepared.layerKinds.first?.modelLayerIndex == 1)
        #expect(prepared.modelCapabilities.supportsPrefixReuse == false)
        #expect(EngineV2Factory.adoptionBoundTokens(model: target) == 0)

        let dense = try EngineV2Factory.prepareProductionBackend(
            model: Qwen35Model(config),
            kvBytesCapacity: 1 << 20,
            maxConcurrentRequests: 2,
            kvBackend: EngineV2KVBackendSelection.contiguous)
        #expect(dense.layerKinds == prepared.layerKinds)
        #expect(dense.modelCapabilities == prepared.modelCapabilities)
    }

    @Test("Qwen core capability veto forces paged selection to contiguous before preflight")
    func pagedCapabilityVeto() throws {
        let config = try EngineV2VLMTextExtraction.decodeQwenConfiguration(
            configData: qwenTargetFixtureJSON(fullAttentionInterval: 2))
        var preflightCalled = false
        let prepared = try EngineV2Factory.prepareProductionBackend(
            model: Qwen35MoEModel(config),
            kvBytesCapacity: 1 << 20,
            maxConcurrentRequests: 2,
            kvBackend: EngineV2KVBackendSelection.paged,
            pagedPreflightOverride: { _ in preflightCalled = true })

        #expect(prepared.kind == EngineV2KVBackendKind.contiguous)
        #expect(prepared.fallbackReason == "model_capability")
        #expect(preflightCalled == false)
    }

    @Test("Qwen recurrent target never constructs or retains an SSD prefix cache")
    func recurrentTargetSkipsPrefixCacheConstruction() async throws {
        let config = try EngineV2VLMTextExtraction.decodeQwenConfiguration(
            configData: qwenTargetFixtureJSON(fullAttentionInterval: 2))
        let target = Qwen35MoEModel(config)
        let tokenizer = StubBridgeTokenizer()
        let container = ModelContainer(
            context: ModelContext(
                configuration: ModelConfiguration(id: "tiny/qwen"),
                model: target,
                processor: QwenExtractionProcessor(),
                tokenizer: tokenizer))
        let prepared = EngineV2PreparedModel(
            snapshot: EngineV2ModelSnapshot(
                model: target, eosTokenIds: [1], extraEOSTokens: []),
            servingModel: target,
            assistant: nil,
            mtpStatus: .disabled(.configDisabled, configured: false),
            mtpArtifact: nil)
        let probe = QwenPrefixCacheConstructionProbe()

        let bundle = try await EngineV2SlotFactory.makeProductionBundle(
            modelId: "tiny-qwen",
            modelType: "qwen3_5_moe",
            isVLM: false,
            modelDirectory: nil,
            container: container,
            tokenizer: TokenizerHandle(tokenizer),
            sizing: SlotSizingSnapshot(
                weightsBytes: 1,
                fp16KVBytesPerToken: 256,
                maxContextLength: 2_048,
                defaultMaxTokens: 32),
            kvBytesCapacity: 8 << 20,
            maxConcurrentRequests: 2,
            kvBudget: nil,
            weightHash: String(repeating: "a", count: 64),
            specDecPreparation: .init(
                artifact: nil,
                status: .disabled(.configDisabled, configured: false)),
            preparedModel: prepared,
            assemblyOverrides: .init(
                promptContractID: "tiny-qwen-contract",
                makePrefixCache: { _, _ in
                    probe.record()
                    return nil
                }),
            environment: ["DARKBLOOM_PREFIX_CACHE": "1"])

        #expect(probe.calls == 0)
        #expect(bundle.bridge.ssdPrefixCache == nil)
        let status = bundle.bridge.prefixCacheModelStatus()
        #expect(status.state == .disabled)
        #expect(status.reason == .unsupportedLayout)
        await bundle.bridge.shutdown()
    }

    @Test("Qwen VLM sizing counts only full-attention KV rows")
    func qwenSizingUsesCompactAttentionLayout() throws {
        let configData = qwenTargetFixtureJSON(fullAttentionInterval: 2)
        let directory = try qwenTargetFixtureDirectory(configData: configData)
        defer { try? FileManager.default.removeItem(at: directory) }

        // One of two layers owns attention KV: 2(K+V) * 1 head * 64 dim * 2-byte fp16.
        #expect(SlotSizingSnapshot.qwenVLMTextKVRate(modelDirectory: directory) == 256)
    }

    @Test("production Qwen config sizes attention KV and fixed recurrent residency separately")
    func productionQwenSizingFacts() throws {
        var text: [String: Any] = [
            "model_type": "qwen3_5_moe",
            "hidden_size": 2048,
            "num_hidden_layers": 40,
            "num_attention_heads": 16,
            "num_key_value_heads": 2,
            "head_dim": 256,
            "linear_num_value_heads": 32,
            "linear_num_key_heads": 16,
            "linear_key_head_dim": 128,
            "linear_value_head_dim": 128,
            "linear_conv_kernel_dim": 4,
            "vocab_size": 248_320,
            "full_attention_interval": 4,
        ]
        text["num_experts"] = 256
        text["num_experts_per_tok"] = 8
        let data = try JSONSerialization.data(withJSONObject: [
            "model_type": "qwen3_5_moe",
            "text_config": text,
        ])
        let config = try EngineV2VLMTextExtraction.decodeQwenTextConfiguration(
            configData: data)

        #expect(config.cbv2LayerKinds.count == 10)
        #expect(
            SlotSizingSnapshot.fp16KVBytesPerToken(layerKinds: config.cbv2LayerKinds)
                == 20_480)
        #expect(try config.cbv2RecurrentStateSpec().fixedBytesPerRequest() == 64_389_120)
        #expect(try config.cbv2RecurrentStateSpec().peakBytesPerRequest() == 193_167_360)
    }

    @Test("Qwen3.8 dense topology derives measured KV and recurrent residency")
    func qwen38DenseSizingFacts() throws {
        let text: [String: Any] = [
            "model_type": "qwen3_5_text",
            "hidden_size": 5_120,
            "num_hidden_layers": 64,
            "num_attention_heads": 24,
            "num_key_value_heads": 4,
            "head_dim": 256,
            "linear_num_value_heads": 48,
            "linear_num_key_heads": 16,
            "linear_key_head_dim": 128,
            "linear_value_head_dim": 128,
            "linear_conv_kernel_dim": 4,
            "vocab_size": 248_320,
            "full_attention_interval": 4,
            "max_position_embeddings": 262_144,
            "mtp_num_hidden_layers": 1,
        ]
        let data = try JSONSerialization.data(withJSONObject: [
            "model_type": "qwen3_5",
            "text_config": text,
        ])
        let config = try EngineV2VLMTextExtraction.decodeQwenTextConfiguration(
            configData: data)

        #expect(config.cbv2LayerKinds.count == 16)
        #expect(
            SlotSizingSnapshot.fp16KVBytesPerToken(layerKinds: config.cbv2LayerKinds)
                == 65_536)
        #expect(try config.cbv2RecurrentStateSpec().fixedBytesPerRequest() == 153_944_064)
        #expect(try config.cbv2RecurrentStateSpec().peakBytesPerRequest() == 461_832_192)
    }

    @Test("Qwen is advertised after target, vision, MTP, and cleanup canaries pass")
    func allowlistIsOpen() {
        #expect(EngineV2SupportedModels.isSupported(modelType: "qwen3_5"))
        #expect(EngineV2SupportedModels.isSupported(modelType: " QWEN3_5 "))
        #expect(EngineV2SupportedModels.isSupported(modelType: "qwen3_5_moe"))
        #expect(EngineV2SupportedModels.isSupported(modelType: " QWEN3_5_MOE "))
    }
}
