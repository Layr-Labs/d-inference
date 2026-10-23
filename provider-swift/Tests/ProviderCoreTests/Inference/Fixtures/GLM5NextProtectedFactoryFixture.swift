import CryptoKit
import Foundation
import MLX
import MLXLLM
import MLXVLM
import ProviderCoreFoundation
import Testing

@testable import MLXLMCommon
@testable import ProviderCore

/// Tiny synthetic GLM weights and the real managed load/engine construction,
/// shared by the protected factory and provider-loop GLM suites.
final class GLM5NextProtectedFactoryFixture: @unchecked Sendable {
    let root: URL
    let directory: URL
    let plan: GLM5NextArtifactPlan
    let identity: CBv2CompleteCheckpointIdentity
    let budget = GLM5NextProtectedFactoryFixture.makeBudget()
    // The unchanged provider service floor is 1 GiB plus fixed workspace.
    // A segmented grant is a logical ceiling, not eagerly allocated storage.
    let kvBytesCapacity = 2 << 30
    var bridges: [EngineV2Bridge] = []
    var stores: [SSDHybridCheckpointStore] = []
    private var containers: [ModelContainer] = []
    private var unexpectedEngines: [EngineV2] = []
    private var retirementUnproven = false
    var cacheRoot: URL { root.appendingPathComponent("ssd", isDirectory: true) }
    var environment: [String: String] {
        [
            "DARKBLOOM_PREFIX_CACHE": "1", "DARKBLOOM_PREFIX_CACHE_MEMORY": "0",
            "DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL": "1",
            "DARKBLOOM_PREFIX_CACHE_TEST_PERSISTENT_KEY": "0",
            "DARKBLOOM_PREFIX_CACHE_TEST_ROOT": cacheRoot.path,
            "DARKBLOOM_PREFIX_CACHE_DISK_GB": "1",
            "DARKBLOOM_PREFIX_CACHE_SSD_MAX_STAGE_MS": "10000",
            "DARKBLOOM_CBV2_SOLO_PREFILL_STRIPE": "0",
            // Automatic selection consults the crash-loop guard; never read a live record.
            KVBackendGuardStore.pathEnvKey: root.appendingPathComponent("kv-backend-guard.json").path,
        ]
    }
    var mtpConfig: CBv2MTPConfig {
        // The provider's GLM default: rectangular, adaptive depth up to 3.
        .init(
            enabled: true, maxDraftTokens: 3,
            maxSpeculativeBatch: 1, fixedDraftTokens: nil, verificationMode: .rectangular)
    }
    var mtpPreparation: SpecDecPreparation {
        .init(
            artifact: nil,
            status: .init(
                configured: true, active: false, reason: nil, source: .inline, revision: "fixture",
                artifactBytes: 0, assistantBytes: 0))
    }
    var sizing: SlotSizingSnapshot {
        .init(
            weightsBytes: Int(plan.quotation.requiredWeightBytes),
            fp16KVBytesPerToken: 386, maxContextLength: 1536, defaultMaxTokens: 4)
    }

    /// `modelID` nil names a unique synthetic build; the catalog ID exercises
    /// coordinator-mode identity, which also needs the shipped `chatTemplate`.
    init(modelID: String? = nil, chatTemplate: String? = nil) throws {
        _ = LiveInferenceFixtures.ensureMetallibColocated()
        root = try SSDTestDirectory.parent().appendingPathComponent(
            "glm-provider-factory-\(UUID())", isDirectory: true)
        directory = root.appendingPathComponent("model", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let configurationData = Data(Self.configuration.utf8)
        let configuration = try JSONDecoder().decode(
            GLM5NextConfiguration.self, from: configurationData)
        let tensors = try GLM5NextWeightInventory.expectedTensors(
            configuration: configuration,
            storage: .vontraQ4, shard: "weights.safetensors")
        let inventory = try GLM5NextWeightInventory.validate(
            configuration: configuration, tensors: tensors, storage: .vontraQ4)
        var payload = Data()
        var header: [String: Any] = [:]
        for tensor in tensors {
            let entry = inventory.entries[tensor.name]!
            let start = payload.count
            if tensor.name.contains("norm.weight") || tensor.name.hasSuffix("_scale") {
                if tensor.dtype == "BF16" {
                    payload.append(
                        [UInt16](repeating: 0x3f80, count: entry.bytes / 2).withUnsafeBytes {
                            Data($0)
                        })
                } else {
                    payload.append(
                        [Float](repeating: 1, count: entry.bytes / 4).withUnsafeBytes { Data($0) })
                }
            } else {
                payload.append(Data(repeating: 0, count: entry.bytes))
            }
            header[tensor.name] = [
                "shape": tensor.shape, "dtype": tensor.dtype,
                "data_offsets": [start, payload.count],
            ]
        }
        let encodedHeader = try JSONSerialization.data(withJSONObject: header, options: .sortedKeys)
        var length = UInt64(encodedHeader.count).littleEndian
        var shard = withUnsafeBytes(of: &length) { Data($0) }
        shard.append(encodedHeader)
        shard.append(payload)
        let vocabulary = [
            "<unk>": 0, "<s>": 1, "</s>": 2, "x": 3,
            "<|image|>": 154854, "<|video|>": 154855, "<|begin_of_image|>": 154830,
            "<|end_of_image|>": 154831, "<|begin_of_video|>": 154832, "<|end_of_video|>": 154833,
        ]
        let template = chatTemplate
            ?? "{% for message in messages %}{{ message['content'] }}{% endfor %}x"
        let tokenizer: [String: Any] = [
            "version": "1.0", "truncation": NSNull(), "padding": NSNull(),
            "added_tokens": vocabulary.filter { $0.key != "x" }.map { token, id in
                [
                    "id": id, "content": token, "single_word": false, "lstrip": false,
                    "rstrip": false, "normalized": false, "special": true,
                ] as [String: Any]
            }, "normalizer": NSNull(), "pre_tokenizer": ["type": "Whitespace"],
            "post_processor": NSNull(),
            "decoder": ["type": "ByteLevel"],
            "model": [
                "type": "BPE", "vocab": vocabulary,
                "merges": [], "unk_token": "<unk>", "byte_fallback": false, "fuse_unk": false,
            ],
        ]
        let media: [String: Any] = [
            "do_rescale": true, "patch_expand_factor": 1, "merge_size": 2,
            "image_mean": GLM5NextProcessor.mean, "image_std": GLM5NextProcessor.standardDeviation,
            "temporal_patch_size": 2, "patch_size": 2, "min_image_tokens": 1, "max_image_tokens": 4,
            "fps": 2, "image_processor_type": "Glm5NextImageProcessor",
            "video_processor_type": "Glm5NextVideoProcessor",
        ]
        let files: [String: Data] = [
            "config.json": configurationData, "weights.safetensors": shard,
            "model.safetensors.index.json": try JSONSerialization.data(withJSONObject: [
                "metadata": ["total_size": payload.count],
                "weight_map": Dictionary(uniqueKeysWithValues: tensors.map { ($0.name, $0.shard) }),
            ]),
            "tokenizer.json": try JSONSerialization.data(
                withJSONObject: tokenizer, options: .sortedKeys),
            "tokenizer_config.json": try JSONSerialization.data(withJSONObject: [
                "tokenizer_class": "PreTrainedTokenizerFast", "eos_token": "</s>",
                "unk_token": "<unk>", "chat_template": template,
            ]),
            "chat_template.jinja": Data(template.utf8),
            "processor_config.json": try JSONSerialization.data(withJSONObject: [
                "processor_class": "Glm5NextProcessor", "image_processor": media,
                "video_processor": media,
            ]),
        ]
        let entries = files.keys.sorted().map { name in
            ManifestFile(
                path: name, sizeBytes: Int64(files[name]!.count),
                sha256: Data(SHA256.hash(data: files[name]!)).hexString,
                role: ModelScanner.roleFor(filename: name))
        }
        var aggregate = SHA256()
        for name in files.keys.sorted() {
            aggregate.update(data: Data(SHA256.hash(data: files[name]!)))
        }
        let hash = Data(aggregate.finalize()).hexString
        let id = modelID ?? "synthetic/glm-provider-\(UUID())"
        let manifest = ModelManifest(
            schemaVersion: 1, modelID: id, version: "synthetic-v1", r2Prefix: "synthetic/v1",
            aggregateSHA256: hash, totalSizeBytes: entries.reduce(0) { $0 + $1.sizeBytes },
            fileCount: entries.count, files: entries, createdAt: Date(timeIntervalSince1970: 0))
        let catalog = CatalogModel(
            id: id, s3Name: "synthetic", displayName: "synthetic", sizeGb: 1,
            version: manifest.version, r2Prefix: manifest.r2Prefix,
            huggingFaceArtifact: .init(
                repoID: "synthetic/glm5", revision: String(repeating: "a", count: 40)),
            aggregateSHA256: hash)
        for (name, data) in files { try data.write(to: directory.appendingPathComponent(name)) }
        plan = try .inspect(directory: directory, catalog: catalog, manifest: manifest)
        // Fixture build/numerics identities use the existing test-only override;
        // artifact and prompt identities still come from these actual local files.
        identity = .init(
            modelAggregateHash: hash,
            promptContractID: try PromptContractIdentity.compute(modelDirectory: directory),
            buildID: Data(SHA256.hash(data: Data("glm-provider-factory-build".utf8))).hexString,
            numericsFingerprint: Data(
                SHA256.hash(data: Data("glm-provider-factory-native-fp32-mtp".utf8))
            ).hexString)
    }

    /// Runs `body` with this fixture's model cache, then retires every owner;
    /// an unproven retirement keeps all references and files.
    static func with(
        modelID: String? = nil, chatTemplate: String? = nil,
        _ body: (GLM5NextProtectedFactoryFixture) async throws -> Void
    ) async throws {
        try #require(CBv2MTPConfig.envEnabled, "DARKBLOOM_CBV2_MTP must be enabled")
        let fixture = try GLM5NextProtectedFactoryFixture(modelID: modelID, chatTemplate: chatTemplate)
        let previousCache = ModelScanner.configuredCacheDirectory
        ModelScanner.configureCacheDirectory(fixture.root.appendingPathComponent("scanner").path)
        defer { ModelScanner.configureCacheDirectory(previousCache) }
        let result: Result<Void, any Error>
        do {
            try await body(fixture)
            result = .success(())
        } catch {
            if let construction = error as? GLM5NextNativeConstructionFailure {
                Issue.record("GLM factory refused native construction: \(construction.cause)")
            }
            let failure = await GLM5NextRetirement.validatedFailure(error, retaining: [fixture])
            // Independent owners still get cleanup attempts; the recorded
            // state keeps every reference and file if any retirement is unproven.
            if GLM5NextLoadFunnel.isUnproven(failure) { fixture.recordUnprovenRetirement() }
            result = .failure(failure)
        }
        do {
            try await fixture.close()
        } catch {
            guard case .failure(let failure) = result else { throw error }
            Issue.record("Cleanup after a failed body also failed: \(error)")
            throw failure
        }
        try result.get()
    }

    static func makeBudget() -> GlobalKVCacheBudget {
        GlobalKVCacheBudget(
            activationReserveBytes: UnifiedMemoryCap.defaultActivationReserveBytes,
            memorySnapshot: {
                let usage = Memory.snapshot()
                return .init(
                    total: 64 << 30, active: UInt64(usage.activeMemory),
                    cache: UInt64(usage.cacheMemory), systemAvailable: 64 << 30)
            })
    }

    func load() async throws -> ModelContainer {
        let load = try await GLM5NextManagedLoad.claim(plan: plan, budget: budget)
        let container = try #require(try await load.load().autoregressive)
        containers.append(container)
        return container
    }

    @discardableResult
    func run(_ bridge: EngineV2Bridge, tokens: [Int], id: String) async throws
        -> EngineV2RequestUsageSignal
    {
        let engine = try #require(await bridge.ownedEngine as? EngineV2)
        let previousMTP = try #require(engine.mtpMetricsSnapshot())
        let usage = EngineV2RequestUsageSignal()
        let stream = await bridge.submitTokenized(
            promptTokens: tokens,
            request: .init(
                model: plan.weights.catalog.id, messages: [], temperature: 0, max_tokens: 4),
            requestId: id, cacheScope: "fixture-tenant", cacheEnabled: true, usageSignal: usage)
        var count: Int?
        for await event in stream {
            switch event {
            case .info(_, let tokens, _, _): count = tokens
            case .error(let reason): Issue.record("factory bridge refused: \(reason)")
            default: break
            }
        }
        // A terminal event precedes native retirement. Wait for the actual pump
        // settlement before attributing cumulative MTP deltas to this request.
        await usage.waitForTerminalObservation()
        #expect(count == 4)
        let currentMTP = try #require(engine.mtpMetricsSnapshot())
        #expect(currentMTP.active)
        #expect(currentMTP.rounds > previousMTP.rounds, "request \(id) must run MTP rounds")
        #expect(
            currentMTP.proposedTokens > previousMTP.proposedTokens,
            "request \(id) must propose draft tokens")
        #expect(
            currentMTP.rectangularVerificationRounds > previousMTP.rectangularVerificationRounds)
        return usage
    }

    func expectFactoryRefusal(_ make: () throws -> EngineV2Factory.ProductionBuild) throws {
        do {
            let build = try make()
            if let engine = build.engine as? EngineV2 { unexpectedEngines.append(engine) }
            Issue.record("foreign protected factory tuple was accepted")
        } catch let error as EngineV2ProductionError {
            guard case .pagedUnavailable = error else { throw error }
        }
    }

    private enum CleanupError: Error {
        case retirementUnproven
        case outstandingBudget(UInt64)
        case failures([any Error])
    }

    private static func requireReceipt(
        _ outcome: CBv2NativeShutdownOutcome?, engineID: UUID, contractID: UUID
    ) throws {
        guard case .quiescent(let receipt)? = outcome,
            receipt.engineID == engineID, receipt.executionContractID == contractID,
            receipt.generation == 1
        else {
            throw CleanupError.retirementUnproven
        }
    }

    private func retainAfterUnprovenCleanup() {
        retirementUnproven = true
        GLM5NextLoadFaultState.retain([self])
    }

    func recordUnprovenRetirement() { retainAfterUnprovenCleanup() }

    func close() async throws {
        var failures: [any Error] = []
        var ownedStores = stores
        for bridge in bridges {
            if let store = bridge.ssdHybridCheckpointStore,
                !ownedStores.contains(where: { $0 === store })
            {
                ownedStores.append(store)
            }
            do {
                let nativeOwner = await bridge.glm5NextNativeOwner
                let owner = try #require(nativeOwner)
                if let engine = await bridge.ownedEngine as? EngineV2 {
                    guard engine.nativeShutdownEngineID == owner.engineID,
                        engine.nativeShutdownExecutionContractID == owner.contractID
                    else {
                        throw CleanupError.retirementUnproven
                    }
                }
                try await GLM5NextRetirement.beforeRelease(bridge)
                try Self.requireReceipt(
                    await bridge.nativeShutdownResult,
                    engineID: owner.engineID, contractID: owner.contractID)
                guard await bridge.ownedEngine == nil else { throw CleanupError.retirementUnproven }
            } catch {
                failures.append(error)
                retainAfterUnprovenCleanup()
            }
        }
        for engine in unexpectedEngines {
            do {
                let engineID = engine.nativeShutdownEngineID
                let contractID = engine.nativeShutdownExecutionContractID
                let outcome = await engine.shutdownReportingNativeCompletion()
                guard let contractID,
                    engine.nativeShutdownEngineID == engineID,
                    engine.nativeShutdownExecutionContractID == contractID
                else {
                    throw CleanupError.retirementUnproven
                }
                try Self.requireReceipt(outcome, engineID: engineID, contractID: contractID)
            } catch {
                failures.append(error)
                retainAfterUnprovenCleanup()
            }
        }
        // Attempt every independent owner even after a failed retirement. Keep
        // all references and files unless every native receipt and refund joins.
        for store in ownedStores { await store.closeAndWait() }
        SSDWholeRootMaintainer.shared.stopPeriodicMaintenance(root: cacheRoot)
        SSDWholeRootMaintainer.shared.stopPeriodicMaintenance(
            root: root.appendingPathComponent("foreign-cache"))
        let remaining = await budget.outstandingReservedBytes()
        guard remaining == 0 else {
            failures.append(CleanupError.outstandingBudget(remaining))
            retainAfterUnprovenCleanup()
            throw CleanupError.failures(failures)
        }
        guard failures.isEmpty, !retirementUnproven else {
            if failures.isEmpty { failures.append(CleanupError.retirementUnproven) }
            retainAfterUnprovenCleanup()
            throw CleanupError.failures(failures)
        }
        bridges.removeAll()
        unexpectedEngines.removeAll()
        stores.removeAll()
        containers.removeAll()
        try FileManager.default.removeItem(at: root)
    }

    private static let configuration = #"""
        {"model_type":"glm5_next","architectures":["Glm5NextForConditionalGeneration"],"tie_word_embeddings":false,
         "image_token_id":154854,"video_token_id":154855,"image_start_token_id":154830,"image_end_token_id":154831,
         "video_start_token_id":154832,"video_end_token_id":154833,"quantization":{"bits":4,"group_size":64,"mode":"affine"},
         "text_config":{"model_type":"glm5_next_text","vocab_size":154900,"hidden_size":64,"intermediate_size":64,
          "moe_intermediate_size":64,"num_hidden_layers":4,"num_attention_heads":1,"num_key_value_heads":1,
          "head_dim":0,"qk_head_dim":64,"qk_nope_head_dim":64,"qk_rope_head_dim":0,"v_head_dim":64,
          "q_lora_rank":64,"kv_lora_rank":64,"mla_use_nope":true,
          "layer_types":["linear_attention","linear_attention","linear_attention","deepseek_sparse_attention"],
          "mlp_layer_types":["dense","dense","dense","sparse"],"indexer_types":["full","full","full","full"],
          "linear_attn_config":{"num_heads":1,"head_dim":64,"gate_lower_bound":-5,"short_conv_kernel_size":4,
            "kda_layers":[0,1,2],"full_attn_layers":[3]},
          "index_head_dim":64,"index_n_heads":1,"index_topk":4,"index_kpool":4,"index_kpool_compress":true,
          "index_kpool_always_select_tail":true,"indexer_rope_interleave":true,"index_share_for_mtp_iteration":true,
          "mhc":true,"hc_mult":4,"hc_eps":0.000001,"hc_sinkhorn_iters":20,"first_k_dense_replace":3,
          "n_routed_experts":2,"n_shared_experts":1,"num_experts_per_tok":1,"n_group":1,"topk_group":1,
          "norm_topk_prob":true,"routed_scaling_factor":2.5,"scoring_func":"sigmoid","topk_method":"noaux_tc",
          "moe_router_dtype":"float32","output_router_logits":false,"router_aux_loss_coef":0.001,
          "num_nextn_predict_layers":1,"hidden_act":"silu","swiglu_limit":10,"rms_norm_eps":0.00001,
          "attention_bias":false,"attention_dropout":0,"max_position_embeddings":2048,"initializer_range":0.02,
          "use_cache":true,"tie_word_embeddings":false,"dtype":"bfloat16","pad_token_id":0,"eos_token_id":[2]},
         "vision_config":{"model_type":"glm5_next_vision","depth":1,"hidden_size":8,"intermediate_size":12,
          "num_heads":2,"image_size":8,"patch_size":2,"temporal_patch_size":2,"spatial_merge_size":2,"in_channels":3,
          "out_hidden_size":64,"projection_intermediate_size":8,"hidden_act":"silu","swiglu_limit":10,
          "rms_norm_eps":0.00001,"attention_bias":true,"attention_dropout":0,"initializer_range":0.02}}
        """#
}
