import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Testing

@testable import ProviderCore

@Suite("Nemotron native paging and complete prefix eligibility", .serialized)
struct NemotronPagingPrefixIntegrationTests {
    private var environment: [String: String] {
        [KVBackendGuardStore.pathEnvKey: "/dev/null"]
    }

    private func tinyTarget() throws -> NemotronH35Model {
        let data = Data("""
            {"model_type":"nemotron_h", "vocab_size":100, "hidden_size":64,
             "num_hidden_layers":4, "num_attention_heads":4, "num_key_value_heads":2,
             "head_dim":64, "mamba_num_heads":4, "mamba_head_dim":16,
             "ssm_state_size":16, "conv_kernel":4, "n_groups":2,
             "intermediate_size":128, "moe_intermediate_size":64,
             "moe_shared_expert_intermediate_size":64, "n_routed_experts":4,
             "num_experts_per_tok":2, "layers_block_type":["mamba","moe","mamba","attention"],
             "norm_eps":0.00001, "mamba_ssm_cache_dtype":"float32"}
            """.utf8)
        return NemotronH35Model(try JSONDecoder().decode(NemotronH35Configuration.self, from: data))
    }

    private func preparation(_ model: NemotronH35Model, paged: Bool = true) throws
        -> EngineV2Factory.ProductionBackendPreparation
    {
        _ = LiveInferenceFixtures.ensureMetallibColocated()
        return try EngineV2Factory.prepareProductionBackend(
            model: model, modelID: EngineV2SupportedModels.nemotron35LightningRegistryModelID,
            kvBytesCapacity: 128 << 20, maxConcurrentRequests: 1, kvBackend: .auto,
            maxContextLength: 1024,
            environment: paged ? environment : environment.merging(
                [EngineV2KVBackendPolicy.killSwitchEnvKey: "0"]) { _, value in value })
    }

    private func storage(_ model: NemotronH35Model,
                         _ prepared: EngineV2Factory.ProductionBackendPreparation,
                         assistant: (any CBv2MTPDrafter)? = nil) -> CompleteCheckpointStorageIdentity?
    {
        EngineV2SlotFactory.completeCheckpointStorage(
            kind: prepared.kind, layerKinds: prepared.layerKinds,
            supportsRecurrent: prepared.modelCapabilities.supportsRecurrentCheckpointReuse,
            supportsHistoricalAttention: false,
            modelDTypes: model.cbv2CompleteCheckpointKVDTypes,
            nativeDTypes: prepared.pagedLayerDTypes, pagedConfig: prepared.pagedPoolConfig,
            assistant: .init(drafter: assistant))
    }

    @Test("Automatic Lightning backend uses native pages and complete recurrent checkpoints")
    func automaticNativeTarget() throws {
        let model = try tinyTarget()
        let prepared = try preparation(model)
        #expect(prepared.kind == .paged)
        #expect(prepared.fallbackReason == nil)
        #expect(prepared.pagedPoolConfig?.segmentSizeBytes != nil)
        #expect(prepared.pagedLayerDTypes == model.cbv2CompleteCheckpointKVDTypes)
        #expect(prepared.layerKinds.count == 1)
        #expect(model.cbv2RecurrentStateSpec.layers.count == 2)
        #expect(!prepared.modelCapabilities.supportsPrefixReuse)
        #expect(!prepared.residentPrefixCacheEnabled)
        #expect(storage(model, prepared)?.backendLayout == CBv2CompleteCheckpointManifest.pagedLayout)
    }

    @Test("Paging kill switch preserves native contiguous complete checkpoints")
    func operatorOverrideRemainsSafe() throws {
        let model = try tinyTarget()
        let prepared = try preparation(model, paged: false)
        #expect(prepared.kind == .contiguous)
        #expect(prepared.fallbackReason == "kill_switch")
        #expect(storage(model, prepared)?.backendLayout == CBv2CompleteCheckpointManifest.layout)
    }

    @Test("Loaded embedded assistant passes the actual provider prefix gate",
          .enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_NEMOTRON35_MTP_MODEL"] != nil))
    func loadedAssistantCheckpointEligibility() throws {
        let path = try #require(ProcessInfo.processInfo.environment["DARKBLOOM_NEMOTRON35_MTP_MODEL"])
        let directory = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: directory.appendingPathComponent("config.json"))
        let model = NemotronH35Model(try JSONDecoder().decode(NemotronH35Configuration.self, from: data))
        let base = try JSONDecoder().decode(BaseConfiguration.self, from: data)
        try loadWeights(modelDirectory: directory, model: model, perLayerQuantization: base.perLayerQuantization)
        eval(model)
        let assistant = try NemotronH35MTPAssistant.load(from: directory, target: model)
        #expect(EngineV2SlotFactory.CompleteCheckpointAssistant(drafter: assistant) == .persistentCodec)
        let prepared = try preparation(model)
        #expect(prepared.kind == .paged)
        #expect(prepared.layerKinds.count == 6)
        #expect(storage(model, prepared, assistant: assistant)?.backendLayout == CBv2CompleteCheckpointManifest.pagedLayout)
        #expect(PrefixCachePolicy.hybridConfig(
            modelId: EngineV2SupportedModels.nemotron35LightningRegistryModelID,
            promptContractID: "test-contract", kvBytesCapacity: 128 << 20,
            hasMTPDrafter: true,
            supportsMTPPrefixCheckpoint: assistant is any CBv2MTPPrefixCheckpointDrafter,
            environment: [PrefixCachePolicy.memoryEnvironmentFlag: "1"]) != nil)
    }
}
