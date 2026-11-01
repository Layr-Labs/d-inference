// Copyright © 2026 Eigen Labs.
//
// LFM2.5-24B-A2B through the provider's production seams: the
// ProductionModelAdapter dispatch for LFM2MoEModel, automatic native paged KV
// with complete recurrent (conv-state) checkpoints, MTP off, and memory
// charges that count the 10 attention layers for KV and the 30 conv layers
// only as fixed per-request state. Tiny randomly initialized targets; no
// 24B download.

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Testing

@testable import ProviderCore

private struct LFM25UnusedProcessor: UserInputProcessor {
    private struct NotUsed: Error {}
    func prepare(input: UserInput) async throws -> LMInput { throw NotUsed() }
}

@Suite("LFM2.5-24B-A2B native adapter", .serialized)
struct LFM25NativeAdapterTests {
    private var environment: [String: String] {
        [KVBackendGuardStore.pathEnvKey: "/dev/null",
         EngineV2KVQuantizationPolicy.environmentKey: "native"]
    }

    /// Same equations as the artifact, at test scale: conv, conv,
    /// attention, conv with one dense layer and four routed experts. The
    /// artifact's head_dim 64 keeps the paged kernel preflight meaningful.
    private func tinyTarget() throws -> LFM2MoEModel {
        let data = Data("""
            {"model_type":"lfm2_moe","vocab_size":100,"hidden_size":128,
             "num_hidden_layers":4,"num_attention_heads":2,"num_key_value_heads":1,
             "intermediate_size":128,"moe_intermediate_size":32,"num_experts":4,
             "num_experts_per_tok":2,"num_dense_layers":1,"norm_topk_prob":true,
             "use_expert_bias":true,"routed_scaling_factor":1.0,"norm_eps":0.00001,
             "conv_bias":false,"conv_L_cache":3,"max_position_embeddings":4096,
             "rope_parameters":{"rope_theta":10000000.0,"rope_type":"default"},
             "layer_types":["conv","conv","full_attention","conv"]}
            """.utf8)
        return LFM2MoEModel(try JSONDecoder().decode(LFM2MoEConfiguration.self, from: data))
    }

    private func preparation(
        _ model: LFM2MoEModel,
        modelID: String = EngineV2SupportedModels.lfm25_24bA2BRegistryModelID,
        paged: Bool = true
    ) throws -> EngineV2Factory.ProductionBackendPreparation {
        _ = LiveInferenceFixtures.ensureMetallibColocated()
        return try EngineV2Factory.prepareProductionBackend(
            model: model, modelID: modelID,
            kvBytesCapacity: 128 << 20, maxConcurrentRequests: 1, kvBackend: .auto,
            maxContextLength: 1024,
            environment: paged ? environment : environment.merging(
                [EngineV2KVBackendPolicy.killSwitchEnvKey: "0"]) { _, value in value })
    }

    private func storage(
        _ model: LFM2MoEModel, _ prepared: EngineV2Factory.ProductionBackendPreparation
    ) -> CompleteCheckpointStorageIdentity? {
        EngineV2SlotFactory.completeCheckpointStorage(
            kind: prepared.kind, layerKinds: prepared.layerKinds,
            supportsRecurrent: prepared.modelCapabilities.supportsRecurrentCheckpointReuse,
            supportsHistoricalAttention: false,
            modelDTypes: model.cbv2CompleteCheckpointKVDTypes,
            nativeDTypes: prepared.nativeLayerDTypes, pagedConfig: prepared.pagedPoolConfig,
            assistant: .none)
    }

    @Test("pinned config: attention-only KV storage and a fixed conv-state charge")
    func pinnedConfigurationCharges() throws {
        let configuration = try JSONDecoder().decode(
            LFM2MoEConfiguration.self, from: Data(lfm25PinnedConfigJSON().utf8))
        let kinds = configuration.cbv2LayerKinds
        #expect(kinds.count == 10)
        #expect(kinds.compactMap(\.modelLayerIndex) == Array(stride(from: 2, to: 40, by: 4)))
        #expect(kinds.allSatisfy { kind in
            if case .full = kind.attention {
                return kind.kvHeads == 8 && kind.headDim == 64 && kind.sharesKVWithLayer == nil
            }
            return false
        })
        // Engine-truth KV rate (slot sizing) == the pre-load config estimate.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lfm25-native-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("config.json")
        try Data(lfm25PinnedConfigJSON().utf8).write(to: config)
        let preLoad = KVEstimation.resolvedKVBytesPerToken(
            architecture: KVEstimation.parseModelArchitecture(at: config), weightBytes: 1)
        #expect(SlotSizingSnapshot.fp16KVBytesPerToken(layerKinds: kinds) == 20_480)
        #expect(preLoad == 20_480)

        // 30 conv layers x (L_cache - 1 = 2) x hidden 2048 x bf16, no SSM.
        let spec = configuration.cbv2RecurrentStateSpec(activationDType: .bfloat16)
        #expect(spec.layers.count == 30)
        #expect(Set(spec.layers.map(\.modelLayerIndex)).isDisjoint(with: Set(kinds.compactMap(\.modelLayerIndex))))
        #expect(spec.layers.allSatisfy { $0.convShape == [1, 2, 2048] })
        #expect(try spec.fixedBytesPerRequest() == 30 * 2 * 2048 * 2)
        #expect(try spec.peakBytesPerRequest()
            == 30 * 2 * 2048 * 2 * CBv2RecurrentStateSpec.maximumLiveGenerations)

        let capabilities = configuration.cbv2Capabilities
        #expect(capabilities.supportsRecurrentCheckpointReuse)
        #expect(capabilities.supportsPagedKV)
        #expect(capabilities.requiresNativePagedKV)
        #expect(!capabilities.supportsMTP)
        #expect(!capabilities.supportsCompactRecurrentMTPReplay)
    }

    @Test("the production adapter dispatches the loaded LFM2MoEModel")
    func adapterDispatch() throws {
        let model = try tinyTarget()
        let adapter = try #require(EngineV2Factory.ProductionModelAdapter(model: model))
        #expect(adapter.layerKinds == model.cbv2LayerKinds)
        #expect(adapter.layerKinds.count == 1)
        #expect(adapter.modelCapabilities == model.cbv2Capabilities)
        #expect(!adapter.modelCapabilities.supportsMTP)
        let caches = try adapter.newCaches { index, kind in
            CBv2LayerCache(layerIndex: index, kind: kind)
        }
        #expect(caches.count == 1)
        #expect(EngineV2Factory.cbv2LayerKinds(model: model) == model.cbv2LayerKinds)
        let served = try EngineV2Factory.directServingModel(model: model, isVLM: false)
        #expect((served as? LFM2MoEModel) === model)
        #expect(model.cbv2RecurrentStateSpec.layers.count == 3)
    }

    @Test("automatic backend: native pages and complete recurrent checkpoints")
    func automaticNativeTarget() throws {
        let model = try tinyTarget()
        for modelID in [EngineV2SupportedModels.lfm25_24bA2BRegistryModelID,
                        EngineV2SupportedModels.lfm25_24bA2BModelID] {
            let prepared = try preparation(model, modelID: modelID)
            #expect(prepared.kind == .paged)
            #expect(prepared.fallbackReason == nil)
            #expect(prepared.pagedPoolConfig?.segmentSizeBytes != nil)
            #expect(prepared.nativeLayerDTypes == model.cbv2CompleteCheckpointKVDTypes)
            #expect(prepared.layerKinds.count == 1)
            #expect(!prepared.modelCapabilities.supportsPrefixReuse)
            #expect(!prepared.residentPrefixCacheEnabled)
            #expect(storage(model, prepared)?.backendLayout == CBv2CompleteCheckpointManifest.pagedLayout)
        }
    }

    @Test("paging kill switch and unqualified ids keep native contiguous complete checkpoints")
    func contiguousRemainsSafe() throws {
        let model = try tinyTarget()
        let killed = try preparation(model, paged: false)
        #expect(killed.kind == .contiguous)
        #expect(killed.fallbackReason == "kill_switch")
        #expect(storage(model, killed)?.backendLayout == CBv2CompleteCheckpointManifest.layout)
        let unqualified = try preparation(model, modelID: "LiquidAI/LFM2.5-8B-A1B-MLX-4bit")
        #expect(unqualified.kind == .contiguous)
    }

    @Test("slot sizing charges attention KV from the loaded target's layer kinds")
    func slotSizingUsesLoadedLayerKinds() async throws {
        let model = try tinyTarget()
        let container = ModelContainer(context: ModelContext(
            configuration: ModelConfiguration(id: "tiny/lfm2-moe"),
            model: model, processor: LFM25UnusedProcessor(), tokenizer: StubBridgeTokenizer()))
        let sizing = await SlotSizingSnapshot.build(
            container: container, modelPath: nil, fallbackDefaultMaxTokens: 64)
        // One attention layer x (K+V) x 1 kv head x head_dim 64 x fp16.
        #expect(sizing.fp16KVBytesPerToken == 1 * 2 * 1 * 64 * 2)
        #expect(sizing.fp16KVBytesPerToken
            == SlotSizingSnapshot.fp16KVBytesPerToken(layerKinds: model.cbv2LayerKinds))
    }
}
