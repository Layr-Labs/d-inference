// Copyright © 2026 Eigen Labs.

import Foundation
import MLX
import MLXLLM
@testable import MLXLMCommon
import MLXNN
import MLXVLM
import Testing

@_spi(Benchmarking) @testable import ProviderCore

private func qwenTargetFixtureJSON(
    mtpLayers: Int = 1,
    fullAttentionInterval: Int = 1,
    numExperts: Int = 0
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
            "num_experts": \(numExperts),
            "num_experts_per_tok": \(numExperts > 0 ? 2 : 0),
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

@Suite("Qwen VLM target-only extraction", .serialized)
struct QwenVLMTargetExtractionTests {
    init() {
        // The tiny synthetic modules here still evaluate MLX arrays, so the
        // GPU library must sit beside the active test runner like every
        // other MLX-touching suite (LiveInferenceFixtures.swift:89).
        _ = LiveInferenceFixtures.ensureMetallibColocated()
    }

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

    @Test("dense Qwen wrapper extracts to the wired dense target")
    func denseQwenWrapperExtracts() throws {
        let configData = qwenTargetFixtureJSON()
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
    }

    @Test("dense Qwen uses the long-context solo prefill stripe")
    func denseQwenUsesLongContextSoloStripe() throws {
        let config = try EngineV2VLMTextExtraction.decodeQwenConfiguration(
            configData: qwenTargetFixtureJSON(fullAttentionInterval: 2))
        let dense = Qwen35Model(config)
        let moe = Qwen35MoEModel(config)

        let denseScheduler = EngineV2Factory.productionSchedulerConfig(
            maxConcurrentRequests: 2,
            model: dense,
            environment: [:])
        let moeScheduler = EngineV2Factory.productionSchedulerConfig(
            maxConcurrentRequests: 2,
            model: moe,
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
            isVLM: true,
            modelDirectory: directory,
            environment: [EngineV2VLMTextExtraction.parityCheckFlag: "0"])
        #expect(serving is Qwen35MoEModel)
    }

    @Test("benchmark slot grant observes production headroom and rejects physical-RAM grants", arguments: [false, true])
    func benchmarkSlotBudgetGuard(oversized: Bool) async throws {
        let configData = qwenTargetFixtureJSON(mtpLayers: 0)
        let config = try EngineV2VLMTextExtraction.decodeQwenConfiguration(configData: configData)
        let directory = try qwenTargetFixtureDirectory(configData: configData)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tokenizer = StubBridgeTokenizer()
        let container = ModelContainer(context: ModelContext(
            configuration: ModelConfiguration(id: "tiny/qwen-benchmark-budget"),
            model: Qwen35Model(config), processor: QwenExtractionProcessor(), tokenizer: tokenizer))
        let requested = oversized ? Int(ProcessInfo.processInfo.physicalMemory) : 64 << 20
        do {
            let session = try await EngineV2Factory.makeBenchmarkSession(
                modelId: "tiny/qwen-benchmark-budget", modelDirectory: directory,
                isVLM: false, container: container, tokenizer: TokenizerHandle(tokenizer),
                verifiedWeightHash: String(repeating: "a", count: 64),
                kvBytesCapacity: requested, maxConcurrentRequests: 2,
                mtpEnabled: false, kvBackendConfig: "contiguous",
                environment: ["DARKBLOOM_PREFIX_CACHE": "0", "DARKBLOOM_PREFIX_CACHE_MEMORY": "0"])
            let snapshot = await session.cacheSnapshot()
            #expect(oversized == false)
            #expect(snapshot.engineKVCapacityBytes == requested)
            #expect(snapshot.physicalMemoryBytes == ProcessInfo.processInfo.physicalMemory)
            #expect(snapshot.activationReserveBytes > 0)
            #expect(snapshot.postLoadMaximumKVBytes < snapshot.physicalMemoryBytes)
            #expect(UInt64(requested) <= snapshot.postLoadMaximumKVBytes)
            await session.shutdown()
        } catch EngineV2BenchmarkSession.Failure.invalidCapacity {
            #expect(oversized)
        }
    }

    @Test("Qwen3-VL MoE stays the direct serving model in production and benchmarks")
    func qwen3VLDirectServingResolution() throws {
        let wrapper = try qwen3VLMoEFixture()
        let direct = try EngineV2Factory.directServingModel(model: wrapper, isVLM: true)
        let benchmark = try EngineV2Factory.benchmarkServingModel(
            model: wrapper, isVLM: true, modelDirectory: nil)

        #expect(ObjectIdentifier(direct) == ObjectIdentifier(wrapper))
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
        let prepared = try await EngineV2SlotFactory.prepareProductionModel(
            modelId: "tiny/qwen3-vl-moe",
            isVLM: true,
            container: container,
            specDecPreparation: .init(
                artifact: nil,
                status: .disabled(.targetUnsupported, configured: false)))

        let sizing = await SlotSizingSnapshot.build(
            container: container,
            modelPath: nil,
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
        let build = try EngineV2Factory.makeProductionBuild(
            model: wrapper,
            tokenizer: StubBridgeTokenizer(),
            kvBytesCapacity: 1 << 20,
            maxConcurrentRequests: 2,
            kvBackend: .contiguous)
        #expect(build.kvBackendKind == .contiguous)
        #expect(EngineV2Factory.cbv2LayerKinds(model: wrapper)?.count == 1)

        var preflightCalled = false
        let paged = try EngineV2Factory.prepareProductionBackend(
            model: try qwen3VLMoEFixture(),
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

        let dense = try EngineV2Factory.prepareProductionBackend(
            model: Qwen35Model(config),
            kvBytesCapacity: 1 << 20,
            maxConcurrentRequests: 2,
            kvBackend: EngineV2KVBackendSelection.contiguous)

        #expect(dense.kind == EngineV2KVBackendKind.contiguous)
        #expect(dense.layerKinds.count == 1)
        #expect(dense.modelCapabilities.supportsPrefixReuse == false)
    }

    @Test("Qwen paged preparation requires segmented storage and observed native types")
    func pagedNativePreparation() throws {
        let config = try EngineV2VLMTextExtraction.decodeQwenConfiguration(
            configData: qwenTargetFixtureJSON(fullAttentionInterval: 2))
        var preflightCalled = false
        let target = Qwen35MoEModel(config)
        let prepared = try EngineV2Factory.prepareProductionBackend(
            model: target,
            kvBytesCapacity: 1 << 20,
            maxConcurrentRequests: 2,
            kvBackend: EngineV2KVBackendSelection.paged,
            pagedPreflightOverride: { _ in preflightCalled = true })

        #expect(prepared.kind == EngineV2KVBackendKind.paged)
        #expect(prepared.fallbackReason == nil)
        #expect(preflightCalled)
        #expect(prepared.modelCapabilities.requiresNativePagedKV)
        let (backend, _) = try prepared.consume(model: target, maxConcurrentRequests: 2)
        let paged = try #require(backend as? PagedKVBackend)
        #expect(paged.pool.config.segmentSizeBytes == 64 << 20)
        #expect(paged.pool.config.layerDTypes == [.float32])
        #expect(EngineV2.backendCapabilityViolation(
            capabilities: prepared.modelCapabilities, backend: backend) == nil)
    }

    @Test("Qwen rejects attention-only SSD and requires verified identity for complete checkpoints")
    func recurrentTargetRequiresCompleteCheckpointIdentity() async throws {
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
        #expect(bundle.bridge.ssdHybridCheckpointStore == nil)
        let status = bundle.bridge.prefixCacheModelStatus()
        #expect(status.state == .disabled)
        #expect(status.reason == .runtimeIdentityUnavailable)
        await bundle.bridge.shutdown()
    }


    @Test("slot factory preserves hybrid bank, memory capability, and unique receipts",
          arguments: [true, false])
    func hybridSlotBridgeWiring(hybridEnabled: Bool) async throws {
        let modelID = "tiny-qwen-hybrid"
        let modelHash = String(repeating: "a", count: 64)
        let contract = String(repeating: "b", count: 64)
        let slotBytes = 8 << 20
        let bankBytes = 1 << 20
        let config = try EngineV2VLMTextExtraction.decodeQwenConfiguration(
            configData: qwenTargetFixtureJSON(mtpLayers: 0, fullAttentionInterval: 2))
        let target = Qwen35Model(config)
        let tokenizer = StubBridgeTokenizer()
        let container = ModelContainer(
            context: ModelContext(
                configuration: ModelConfiguration(id: modelID),
                model: target,
                processor: QwenExtractionProcessor(),
                tokenizer: tokenizer))
        let prepared = EngineV2PreparedModel(
            snapshot: EngineV2ModelSnapshot(
                model: target, eosTokenIds: [], extraEOSTokens: []),
            servingModel: target,
            assistant: nil,
            mtpStatus: .disabled(.configDisabled, configured: false),
            mtpArtifact: nil)

        // Keep the real slot -> preparation -> assembly -> bridge path.
        // Only model loading and prompt-contract disk IO use existing fixtures.
        let bundle = try await EngineV2SlotFactory.makeProductionBundle(
            modelId: modelID,
            modelType: "qwen3_5",
            isVLM: false,
            modelDirectory: nil,
            container: container,
            tokenizer: TokenizerHandle(tokenizer),
            sizing: SlotSizingSnapshot(
                weightsBytes: 1, fp16KVBytesPerToken: 256,
                maxContextLength: 2_048, defaultMaxTokens: 1),
            kvBytesCapacity: slotBytes,
            maxConcurrentRequests: 2,
            kvBudget: nil,
            activationReserveBytes: 0,
            kvBackendConfig: "contiguous",
            weightHash: modelHash,
            specDecPreparation: .init(
                artifact: nil, status: .disabled(.configDisabled, configured: false)),
            preparedModel: prepared,
            assemblyOverrides: .init(promptContractID: contract),
            environment: [
                "DARKBLOOM_PREFIX_CACHE": "1",
                "DARKBLOOM_PREFIX_CACHE_MEMORY": "1",
                "DARKBLOOM_CBV2_HYBRID_PREFIX_CACHE": hybridEnabled ? "1" : "0",
                "DARKBLOOM_CBV2_HYBRID_PREFIX_BYTES": String(bankBytes),
                KVBackendGuardStore.pathEnvKey: "/dev/null",
            ],
            emitTelemetry: { _ in })
        let bridge = bundle.bridge
        let evidence = bridge.residentPrefixCacheEvidence
        do {
            let ownedEngine = await bridge.ownedEngine
            let engine = try #require(ownedEngine as? EngineV2)
            let backendKind = await bridge.kvBackendKind
            #expect(backendKind == .contiguous)
            #expect(bridge.ssdPrefixCache == nil)
            #expect(engine.capacity().kvBytesCapacity == slotBytes - (hybridEnabled ? bankBytes : 0))
            if hybridEnabled {
                let bank = try #require(engine.hybridPrefixCache)
                #expect(bank.config.maximumBytes == bankBytes)
                #expect(bank.config.modelID == modelID)
                #expect(bank.config.promptContractID == contract)
                let capability = try #require(evidence?.capability())
                #expect(capability.modelId == modelID)
                #expect(capability.modelAggregateHash == modelHash)
                #expect(capability.promptContractId == contract)
                #expect(capability.enabled && capability.ready)
                #expect(!capability.cacheEpoch.isEmpty)
            } else {
                #expect(engine.hybridPrefixCache == nil)
                #expect(evidence == nil)
            }

            // Observe requests after actual enqueue, but before a model forward.
            // Native cache/MTP tests own checkpoint publication and token parity.
            let loop = engine.loopForTesting
            loop.onEngineQueueSync {
                loop.suspendStepExecutionAtCountForTesting = 0
            }
            defer {
                loop.onEngineQueueSync {
                    loop.suspendStepExecutionAtCountForTesting = nil
                }
            }
            let prompt = Array(repeating: 7, count: 257)
            let request = ChatCompletionRequest(
                model: modelID,
                messages: [ChatMessage(role: "user", content: "fixture")],
                max_tokens: 1, seed: 42)
            var engineIDs: [CBv2RequestID] = []
            var receipts: [CBv2RequestID] = []
            for index in 0..<2 {
                let providerID = "hybrid-seam-\(index)"
                let signal = EngineV2RequestUsageSignal()
                let stream = await bridge.submitTokenized(
                    promptTokens: prompt, request: request, requestId: providerID,
                    cacheScope: "tenant-fixture", usageSignal: signal)
                let mappedID = await bridge._testEngineRequestId(for: providerID)
                let engineID = try #require(mappedID)
                let queued = loop.onEngineQueueSync {
                    let request = loop.scheduler.record(for: engineID)?.request
                    // No step is in flight. Retire through the engine's real
                    // cancellation cleanup so the stable ID can be reused.
                    loop.finishRequest(engineID, reason: .cancelled)
                    return request
                }
                let submitted = try #require(queued)
                #expect(submitted.id == engineID)
                engineIDs.append(engineID)
                if hybridEnabled {
                    receipts.append(try #require(submitted.prefixCacheReceiptID))
                } else {
                    #expect(submitted.prefixCacheReceiptID == nil)
                }
                var cancelled = false
                for await event in stream {
                    if case .error("request cancelled") = event { cancelled = true }
                }
                #expect(cancelled)
            }
            #expect(engineIDs[0] == engineIDs[1])
            if hybridEnabled {
                #expect(receipts[0] != receipts[1])
                #expect(receipts.allSatisfy { $0 != engineIDs[0] })
            }
            #expect((engine.hybridPrefixCache?.stats.entries ?? 0) == 0)
        } catch {
            await bridge.shutdown()
            throw error
        }
        await bridge.shutdown()
        #expect(evidence?.capability() == nil)
    }
    @Test("SSD defaults preserve the complete store, capability and unique receipts without a RAM bank",
          arguments: [true, false], [0, 4])
    func completeCheckpointSlotBridgeWiring(cacheEnabled: Bool, numExperts: Int) async throws {
        try await checkCompleteCheckpointSlotBridgeWiring(cacheEnabled: cacheEnabled, numExperts: numExperts)
    }

    @Test("Complete SSD suppresses unused resident evidence even with the memory opt-in")
    func completeCheckpointPrecedesResidentEvidence() async throws {
        try await checkCompleteCheckpointSlotBridgeWiring(
            cacheEnabled: true, numExperts: 0, memoryEnabled: true)
    }

    private func checkCompleteCheckpointSlotBridgeWiring(
        cacheEnabled: Bool, numExperts: Int, memoryEnabled: Bool = false
    ) async throws {
        // Tiny tensors exercise the default policy under the release catalog IDs.
        // A synthetic model ID requires an explicit cache opt-in.
        let modelID = numExperts > 0
            ? "qwen3.5-35b-a3b" : "EigenLabs/Qwen3.8-27B-4bit-mtp"
        let modelHash = String(repeating: "a", count: 64)
        let contract = String(repeating: "b", count: 64)
        let slotBytes = 8 << 20
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("complete-checkpoint-seam-\(UUID().uuidString)", isDirectory: true)
        defer {
            SSDWholeRootMaintainer.shared.stopPeriodicMaintenance(root: root)
            try? FileManager.default.removeItem(at: root)
        }
        let identity = CBv2CompleteCheckpointIdentity(
            modelAggregateHash: modelHash, promptContractID: contract,
            buildID: String(repeating: "c", count: 64), numericsFingerprint: String(repeating: "d", count: 64))
        var environment = [
            "DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL": "1",
            SSDPrefixCacheFactory.testRootEnvironmentKey: root.path,
            "DARKBLOOM_PREFIX_CACHE_STATS_INTERVAL_SECS": "0",
            KVBackendGuardStore.pathEnvKey: "/dev/null",
        ]
        let residentBytes = 1 << 20
        if memoryEnabled {
            environment[PrefixCachePolicy.memoryEnvironmentFlag] = "1"
            environment["DARKBLOOM_CBV2_HYBRID_PREFIX_BYTES"] = String(residentBytes)
        }
        if !cacheEnabled { environment[PrefixCachePolicy.environmentFlag] = "0" }
        let config = try EngineV2VLMTextExtraction.decodeQwenConfiguration(
            configData: qwenTargetFixtureJSON(mtpLayers: 0, fullAttentionInterval: 2, numExperts: numExperts))
        let target: any LanguageModel = numExperts > 0 ? Qwen35MoEModel(config) : Qwen35Model(config)
        let tokenizer = StubBridgeTokenizer()
        let container = ModelContainer(
            context: ModelContext(
                configuration: ModelConfiguration(id: modelID),
                model: target,
                processor: QwenExtractionProcessor(),
                tokenizer: tokenizer))
        let prepared = EngineV2PreparedModel(
            snapshot: EngineV2ModelSnapshot(
                model: target, eosTokenIds: [], extraEOSTokens: []),
            servingModel: target,
            assistant: nil,
            mtpStatus: .disabled(.configDisabled, configured: false),
            mtpArtifact: nil)

        // Keep the real slot -> preparation -> assembly -> bridge path.
        // Model loading and artifact hashes use fixtures; cache construction is real.
        let bundle = try await EngineV2SlotFactory.makeProductionBundle(
            modelId: modelID,
            modelType: "qwen3_5",
            isVLM: false,
            modelDirectory: nil,
            container: container,
            tokenizer: TokenizerHandle(tokenizer),
            sizing: SlotSizingSnapshot(
                weightsBytes: 1, fp16KVBytesPerToken: 256,
                maxContextLength: 2_048, defaultMaxTokens: 1),
            kvBytesCapacity: slotBytes,
            maxConcurrentRequests: 2,
            kvBudget: nil,
            activationReserveBytes: 0,
            kvBackendConfig: "contiguous",
            weightHash: modelHash,
            specDecPreparation: .init(
                artifact: nil, status: .disabled(.configDisabled, configured: false)),
            preparedModel: prepared,
            assemblyOverrides: .init(
                promptContractID: contract, completeCheckpointIdentity: identity),
            environment: environment,
            emitTelemetry: { _ in })
        let bridge = bundle.bridge
        let evidence = bridge.durablePrefixCacheEvidenceSource
        do {
            let ownedEngine = await bridge.ownedEngine
            let engine = try #require(ownedEngine as? EngineV2)
            let kind = await bridge.kvBackendKind
            #expect(kind == .contiguous)
            #expect(bridge.ssdPrefixCache == nil)
            let hasResidentBank = cacheEnabled && memoryEnabled
            #expect(engine.capacity().kvBytesCapacity == slotBytes - (hasResidentBank ? residentBytes : 0))
            #expect((engine.hybridPrefixCache != nil) == hasResidentBank)
            // The bank can exist for the explicit opt-in, but the actual engine
            // selector only adopts complete SSD. It must have no resident wire
            // producer even if durable readiness temporarily disappears.
            #expect(bridge.residentPrefixCacheEvidence == nil)
            #expect(bridge.residentPrefixCacheEvidenceSequencer == nil)
            if cacheEnabled {
                let store = try #require(bridge.ssdHybridCheckpointStore)
                let engineStore = try #require(engine.completePrefixCache)
                #expect(engineStore === store)
                #expect(store.identity == identity)
                let capability = try #require(evidence?.prefixCacheV2Capability())
                #expect(capability.modelId == modelID)
                #expect(capability.modelAggregateHash == modelHash)
                #expect(capability.promptContractId == contract)
                #expect(capability.readyBoundaryMode == PrefixCacheV2Capability.checkpointBoundaryMode)
                #expect(capability.enabled && capability.ready)
                #expect(!capability.cacheEpoch.isEmpty)
            } else {
                #expect(engine.completePrefixCache == nil)
                #expect(bridge.ssdHybridCheckpointStore == nil)
                #expect(evidence == nil)
            }

            // Observe requests after actual enqueue, but before a model forward.
            // Native cache/MTP tests own checkpoint publication and token parity.
            let loop = engine.loopForTesting
            loop.onEngineQueueSync {
                loop.suspendStepExecutionAtCountForTesting = 0
            }
            defer {
                loop.onEngineQueueSync {
                    loop.suspendStepExecutionAtCountForTesting = nil
                }
            }
            let prompt = Array(repeating: 7, count: 257)
            let request = ChatCompletionRequest(
                model: modelID,
                messages: [ChatMessage(role: "user", content: "fixture")],
                max_tokens: 1, seed: 42)
            var engineIDs: [CBv2RequestID] = []
            var receipts: [CBv2RequestID] = []
            for index in 0..<2 {
                let providerID = "complete-seam-\(index)"
                let signal = EngineV2RequestUsageSignal()
                let stream = await bridge.submitTokenized(
                    promptTokens: prompt, request: request, requestId: providerID,
                    cacheScope: "tenant-fixture", usageSignal: signal)
                let mappedID = await bridge._testEngineRequestId(for: providerID)
                let engineID = try #require(mappedID)
                let queued = loop.onEngineQueueSync {
                    let request = loop.scheduler.record(for: engineID)?.request
                    // No step is in flight. Retire through the engine's real
                    // cancellation cleanup so the stable ID can be reused.
                    loop.finishRequest(engineID, reason: .cancelled)
                    return request
                }
                let submitted = try #require(queued)
                #expect(submitted.id == engineID)
                engineIDs.append(engineID)
                if cacheEnabled {
                    receipts.append(try #require(submitted.prefixCacheReceiptID))
                } else {
                    #expect(submitted.prefixCacheReceiptID == nil)
                }
                var cancelled = false
                for await event in stream {
                    if case .error("request cancelled") = event { cancelled = true }
                }
                #expect(cancelled)
            }
            #expect(engineIDs[0] == engineIDs[1])
            if cacheEnabled {
                #expect(receipts[0] != receipts[1])
                #expect(receipts.allSatisfy { $0 != engineIDs[0] })
            }
        } catch {
            await bridge.shutdown()
            throw error
        }
        await bridge.shutdown()
        #expect(evidence?.prefixCacheV2Capability() == nil)
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

    @Test("Qwen is advertised after target, vision, MTP, and cleanup canaries pass")
    func allowlistIsOpen() {
        #expect(EngineV2SupportedModels.isSupported(modelType: "qwen3_5_moe"))
        #expect(EngineV2SupportedModels.isSupported(modelType: " QWEN3_5_MOE "))
    }
}
