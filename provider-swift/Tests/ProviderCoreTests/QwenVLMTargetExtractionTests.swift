// Copyright © 2026 Eigen Labs.

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
import MLXRunners
import MLXVLM
import Testing

@testable import ProviderCore

private func qwenTargetFixtureJSON(
    mtpLayers: Int = 1,
    fullAttentionInterval: Int = 1
) -> Data {
    Data(
        """
        {
          "model_type": "qwen3_5_moe",
          "mtp_num_hidden_layers": \(mtpLayers),
          "text_config": {
            "model_type": "qwen3_5_moe",
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
            "model_type": "qwen3_5_moe",
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

private func qwen3VLMoEFixture() throws -> MLXVLM.Qwen3VL {
    let data = Data(
        """
        {
          "model_type": "qwen3_vl_moe",
          "text_config": {
            "model_type": "qwen3_vl_moe_text",
            "hidden_size": 8,
            "intermediate_size": 16,
            "num_hidden_layers": 1,
            "num_attention_heads": 1,
            "num_key_value_heads": 1,
            "head_dim": 8,
            "max_position_embeddings": 64,
            "vocab_size": 32,
            "num_experts": 4,
            "num_experts_per_tok": 2,
            "decoder_sparse_step": 1,
            "mlp_only_layers": [],
            "moe_intermediate_size": 4,
            "norm_topk_prob": true
          },
          "vision_config": {
            "model_type": "qwen3_vl_moe",
            "depth": 1,
            "hidden_size": 8,
            "hidden_act": "gelu_pytorch_tanh",
            "intermediate_size": 16,
            "out_hidden_size": 8,
            "num_heads": 1,
            "patch_size": 2,
            "spatial_merge_size": 1,
            "temporal_patch_size": 1,
            "num_position_embeddings": 8,
            "deepstack_visual_indexes": []
          }
        }
        """.utf8)
    return MLXVLM.Qwen3VL(
        try JSONDecoder().decode(MLXVLM.Qwen3VLConfiguration.self, from: data))
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


/// Adopt a fixture module through the registry, the way the serving path
/// does: a directory holding only `config.json`, and no tensors read.
private func adoptFixture(
    _ model: any LanguageModel, modelType: String
) throws -> any Runner {
    let directory = try makeCheckpointDirectory(modelType: modelType)
    return try EngineV2Factory.adoptRunner(
        model: model,
        tokenizer: StubBridgeTokenizer(),
        modelDirectory: directory,
        options: EngineV2Factory.runnerLoadOptions(
            modelDirectory: directory,
            kvBytesCapacity: 0,
            maxSequenceLength: 2048))
}


/// Decode the fixture's TEXT configuration the way MLXLLM does. The
/// extraction that used to live in the provider now belongs to the fork, and
/// its decoder is internal there; these provider-side tests only need a
/// configuration object to build a fixture module from.
private func decodeQwenTargetConfiguration(
    _ configData: Data
) throws -> MLXLLM.Qwen35Configuration {
    let object = try JSONSerialization.jsonObject(with: configData) as? [String: Any] ?? [:]
    let text = (object["text_config"] as? [String: Any]) ?? object
    return try JSONDecoder.json5().decode(
        MLXLLM.Qwen35Configuration.self,
        from: try JSONSerialization.data(withJSONObject: text))
}

@Suite("Qwen VLM target-only extraction", .serialized)
struct QwenVLMTargetExtractionTests {
    init() {
        // The tiny synthetic modules here still evaluate MLX arrays, so the
        // GPU library must sit beside the active test runner like every
        // other MLX-touching suite (LiveInferenceFixtures.swift:89).
        _ = LiveInferenceFixtures.ensureMetallibColocated()
    }

    @Test("dense Qwen uses the long-context solo prefill stripe")
    func denseQwenUsesLongContextSoloStripe() throws {
        // Keyed on the checkpoint's declared `model_type` now, not on a
        // module class: same two answers, from data the engine path has.
        let denseScheduler = EngineV2Factory.productionSchedulerConfig(
            maxConcurrentRequests: 2,
            modelType: "qwen3_5",
            environment: [:])
        let moeScheduler = EngineV2Factory.productionSchedulerConfig(
            maxConcurrentRequests: 2,
            modelType: "qwen3_5_moe",
            environment: [:])

        #expect(
            denseScheduler.soloPrefillStripeTokens
                == EngineV2Factory.defaultDenseQwenSoloPrefillStripeTokens)
        #expect(
            moeScheduler.soloPrefillStripeTokens
                == EngineV2Factory.defaultSoloPrefillStripeTokens)
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
            tokenizer: StubBridgeTokenizer(),
            modelDirectory: directory,
            environment: [QwenVLMTextExtraction.parityCheckFlag: "0"])
        // The runner answers with the extracted MLXLLM target — the fork
        // owns the re-key and the parity gate now.
        #expect(serving is Qwen35MoEModel)
    }

    @Test("Qwen3-VL MoE stays the direct serving model in production and benchmarks")
    func qwen3VLDirectServingResolution() throws {
        let wrapper = try qwen3VLMoEFixture()
        let directory = try makeCheckpointDirectory(modelType: "qwen3_vl_moe")
        defer { try? FileManager.default.removeItem(at: directory) }
        // Qwen3-VL's runner serves the wrapper itself: the same object comes
        // back, so vision state and the language tower stay one identity.
        let benchmark = try EngineV2Factory.benchmarkServingModel(
            model: wrapper, tokenizer: StubBridgeTokenizer(),
            modelDirectory: directory)
        #expect(ObjectIdentifier(benchmark) == ObjectIdentifier(wrapper))
    }

    @Test("slot preparation keeps the loaded Qwen3-VL wrapper as its target")
    func qwen3VLSlotServingResolution() async throws {
        let wrapper = try qwen3VLMoEFixture()
        let container = ModelContainer(
            context: ModelContext(
                configuration: ModelConfiguration(id: "tiny/qwen3-vl-moe"),
                model: wrapper,
                processor: QwenExtractionProcessor(),
                tokenizer: StubBridgeTokenizer()))
        let checkpoint = try makeCheckpointDirectory(modelType: "qwen3_vl_moe")
        defer { try? FileManager.default.removeItem(at: checkpoint) }
        let prepared = try await EngineV2SlotFactory.prepareProductionModel(
            modelId: "tiny/qwen3-vl-moe",
            isVLM: true,
            modelDirectory: checkpoint,
            container: container,
            specDecPreparation: .init(
                artifact: nil,
                status: .disabled(.targetUnsupported, configured: false)))

        // Sizing reads the layer kinds off the same runner the engine will
        // use, so it needs the checkpoint path production always passes.
        let sizing = await SlotSizingSnapshot.build(
            container: container,
            modelPath: checkpoint,
            fallbackDefaultMaxTokens: 64)
        let expectedKVRate = SlotSizingSnapshot.fp16KVBytesPerToken(
            layerKinds: wrapper.cbv2LayerKinds)

        #expect(ObjectIdentifier(prepared.snapshot.model) == ObjectIdentifier(wrapper))
        #expect(ObjectIdentifier(prepared.servingModel) == ObjectIdentifier(wrapper))
        #expect(prepared.assistant == nil)
        #expect(prepared.mtpStatus.active == false)
        #expect(expectedKVRate > 0)
        #expect(sizing.fp16KVBytesPerToken == expectedKVRate)
    }

    @Test("Qwen3-VL MoE constructs the contiguous production backend and vetoes paged KV")
    func qwen3VLProductionBackend() throws {
        let wrapper = try qwen3VLMoEFixture()
        let runner = try adoptFixture(wrapper, modelType: "qwen3_vl_moe")
        let build = try EngineV2Factory.makeProductionBuild(
            model: wrapper,
            tokenizer: StubBridgeTokenizer(),
            modelDirectory: try makeCheckpointDirectory(modelType: "qwen3_vl_moe"),
            kvBytesCapacity: 1 << 20,
            maxConcurrentRequests: 2,
            kvBackend: .contiguous)
        #expect(build.kvBackendKind == .contiguous)
        #expect(runner.layerKinds.count == 1)
        #expect(
            EngineV2Factory.adoptionBoundTokens(
                layerKinds: runner.layerKinds,
                capabilities: runner.manifest.engine) == 0)

        var preflightCalled = false
        let paged = try EngineV2Factory.prepareProductionBackend(
            runner: try adoptFixture(
                try qwen3VLMoEFixture(), modelType: "qwen3_vl_moe"),
            kvBytesCapacity: 1 << 20,
            maxConcurrentRequests: 2,
            kvBackend: .paged,
            pagedPreflightOverride: { _ in preflightCalled = true })
        #expect(paged.kind == .contiguous)
        #expect(paged.fallbackReason == "model_capability")
        #expect(paged.modelCapabilities.supportsPrefixReuse == false)
        #expect(paged.modelCapabilities.supportsPagedKV == false)
        #expect(paged.modelCapabilities.supportsCompiledDecode == false)
        #expect(paged.modelCapabilities.supportsPackedPrefill == false)
        #expect(paged.modelCapabilities.supportsMTP == false)
        #expect(preflightCalled == false)
    }


    @Test("production factory accepts wired Qwen dense and MoE target families")
    func factoryAcceptanceAndRefusal() throws {
        let config = try decodeQwenTargetConfiguration(
            qwenTargetFixtureJSON(fullAttentionInterval: 2))
        let target = Qwen35MoEModel(config)
        let targetRunner = try adoptFixture(target, modelType: "qwen3_5_moe")
        let prepared = try EngineV2Factory.prepareProductionBackend(
            runner: targetRunner,
            kvBytesCapacity: 1 << 20,
            maxConcurrentRequests: 2,
            kvBackend: EngineV2KVBackendSelection.contiguous)

        #expect(prepared.kind == EngineV2KVBackendKind.contiguous)
        #expect(prepared.layerKinds.count == 1)
        #expect(prepared.layerKinds.first?.modelLayerIndex == 1)
        #expect(prepared.modelCapabilities.supportsPrefixReuse == false)
        #expect(
            EngineV2Factory.adoptionBoundTokens(
                layerKinds: targetRunner.layerKinds,
                capabilities: targetRunner.manifest.engine) == 0)

        let dense = try EngineV2Factory.prepareProductionBackend(
            runner: try adoptFixture(Qwen35Model(config), modelType: "qwen3_5"),
            kvBytesCapacity: 1 << 20,
            maxConcurrentRequests: 2,
            kvBackend: EngineV2KVBackendSelection.contiguous)

        #expect(dense.kind == EngineV2KVBackendKind.contiguous)
        #expect(dense.layerKinds.count == 1)
        #expect(dense.modelCapabilities.supportsPrefixReuse == false)
    }

    @Test("Qwen core capability veto forces paged selection to contiguous before preflight")
    func pagedCapabilityVeto() throws {
        let config = try decodeQwenTargetConfiguration(
            qwenTargetFixtureJSON(fullAttentionInterval: 2))
        var preflightCalled = false
        let prepared = try EngineV2Factory.prepareProductionBackend(
            runner: try adoptFixture(Qwen35MoEModel(config), modelType: "qwen3_5_moe"),
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
        let config = try decodeQwenTargetConfiguration(
            qwenTargetFixtureJSON(fullAttentionInterval: 2))
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
            runner: try adoptFixture(target, modelType: "qwen3_5_moe"),
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
        let config = try decodeQwenTargetConfiguration(configData)

        // One of two layers owns attention KV: 2(K+V) * 1 head * 64 dim * 2-byte fp16.
        // Sizing reads the layer kinds the RUNNER reports, and those are the
        // model's own — the same array this fixture's configuration derives.
        #expect(
            SlotSizingSnapshot.fp16KVBytesPerToken(layerKinds: config.cbv2LayerKinds)
                == 256)
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
        let config = try decodeQwenTargetConfiguration(data)

        #expect(config.cbv2LayerKinds.count == 10)
        #expect(
            SlotSizingSnapshot.fp16KVBytesPerToken(layerKinds: config.cbv2LayerKinds)
                == 20_480)
        #expect(try config.cbv2RecurrentStateSpec().fixedBytesPerRequest() == 64_389_120)
        #expect(try config.cbv2RecurrentStateSpec().peakBytesPerRequest() == 193_167_360)
    }

    @Test("Qwen is advertised after target, vision, MTP, and cleanup canaries pass")
    func allowlistIsOpen() {
        #expect(EngineV2SupportedModels.isSupported(modelType: "qwen3_5_moe"))
        #expect(EngineV2SupportedModels.isSupported(modelType: " QWEN3_5_MOE "))
    }
}
