import CryptoKit
import Foundation
import MLXLLM
import MLXLMCommon
import Testing

@_spi(Benchmarking) @testable import ProviderCore

/// Factory-policy witnesses use a real loaded-model class and real empty SSD
/// stores. They perform no native forward or artifact-speed qualification.
private final class NemotronShortCheckpointFixture {
    let root: URL
    let configuration: NemotronH35Configuration
    private var stores: [SSDHybridCheckpointStore] = []

    init(blocks: [String] = ["mamba", "attention"]) throws {
        let data = Data("""
            {"model_type":"nemotron_h", "vocab_size":100, "hidden_size":64,
             "num_hidden_layers":\(blocks.count), "num_attention_heads":4, "num_key_value_heads":2,
             "head_dim":64, "mamba_num_heads":4, "mamba_head_dim":16,
             "ssm_state_size":16, "conv_kernel":4, "n_groups":2,
             "intermediate_size":128, "moe_intermediate_size":64,
             "moe_shared_expert_intermediate_size":64, "n_routed_experts":4,
             "num_experts_per_tok":2, "layers_block_type":\(String(decoding: try JSONEncoder().encode(blocks), as: UTF8.self)),
             "norm_eps":0.00001, "mamba_ssm_cache_dtype":"float32"}
            """.utf8)
        configuration = try JSONDecoder().decode(NemotronH35Configuration.self, from: data)
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("nemotron-short-policy-\(UUID().uuidString)")
    }

    func store(modelID: String = EngineV2SupportedModels.nemotron35LightningRegistryModelID,
               aggregate: String = EngineV2Factory.qualifiedNemotron35ShortCheckpointAggregateHash,
               floor: Int = 1_024,
               layout: String = CBv2CompleteCheckpointManifest.pagedLayout) throws -> SSDHybridCheckpointStore {
        let modelRoot = root.appendingPathComponent(String(format: "%012x", stores.count))
        try SSDBlockStore.prepareModelRoot(dedicatedRoot: root, modelRoot: modelRoot)
        let identity = CBv2CompleteCheckpointIdentity(modelAggregateHash: aggregate,
            promptContractID: String(repeating: "a", count: 64), buildID: "fixture-build",
            numericsFingerprint: "fixture-numerics")
        let store = SSDHybridCheckpointStore(config: .init(
            modelId: modelID, identity: identity, backendLayout: layout,
            root: modelRoot, dedicatedRoot: root, epochStore: nil,
            maxReadBytes: 16 << 20, maxStageMillis: 1_000, minEffectiveTokens: floor,
            ttlSeconds: 1_800, strictFsync: false, nowSeconds: { 100 },
            diskBudgetBytes: { 1 << 30 }, maintainWholeRoot: {}),
            kekKey: SymmetricKey(data: Data(repeating: 7, count: 32)),
            kvBudget: nil, diskBudget: SSDDiskBudget(), maxWriteBytesPerDay: 1 << 30)
        stores.append(store)
        return store
    }

    func remove() {
        // No job/stage is submitted by these factory-policy tests.
        stores.forEach { $0.close() }
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite("Qualified Nemotron demanded short checkpoints", .serialized)
struct NemotronDemandedShortCheckpointTests {
    @Test("serving and production benchmark use the measured canonical Lightning artifact")
    func canonicalProductionArtifactQualifies() throws {
        let fixture = try NemotronShortCheckpointFixture()
        defer { fixture.remove() }
        let model = NemotronH35Model(fixture.configuration)
        #expect(!model.cbv2RecurrentStateSpec.layers.isEmpty)
        for floor in [1_024, 2_048] {
            let store = try fixture.store(floor: floor)
            for purpose in [EngineV2Factory.ConstructionPurpose.serving, .benchmark] {
                #expect(EngineV2Factory.demandedShortCheckpointMinimumTokens(
                    model: model, backend: .paged, store: store,
                    constructionPurpose: purpose, checkpointPartition: .production) == floor)
            }
        }
    }

    @Test("unmeasured aliases and replacement aggregate hashes do not activate serving")
    func exactCanonicalIdentityOnly() throws {
        let fixture = try NemotronShortCheckpointFixture()
        defer { fixture.remove() }
        let model = NemotronH35Model(fixture.configuration)
        for modelID in [EngineV2SupportedModels.nemotron35LightningModelID,
                        EngineV2SupportedModels.nemotron35LightningMTPModelID,
                        EngineV2SupportedModels.nemotron35LightningHybrid8BuildID,
                        EngineV2SupportedModels.nemotron35LightningRollback4bitBuildID,
                        "nvidia/nemotron-3.5-lightning", "nvidia-nemotron-3.5-lightning-future",
                        "NVIDIA-NEMOTRON-3.5-LIGHTNING", "nvidia-nemotron-3.5-lightning "] {
            #expect(EngineV2Factory.demandedShortCheckpointMinimumTokens(
                model: model, backend: .paged, store: try fixture.store(modelID: modelID)) == nil)
        }
        #expect(EngineV2Factory.demandedShortCheckpointMinimumTokens(
            model: model, backend: .paged,
            store: try fixture.store(aggregate: String(repeating: "b", count: 64))) == nil)
    }

    @Test("paged COMPLETE storage and the unchanged effective-token floor are mandatory")
    func backendLayoutAndFloorRemainMandatory() throws {
        let fixture = try NemotronShortCheckpointFixture()
        defer { fixture.remove() }
        let model = NemotronH35Model(fixture.configuration)
        #expect(EngineV2Factory.demandedShortCheckpointMinimumTokens(
            model: model, backend: .paged, store: nil) == nil)
        #expect(EngineV2Factory.demandedShortCheckpointMinimumTokens(
            model: model, backend: .contiguous, store: try fixture.store()) == nil)
        #expect(EngineV2Factory.demandedShortCheckpointMinimumTokens(
            model: model, backend: .paged, store: try fixture.store(floor: 1_023)) == nil)
        for layout in [CBv2CompleteCheckpointManifest.layout,
                       CBv2CompleteCheckpointManifest.historicalAttentionLayout,
                       CBv2CompleteCheckpointManifest.pagedAsymmetricMTPLayout] {
            #expect(EngineV2Factory.demandedShortCheckpointMinimumTokens(
                model: model, backend: .paged, store: try fixture.store(layout: layout)) == nil)
        }
    }

    @Test("legacy Nemotron and a Lightning model without recurrent state are excluded")
    func actualModelClassAndStateAreRequired() throws {
        let fixture = try NemotronShortCheckpointFixture()
        defer { fixture.remove() }
        let legacy = NemotronHModel(fixture.configuration.target)
        #expect(EngineV2Factory.demandedShortCheckpointMinimumTokens(
            model: legacy, backend: .paged, store: try fixture.store()) == nil)
        let attentionOnly = try NemotronShortCheckpointFixture(blocks: ["attention"])
        defer { attentionOnly.remove() }
        let noRecurrent = NemotronH35Model(attentionOnly.configuration)
        #expect(noRecurrent.cbv2RecurrentStateSpec.layers.isEmpty)
        #expect(EngineV2Factory.demandedShortCheckpointMinimumTokens(
            model: noRecurrent, backend: .paged, store: try attentionOnly.store()) == nil)
    }

    @Test("production stays short-only even when a benchmark partition is supplied to serving")
    func longPromptExtensionRemainsBenchmarkOnly() throws {
        let fixture = try NemotronShortCheckpointFixture()
        defer { fixture.remove() }
        let model = NemotronH35Model(fixture.configuration)
        let store = try fixture.store()
        for purpose in [EngineV2Factory.ConstructionPurpose.serving, .benchmark] {
            #expect(!EngineV2Factory.benchmarkDemandedCheckpointPartitionIncludesLongPrompts(
                model: model, backend: .paged, store: store,
                constructionPurpose: purpose, checkpointPartition: .production))
        }
        #expect(!EngineV2Factory.benchmarkDemandedCheckpointPartitionIncludesLongPrompts(
            model: model, backend: .paged, store: store,
            constructionPurpose: .serving, checkpointPartition: .demandedRecurrentQualification))
        #expect(EngineV2Factory.benchmarkDemandedCheckpointPartitionIncludesLongPrompts(
            model: model, backend: .paged, store: store,
            constructionPurpose: .benchmark, checkpointPartition: .demandedRecurrentQualification))
    }
}
