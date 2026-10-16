import CryptoKit
import Foundation
import MLX
import MLXLLM
import Testing

@testable import MLXLMCommon
@testable import ProviderCore

/// Real tiny target and real encrypted store. The key is deliberately supplied
/// by this fixture: reopening is not Keychain or cross-process qualification.
final class GLM5NextCheckpointFixture: @unchecked Sendable {
    static let boundary = 1024
    static let chunk = 32
    let root: URL
    let modelRoot: URL
    let key = SymmetricKey(size: .bits256)
    let identity = CBv2CompleteCheckpointIdentity(
        modelAggregateHash: "glm5next-synthetic-weights-v1", promptContractID: "glm5next-synthetic-template-v1",
        buildID: "glm5next-encrypted-test-v1", numericsFingerprint: "fp32-tiny-target")
    let tokens = (0..<1057).map { 4 + $0 % 20 }
    let budget = GlobalKVCacheBudget(capFraction: 0.9, activationReserveBytes: 0, memorySnapshot: {
        let usage = Memory.snapshot()
        return .init(total: 64 << 30, active: UInt64(usage.activeMemory),
                     cache: UInt64(usage.cacheMemory), systemAvailable: 64 << 30)
    })
    private var stores: [SSDHybridCheckpointStore] = []
    private var engines: [EngineV2] = []
    private var nativeContracts: [ObjectIdentifier: UUID] = [:]
    private var retainedConstructionScopes: [NativeConstructionScope] = []
    private var retirementUnproven = false
    private var cleanupProven = false

    private enum CleanupError: Error {
        case retirementUnproven
        case outstandingBudget(UInt64)
        case cleanupNotConfirmed
    }

    init() throws {
        _ = LiveInferenceFixtures.ensureMetallibColocated()
        root = try SSDTestDirectory.parent().appendingPathComponent("glm5next-encrypted-\(UUID())")
        modelRoot = root.appendingPathComponent(SSDHybridCheckpointStoreFactory.namespace(
            modelId: "synthetic-glm5next", identity: identity,
            backendLayout: CBv2CompleteCheckpointManifest.glm5NextPagedLayout))
        try SSDBlockStore.prepareModelRoot(dedicatedRoot: root, modelRoot: modelRoot)
    }

    func makeStore() throws -> SSDHybridCheckpointStore {
        let layout = CBv2CompleteCheckpointManifest.glm5NextPagedLayout
        let epoch = try SSDCacheEpochStore(root: modelRoot, binding: .init(
            modelId: "synthetic-glm5next", modelAggregateHash: identity.modelAggregateHash,
            promptContractId: identity.promptContractID, blockHashVersion: CBv2BlockHasher.version,
            blockSize: PrefixCachePolicy.blockSize,
            layoutEpoch: SSDHybridCheckpointEnvelope.layoutEpoch(identity: identity, backendLayout: layout),
            keyFingerprint: Data(HMAC<SHA256>.authenticationCode(
                for: Data("darkbloom-cache-epoch-key-binding-v1".utf8), using: key)).hexString))
        let store = SSDHybridCheckpointStore(config: .init(
            modelId: "synthetic-glm5next", identity: identity, backendLayout: layout,
            root: modelRoot, dedicatedRoot: root, epochStore: epoch,
            maxReadBytes: 16 << 20, maxStageMillis: SSDPrefixCachePolicy.defaultMaxStageMillis,
            minEffectiveTokens: SSDPrefixCachePolicy.minEffectiveTokens(environment: [:]),
            ttlSeconds: SSDPrefixCachePolicy.defaultTTLSeconds, strictFsync: false,
            nowSeconds: { Int64(Date().timeIntervalSince1970) }, diskBudgetBytes: { 1 << 30 },
            maintainWholeRoot: {}), kekKey: key, kvBudget: budget, diskBudget: SSDDiskBudget(),
            maxWriteBytesPerDay: 1 << 30, usesEphemeralKey: true)
        store.scanOnDisk()
        stores.append(store)
        return store
    }

    func makeEngine(store: SSDHybridCheckpointStore, withMTP: Bool = false) throws -> EngineV2 {
        let model = try Self.makeModel()
        if withMTP {
            let predictor = try GLM5NextMTP(target: model) { try Self.tensor($0, inventory: model.inventory) }
            let factory = try GLM5NextMTPExecution(target: model, predictor: predictor,
                maximumInputs: 1536, storage: .contiguous)
            let assistant = try GLM5NextMTPAdapter(target: model, predictor: predictor, factory: factory)
            let limits = try CBv2PagedGatheredAttentionLimits(maximumBatchSize: 1,
                maximumQueryTokens: Self.chunk, maximumContextTokens: 1536,
                maximumInFlightGraphs: 2, maximumScratchBytes: 128 << 20,
                admissionMode: .stepOwned(.pinnedMetal))
            let construction = NativeConstructionScope()
            let resources: GLM5NextMTPExecution.NativeResources
            do {
                resources = try factory.makeNativeResources(assistant: assistant,
                    config: .init(capacityBytes: 64 << 20, dtype: .float32,
                        maxPrefillChunk: Self.chunk, nominalMaxSequenceLength: 1536,
                        maxBufferLength: 16 << 20, segmentSizeBytes: 64 << 10,
                        layerDTypes: model.cbv2CompleteCheckpointKVDTypes, gatheredAttention: limits),
                    processMemoryOwner: budget.makeEngineMemoryOwner(),
                    construction: construction, completePrefixCache: store)
            } catch {
                if construction.snapshot.isRetainedFault {
                    retainedConstructionScopes.append(construction)
                    retainAfterUnprovenRetirement()
                }
                throw error
            }
            let engine = EngineV2(model: resources.model, layerKinds: model.cbv2LayerKinds,
                backend: resources.backend, cacheProvider: resources.cacheProvider,
                sampler: CBv2GreedySampler(), schedulerConfig: .init(maxConcurrentRequests: 1,
                    maxBatchedTokensPerStep: Self.chunk, prefillChunkSize: Self.chunk,
                    maxConcurrentPartialPrefills: 1,
                    maxWaiting: 4, enablePrefixCache: true),
                admissionConfig: model.cbv2NativeAdmissionConfig, completePrefixCache: store,
                mtpDrafter: assistant, mtpConfig: .init(enabled: true, maxDraftTokens: 1,
                    maxSpeculativeBatch: 1, fixedDraftTokens: 1, verificationMode: .serialTarget),
                processMemoryOwner: resources.processMemoryOwner, nativeCompletionTracking: true,
                nativeExecutionContract: resources.contract)
            nativeContracts[ObjectIdentifier(engine)] = resources.contract.id
            engines.append(engine)
            return engine
        }
        let backend = try model.makeCBv2PagedBackend(
            kvBytesCapacity: 64 << 20, maximumBatchSize: 1, maximumQueryTokens: Self.chunk,
            maximumContextTokens: 1536, maximumScratchBytes: 128 << 20,
            segmentBytes: 64 << 10, maximumBufferBytes: 16 << 20)
        let engine = EngineV2(model: CBv2SteppableLanguageModelAdapter(model),
            layerKinds: model.cbv2LayerKinds, backend: backend,
            cacheProvider: CBv2LayerCacheBank(caches: backend.makeLayerCaches()),
            sampler: CBv2GreedySampler(), schedulerConfig: .init(
                maxConcurrentRequests: 1, maxBatchedTokensPerStep: Self.chunk,
                prefillChunkSize: Self.chunk, maxConcurrentPartialPrefills: 1,
                maxWaiting: 4, enablePrefixCache: true),
            admissionConfig: model.cbv2NativeAdmissionConfig, completePrefixCache: store,
            processMemoryOwner: budget.makeEngineMemoryOwner())
        engines.append(engine)
        return engine
    }

    func request(id: UInt64, scope: String = "tenant-a", maxTokens: Int = 2) -> CBv2Request {
        .init(id: .init(id), promptTokens: tokens, sampling: .init(temperature: 0),
              maxTokens: maxTokens, cacheSalt: scope, prefixCacheReceiptID: .init(id + 10_000))
    }

    func file(store: SSDHybridCheckpointStore) throws -> URL {
        let hashes = store.hashes(tokens: tokens, scope: "tenant-a")
        let index = Self.boundary / PrefixCachePolicy.blockSize - 1
        let hash = try #require(hashes.indices.contains(index) ? hashes[index] : nil)
        let tag = store.lookupKeys.checkpointTag(chainHash: hash, cacheSalt: "tenant-a")
        return SSDBlockStore.fileURL(root: modelRoot, tag16Hex: Data(tag.prefix(16)).hexString)
    }

    struct Output {
        let logits: [Float]
        let tokens: [Int]
        let usage: CBv2Usage
    }

    private final class Frontier: @unchecked Sendable {
        private let lock = NSLock()
        private var logits: MLXArray?
        func set(_ value: MLXArray) { lock.withLock { logits = value } }
        func take() -> MLXArray? { lock.withLock { defer { logits = nil }; return logits } }
    }

    /// Observes the existing pre-sampler frontier, without a replacement model
    /// or fabricated cache counters. Native evaluation remains on engine queue.
    func run(engine: EngineV2, request: CBv2Request, expectMTP: Bool = false) async throws -> Output {
        let previousMTP: CBv2MTPMetrics?
        if expectMTP { previousMTP = try #require(engine.mtpMetricsSnapshot()) }
        else { previousMTP = nil }
        let frontier = Frontier()
        let tracking = engine.loopForTesting.nativeShutdownState
        let loan = try tracking?.beginLoan(owner: frontier)
        defer { engine.loopForTesting.nativeDiagnosticLoanEnded(loan) }
        engine.loopForTesting.setPrefillFrontierCapture { id, values in
            if id == request.id { frontier.set(values) }
        }
        defer { engine.loopForTesting.setPrefillFrontierCapture(nil) }
        var tokens: [Int] = []
        var usage: CBv2Usage?
        let stream = try engine.submit(request)
        for await event in stream {
            switch event {
            case .delta(_, let next, _): tokens += next
            case .finished(let reason, let final):
                #expect(reason == .length)
                usage = final
            default: break
            }
        }
        let logits = try engine.loopForTesting.onEngineQueueSync {
            let value = try #require(frontier.take())
            let mark = tracking?.rootMark ?? 0
            engine.loopForTesting.retainNativeWork([value], owners: [frontier])
            do {
                let values = try withError { fault in
                    eval(value)
                    try fault.check()
                    let values = value.asType(.float32).asArray(Float.self)
                    try fault.check()
                    return values
                }
                try engine.loopForTesting.requireNativeWork()
                if let tracking { tracking.retireCompleted(tracking.rootIDs(since: mark)) }
                return values
            } catch {
                engine.loopForTesting.failNativeCompletion(.nativeWorkFailed)
                throw error
            }
        }
        if let previousMTP {
            let metrics = try #require(engine.mtpMetricsSnapshot())
            #expect(metrics.active)
            #expect(metrics.rounds > previousMTP.rounds)
            #expect(metrics.proposedTokens > previousMTP.proposedTokens)
            #expect(metrics.serialVerificationRounds > previousMTP.serialVerificationRounds)
        }
        return .init(logits: logits, tokens: tokens, usage: try #require(usage))
    }

    func stage(store: SSDHybridCheckpointStore, engine: EngineV2, request: CBv2Request) async
        -> SSDPrefixCacheStageResult {
        await store.stage(requestID: request.prefixCacheReceiptID!, request: request,
            reserveReadScratch: { try engine.reserveCompleteCheckpointReadScratch() },
            makeImportPlan: { try engine.planCompleteCheckpointImport(manifest: $0, request: request) })
    }

    func retire(_ engine: EngineV2) async throws {
        guard let contractID = nativeContracts[ObjectIdentifier(engine)] else {
            await engine.shutdown()
            return
        }
        let outcome = await engine.shutdownReportingNativeCompletion()
        guard case .quiescent(let receipt) = outcome,
            engine.nativeShutdownExecutionContractID == contractID,
            receipt.engineID == engine.nativeShutdownEngineID,
            receipt.executionContractID == contractID, receipt.generation == 1
        else {
            retainAfterUnprovenRetirement()
            throw CleanupError.retirementUnproven
        }
    }

    func close() async throws {
        var firstFailure: (any Error)?
        for engine in engines {
            do { try await retire(engine) }
            catch { if firstFailure == nil { firstFailure = error } }
        }
        // Attempt every owner even after a failed engine drain, but never drop
        // the fixture's references or files without confirmed retirement.
        for store in stores { await store.closeAndWait() }
        if let firstFailure { throw firstFailure }
        guard !retirementUnproven else { throw CleanupError.retirementUnproven }
        let remaining = await budget.outstandingReservedBytes()
        guard remaining == 0 else {
            retainAfterUnprovenRetirement()
            throw CleanupError.outstandingBudget(remaining)
        }
        engines.removeAll()
        nativeContracts.removeAll()
        stores.removeAll()
        cleanupProven = true
    }

    func remove() throws {
        guard cleanupProven, !retirementUnproven else { throw CleanupError.cleanupNotConfirmed }
        try FileManager.default.removeItem(at: root)
    }

    private func retainAfterUnprovenRetirement() {
        retirementUnproven = true
        GLM5NextLoadFaultState.retain([self])
    }

    private static func makeModel() throws -> GLM5NextTextModel {
        let text: [String: Any] = [
            "model_type": "glm5_next_text", "vocab_size": 32, "hidden_size": 4,
            "intermediate_size": 8, "moe_intermediate_size": 4,
            "num_hidden_layers": 4, "num_attention_heads": 1, "num_key_value_heads": 1,
            "head_dim": 0, "qk_head_dim": 2, "qk_nope_head_dim": 2, "qk_rope_head_dim": 0,
            "v_head_dim": 2, "q_lora_rank": 4, "kv_lora_rank": 64, "mla_use_nope": true,
            "layer_types": ["linear_attention", "linear_attention", "linear_attention", "deepseek_sparse_attention"],
            "mlp_layer_types": ["dense", "dense", "dense", "sparse"],
            "indexer_types": ["full", "full", "full", "full"],
            "linear_attn_config": ["num_heads": 1, "head_dim": 2, "gate_lower_bound": -5,
                "short_conv_kernel_size": 4, "kda_layers": [0, 1, 2], "full_attn_layers": [3]],
            "index_head_dim": 2, "index_n_heads": 1, "index_topk": 4, "index_kpool": 4,
            "index_kpool_compress": true, "index_kpool_always_select_tail": true,
            "indexer_rope_interleave": true, "index_share_for_mtp_iteration": true,
            "mhc": true, "hc_mult": 4, "hc_eps": 1e-6, "hc_sinkhorn_iters": 20,
            "first_k_dense_replace": 3, "n_routed_experts": 2, "n_shared_experts": 1,
            "num_experts_per_tok": 1, "n_group": 1, "topk_group": 1,
            "norm_topk_prob": true, "routed_scaling_factor": 2.5, "scoring_func": "sigmoid",
            "topk_method": "noaux_tc", "moe_router_dtype": "float32", "output_router_logits": false,
            "router_aux_loss_coef": 0.001, "num_nextn_predict_layers": 1, "hidden_act": "silu",
            "swiglu_limit": 10, "rms_norm_eps": 1e-5, "attention_bias": false,
            "attention_dropout": 0, "max_position_embeddings": 2048, "initializer_range": 0.02,
            "use_cache": true, "tie_word_embeddings": false, "dtype": "float32",
            "pad_token_id": 0, "eos_token_id": [1, 2, 3],
        ]
        let root: [String: Any] = [
            "model_type": "glm5_next", "architectures": ["Glm5NextForConditionalGeneration"],
            "tie_word_embeddings": false, "text_config": text,
            "image_token_id": 10, "video_token_id": 11, "image_start_token_id": 12,
            "image_end_token_id": 13, "video_start_token_id": 14, "video_end_token_id": 15,
            "vision_config": ["model_type": "glm5_next_vision", "depth": 1, "hidden_size": 8,
                "intermediate_size": 12, "num_heads": 2, "image_size": 8, "patch_size": 2,
                "temporal_patch_size": 2, "spatial_merge_size": 2, "in_channels": 3,
                "out_hidden_size": 4, "projection_intermediate_size": 8, "hidden_act": "silu",
                "swiglu_limit": 10, "rms_norm_eps": 1e-5, "attention_bias": true,
                "attention_dropout": 0, "initializer_range": 0.02],
        ]
        let configuration = try JSONDecoder().decode(GLM5NextConfiguration.self,
            from: JSONSerialization.data(withJSONObject: root))
        let headers = try GLM5NextWeightInventory.expectedTensors(
            configuration: configuration, storage: .float32, shard: "synthetic.safetensors")
        let inventory = try GLM5NextWeightInventory.validate(
            configuration: configuration, tensors: headers, storage: .float32)
        return try GLM5NextTextModel(configuration: configuration.textConfig, inventory: inventory) { name in
            try Self.tensor(name, inventory: inventory)
        }
    }

    private static func tensor(_ name: String, inventory: GLM5NextWeightInventory) throws -> MLXArray {
        let shape = try #require(inventory.entries[name]?.tensor.shape)
        let count = shape.reduce(1, *)
        let salt = name.utf8.reduce(0) { ($0 + Int($1)) % 17 }
        let values: [Float]
        if name.contains("norm.weight") || name.hasSuffix("_scale") {
            values = Array(repeating: 1, count: count)
        } else if name.hasSuffix("A_log") || name.hasSuffix("dt_bias") {
            values = Array(repeating: -0.5, count: count)
        } else if name.hasSuffix(".bias") || name.hasSuffix("_base") {
            values = Array(repeating: 0, count: count)
        } else {
            values = (0..<count).map { Float(($0 * 3 + salt) % 19 - 9) * 0.015 }
        }
        return MLXArray(values, shape)
    }
}
