import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Testing

@testable import ProviderCore

/// Inkling 2's complete prefix checkpoints through the production pieces: the
/// backend the provider prepares (native paged pool, probed dtypes), the
/// provider's storage gate under the fleet's default checkpoint profile, and
/// the engine the production assembler builds, which must adopt the store.
/// A tiny target on the GPU; no weights.
@Suite("Inkling 2 complete prefix checkpoint wiring", .serialized)
struct Inkling2PrefixCheckpointWiringTests {
    /// A store that only answers the engine's construction-time questions.
    final class IdentityOnlyStore: CBv2CompletePrefixCache, @unchecked Sendable {
        let identity = CBv2CompleteCheckpointIdentity(
            modelAggregateHash: "inkling2-fixture-weights", promptContractID: "inkling2-fixture-contract",
            buildID: "inkling2-fixture-build", numericsFingerprint: "inkling2-fixture-numerics")
        func takeStaged(
            requestID: CBv2RequestID, tokens: [Int], cacheSalt: String?, maximumSequenceLength: Int
        ) -> CBv2StagedCompleteCheckpoint? { nil }
        func donate(
            _ source: CBv2CompleteCheckpointExport, requestID: CBv2RequestID?,
            tokens: [Int], cacheSalt: String?, completion: @escaping @Sendable ([Int]) -> Void
        ) { completion([]) }
        func close() {}
    }

    static func tinyTarget() throws -> Inkling2Model {
        let config: [String: Any] = [
            "model_type": "inkling2_loop",
            "text_config": [
                "hidden_size": 128, "num_hidden_layers": 6, "vocab_size": 64,
                "unpadded_vocab_size": 60, "num_attention_heads": 2, "num_key_value_heads": 1,
                "head_dim": 64, "d_rel": 4, "rel_extent": 24, "log_scaling_n_floor": 8,
                "log_scaling_alpha": 0.5, "qk_l2_clip_threshold": 8.0,
                "rel_l2_clip_threshold": 2.0, "local_layer_ids": [0, 2, 4],
                "sconv_kernel_size": 4, "final_logit_softcapping": 30.0,
                "sliding_window_size": 24, "n_layers_per_attn_res_block": 2,
                "n_routed_experts": 8, "num_experts_per_tok": 2, "intermediate_size": 32,
                "loop_config": ["core_start": 2, "core_end": 4, "num_passes": 3, "gate_rank": 8],
            ] as [String: Any],
        ]
        let configuration = try JSONDecoder().decode(
            Inkling2Configuration.self, from: JSONSerialization.data(withJSONObject: config))
        return Inkling2Model(configuration)
    }

    @Test func productionEngineAdoptsTheHistoricalRecurrentStore() async throws {
        _ = LiveInferenceFixtures.ensureMetallibColocated()
        let model = try Self.tinyTarget()
        let prepared = try EngineV2Factory.prepareProductionBackend(
            model: model, modelID: "inkling2-prefix-fixture", kvBytesCapacity: 128 << 20,
            maxConcurrentRequests: 2, kvBackend: .auto, maxContextLength: 1_024,
            environment: [KVBackendGuardStore.pathEnvKey: "/dev/null",
                          EngineV2KVQuantizationPolicy.environmentKey: "native"])
        #expect(prepared.kind == .paged)
        #expect(prepared.modelCapabilities.supportsRecurrentCheckpointReuse)
        let requested = try EngineV2KVQuantizationPolicy.resolve(
            modelType: "inkling2_loop", modelID: "inkling2-prefix-fixture", environment: [:], purpose: .checkpoint)
        let storage = try #require(EngineV2SlotFactory.completeCheckpointStorage(
            kind: prepared.kind, layerKinds: prepared.layerKinds,
            supportsRecurrent: prepared.modelCapabilities.supportsRecurrentCheckpointReuse,
            supportsHistoricalAttention: false, isInkling2: EngineV2Factory.isInkling2(model), modelDTypes: nil,
            nativeDTypes: prepared.nativeLayerDTypes, pagedConfig: prepared.pagedPoolConfig,
            assistant: .none, checkpointQuantization: requested.configuration))
        #expect(storage.backendLayout == CBv2CompleteCheckpointManifest.pagedHistoricalRecurrentLayout)
        #expect(storage.checkpointQuantization == nil)
        let store = IdentityOnlyStore()
        let build = try EngineV2Factory.assembleProductionBuild(
            model: model, tokenizer: StubBridgeTokenizer(), prefixCache: nil,
            completePrefixCache: store, checkpointQuantization: storage.checkpointQuantization,
            maxConcurrentRequests: 2, mtpDrafter: nil, mtpConfig: CBv2MTPConfig(),
            preparedBackend: prepared)
        let engine = try #require(build.engine as? EngineV2)
        #expect(engine.completePrefixCache === store)
        await engine.shutdown()
    }

    static let fixtureWeightHash = String(repeating: "a", count: 64)
    static let fixtureContractID = "inkling2-fixture-contract"

    static func preparedBackend(_ model: Inkling2Model) throws -> EngineV2Factory.ProductionBackendPreparation {
        try EngineV2Factory.prepareProductionBackend(
            model: model, modelID: "inkling2-prefix-fixture", kvBytesCapacity: 128 << 20,
            maxConcurrentRequests: 2, kvBackend: .auto, maxContextLength: 1_024,
            environment: [KVBackendGuardStore.pathEnvKey: "/dev/null",
                          EngineV2KVQuantizationPolicy.environmentKey: "native"])
    }

    /// The slot factory's complete-cache preparation over a prepared backend,
    /// with an ephemeral store under `root`.
    static func completePreparation(
        _ model: any LanguageModel, _ prepared: EngineV2Factory.ProductionBackendPreparation, root: URL
    ) async -> EngineV2SlotFactory.CompletePrefixCachePreparation? {
        await EngineV2SlotFactory.prepareCompletePrefixCache(
            modelId: "inkling2-prefix-fixture", model: model, preparedBackend: prepared,
            weightHash: fixtureWeightHash, promptContractID: fixtureContractID,
            mtpDrafter: nil, mtpConfig: .init(), kvBudget: nil,
            environment: [PrefixCachePolicy.environmentFlag: "1",
                          "DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL": "1",
                          "DARKBLOOM_PREFIX_CACHE_TEST_ROOT": root.path],
            identityOverride: .init(modelAggregateHash: fixtureWeightHash, promptContractID: fixtureContractID,
                                    buildID: "inkling2-fixture-build", numericsFingerprint: "inkling2-fixture-numerics"))
    }

    static func temporaryRoot(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("\(name)-\(UUID().uuidString)")
    }

    /// The slot factory's own call names Inkling 2 (`EngineV2Factory.isInkling2`),
    /// so its prepared backend gets the historical recurrent store.
    @Test func theSlotFactoryBuildsTheHistoricalRecurrentStoreForInkling2() async throws {
        _ = LiveInferenceFixtures.ensureMetallibColocated()
        let model = try Self.tinyTarget()
        let prepared = try Self.preparedBackend(model)
        let root = Self.temporaryRoot("inkling2-complete")
        defer { try? FileManager.default.removeItem(at: root) }
        let result = await Self.completePreparation(model, prepared, root: root)
        let cache = try #require(result?.cache)
        #expect(cache.config.backendLayout == CBv2CompleteCheckpointManifest.pagedHistoricalRecurrentLayout)
        #expect(result?.checkpointQuantization == nil)
        await cache.closeAndWait()
    }

    /// The historical recurrent codec was reviewed for Inkling 2 alone. A model
    /// that is not Inkling 2, over a prepared backend of Inkling's layer shape
    /// (sliding windows beside recurrent state on the native paged pool), gets
    /// no complete checkpoint store, as before that codec.
    @Test func aModelThatIsNotInkling2GetsNoHistoricalRecurrentStore() async throws {
        _ = LiveInferenceFixtures.ensureMetallibColocated()
        let prepared = try Self.preparedBackend(Self.tinyTarget())
        #expect(prepared.kind == .paged && prepared.modelCapabilities.supportsRecurrentCheckpointReuse)
        let other = GPTOSSModel(try JSONDecoder().decode(GPTOSSConfiguration.self, from: Data("""
            {"model_type":"gpt_oss", "num_hidden_layers":2,
             "num_local_experts":4, "num_experts_per_tok":2, "vocab_size":128,
             "rms_norm_eps":0.00001, "hidden_size":64, "intermediate_size":64,
             "head_dim":64, "num_attention_heads":4, "num_key_value_heads":2,
             "sliding_window":32}
            """.utf8)))
        let root = Self.temporaryRoot("inkling2-shape-other")
        defer { try? FileManager.default.removeItem(at: root) }
        let result = await Self.completePreparation(other, prepared, root: root)
        if let cache = result?.cache { await cache.closeAndWait() }
        #expect(result?.cache == nil)
        #expect(result?.status.reason == .unsupportedLayout)
    }

    /// Records the position of every donated checkpoint; every lookup misses.
    final class RecordingStore: CBv2CompletePrefixCache, @unchecked Sendable {
        let identity = IdentityOnlyStore().identity
        private let lock = NSLock()
        private var donated: [Int] = []
        var donatedPositions: [Int] { lock.withLock { donated } }
        func takeStaged(
            requestID: CBv2RequestID, tokens: [Int], cacheSalt: String?, maximumSequenceLength: Int
        ) -> CBv2StagedCompleteCheckpoint? { nil }
        func donate(
            _ source: CBv2CompleteCheckpointExport, requestID: CBv2RequestID?,
            tokens: [Int], cacheSalt: String?, completion: @escaping @Sendable ([Int]) -> Void
        ) {
            let position = source.manifest.position
            lock.withLock { donated.append(position) }
            source.close()
            completion([position])
        }
        func close() {}
    }

    /// With MLX's own prefill products the engine keeps a fixed chunk grid and
    /// captures only where every prompt range was one grid chunk, so serving
    /// takes the 2,048 grid with no solo stripe, an operator stripe included.
    @Test func servingGeometryIsOneGridChunkPerRangeWithoutSoloStripes() throws {
        let model = try Self.tinyTarget()
        #expect(model.cbv2Capabilities.requiresFixedPrefillChunkGrid)
        #expect(model.cbv2Capabilities.alignsRecurrentCheckpointsToPrefillChunks)
        let geometry = EngineV2Factory.prefillGeometry(model: model, environment: [:])
        #expect(geometry.prefillChunkTokens == EngineV2Factory.inkling2PrefillChunkTokens)
        #expect(geometry.soloPrefillStripeTokens == nil)
        let striped = EngineV2Factory.prefillGeometry(
            model: model, environment: [EngineV2Factory.soloPrefillStripeKey: "8192"])
        #expect(striped.soloPrefillStripeTokens == nil)
        let scheduler = EngineV2Factory.productionSchedulerConfig(
            maxConcurrentRequests: 2, model: model, environment: [:])
        #expect(scheduler.prefillChunkSize == 2048)
        #expect(scheduler.soloPrefillStripeTokens == nil)
        #expect(scheduler.maxBatchedTokensPerStep == 2048)
    }

    /// Turn 1 of a prompt past two grid chunks donates a checkpoint on the
    /// grid through the production build (the real-weight run donated none
    /// under the SDK's 512-token chunk and the 2,048-token solo stripe).
    @Test func aPromptPastTwoGridChunksDonatesGridCheckpoints() async throws {
        _ = LiveInferenceFixtures.ensureMetallibColocated()
        let model = try Self.tinyTarget()
        let store = RecordingStore()
        let built = try EngineV2Factory.makeProductionBuild(
            model: model, modelID: "inkling2-prefix-fixture", tokenizer: StubBridgeTokenizer(),
            kvBytesCapacity: 256 << 20, maxConcurrentRequests: 2, completePrefixCache: store,
            kvBackend: .auto, checkpointQuantization: .native, maxContextLength: 8_192,
            environment: [KVBackendGuardStore.pathEnvKey: "/dev/null",
                          EngineV2KVQuantizationPolicy.environmentKey: "native"])
        let engine = try #require(built.engine as? EngineV2)
        let request = CBv2Request(
            id: .init(31), promptTokens: (0..<4_200).map { 3 + $0 % 50 },
            sampling: .init(temperature: 0), maxTokens: 4, cacheSalt: "synthetic-tenant-a",
            prefixCacheReceiptID: .init(301))
        var finished = false
        for await event in try engine.submit(request) {
            if case .finished = event { finished = true }
        }
        #expect(finished)
        // Donation runs after the request finishes.
        for _ in 0..<300 where store.donatedPositions.isEmpty {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let positions = store.donatedPositions
        #expect(!positions.isEmpty)
        #expect(positions.allSatisfy { $0 > 0 && $0.isMultiple(of: 2048) && $0 < 4_200 })
        #expect(positions.max() == 4096)
        await engine.shutdown()
    }
}
