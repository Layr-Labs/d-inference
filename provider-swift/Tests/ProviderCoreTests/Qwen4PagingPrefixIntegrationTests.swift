import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Testing

@testable import ProviderCore

// This tiny eligibility fixture has no PLE layers and is not a full-artifact
// SSD/prefix restore qualification. Those require separate same-tuple evidence.
@Suite("Qwen4 native paging and complete prefix eligibility", .serialized)
struct Qwen4PagingPrefixIntegrationTests {
    private let flashNextID = "DarkBloom/Qwen3.8-Flash-Next-Q4-mtp"

    private var environment: [String: String] {
        [KVBackendGuardStore.pathEnvKey: "/dev/null"]
    }

    private func tinyTarget() throws -> Qwen4ExpTextModel {
        var text = Qwen4ExpTextConfiguration()
        text.hiddenSize = 64
        text.hiddenLayers = 2
        text.attentionHeads = 2
        text.kvHeads = 1
        text.headDim = 64
        text.linearNumValueHeads = 2
        text.linearNumKeyHeads = 1
        text.linearKeyHeadDim = 64
        text.linearValueHeadDim = 64
        text.vocabularySize = 64
        text.maxPositionEmbeddings = 512
        text.fullAttentionInterval = 2
        text.layerTypes = ["linear_attention", "qwen_sparse_attention"]
        text.hcCount = 2
        text.hcLowrank = 8
        text.pleLayerIds = []
        text.pleEmbedDim = 64
        text.indexerNHeads = 2
        text.indexerKVHeads = 1
        text.indexerHeadDim = 32
        text.indexerBudget = 16
        text.indexerCompressRatio = 4
        text.numExperts = 1
        text.numExpertsPerTok = 1
        text.sharedExpertIntermediateSize = 32
        text.moeIntermediateSize = 32
        text.mropeSection = [2, 1, 1]
        return Qwen4ExpTextModel(text)
    }

    private func preparation(
        _ model: Qwen4ExpTextModel,
        selection: EngineV2KVBackendSelection = .auto,
        paged: Bool = true
    ) throws -> EngineV2Factory.ProductionBackendPreparation {
        _ = LiveInferenceFixtures.ensureMetallibColocated()
        var environment = environment
        if !paged {
            environment[EngineV2KVBackendPolicy.killSwitchEnvKey] = "0"
        }
        return try EngineV2Factory.prepareProductionBackend(
            model: model, modelID: flashNextID,
            kvBytesCapacity: 128 << 20, maxConcurrentRequests: 1,
            kvBackend: selection, maxContextLength: 1024,
            environment: environment)
    }

    private func storage(
        _ prepared: EngineV2Factory.ProductionBackendPreparation
    ) -> CompleteCheckpointStorageIdentity? {
        EngineV2SlotFactory.completeCheckpointStorage(
            kind: prepared.kind, layerKinds: prepared.layerKinds,
            supportsRecurrent: prepared.modelCapabilities.supportsRecurrentCheckpointReuse,
            supportsHistoricalAttention: false,
            modelDTypes: prepared.pagedLayerDTypes,
            nativeDTypes: prepared.pagedLayerDTypes, pagedConfig: prepared.pagedPoolConfig,
            assistant: .persistentCodec)
    }

    @Test("Automatic Flash-Next backend uses native pages and complete recurrent checkpoints")
    func automaticNativeTarget() throws {
        let model = try tinyTarget()
        let prepared = try preparation(model)
        #expect(prepared.kind == .paged)
        #expect(prepared.fallbackReason == nil)
        #expect(prepared.pagedPoolConfig?.segmentSizeBytes != nil)
        #expect(prepared.pagedPoolConfig?.pageSize == CBv2PagedDefaults.pageSize)
        #expect(prepared.layerKinds.count == 1)
        #expect(prepared.layerKinds[0].qwen4IndexerCompressRatio == 4)
        #expect(model.cbv2RecurrentStateSpec.layers.count == 1)
        #expect(!prepared.modelCapabilities.supportsPrefixReuse)
        #expect(prepared.modelCapabilities.supportsRecurrentCheckpointReuse)
        #expect(prepared.modelCapabilities.requiresNativePagedKV)
        #expect(!prepared.residentPrefixCacheEnabled)
        #expect(storage(prepared)?.backendLayout == CBv2CompleteCheckpointManifest.pagedLayout)
        #expect(!EngineV2KVBackendPolicy.degradesPagedFailure(selection: .paged))
    }

    @Test("Kill switch can force contiguous; explicit paged construction stays paged")
    func killSwitchVersusExplicitPaged() throws {
        let model = try tinyTarget()
        let automatic = try preparation(model, selection: .auto, paged: false)
        #expect(automatic.kind == .contiguous)
        #expect(automatic.fallbackReason == "kill_switch")
        let explicit = try preparation(model, selection: .paged, paged: true)
        #expect(explicit.kind == .paged)
        #expect(explicit.fallbackReason == nil)
        #expect(storage(explicit)?.backendLayout == CBv2CompleteCheckpointManifest.pagedLayout)
    }

    @Test("Complete prefix stays off for baselines and constructs only when enabled")
    func completePrefixBaselineOff() {
        #expect(!PrefixCachePolicy.isEnabled(
            modelId: flashNextID,
            environment: [PrefixCachePolicy.environmentFlag: "0"]))
        #expect(PrefixCachePolicy.isEnabled(modelId: flashNextID, environment: [:]))
        #expect(PrefixCachePolicy.residentConfig(
            modelId: flashNextID, promptContractID: "contract", environment: [:]) == nil)
        #expect(PrefixCachePolicy.hybridConfig(
            modelId: flashNextID, promptContractID: "contract", kvBytesCapacity: 128 << 20,
            hasMTPDrafter: true, supportsMTPPrefixCheckpoint: true,
            environment: [PrefixCachePolicy.environmentFlag: "0",
                          PrefixCachePolicy.memoryEnvironmentFlag: "1"]) == nil)
    }
}
