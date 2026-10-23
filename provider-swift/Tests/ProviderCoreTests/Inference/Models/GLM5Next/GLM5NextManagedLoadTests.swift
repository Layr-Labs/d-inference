import CoreImage
import CoreMedia
import CryptoKit
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM
import ProviderCoreFoundation
import Testing

@testable import ProviderCore

/// Self-contained local artifact. The synthetic template is deliberately NOT
/// the official template, and no production path or downloaded model is used.
/// `modelID`/`directory` let isolated host tests place the synthetic bytes
/// under the locally qualified identity in a private HF-style cache.
final class GLM5NextManagedFixture {
    let directory: URL
    let manifest: ModelManifest
    let catalog: CatalogModel
    let configuration: GLM5NextConfiguration

    /// The reviewed template the provider recognizes (`GLM5NextPromptPolicy.templateSHA256`).
    static func shippedTemplate() throws -> String {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { root.deleteLastPathComponent() }
        return try String(contentsOf: root.appendingPathComponent(
            "fixtures/prompt-contract/glm53-flash/eigenlabs-chat_template.jinja"), encoding: .utf8)
    }

    init(modelID: String? = nil, directory: URL? = nil, chatTemplate: String? = nil) throws {
        let root = directory ?? FileManager.default.temporaryDirectory.appendingPathComponent(
            "glm5-managed-\(UUID())")
        self.directory = root
        let text: [String: Any] = [
            "model_type": "glm5_next_text", "vocab_size": 154900, "hidden_size": 64,
            "intermediate_size": 64, "moe_intermediate_size": 64,
            "num_hidden_layers": 4, "num_attention_heads": 1, "num_key_value_heads": 1,
            "head_dim": 0, "qk_head_dim": 64, "qk_nope_head_dim": 64, "qk_rope_head_dim": 0,
            "v_head_dim": 64, "q_lora_rank": 64, "kv_lora_rank": 64, "mla_use_nope": true,
            "layer_types": [
                "linear_attention", "linear_attention", "linear_attention",
                "deepseek_sparse_attention",
            ],
            "mlp_layer_types": ["dense", "dense", "dense", "sparse"],
            "indexer_types": ["full", "full", "full", "full"],
            "linear_attn_config": [
                "num_heads": 1, "head_dim": 64, "gate_lower_bound": -5,
                "short_conv_kernel_size": 4, "kda_layers": [0, 1, 2], "full_attn_layers": [3],
            ],
            "index_head_dim": 64, "index_n_heads": 1, "index_topk": 4, "index_kpool": 4,
            "index_kpool_compress": true, "index_kpool_always_select_tail": true,
            "indexer_rope_interleave": true, "index_share_for_mtp_iteration": true,
            "mhc": true, "hc_mult": 4, "hc_eps": 1e-6, "hc_sinkhorn_iters": 20,
            "first_k_dense_replace": 3, "n_routed_experts": 2, "n_shared_experts": 1,
            "num_experts_per_tok": 1, "n_group": 1, "topk_group": 1,
            "norm_topk_prob": true, "routed_scaling_factor": 2.5, "scoring_func": "sigmoid",
            "topk_method": "noaux_tc", "moe_router_dtype": "float32", "output_router_logits": false,
            "router_aux_loss_coef": 0.001, "num_nextn_predict_layers": 1, "hidden_act": "silu",
            "swiglu_limit": 10, "rms_norm_eps": 1e-5, "attention_bias": false,
            "attention_dropout": 0, "max_position_embeddings": 64, "initializer_range": 0.02,
            "use_cache": true, "tie_word_embeddings": false, "dtype": "bfloat16",
            "pad_token_id": 0, "eos_token_id": [2],
        ]
        let config: [String: Any] = [
            "model_type": "glm5_next", "architectures": ["Glm5NextForConditionalGeneration"],
            "tie_word_embeddings": false, "text_config": text,
            "image_token_id": 154854, "video_token_id": 154855,
            "image_start_token_id": 154830, "image_end_token_id": 154831,
            "video_start_token_id": 154832, "video_end_token_id": 154833,
            "quantization": ["bits": 4, "group_size": 64, "mode": "affine"],
            "vision_config": [
                "model_type": "glm5_next_vision", "depth": 1, "hidden_size": 8,
                "intermediate_size": 12, "num_heads": 2, "image_size": 8, "patch_size": 2,
                "temporal_patch_size": 2, "spatial_merge_size": 2, "in_channels": 3,
                "out_hidden_size": 64, "projection_intermediate_size": 8, "hidden_act": "silu",
                "swiglu_limit": 10, "rms_norm_eps": 1e-5, "attention_bias": true,
                "attention_dropout": 0, "initializer_range": 0.02,
            ],
        ]
        let configData = try JSONSerialization.data(withJSONObject: config, options: .sortedKeys)
        configuration = try JSONDecoder().decode(GLM5NextConfiguration.self, from: configData)
        let tensors = try GLM5NextWeightInventory.expectedTensors(
            configuration: configuration,
            storage: .vontraQ4, shard: "weights.safetensors")
        let inventory = try GLM5NextWeightInventory.validate(
            configuration: configuration,
            tensors: tensors, storage: .vontraQ4)
        var payload = Data()
        var header: [String: Any] = [:]
        for tensor in tensors {
            let entry = inventory.entries[tensor.name]!
            let start = payload.count
            if tensor.name.contains("norm.weight") || tensor.name.hasSuffix("_scale") {
                if tensor.dtype == "BF16" {
                    let ones = [UInt16](repeating: 0x3f80, count: entry.bytes / 2)
                    payload.append(ones.withUnsafeBytes { Data($0) })
                } else {
                    let ones = [Float](repeating: 1, count: entry.bytes / 4)
                    payload.append(ones.withUnsafeBytes { Data($0) })
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
        var size = UInt64(encodedHeader.count).littleEndian
        var shard = withUnsafeBytes(of: &size) { Data($0) }
        shard.append(encodedHeader)
        shard.append(payload)
        let vocabulary = [
            "<unk>": 0, "<s>": 1, "</s>": 2, "x": 3,
            "<|image|>": 154854, "<|video|>": 154855, "<|begin_of_image|>": 154830,
            "<|end_of_image|>": 154831, "<|begin_of_video|>": 154832, "<|end_of_video|>": 154833,
            // The serving tokenizer requires both atomic thinking tokens.
            "<think>": 154841, "</think>": 154842,
        ]
        let added: [[String: Any]] = vocabulary.sorted { $0.key < $1.key }.filter { $0.key != "x" }.map { token, id in
            [
                "id": id, "content": token, "single_word": false, "lstrip": false,
                "rstrip": false, "normalized": false, "special": true,
            ]
        }
        let tokenizer: [String: Any] = [
            "version": "1.0", "truncation": NSNull(), "padding": NSNull(),
            "added_tokens": added, "normalizer": NSNull(), "pre_tokenizer": ["type": "Whitespace"],
            "post_processor": NSNull(), "decoder": ["type": "ByteLevel"],
            "model": [
                "type": "BPE", "vocab": vocabulary, "merges": [], "unk_token": "<unk>",
                "byte_fallback": false, "fuse_unk": false,
            ],
        ]
        let template = chatTemplate ?? """
            {% for message in messages %}{% if message['content'] is string %}{{ message['content'] }}{% else %}{% for part in message['content'] %}{% if part['type'] == 'image' %}<|begin_of_image|><|image|><|end_of_image|>{% elif part['type'] == 'video' %}<|begin_of_video|><|video|><|end_of_video|>{% else %}{{ part['text'] }}{% endif %}{% endfor %}{% endif %}{% endfor %}x
            """
        let processorMedia: [String: Any] = [
            "do_rescale": true, "patch_expand_factor": 1,
            "merge_size": 2, "image_mean": GLM5NextProcessor.mean,
            "image_std": GLM5NextProcessor.standardDeviation, "temporal_patch_size": 2,
            "patch_size": 2, "min_image_tokens": 1, "max_image_tokens": 4, "fps": 2,
            "image_processor_type": "Glm5NextImageProcessor",
            "video_processor_type": "Glm5NextVideoProcessor",
        ]
        let files: [String: Data] = [
            "config.json": configData, "weights.safetensors": shard,
            "model.safetensors.index.json": try JSONSerialization.data(withJSONObject: [
                "metadata": ["total_size": payload.count],
                "weight_map": Dictionary(uniqueKeysWithValues: tensors.map { ($0.name, $0.shard) }),
            ]),
            "tokenizer.json": try JSONSerialization.data(
                withJSONObject: tokenizer, options: .sortedKeys),
            "tokenizer_config.json": try JSONSerialization.data(withJSONObject: [
                "tokenizer_class": "PreTrainedTokenizerFast", "eos_token": "</s>",
                "unk_token": "<unk>",
                "chat_template": template,
            ]), "chat_template.jinja": Data(template.utf8),
            "processor_config.json": try JSONSerialization.data(withJSONObject: [
                "processor_class": "Glm5NextProcessor",
                "image_processor": processorMedia, "video_processor": processorMedia,
            ]),
            "generation_config.json": Data("{\"eos_token_id\":[2,4]}".utf8),
        ]
        let entries = files.keys.sorted().map { name in
            ManifestFile(
                path: name, sizeBytes: Int64(files[name]!.count),
                sha256: SHA256.hash(data: files[name]!).map { String(format: "%02x", $0) }.joined(),
                role: ModelScanner.roleFor(filename: name))
        }
        var combined = SHA256()
        for name in files.keys.sorted() {
            combined.update(data: Data(SHA256.hash(data: files[name]!)))
        }
        let aggregate = combined.finalize().map { String(format: "%02x", $0) }.joined()
        let id = modelID ?? "synthetic/glm5-\(UUID())"
        manifest = .init(
            schemaVersion: 1, modelID: id, version: "synthetic-v1", r2Prefix: "synthetic/v1",
            aggregateSHA256: aggregate, totalSizeBytes: entries.reduce(0) { $0 + $1.sizeBytes },
            fileCount: entries.count, files: entries, createdAt: Date(timeIntervalSince1970: 0))
        catalog = .init(
            id: id, s3Name: "synthetic", displayName: "synthetic", sizeGb: 1,
            version: manifest.version, r2Prefix: manifest.r2Prefix,
            huggingFaceArtifact: .init(
                repoID: modelID ?? "synthetic/glm5", revision: String(repeating: "a", count: 40)),
            aggregateSHA256: aggregate, totalSizeBytes: manifest.totalSizeBytes,
            fileCount: manifest.fileCount)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: directory != nil)
        for (name, bytes) in files { try bytes.write(to: root.appendingPathComponent(name)) }
    }
    deinit {
        if !GLM5NextLoadFaultState.isRetained { try? FileManager.default.removeItem(at: directory) }
    }
    func plan() throws -> GLM5NextArtifactPlan {
        try .inspect(directory: directory, catalog: catalog, manifest: manifest)
    }
    func plan(replacingTemplate template: String) throws -> GLM5NextArtifactPlan {
        try plan(replacing: "chat_template.jinja", with: Data(template.utf8))
    }
    func plan(replacing name: String, with data: Data) throws -> GLM5NextArtifactPlan {
        try data.write(to: directory.appendingPathComponent(name))
        var aggregate = SHA256()
        let files = try manifest.files.sorted(by: { $0.path < $1.path }).map { entry in
            let data = try Data(contentsOf: directory.appendingPathComponent(entry.path))
            let digest = SHA256.hash(data: data)
            aggregate.update(data: Data(digest))
            return ManifestFile(
                path: entry.path, sizeBytes: Int64(data.count),
                sha256: digest.map { String(format: "%02x", $0) }.joined(), role: entry.role)
        }
        let hash = aggregate.finalize().map { String(format: "%02x", $0) }.joined()
        let replaced = ModelManifest(
            schemaVersion: manifest.schemaVersion, modelID: manifest.modelID,
            version: manifest.version, r2Prefix: manifest.r2Prefix, aggregateSHA256: hash,
            totalSizeBytes: files.reduce(0) { $0 + $1.sizeBytes }, fileCount: files.count,
            files: files, createdAt: manifest.createdAt)
        let selection = CatalogModel(
            id: catalog.id, s3Name: catalog.s3Name, displayName: catalog.displayName,
            sizeGb: catalog.sizeGb, version: replaced.version, r2Prefix: replaced.r2Prefix,
            huggingFaceArtifact: catalog.huggingFaceArtifact, aggregateSHA256: hash)
        return try .inspect(directory: directory, catalog: selection, manifest: replaced)
    }
}

private final class GLM5NextEvaluationProbe: @unchecked Sendable {
    enum Refusal: Error { case requested }
    private let lock = NSLock()
    private var evaluations = 0
    private weak var array: MLXArray?
    var count: Int { lock.withLock { evaluations } }
    var hasLiveArray: Bool { lock.withLock { array != nil } }
    func observe(_ arrays: [MLXArray], stopAt: Int) throws {
        try lock.withLock {
            evaluations += 1
            if array == nil { array = arrays.first }
            if evaluations == stopAt { throw Refusal.requested }
        }
    }
}

@Suite struct GLM5NextManagedMetadataTests {
    @Test func enforcedContextIsExplicitAndRejectsOversizedRequests() throws {
        for bound in [512, 4096] {
            #expect(try GLM5NextExecutionBound.require(bound, modelMaximum: 1_048_576) == bound)
            try GLM5NextExecutionBound.validateRequest(
                promptTokens: bound - 4, maximumOutputTokens: 4, limit: bound)
            #expect(throws: GLM5NextExecutionBoundError.self) {
                try GLM5NextExecutionBound.validateRequest(
                    promptTokens: bound, maximumOutputTokens: 1, limit: bound)
            }
        }
        for value: Int? in [nil, 0, -1, 1_048_577] {
            #expect(throws: GLM5NextExecutionBoundError.self) {
                try GLM5NextExecutionBound.require(value, modelMaximum: 1_048_576)
            }
        }
        #expect(throws: GLM5NextExecutionBoundError.self) {
            try GLM5NextExecutionBound.validateRequest(
                promptTokens: Int.max, maximumOutputTokens: 1, limit: 4096)
        }
    }

    @Test func preparedBoundMustMatchAllBackendContextFields() throws {
        func configuration(nominal: Int, gathered: Int, query: Int = 16) throws -> PagedKVPoolConfig
        {
            let limits = try CBv2PagedGatheredAttentionLimits(
                maximumBatchSize: 1,
                maximumQueryTokens: query, maximumContextTokens: gathered, maximumInFlightGraphs: 2,
                maximumScratchBytes: 1 << 20, admissionMode: .stepOwned(.pinnedMetal))
            return PagedKVPoolConfig(
                capacityBytes: 16 << 20, dtype: .float32,
                maxPrefillChunk: query, nominalMaxSequenceLength: nominal,
                maxBufferLength: 16 << 20, segmentSizeBytes: 1 << 20, gatheredAttention: limits)
        }
        try GLM5NextExecutionBound.validateBackend(
            configuration(nominal: 512, gathered: 512), prepared: 512)
        for pair in [(512, 4096), (4096, 512), (4096, 4096)] {
            #expect(throws: GLM5NextExecutionBoundError.self) {
                try GLM5NextExecutionBound.validateBackend(
                    configuration(nominal: pair.0, gathered: pair.1), prepared: 512)
            }
        }
    }

    @Test func nativeMTPPlanStillPricesTheEntireExplicitBound() throws {
        let fixture = try GLM5NextManagedFixture()
        let limits = CBv2MTPAllocationLimits(maximumPrefillTokens: 8, maximumDraftTokens: 1)
        let shorter = try GLM5NextMTPExecution.memoryPlan(
            configuration: fixture.configuration.textConfig,
            maximumInputs: 16, limits: limits)
        let longer = try GLM5NextMTPExecution.memoryPlan(
            configuration: fixture.configuration.textConfig,
            maximumInputs: 32, limits: limits)
        #expect(shorter.maximumInputs == 16 && longer.maximumInputs == 32)
        let shortBytes = shorter.cacheBuffers.reduce(0) {
            $0 + $1.logicalBytes * $1.allocationCount
        }
        let longBytes = longer.cacheBuffers.reduce(0) { $0 + $1.logicalBytes * $1.allocationCount }
        #expect(longBytes > shortBytes)
    }
    /// GLM serves only with its embedded MTP, so `.auto` now enables it (no
    /// operator knob); the load allowance still never replaces generic headroom.
    @Test func outerLoadAllowanceNeverReplacesGenericHeadroomAndAutoEnablesGLMMTP() throws {
        let fixture = try GLM5NextManagedFixture()
        let plan = try fixture.plan()
        let larger = plan.quotation.estimatedWeightsGb + 10
        #expect(GLM5NextLoadFunnel.estimatedWeightsGb(scanned: larger, plan: plan) == larger)
        #expect(
            GLM5NextLoadFunnel.pendingBytes(scanned: 0, plan: plan, extra: 0)
                >= plan.quotation.requiredWeightBytes)
        #expect(
            try GLM5NextLoadFunnel.preparation(plan: plan, mode: .auto, externalPath: nil).status
                .configured)
        #expect(
            try GLM5NextLoadFunnel.preparation(plan: plan, mode: .on, externalPath: nil).artifact
                == nil)
        #expect(throws: GLM5NextManagedLoadError.self) {
            try GLM5NextLoadFunnel.preparation(
                plan: plan, mode: .on, externalPath: "unowned-assistant")
        }
    }

    @Test func offlineManifestMappingRequiresAnIndependentExpectedIdentity() throws {
        // The qualification entry accepts only the locally qualified identity.
        let fixture = try GLM5NextManagedFixture(modelID: GLM5NextLocalQualification.modelID)
        let url = fixture.directory.appendingPathComponent("qualification-manifest.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(fixture.manifest).write(to: url)
        let source = HuggingFaceArtifact(
            repoID: fixture.catalog.id, revision: String(repeating: "a", count: 40))
        let plan = try GLM5NextLocalQualification.plan(
            directory: fixture.directory, manifestURL: url,
            source: source, expectedAggregateSHA256: fixture.manifest.aggregateSHA256)
        #expect(plan.nativeIdentity.repository == source.repoID)
        #expect(plan.weights.catalog.version == fixture.manifest.version)
        #expect(plan.weights.catalog.aggregateSHA256 == fixture.manifest.aggregateSHA256)
        #expect(throws: GLM5NextManagedLoadError.self) {
            try GLM5NextLocalQualification.plan(
                directory: fixture.directory, manifestURL: url,
                source: source, expectedAggregateSHA256: String(repeating: "0", count: 64))
        }
    }
    @Test func rawDiscoveryQuotationMatchesManagedTinyFixture() throws {
        let fixture = try GLM5NextManagedFixture()
        let plan = try fixture.plan()
        let info = try #require(
            ModelScanner.parseModelInfo(
                snapshotDir: fixture.directory, modelName: "arbitrary/catalog-id"))
        let estimate = try #require(
            ModelScanner.glm5NextLoadEstimate(
                snapshotDir: fixture.directory, sizeBytes: info.sizeBytes))
        #expect(estimate.sourceBytes == UInt64(fixture.manifest.totalSizeBytes))
        #expect(estimate.nativeTransientBytes == plan.quotation.nativeTransientBytes)
        #expect(estimate.tokenizerAllowanceBytes == plan.quotation.tokenizerAllowanceBytes)
        #expect(estimate.residualAllowanceBytes == plan.quotation.residualAllowanceBytes)
        #expect(estimate.totalBytes == plan.quotation.requiredWeightBytes)
        #expect(info.estimatedMemoryGb == plan.quotation.estimatedWeightsGb)
        #expect(info.nativeLoadTransientBytes == estimate.supplementBytes)
        #expect(info.ssdOffloadedWeightBytes == nil)
        // The shared pre-allocation recheck must not read GLM's declaration
        // as a stale Qwen4 SSD-offload allowance.
        #expect(Qwen4ExpLoadFootprint.isCurrent(info, directory: fixture.directory))
        #expect(ModelScanner.glm5NextLoadQuotationIsCurrent(info, directory: fixture.directory))
        var underquote = info
        underquote.nativeLoadTransientBytes = estimate.supplementBytes - 1
        #expect(
            !ModelScanner.glm5NextLoadQuotationIsCurrent(underquote, directory: fixture.directory))
        let wire =
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(info)) as! [String: Any]
        #expect((wire["native_load_transient_bytes"] as? UInt64) == estimate.supplementBytes)
        #expect(wire["ssd_offloaded_weight_bytes"] == nil)
        // A changed source is re-priced, never justified by a download receipt.
        try Data(repeating: 0, count: 16 << 20).write(
            to: fixture.directory.appendingPathComponent("tokenizer.json"))
        #expect(
            !ModelScanner.glm5NextLoadQuotationIsCurrent(info, directory: fixture.directory))
    }

    @Test func frameBudgetPricesGLMQueryTilesAndRejectsOversizedBuffers() throws {
        let fixture = try GLM5NextManagedFixture()
        let config = fixture.configuration.visionConfig
        let limits = VisionTowerBudget.Limits(
            maxBufferBytes: 4 << 20,
            attentionElementBytes: 2, headFactor: 1, operatorMaxPatches: 64)
        let plan = try VisionTowerBudget.glm5FrameLimits(
            grid: THW(1, 4, 4), configuration: config, limits: limits)
        #expect(plan.maximumQueryTokens <= 16 && plan.maximumFramePatches == 64)
        #expect(throws: EngineV2VisionPrefillError.self) {
            try VisionTowerBudget.glm5FrameLimits(
                grid: THW(1, 16, 16), configuration: config, limits: limits)
        }
        #expect(throws: EngineV2VisionPrefillError.self) {
            try VisionTowerBudget.glm5FrameLimits(
                grid: THW(1, 4, 4), configuration: config,
                limits: .init(maxBufferBytes: 8, attentionElementBytes: 2, headFactor: 1))
        }
    }

    @Test func httpMediaRejectsUnknownPartsAndNonUserMediaBeforeDecode() async throws {
        for role in ["assistant", "system"] {
            let body = Data(
                """
                {"model":"synthetic","messages":[{"role":"\(role)","content":[{"type":"image_url","image_url":{"url":"not-a-url"}}]}]}
                """.utf8)
            let request = try ProviderLoop.decodeOpenAIRequest(body, modelType: "glm5_next")
            await #expect(throws: EngineV2VisionPrefillError.self) {
                try await EngineV2VisionPrefill.glm5NextUserInput(
                    request: request, controls: .init())
            }
        }
    }

    @Test func exactPlanRetainsAllPartitionsAndRawTemplateIdentity() throws {
        let fixture = try GLM5NextManagedFixture()
        let plan = try fixture.plan()
        #expect(
            plan.quotation.textBytes > 0 && plan.quotation.visionBytes > 0
                && plan.quotation.mtpBytes > 0)
        let quote = plan.quotation
        #expect(quote.sourceBytes == UInt64(fixture.manifest.totalSizeBytes))
        #expect(quote.residualAllowanceBytes == 1 << 30)
        #expect(quote.requiredWeightBytes == quote.sourceBytes + quote.nativeTransientBytes
            + quote.tokenizerAllowanceBytes + quote.residualAllowanceBytes)
        #expect(plan.templateSHA256 == fixture.manifest.files.first {
            $0.path == "chat_template.jinja" }?.sha256)
        #expect(!plan.usesShippedPromptTemplate)
        #expect(plan.eosTokenIDs == [2, 4])
    }

    /// The pinned renderer cannot parse the official spelling, so only the
    /// shipped artifact template is recognized and passes the load-time render check.
    @Test func onlyTheShippedArtifactTemplateIsRecognizedAndRenders() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { root.deleteLastPathComponent() }
        let prompts = root.appendingPathComponent("fixtures/prompt-contract/glm53-flash")
        let fixture = try GLM5NextManagedFixture()
        let shipped = try fixture.plan(replacingTemplate: String(
            contentsOf: prompts.appendingPathComponent("eigenlabs-chat_template.jinja"), encoding: .utf8))
        #expect(shipped.usesShippedPromptTemplate)
        #expect(TemplateRenderCheck.renderOK(at: fixture.directory) == true)
        let official = try fixture.plan(replacingTemplate: String(
            contentsOf: prompts.appendingPathComponent("chat_template.jinja"), encoding: .utf8))
        #expect(!official.usesShippedPromptTemplate)
        #expect(TemplateRenderCheck.renderOK(at: fixture.directory) == false)
    }

    @Test func inspectionDoesNotReadOrHashWeightPayloads() throws {
        let fixture = try GLM5NextManagedFixture()
        let url = fixture.directory.appendingPathComponent("weights.safetensors")
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.seek(toOffset: 64)
        try handle.write(contentsOf: Data([255]))
        try handle.close()
        // Same-size corrupted bytes remain undiagnosed by metadata inspection.
        // The admitted load's existing WeightHasher must diagnose them.
        let plan = try fixture.plan()
        #expect(throws: GLM5NextManagedLoadError.self) { try plan.weights.verifyContents() }
    }

    @Test func unmanagedGenericLoadAndChangedMetadataFailClosed() async throws {
        let fixture = try GLM5NextManagedFixture()
        await #expect(throws: GLM5NextManagedLoadError.self) {
            try await ModelContainerLoading.loadServingContainer(from: fixture.directory)
        }
        let plan = try fixture.plan()
        try Data("changed".utf8).write(
            to: fixture.directory.appendingPathComponent("chat_template.jinja"))
        #expect(throws: GLM5NextManagedLoadError.self) { try plan.weights.recheck() }
        #expect(throws: GLM5NextManagedLoadError.self) { try fixture.plan() }
    }

    @Test func realPendingPermitRejectsUndersizingAndReleasesCancellation() async throws {
        let fixture = try GLM5NextManagedFixture()
        let plan = try fixture.plan()
        let gib: UInt64 = 1 << 30
        let budget = GlobalKVCacheBudget(
            activationReserveBytes: UnifiedMemoryCap.defaultActivationReserveBytes,
            memorySnapshot: { .init(total: 64 * gib, active: 0, cache: 0, systemAvailable: .max) })
        let id = "pending-load:\(fixture.catalog.id)"
        let undersized = try #require(await budget.claimPendingLoad(requestID: id, weightBytes: 1))
        await #expect(throws: GLM5NextManagedLoadError.self) {
            try await GLM5NextManagedLoad.adopting(plan: plan, budget: budget, permit: undersized)
        }
        await budget.finishPendingLoad(undersized)
        let load = try await GLM5NextManagedLoad.claim(plan: plan, budget: budget)
        #expect(await budget.outstandingReservedBytes() >= plan.quotation.requiredWeightBytes)
        try await load.cancelBeforeStart()
        #expect(await budget.outstandingReservedBytes() == 0)
        await #expect(throws: GLM5NextManagedLoadError.self) { try await load.cancelBeforeStart() }
    }

    @Test func foreignGenerationAndLowActivationFloorAreNotAuthorization() async throws {
        let fixture = try GLM5NextManagedFixture()
        let plan = try fixture.plan()
        let budget = GlobalKVCacheBudget(
            activationReserveBytes: 0,
            memorySnapshot: { .init(total: 64 << 30, active: 0, cache: 0, systemAvailable: .max) })
        await #expect(throws: GLM5NextManagedLoadError.self) {
            try await GLM5NextManagedLoad.claim(plan: plan, budget: budget)
        }
        #expect(await budget.outstandingReservedBytes() == 0)
    }

    @Test func adoptedPermitRemainsOwnedByTheOuterLoadFunnel() async throws {
        let fixture = try GLM5NextManagedFixture()
        let plan = try fixture.plan()
        let budget = GlobalKVCacheBudget(
            activationReserveBytes: UnifiedMemoryCap.defaultActivationReserveBytes,
            memorySnapshot: { .init(total: 64 << 30, active: 0, cache: 0, systemAvailable: .max) })
        let permit = try #require(
            await budget.claimPendingLoad(
                requestID: "pending-load:\(fixture.catalog.id)",
                weightBytes: plan.quotation.requiredWeightBytes))
        let load = try await GLM5NextManagedLoad.adopting(
            plan: plan, budget: budget, permit: permit)
        try await load.cancelBeforeStart()
        #expect(await budget.outstandingReservedBytes() > 0)
        #expect(await budget.finishPendingLoad(permit))
        await #expect(throws: GLM5NextManagedLoadError.self) {
            try await GLM5NextManagedLoad.adopting(plan: plan, budget: budget, permit: permit)
        }
    }

    /// The published NVFP4 `config.json` is ~10 MB; the plan reads it up to the
    /// native loader's 32 MiB bound and refuses anything larger.
    @Test func planReadsNVFP4SizedConfigurationUpToTheNativeLoaderBound() throws {
        let fixture = try GLM5NextManagedFixture()
        let original = try Data(contentsOf: fixture.directory.appendingPathComponent("config.json"))
        var config = try #require(try JSONSerialization.jsonObject(with: original) as? [String: Any])
        // The strict decoder refuses unknown keys; this optional string is free-form.
        func padded(toBytes target: Int) throws -> Data {
            config["transformers_version"] = ""
            let overhead = try JSONSerialization.data(withJSONObject: config, options: .sortedKeys).count
            config["transformers_version"] = String(repeating: "x", count: target - overhead)
            let data = try JSONSerialization.data(withJSONObject: config, options: .sortedKeys)
            #expect(data.count == target)
            return data
        }
        let limit = GLM5NextDiscoveryLoadFootprint.maximumConfigurationBytes
        _ = try fixture.plan(replacing: "config.json", with: padded(toBytes: 10_023_646))
        _ = try fixture.plan(replacing: "config.json", with: padded(toBytes: limit))
        #expect(throws: GLM5NextManagedLoadError.self) {
            try fixture.plan(replacing: "config.json", with: padded(toBytes: limit + 1))
        }
    }

    @Test func unpinnedCatalogAndExtraIntegrityFilesAreRejected() throws {
        let fixture = try GLM5NextManagedFixture()
        let unpinned = CatalogModel(
            id: fixture.catalog.id, s3Name: "untrusted", displayName: "untrusted", sizeGb: 1)
        #expect(throws: GLM5NextManagedLoadError.self) {
            try GLM5NextArtifactPlan.inspect(
                directory: fixture.directory, catalog: unpinned, manifest: fixture.manifest)
        }
        try Data("extra".utf8).write(
            to: fixture.directory.appendingPathComponent("chat_template.json"))
        #expect(throws: GLM5NextManagedLoadError.self) { try fixture.plan() }
    }
}

/// Run only in an isolated filtered test process. The explicit opt-in cannot
/// select real weights; this suite creates its own complete synthetic artifact.
@Suite(.serialized) struct GLM5NextManagedKernelTests {
    @Test(
        .enabled(
            if: ProcessInfo.processInfo.environment["DARKBLOOM_TEST_GLM5_MANAGED_SYNTHETIC"] == "1")
    )
    func checkedExpertBanksRetireIndividualSourceRoots() throws {
        let fixture = try GLM5NextManagedFixture()
        let plan = try fixture.plan()
        let roots = GLM5NextArtifactLoadRoots()
        let artifact = try GLM5NextArtifactLoader(
            directory: fixture.directory,
            expectedIdentity: plan.nativeIdentity, storage: .vontraQ4, constructionRoots: roots)
        let model = try artifact.loadTextModel()
        #expect(roots.retainedExpertSourceCount == 0)
        #expect(roots.retainedArrayCount == 0 && roots.retainedOwnerCount == 1)
        try MLX.withError { errors in
            eval(model.parameters().flattened().map(\.1))
            try errors.check()
        }
        roots.releaseAfterConfirmedFence()
        #expect(roots.retainedOwnerCount == 0)
    }
    @Test(
        .enabled(
            if: ProcessInfo.processInfo.environment["DARKBLOOM_TEST_GLM5_MANAGED_SYNTHETIC"] == "1")
    )
    func glmTemplateProbeRunsBeforeAnyTensorAllocation() async throws {
        let fixture = try GLM5NextManagedFixture()
        let oldCache = ModelScanner.configuredCacheDirectory
        ModelScanner.configureCacheDirectory(
            fixture.directory.appendingPathComponent("isolated-cache").path)
        defer { ModelScanner.configureCacheDirectory(oldCache) }
        let plan = try fixture.plan(
            replacingTemplate:
                "{% if reasoning_effort is defined %}{{ reasoning_effort.items() }}{% endif %}x")
        #expect(TemplateRenderCheck.renderOK(at: fixture.directory) == true)
        let probe = GLM5NextEvaluationProbe()
        let budget = GlobalKVCacheBudget(
            activationReserveBytes: UnifiedMemoryCap.defaultActivationReserveBytes,
            memorySnapshot: { .init(total: 64 << 30, active: 0, cache: 0, systemAvailable: .max) })
        let load = try await GLM5NextManagedLoad.claim(
            plan: plan, budget: budget,
            hooks: .init(beforeEvaluation: { try probe.observe($0, stopAt: 1) }))
        await #expect(throws: (any Error).self) { try await load.load() }
        #expect(probe.count == 0)
        #expect(await budget.outstandingReservedBytes() == 0)
    }

    @Test(
        .enabled(
            if: ProcessInfo.processInfo.environment["DARKBLOOM_TEST_GLM5_MANAGED_SYNTHETIC"] == "1")
    )
    func partialInitializerFailureReleasesRootsOnlyAfterCheckedFence() async throws {
        let fixture = try GLM5NextManagedFixture()
        let oldCache = ModelScanner.configuredCacheDirectory
        ModelScanner.configureCacheDirectory(
            fixture.directory.appendingPathComponent("isolated-cache").path)
        defer { ModelScanner.configureCacheDirectory(oldCache) }
        let probe = GLM5NextEvaluationProbe()
        let budget = GlobalKVCacheBudget(
            activationReserveBytes: UnifiedMemoryCap.defaultActivationReserveBytes)
        let load = try await GLM5NextManagedLoad.claim(
            plan: fixture.plan(), budget: budget,
            hooks: .init(
                beforeEvaluation: { try probe.observe($0, stopAt: 2) },
                beforeCleanupFence: { #expect(probe.hasLiveArray) }))
        await #expect(throws: GLM5NextEvaluationProbe.Refusal.self) { try await load.load() }
        #expect(probe.count == 2 && !probe.hasLiveArray)
        let retained = await load.constructionSnapshot()
        #expect(retained.arrays == 0 && retained.owners == 0)
        #expect(await budget.outstandingReservedBytes() == 0)
    }

    /// Run alone: it deliberately verifies a process-lifetime retained fault.
    @Test(
        .enabled(
            if: ProcessInfo.processInfo.environment["DARKBLOOM_TEST_GLM5_RETAINED_FAULT"] == "1"))
    func failedCleanupFenceRetainsPartialNativeRootsAndPermit() async throws {
        let fixture = try GLM5NextManagedFixture()
        let oldCache = ModelScanner.configuredCacheDirectory
        ModelScanner.configureCacheDirectory(
            fixture.directory.appendingPathComponent("isolated-cache").path)
        defer { ModelScanner.configureCacheDirectory(oldCache) }
        let probe = GLM5NextEvaluationProbe()
        let budget = GlobalKVCacheBudget(
            activationReserveBytes: UnifiedMemoryCap.defaultActivationReserveBytes)
        let load = try await GLM5NextManagedLoad.claim(
            plan: fixture.plan(), budget: budget,
            hooks: .init(
                beforeEvaluation: { try probe.observe($0, stopAt: 2) },
                beforeCleanupFence: {
                    #expect(probe.hasLiveArray)
                    throw GLM5NextEvaluationProbe.Refusal.requested
                }))
        await #expect(throws: GLM5NextManagedLoadError.retirementUnproven) { try await load.load() }
        let retained = await load.constructionSnapshot()
        #expect(retained.arrays >= 2 && probe.hasLiveArray)
        #expect(await budget.outstandingReservedBytes() > 0)
        #expect(GLM5NextLoadFaultState.isRetained)
    }
    @Test(
        .enabled(
            if: ProcessInfo.processInfo.environment["DARKBLOOM_TEST_GLM5_MANAGED_SYNTHETIC"] == "1")
    )
    func outerWriterOwnershipIsBorrowedWithoutNestedAcquisition() async throws {
        let fixture = try GLM5NextManagedFixture()
        let oldCache = ModelScanner.configuredCacheDirectory
        ModelScanner.configureCacheDirectory(
            fixture.directory.appendingPathComponent("isolated-cache").path)
        defer { ModelScanner.configureCacheDirectory(oldCache) }
        let plan = try fixture.plan()
        let ownership = try GLM5NextArtifactOwnership.acquire(plan: plan)
        defer { ownership.release() }
        #expect(throws: (any Error).self) { try GLM5NextArtifactOwnership.acquire(plan: plan) }
        let budget = GlobalKVCacheBudget(
            activationReserveBytes: UnifiedMemoryCap.defaultActivationReserveBytes)
        let permit = try #require(
            await budget.claimPendingLoad(
                requestID: "pending-load:\(fixture.catalog.id)",
                weightBytes: plan.quotation.requiredWeightBytes))
        do {
            let load = try await GLM5NextManagedLoad.adopting(
                plan: plan, budget: budget, permit: permit,
                artifactOwnership: ownership)
            var container = try await load.load().autoregressive
            #expect(container != nil)
            #expect(throws: (any Error).self) { try GLM5NextArtifactOwnership.acquire(plan: plan) }
            await ModelContainerLoading.releaseExternalResources(in: container)
            container = nil
            ownership.release()
            let next = try GLM5NextArtifactOwnership.acquire(plan: plan)
            next.release()
            #expect(await budget.finishPendingLoad(permit))
        } catch {
            if !GLM5NextLoadFunnel.isUnproven(error) { await budget.finishPendingLoad(permit) }
            throw error
        }
    }
    /// The load's own SHA-256 verification is the weight hash callers
    /// publish: it exists only after every manifest file verified, equals
    /// what a separate `WeightHasher` pass reports, and a same-size corrupted
    /// shard leaves it unset.
    @Test(
        .enabled(
            if: ProcessInfo.processInfo.environment["DARKBLOOM_TEST_GLM5_MANAGED_SYNTHETIC"] == "1")
    )
    func verifiedDigestExistsOnlyAfterEveryManifestFileVerified() async throws {
        let fixture = try GLM5NextManagedFixture()
        let oldCache = ModelScanner.configuredCacheDirectory
        ModelScanner.configureCacheDirectory(
            fixture.directory.appendingPathComponent("isolated-cache").path)
        defer { ModelScanner.configureCacheDirectory(oldCache) }
        let budget = GlobalKVCacheBudget(
            activationReserveBytes: UnifiedMemoryCap.defaultActivationReserveBytes)
        let plan = try fixture.plan()
        let load = try await GLM5NextManagedLoad.claim(plan: plan, budget: budget)
        #expect(await load.verifiedArtifactSHA256 == nil)
        var container = try await ModelContainerLoading.loadServingContainer(
            from: fixture.directory, modelID: fixture.catalog.id, nativeGLM5Load: load
        ).autoregressive
        #expect(await load.verifiedArtifactSHA256 == plan.weights.manifest.aggregateSHA256)
        #expect(await load.verifiedArtifactSHA256 == WeightHasher.computeHash(snapshotDir: fixture.directory))
        let phases = try #require(await load.phases)
        #expect(phases.coreVerification > .zero && phases.construction > .zero)
        #expect(phases.total >= phases.auxiliaryVerification + phases.coreVerification + phases.construction)
        await ModelContainerLoading.releaseExternalResources(in: container)
        container = nil

        let shard = fixture.directory.appendingPathComponent("weights.safetensors")
        var bytes = try Data(contentsOf: shard)
        bytes[bytes.count - 1] ^= 0xFF
        try bytes.write(to: shard)
        let corrupted = try await GLM5NextManagedLoad.claim(plan: try fixture.plan(), budget: budget)
        await #expect(throws: (any Error).self) { _ = try await corrupted.load() }
        #expect(await corrupted.verifiedArtifactSHA256 == nil)
        #expect(await budget.outstandingReservedBytes() == 0)
    }

    @Test(
        .enabled(
            if: ProcessInfo.processInfo.environment["DARKBLOOM_TEST_GLM5_MANAGED_SYNTHETIC"] == "1")
    )
    func actualProviderContainerUsesLocalTokenizerProcessorAndNativeRoot() async throws {
        let fixture = try GLM5NextManagedFixture()
        let oldCache = ModelScanner.configuredCacheDirectory
        let cache = fixture.directory.appendingPathComponent("isolated-cache")
        ModelScanner.configureCacheDirectory(cache.path)
        defer { ModelScanner.configureCacheDirectory(oldCache) }
        let plan = try fixture.plan()
        let budget = GlobalKVCacheBudget(
            activationReserveBytes: UnifiedMemoryCap.defaultActivationReserveBytes)
        let load = try await GLM5NextManagedLoad.claim(plan: plan, budget: budget)
        var container = try await ModelContainerLoading.loadServingContainer(
            from: fixture.directory,
            modelID: fixture.catalog.id, nativeGLM5Load: load
        ).autoregressive
        #expect(await budget.outstandingReservedBytes() == 0)
        let result = try await container!.perform { context in
            let root = try #require(context.model as? GLM5NextModel)
            #expect(context.processor is GLM5NextProcessor)
            #expect(root.mtp != nil)
            #expect(context.tokenizer.convertTokenToId("<|image|>") == 154854)
            let output = try root.forward(LMInput(tokens: MLXArray([Int32(3)], [1, 1])))
            return output.logits.shape == [1, 1, 154900]
                && output.logits.asType(.float32).asArray(Float.self).allSatisfy(\.isFinite)
        }
        #expect(result)
        // The re-slice weight equals the engine's admitted FP32 row rate for
        // the actual loaded layer kinds (not a hand-written geometry).
        let sizing = try await GLM5NextLoadFunnel.sizing(container: container!, defaultMaxTokens: 16)
        let kinds = try await container!.perform { context in
            try #require(context.model as? GLM5NextModel).textTower.cbv2LayerKinds
        }
        #expect(!kinds.isEmpty && sizing.fp16KVBytesPerToken > 0)
        #expect(sizing.fp16KVBytesPerToken == EngineV2SlotFactory.slotKVBytesPerToken(
            resolvedKind: .paged, pagedPoolDType: "float32",
            nativeLayerDTypes: Array(repeating: .float32, count: kinds.count),
            layerKinds: kinds, nominalFP16BytesPerToken: 0, servingModelIsGPTOSS: false))
        await ModelContainerLoading.releaseExternalResources(in: container)
        container = nil
    }

    @Test(
        .enabled(
            if: ProcessInfo.processInfo.environment["DARKBLOOM_TEST_GLM5_MANAGED_SYNTHETIC"] == "1")
    )
    func ordinaryFactoryRunsTextHTTPImageAndProtectedEmbeddedMTP() async throws {
        let fixture = try GLM5NextManagedFixture()
        let oldCache = ModelScanner.configuredCacheDirectory
        ModelScanner.configureCacheDirectory(
            fixture.directory.appendingPathComponent("isolated-cache").path)
        defer { ModelScanner.configureCacheDirectory(oldCache) }
        let budget = GlobalKVCacheBudget(
            activationReserveBytes: UnifiedMemoryCap.defaultActivationReserveBytes)
        let load = try await GLM5NextManagedLoad.claim(plan: fixture.plan(), budget: budget)
        let serving = try await ModelContainerLoading.loadServingContainer(
            from: fixture.directory,
            modelID: fixture.catalog.id, nativeGLM5Load: load)
        let container = try #require(serving.autoregressive)
        // The fixture is not Sendable; closures capture only its immutable ID.
        let catalogID = fixture.catalog.id
        let textEngine = try await container.perform { context -> EngineV2 in
            let root = try #require(context.model as? GLM5NextModel)
            #expect(try EngineV2Factory.directServingModel(model: root, isVLM: true) === root)
            let metadata = try #require(EngineV2Factory.ProductionModelAdapter(model: root))
            #expect(metadata.layerKinds == root.textTower.cbv2LayerKinds)
            #expect(metadata.layerKinds.count == 1 && metadata.layerKinds[0].kvHeads == 1)
            #expect(throws: EngineV2ProductionError.self) {
                try EngineV2Factory.makeProductionBuild(
                    model: root, tokenizer: context.tokenizer,
                    kvBytesCapacity: 256 << 20, maxConcurrentRequests: 1, kvBudget: budget,
                    kvBackend: .contiguous, maxContextLength: 64)
            }
            // Target-only GLM is a benchmark baseline, never a serving engine.
            #expect(throws: EngineV2ProductionError.self) {
                try EngineV2Factory.makeProductionBuild(
                    model: root, modelID: catalogID,
                    tokenizer: context.tokenizer, kvBytesCapacity: 256 << 20, maxConcurrentRequests: 1,
                    kvBudget: budget, kvBackend: .paged, maxContextLength: 64)
            }
            let build = try EngineV2Factory.makeProductionBuild(
                model: root, modelID: catalogID,
                tokenizer: context.tokenizer, kvBytesCapacity: 256 << 20, maxConcurrentRequests: 1,
                constructionPurpose: .benchmark,
                kvBudget: budget, kvBackend: .paged, maxContextLength: 64)
            #expect(build.kvBackendKind == .paged && build.pagedPoolDType == "float32")
            #expect(build.usesProcessMemoryOwner)
            return try #require(build.engine as? EngineV2)
        }
        let text = try textEngine.submit(
            .init(
                id: .init(41), promptTokens: [3, 3],
                sampling: .init(temperature: 0), maxTokens: 2, prefixCacheEnabled: false))
        var textTokens = 0
        for await event in text {
            if case .delta(_, let tokens, _) = event { textTokens += tokens.count }
        }
        #expect(textTokens == 2)

        let image = CIImage(color: CIColor(red: 0.25, green: 0.5, blue: 0.75)).cropped(
            to: CGRect(x: 0, y: 0, width: 8, height: 8))
        let png = try #require(
            CIContext(options: [.useSoftwareRenderer: true]).pngRepresentation(
                of: image,
                format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()))
        let body = try JSONSerialization.data(withJSONObject: [
            "model": fixture.catalog.id,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        ["type": "text", "text": "x"],
                        [
                            "type": "image_url",
                            "image_url": [
                                "url": "data:image/png;base64," + png.base64EncodedString()
                            ],
                        ],
                    ],
                ]
            ],
            "tools": [
                [
                    "type": "function",
                    "function": [
                        "name": "f", "parameters": ["type": "object", "properties": [:]],
                    ],
                ]
            ],
        ])
        let request = try ProviderLoop.decodeOpenAIRequest(body, modelType: "glm5_next")
        let normalized = try await EngineV2VisionPrefill.glm5NextUserInput(
            request: request, controls: .init())
        #expect(normalized.tools?.count == 1 && normalized.images.count == 1)
        var required = request
        required.toolChoice = .mode(.required)
        await #expect(throws: (any Error).self) {
            try await EngineV2VisionPrefill.glm5NextUserInput(request: required, controls: .init())
        }
        // The serving entry point dispatches GLM to its native media builder.
        let prepared = try await EngineV2VisionPrefill.prepare(container: container, request: request)
        let direct = try await EngineV2VisionPrefill.prepareGLM5NextMedia(
            container: container, request: request, templateControls: .init())
        #expect(direct.promptTokens == prepared.promptTokens && direct.spans == prepared.spans)
        #expect(prepared.attention == .causal && prepared.positionState == nil)
        #expect(prepared.spans.count == 1 && prepared.spanKinds == [.image])
        #expect(prepared.embeddings[0].shape == [1, prepared.spans[0].length, 64])
        let imageStream = try textEngine.submit(
            .init(
                id: .init(42), promptTokens: prepared.promptTokens,
                sampling: .init(temperature: 0), maxTokens: 2, prefixCacheEnabled: false,
                multimodal: prepared.multimodalInput()))
        var imageTokens = 0
        for await event in imageStream {
            if case .delta(_, let tokens, _) = event { imageTokens += tokens.count }
        }
        #expect(imageTokens == 2)
        let videoInput = UserInput(chat: [
            .user(
                "x", images: [],
                videos: [
                    .frames([
                        .init(frame: image, timeStamp: .zero),
                        .init(frame: image, timeStamp: CMTime(seconds: 1, preferredTimescale: 600)),
                    ])
                ])
        ])
        let video = try await container.perform(nonSendable: videoInput) { context, input in
            let root = try #require(context.model as? GLM5NextModel)
            let processor = try #require(context.processor as? GLM5NextProcessor)
            return try await MLX.withError { errors in
                let detailed = try await processor.prepareDetailed(input: input)
                return try EngineV2VisionPrefill.buildGLM5NextSubmission(
                    root: root, prepared: detailed,
                    towerLimits: .init(
                        maxBufferBytes: 64 << 20, attentionElementBytes: 4, headFactor: 1),
                    mlxErrors: errors)
            }
        }
        #expect(video.mediaKind == .video && video.spanKinds.allSatisfy { $0 == .video })
        let videoStream = try textEngine.submit(
            .init(
                id: .init(45), promptTokens: video.promptTokens,
                sampling: .init(temperature: 0), maxTokens: 2, prefixCacheEnabled: false,
                multimodal: video.multimodalInput()))
        var videoTokens = 0
        for await event in videoStream {
            if case .delta(_, let tokens, _) = event { videoTokens += tokens.count }
        }
        #expect(videoTokens == 2)
        let cancelled = try textEngine.submit(
            .init(
                id: .init(43), promptTokens: [3],
                sampling: .init(temperature: 0), maxTokens: 40, prefixCacheEnabled: false))
        for await event in cancelled { if case .delta = event { textEngine.cancel(.init(43)) } }
        await textEngine.shutdown()

        let mtpPreparation = try await EngineV2SlotFactory.glm5NextInlinePreparation(
            container: container, enabled: true)
        if CBv2MTPConfig.envEnabled {
            await #expect(throws: GLM5NextExecutionBoundError.self) {
                try await EngineV2SlotFactory.prepareProductionModel(
                    modelId: fixture.catalog.id,
                    isVLM: false, container: container, specDecPreparation: mtpPreparation)
            }
        }
        let mtp = try await EngineV2SlotFactory.prepareProductionModel(
            modelId: fixture.catalog.id,
            isVLM: false, container: container, specDecPreparation: mtpPreparation,
            maximumContextLength: 32)
        #expect(mtp.mtpArtifact == nil && mtp.assistantBytes == 0)
        // GLM never falls back to its ownerless target-only root.
        if mtp.servingModel is GLM5NextProtectedModel {
            #expect(throws: GLM5NextManagedLoadError.nativeMTPRequired) {
                try mtp.fallingBack(.assistantResliceFloor)
            }
        }
        try #require(
            CBv2MTPConfig.envEnabled, "bridge regression requires DARKBLOOM_CBV2_MTP enabled")
        let mtpBridge = try await container.perform { context -> EngineV2Bridge in
            let protected = try #require(mtp.servingModel as? GLM5NextProtectedModel)
            #expect(protected.maximumContextLength == 32)
            #expect(protected.execution.maximumInputs == 32)
            #expect(protected.root.configuration.textConfig.maxPositionEmbeddings == 64)
            #expect(throws: GLM5NextExecutionBoundError.self) {
                try GLM5NextProtectedModel(root: protected.root, maximumContextLength: 0)
            }
            #expect(throws: GLM5NextExecutionBoundError.self) {
                try GLM5NextProtectedModel(root: protected.root, maximumContextLength: 65)
            }
            #expect(throws: GLM5NextExecutionBoundError.self) {
                try EngineV2Factory.makeProductionBuild(
                    model: protected,
                    tokenizer: context.tokenizer, kvBytesCapacity: 256 << 20,
                    maxConcurrentRequests: 1, kvBudget: budget, mtpDrafter: protected.assistant,
                    mtpConfig: .init(
                        enabled: true, maxDraftTokens: 1, verificationMode: .serialTarget),
                    kvBackend: .paged, maxContextLength: 64)
            }
            return try EngineV2Factory.makeBridge(
                modelId: catalogID,
                tokenizer: TokenizerHandle(context.tokenizer), eosTokenIds: [], defaultMaxTokens: 3,
                maxConcurrentRequests: 1, kvBytesPerToken: 1, kvBudget: budget
            ) {
                try EngineV2Factory.makeProductionBuild(
                    model: mtp.servingModel,
                    modelID: catalogID, tokenizer: context.tokenizer,
                    // Logical segmented grant includes the provider's unchanged
                    // 1 GiB service floor; this does not materialize 2 GiB.
                    kvBytesCapacity: 2 << 30, maxConcurrentRequests: 1, kvBudget: budget,
                    mtpDrafter: mtp.assistant?.drafter,
                    mtpConfig: .init(
                        enabled: true, maxDraftTokens: 1, maxSpeculativeBatch: 1,
                        fixedDraftTokens: 1, verificationMode: .serialTarget),
                    kvBackend: .paged, maxContextLength: 32)
            }
        }
        let mtpEngine = try #require(await mtpBridge.ownedEngine as? EngineV2)
        #expect(mtpEngine.nativeShutdownExecutionContractID != nil)
        #expect(await mtpBridge.canSubmitWithNativeOwner())
        var oversizedRefused = false
        var oversizedTokens = 0
        do {
            let oversized = try mtpEngine.submit(
                .init(
                    id: .init(46), promptTokens: [3],
                    sampling: .init(temperature: 0), maxTokens: 32, prefixCacheEnabled: false))
            for await event in oversized {
                if case .delta(_, let tokens, _) = event { oversizedTokens += tokens.count }
                if case .finished(let reason, _) = event, case .error = reason {
                    oversizedRefused = true
                }
            }
        } catch { oversizedRefused = true }
        #expect(oversizedRefused && oversizedTokens == 0)
        let faultAfterRefusal = mtpEngine.nativeCompletionFault
        #expect(faultAfterRefusal == nil)
        let mtpStream = await mtpBridge.submitTokenized(
            promptTokens: [3, 3],
            request: .init(model: fixture.catalog.id, messages: [], temperature: 0, max_tokens: 3),
            requestId: "glm-bridge", cacheEnabled: false)
        var mtpTokens = 0
        var bridgeErrors: [String] = []
        for await event in mtpStream {
            if case .info(_, let count, _, _) = event { mtpTokens = count }
            if case .error(let reason) = event { bridgeErrors.append(reason) }
        }
        #expect(mtpTokens == 3 && bridgeErrors.isEmpty, "bridge errors: \(bridgeErrors)")
        // The artifact's sampling defaults run on the same protected engine.
        let sampled = await mtpBridge.submitTokenized(
            promptTokens: [3, 3],
            request: .init(
                model: fixture.catalog.id, messages: [], temperature: 1, top_p: 0.95, max_tokens: 3),
            requestId: "glm-bridge-sampled", cacheEnabled: false)
        var sampledTokens = 0
        var sampledErrors: [String] = []
        for await event in sampled {
            if case .info(_, let count, _, _) = event { sampledTokens = count }
            if case .error(let reason) = event { sampledErrors.append(reason) }
        }
        #expect(sampledTokens == 3 && sampledErrors.isEmpty, "sampled errors: \(sampledErrors)")
        // The protected engine's issued contract accepts prepared causal media:
        // an image row prefills and decodes on the MTP engine, and text keeps
        // serving afterwards. This fixture bridge admits one request at a time
        // (`maxConcurrentRequests: 1`), so the rows are submitted in sequence.
        #expect(await mtpBridge.servesGLM5NextMedia)
        let protectedImage = try await EngineV2VisionPrefill.prepare(container: container, request: request)
        let protectedMedia = await mtpBridge.submitTokenized(
            promptTokens: protectedImage.promptTokens,
            request: .init(model: fixture.catalog.id, messages: [], temperature: 0, max_tokens: 2),
            requestId: "glm-bridge-image", cacheEnabled: false,
            multimodal: protectedImage.multimodalInput(), mediaKind: protectedImage.mediaKind)
        var mediaTokens = 0
        var mediaErrors: [String] = []
        for await event in protectedMedia {
            if case .info(_, let count, _, _) = event { mediaTokens = count }
            if case .error(let reason) = event { mediaErrors.append(reason) }
        }
        let followingText = await mtpBridge.submitTokenized(
            promptTokens: [3, 3],
            request: .init(model: fixture.catalog.id, messages: [], temperature: 0, max_tokens: 3),
            requestId: "glm-bridge-image-text", cacheEnabled: false)
        var followingTokens = 0
        for await event in followingText {
            if case .info(_, let count, _, _) = event { followingTokens = count }
            if case .error(let reason) = event { mediaErrors.append(reason) }
        }
        #expect(mediaTokens == 2 && followingTokens == 3 && mediaErrors.isEmpty,
            "protected media errors: \(mediaErrors)")
        #expect(mtpEngine.nativeCompletionFault == nil)
        // The enforced bound is advertised: over-length work is a client
        // rejection before native admission, never a retained engine fault.
        #expect(mtpBridge.advertisedContextTokens == 32)
        let overBound = await mtpBridge.submitTokenized(
            promptTokens: [3, 3],
            request: .init(model: fixture.catalog.id, messages: [], temperature: 0, max_tokens: 31),
            requestId: "glm-bridge-over-bound", cacheEnabled: false)
        var overBoundErrors: [String] = []
        for await event in overBound {
            if case .error(let reason) = event { overBoundErrors.append(reason) }
        }
        #expect(overBoundErrors == [Qwen4SupportPolicy.contextRejectionMessage])
        #expect(mtpEngine.nativeCompletionFault == nil)
        #expect(await mtpBridge.canSubmitWithNativeOwner())
        #if DEBUG
            if ProcessInfo.processInfo.environment["DARKBLOOM_TEST_GLM5_RETAINED_SHUTDOWN"] == "1" {
                try await mtpBridge.installGLM5NextRetirementRefusalForTesting {
                    throw GLM5NextEvaluationProbe.Refusal.requested
                }
                await #expect(throws: GLM5NextManagedLoadError.retirementUnproven) {
                    try await GLM5NextRetirement.beforeRelease(mtpBridge)
                }
                #expect(await mtpBridge.ownedEngine != nil)
                #expect(GLM5NextLoadFaultState.isRetained)
                return  // This isolated process deliberately retains its actual native owner.
            }
        #endif
        try await GLM5NextRetirement.beforeRelease(mtpBridge)
        #expect(await mtpBridge.ownedEngine == nil)
        #expect(!(await mtpBridge.canSubmitWithNativeOwner()))
        await ModelContainerLoading.releaseExternalResources(in: container)
    }
}
