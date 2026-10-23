import Foundation
import MLXLLM
@testable import MLXLMCommon
import ProviderCoreFoundation
import Testing

@testable import ProviderCore

private func hardware(_ family: ChipFamily, _ tier: ChipTier, _ memoryGiB: UInt64) -> HardwareInfo {
    HardwareInfo(
        machineModel: "test", chipName: "Apple \(family.rawValue) \(tier.rawValue)",
        chipFamily: family, chipTier: tier, memoryGb: memoryGiB, memoryAvailableGb: memoryGiB,
        cpuCores: CpuCores(total: 18, performance: 12, efficiency: 6),
        gpuCores: 40, memoryBandwidthGbs: 600)
}

/// GLM-5.3-Flash text dimensions from fixtures/models/glm53-flash/architecture.json.
private func glm53TextConfiguration() throws -> GLM5NextTextConfiguration {
    let sparse = Set(stride(from: 3, through: 43, by: 4))
    let layers = Array(0..<45)
    let text: [String: Any] = [
        "model_type": "glm5_next_text", "vocab_size": 154880, "hidden_size": 4096,
        "intermediate_size": 12288, "moe_intermediate_size": 2048,
        "num_hidden_layers": 45, "num_attention_heads": 64, "num_key_value_heads": 64,
        "head_dim": 0, "qk_head_dim": 256, "qk_nope_head_dim": 256, "qk_rope_head_dim": 0,
        "v_head_dim": 256, "q_lora_rank": 1536, "kv_lora_rank": 512, "mla_use_nope": true,
        "layer_types": layers.map { sparse.contains($0) ? "deepseek_sparse_attention" : "linear_attention" },
        "mlp_layer_types": layers.map { $0 < 3 ? "dense" : "sparse" },
        "indexer_types": layers.map { _ in "full" },
        "linear_attn_config": [
            "num_heads": 64, "head_dim": 128, "gate_lower_bound": -5,
            "short_conv_kernel_size": 4, "kda_layers": layers.filter { !sparse.contains($0) },
            "full_attn_layers": layers.filter { sparse.contains($0) },
        ],
        "index_head_dim": 128, "index_n_heads": 32, "index_topk": 2048, "index_kpool": 4,
        "index_kpool_compress": true, "index_kpool_always_select_tail": true,
        "indexer_rope_interleave": true, "index_share_for_mtp_iteration": true,
        "mhc": true, "hc_mult": 4, "hc_eps": 1e-6, "hc_sinkhorn_iters": 20,
        "first_k_dense_replace": 3, "n_routed_experts": 288, "n_shared_experts": 1,
        "num_experts_per_tok": 8, "n_group": 1, "topk_group": 1,
        "norm_topk_prob": true, "routed_scaling_factor": 2.5, "scoring_func": "sigmoid",
        "topk_method": "noaux_tc", "moe_router_dtype": "float32", "output_router_logits": false,
        "router_aux_loss_coef": 0.001, "num_nextn_predict_layers": 1, "hidden_act": "silu",
        "swiglu_limit": 10, "rms_norm_eps": 1e-5, "attention_bias": false,
        "attention_dropout": 0, "max_position_embeddings": 1_048_576, "initializer_range": 0.02,
        "use_cache": true, "tie_word_embeddings": false, "dtype": "bfloat16",
        "pad_token_id": 0, "eos_token_id": [2],
    ]
    return try JSONDecoder().decode(GLM5NextTextConfiguration.self,
        from: JSONSerialization.data(withJSONObject: text, options: .sortedKeys))
}

struct GLM5NextHardwareGateTests {
    @Test func onlyM5MaxOrUltraWith256GiBQualifies() {
        #expect(GLM5NextHardwareRequirement.refusal(hardware: hardware(.m5, .max, 256)) == nil)
        #expect(GLM5NextHardwareRequirement.refusal(hardware: hardware(.m5, .ultra, 512)) == nil)
        for (family, tier, memory, chip) in [
            (ChipFamily.m5, ChipTier.max, UInt64(128), "M5 Max"), (.m5, .max, 255, "M5 Max"),
            (.m5, .pro, 256, "M5 Pro"), (.m5, .base, 256, "M5"), (.m5, .unknown, 512, "M5 Unknown"),
            (.m4, .max, 256, "M4 Max"), (.m3, .ultra, 512, "M3 Ultra"), (.m6, .ultra, 512, "M6 Ultra"),
        ] {
            let refusal = GLM5NextHardwareRequirement.refusal(hardware: hardware(family, tier, memory))
            #expect(refusal == "GLM-5.3-Flash requires Apple M5 Max or M5 Ultra with at least 256 GB "
                + "unified memory; this Mac is \(chip) with \(memory) GB")
        }
    }

    @Test func capabilityIsReportedOnlyOnQualifyingHardware() {
        let qualified = ProviderRuntimeCapabilityDetector.detectPrepared(
            hardware: hardware(.m5, .max, 256), boundMetallibHash: "abc", naxAvailable: { true })
        #expect(qualified == [.appleM5, .mlxNAX, .modelRevisions, .glm5Next])
        let small = ProviderRuntimeCapabilityDetector.detectPrepared(
            hardware: hardware(.m5, .max, 128), boundMetallibHash: "abc", naxAvailable: { true })
        #expect(!small.contains(.glm5Next))
        #expect(ProviderRuntimeCapability.glm5Next.rawValue == "glm5_next_v1")
    }

    /// Older providers report apple_m5 + mlx_nax but not glm5_next_v1, so the
    /// embedded rule fails them closed even when the catalog omits it.
    @Test func exactGLMIdentitiesRequireAllThreeCapabilities() {
        for id in [GLM5NextCoordinatorServing.catalogModelID, GLM5NextLocalQualification.modelID] {
            #expect(ModelRuntimeRequirements.requiredCapabilities(for: id)
                == [.appleM5, .mlxNAX, .glm5Next])
            #expect(!ModelRuntimeRequirements.isEligible(modelID: id,
                catalogRequirements: [.appleM5, .mlxNAX], available: [.appleM5, .mlxNAX, .modelRevisions]))
            #expect(ModelRuntimeRequirements.isEligible(modelID: id,
                catalogRequirements: [.appleM5, .mlxNAX], available: [.appleM5, .mlxNAX, .glm5Next]))
        }
        #expect(ModelRuntimeRequirements.requiredCapabilities(for: "glm-5.3-flash-r2").isEmpty)
    }
}

struct GLM5NextCoordinatorServingTests {
    private func model(_ id: String) -> ModelInfo {
        .init(id: id, modelType: "glm5_next", sizeBytes: 1, estimatedMemoryGb: 1)
    }

    @Test func onlyTheExactCatalogBuildIsAdvertised() {
        #expect(EngineV2SupportedModels.isSupported(model: model("glm-5.3-flash")))
        for id in [GLM5NextLocalQualification.modelID, "GLM-5.3-Flash", "glm-5.3-flash ", "other/glm5"] {
            #expect(!EngineV2SupportedModels.isSupported(model: model(id)))
        }
        // The catalog build never takes the selection-file local path.
        #expect(!GLM5NextLocalQualification.isSupportedLocally(model: model("glm-5.3-flash"), environment: [:]))
    }

    @Test func contextBoundIs262144AndNeverWidenedByTheCatalog() throws {
        #expect(GLM5NextCoordinatorServing.maximumContextLength == 262_144)
        #expect(try GLM5NextCoordinatorServing.servedContextLength(catalogMaximum: nil) == 262_144)
        #expect(try GLM5NextCoordinatorServing.servedContextLength(catalogMaximum: 262_144) == 262_144)
        #expect(try GLM5NextCoordinatorServing.servedContextLength(catalogMaximum: 131_072) == 131_072)
        for invalid in [0, -1, 262_145, 1_048_576] {
            #expect(throws: GLM5NextManagedLoadError.self) {
                try GLM5NextCoordinatorServing.servedContextLength(catalogMaximum: invalid)
            }
        }
    }

    /// 11 DSA layers × (512 latent + 128 index key + 128 pool gate + 1 validity)
    /// FP32 columns. KDA layers add no per-token bytes.
    @Test func targetKVIsExactPerToken() throws {
        let text = try glm53TextConfiguration()
        let rate = GLM5NextCoordinatorServing.targetKVBytesPerToken(text)
        #expect(rate == 33_836)
        #expect(rate * GLM5NextCoordinatorServing.maximumContextLength == 8_869_904_384)
        #expect(GLM5NextCoordinatorServing.requestBytesPerToken(
            kvBytesPerToken: rate, stepScratchBytesPerToken: 1_000) == 34_836)
        #expect(GLM5NextCoordinatorServing.requestBytesPerToken(
            kvBytesPerToken: rate, stepScratchBytesPerToken: -1) == nil)
        #expect(GLM5NextCoordinatorServing.requestBytesPerToken(
            kvBytesPerToken: .max, stepScratchBytesPerToken: 1) == nil)
    }

    /// The embedded MTP layer keeps 3,074 B of history per token (latent, index
    /// key, pool gate, two validity bytes). Its serving-policy plan charges
    /// 33,900 B per reserved token across six resident copies, two draft and
    /// three priming working copies and 64 host bytes, independent of step size.
    @Test func mtpHistoryIsChargedPerReservedToken() throws {
        let text = try glm53TextConfiguration()
        let bound = GLM5NextCoordinatorServing.maximumContextLength
        for step in [512, EngineV2Factory.glm5NextMaximumStepTokens] {
            let plan = try GLM5NextMTPExecution.memoryPlan(configuration: text, maximumInputs: bound,
                limits: .init(maximumPrefillTokens: step, maximumDraftTokens: 1),
                executionPolicy: GLM5NextManagedLoad.executionPolicy)
            #expect(plan.cacheBuffers.reduce(0) { $0 + $1.logicalBytes * $1.allocationCount }
                == 3_074 * bound)
            let spec = plan.specification
            let perToken = (spec.resident + spec.working).reduce(spec.hostBytesPerToken) {
                $0 + $1.logicalBytesPerToken * $1.allocationCount
            }
            #expect(perToken == 33_900)
        }
    }

    /// Calibrated split bound (2048-token steps, 262,144 context): on a
    /// 56.8 GB grant two rows activate and four do not. Pool tokens and the
    /// admissible ceiling derive from one capacity, so a smaller pool cannot
    /// admit four rows either; they need at least ~72.4 GB.
    @Test func calibratedActivationRowsOnA256GiBGrant() {
        let rate = 55_057, context = 262_144, kv = 33_836
        func admits(_ rows: Int, setup: Int, capacity: Int) -> Bool {
            EngineV2Factory.glm5NextActivationAdmits(
                GLM5NextStepScratch(setupBytes: setup, bytesPerContextToken: rate),
                rows: rows, context: context, capacityBytes: capacity, tokenBytes: kv,
                maximumScratchBytes: capacity, watermarkFraction: 0.05)
        }
        let grant = 56_800_000_000
        #expect(admits(1, setup: 5_589_138_629, capacity: grant))
        #expect(admits(2, setup: 7_398_234_550, capacity: grant))
        #expect(!admits(4, setup: 11_016_754_072, capacity: grant))
        #expect(!admits(4, setup: 11_016_754_072, capacity: 515_000 * kv))
        #expect(admits(4, setup: 11_016_754_072, capacity: 72_400_000_000))
        #expect(!admits(4, setup: 11_016_754_072, capacity: 72_300_000_000))
    }

    /// Publication uses the same admissible capacity as request admission
    /// (pool − watermark − one step's setup): one request at the bound fits.
    @Test func advertisedBoundMustFitAlone() {
        let fixed = 4_000_000_000, context = 262_144
        let rate = 33_836 + 55_057 + 33_900
        let needed = fixed + rate * context
        #expect(GLM5NextCoordinatorServing.fullContextRefusal(admissibleBytes: needed,
            fixedRequestBytes: fixed, bytesPerToken: rate, context: context) == nil)
        let refusal = GLM5NextCoordinatorServing.fullContextRefusal(admissibleBytes: needed - 1,
            fixedRequestBytes: fixed, bytesPerToken: rate, context: context)
        #expect(refusal?.contains("cannot hold one 262144-token request") == true)
        #expect(GLM5NextCoordinatorServing.fullContextRefusal(admissibleBytes: .max,
            fixedRequestBytes: 1, bytesPerToken: .max, context: 2) != nil)
        #expect(GLM5NextCoordinatorServing.fullContextRefusal(admissibleBytes: .max,
            fixedRequestBytes: 0, bytesPerToken: 0, context: 1) != nil)
    }

    /// The bridge admits GLM requests against pool − watermark − setup, so
    /// once held requests fill it, the engine's step (setup + scratch for every
    /// held token) still fits the engine's admissible capacity beside their KV,
    /// MTP and fixed bytes. Further requests are refused as committed capacity.
    @Test func filledSlotStillLeavesRoomForAStep() {
        let setup = 7_398_234_550, scratch = 55_057, kv = 33_836, mtp = 33_900
        let fixed = 4_230_000_000, engineAdmissible = 53_960_000_000
        let bridgeAdmissible = engineAdmissible - setup
        let rate = kv + scratch + mtp
        var committed = 0, tokens: [Int] = []
        for request in [131_072, 32_768, 32_768, 5_120, 5_120, 131_072] {
            switch EngineV2Bridge.glm5NextSlotAdmission(requestBytes: fixed + rate * request,
                committedBytes: committed, admissibleBytes: bridgeAdmissible) {
            case .admit(let bytes):
                committed += bytes
                tokens.append(request)
            case .committed: continue
            case .neverFits: Issue.record("request \(request) never fits")
            }
        }
        #expect(tokens.count >= 2 && tokens.count < 6)
        let held = tokens.reduce(0, +)
        let ledger = tokens.count * fixed + (kv + mtp) * held
        #expect(ledger + setup + scratch * held <= engineAdmissible)
        #expect(EngineV2Bridge.glm5NextSlotAdmission(requestBytes: bridgeAdmissible + 1,
            committedBytes: 0, admissibleBytes: bridgeAdmissible) == .neverFits)
        #expect(EngineV2Bridge.glm5NextSlotAdmission(requestBytes: nil,
            committedBytes: 0, admissibleBytes: bridgeAdmissible) == .neverFits)
        #expect(EngineV2Bridge.glm5NextSlotAdmission(requestBytes: 2,
            committedBytes: .max, admissibleBytes: bridgeAdmissible) == .committed)
    }

    /// A slot refusal is thrown before any stream as the typed capacity error:
    /// 503 `capacity`/`token_budget_exhausted` on the local and coordinator
    /// paths, and the same typed case when a nonthrowing caller carries its
    /// marker in-band.
    @Test(arguments: [true, false])
    func slotRefusalIsATypedRetryableCapacityError(neverFits: Bool) {
        let refusal = EngineV2Bridge.glm5NextSlotRefusal(neverFits: neverFits, reservedTokens: 61_440)
        let message = "token_budget_exhausted: "
            + (neverFits ? "request_exceeds_slot_capacity" : "slot_capacity_committed")
            + " (61440 reserved tokens)"
        #expect(refusal == .tokenBudgetExhausted(message))
        #expect(MultiModelBatchSchedulerEngineError.fromSchedulerMessage(message) == refusal)
        for phase in [InferenceFailurePhase.streamStart, .generation] {
            let failure = ProviderLoop.sanitizedInferenceFailure(from: refusal, phase: phase)
            #expect(failure.statusCode == 503)
            #expect(failure.code == .capacity)
            #expect(failure.errorReason == .tokenBudgetExhausted)
            #expect(failure.message == InferenceFailureCode.capacity.message)
        }
        let enriched = CapacityRejectionEnrichment.enrich(
            ProviderLoop.sanitizedInferenceFailure(from: refusal, phase: .streamStart),
            modelId: GLM5NextCoordinatorServing.catalogModelID, published: nil,
            fallbackReason: .tokenBudget)
        #expect(enriched.statusCode == 503 && enriched.rejectionReason == .tokenBudget)
    }

    /// A closed bridge's pending host consumers are retried, never retained;
    /// any other proof failure escapes unchanged.
    @Test func pendingHostConsumersAreRetriedAfterQuiescence() async throws {
        actor Attempts { var count = 0; func next() -> Int { count += 1; return count } }
        let attempts = Attempts()
        let value = try await GLM5NextRetirement.drainingHostConsumers(sleep: { _ in }) {
            if await attempts.next() < 3 { throw MiMoV26NativeBridgeShutdownError.pendingConsumers }
            return 7
        }
        #expect(value == 7)
        #expect(await attempts.count == 3)
        await #expect(throws: GLM5NextManagedLoadError.retirementUnproven) {
            try await GLM5NextRetirement.drainingHostConsumers(sleep: { _ in }) { () async throws -> Int in
                throw GLM5NextManagedLoadError.retirementUnproven
            }
        }
    }

    /// Only a stale or missing catalog identity is refreshed, exactly once.
    @Test func staleCatalogIsRefreshedOnce() async throws {
        actor Calls { var refreshes: [Bool] = []; func add(_ value: Bool) { refreshes.append(value) } }
        let calls = Calls()
        let value = try await ProviderLoop.resolvingWithOneCatalogRefresh { refresh -> Int in
            await calls.add(refresh)
            if !refresh { throw GLM5NextManagedLoadError.identityMismatch }
            return 1
        }
        #expect(value == 1)
        #expect(await calls.refreshes == [false, true])
        let final = Calls()
        await #expect(throws: GLM5NextManagedLoadError.admission) {
            try await ProviderLoop.resolvingWithOneCatalogRefresh { refresh -> Int in
                await final.add(refresh)
                throw GLM5NextManagedLoadError.admission
            }
        }
        #expect(await final.refreshes == [false])
    }

    @Test func mtpDisabledWithdrawsTheGLMCapability() {
        let all: Set<ProviderRuntimeCapability> = [.appleM5, .mlxNAX, .glm5Next]
        #expect(GLM5NextLocalServing.gatingCapabilities(all, mode: .off, processMTPEnabled: true)
            == [.appleM5, .mlxNAX])
        #expect(GLM5NextLocalServing.gatingCapabilities(all, mode: .auto, processMTPEnabled: false)
            == [.appleM5, .mlxNAX])
        #expect(GLM5NextLocalServing.gatingCapabilities(all, mode: .auto, processMTPEnabled: true) == all)
    }

    /// Catalog entry -> receipt manifest -> recomputed aggregate; an R2-only
    /// entry names the native identity by catalog id and aggregate prefix.
    @Test func catalogRevisionResolvesTheManagedPlan() throws {
        let id = GLM5NextCoordinatorServing.catalogModelID
        let fixture = try GLM5NextManagedFixture(
            modelID: id, chatTemplate: GLM5NextManagedFixture.shippedTemplate())
        try ModelDownloader.writeRevisionReceipt(fixture.manifest, at: fixture.directory)
        let catalog = CatalogModel(
            id: id, s3Name: fixture.manifest.r2Prefix, displayName: "Z.ai: GLM-5.3-Flash", sizeGb: 1,
            version: fixture.manifest.version, r2Prefix: fixture.manifest.r2Prefix,
            aggregateSHA256: fixture.manifest.aggregateSHA256, maxContextLength: 262_144,
            requiredProviderCapabilities: [.appleM5, .mlxNAX])
        let serving = try GLM5NextCoordinatorServing.resolvePlan(
            modelID: id, directory: fixture.directory, catalog: catalog)
        #expect(serving.maximumContextLength == 262_144)
        #expect(serving.plan.nativeIdentity.repository == id)
        #expect(serving.plan.nativeIdentity.revision
            == String(fixture.manifest.aggregateSHA256.prefix(40)))
        #expect(serving.plan.usesShippedPromptTemplate)

        let other = CatalogModel(id: id, s3Name: "x", displayName: "x", sizeGb: 1,
            version: fixture.manifest.version, r2Prefix: fixture.manifest.r2Prefix,
            aggregateSHA256: String(repeating: "0", count: 64))
        #expect(throws: GLM5NextManagedLoadError.identityMismatch) {
            try GLM5NextCoordinatorServing.resolvePlan(modelID: id, directory: fixture.directory, catalog: other)
        }
        #expect(throws: GLM5NextManagedLoadError.self) {
            try GLM5NextCoordinatorServing.resolvePlan(modelID: id, directory: fixture.directory, catalog: nil)
        }
        #expect(throws: GLM5NextManagedLoadError.identityMismatch) {
            try GLM5NextCoordinatorServing.resolvePlan(
                modelID: GLM5NextLocalQualification.modelID, directory: fixture.directory, catalog: catalog)
        }
        // Rollback: the catalog names a newer revision, but the receipt carries
        // the aggregate this provider already verified and served.
        let newer = CatalogModel(id: id, s3Name: "x", displayName: "x", sizeGb: 1,
            version: "newer", r2Prefix: "newer/prefix", aggregateSHA256: String(repeating: "1", count: 64),
            maxContextLength: 131_072)
        let restored = try GLM5NextCoordinatorServing.resolvePlan(modelID: id, directory: fixture.directory,
            catalog: newer, previouslyVerifiedAggregate: fixture.manifest.aggregateSHA256)
        #expect(restored.plan.weights.manifest.version == fixture.manifest.version)
        #expect(restored.maximumContextLength == 131_072)
        #expect(throws: GLM5NextManagedLoadError.identityMismatch) {
            try GLM5NextCoordinatorServing.resolvePlan(modelID: id, directory: fixture.directory,
                catalog: newer, previouslyVerifiedAggregate: String(repeating: "2", count: 64))
        }
        try FileManager.default.removeItem(at: fixture.directory.appendingPathComponent(".darkbloom-manifest.json"))
        #expect(throws: GLM5NextManagedLoadError.identityMismatch) {
            try GLM5NextCoordinatorServing.resolvePlan(modelID: id, directory: fixture.directory, catalog: catalog)
        }
    }

    @Test func revisionSwapBorrowsTheCallersWriterLease() throws {
        let fixture = try GLM5NextManagedFixture(
            modelID: GLM5NextCoordinatorServing.catalogModelID,
            chatTemplate: GLM5NextManagedFixture.shippedTemplate())
        try ModelDownloader.writeRevisionReceipt(fixture.manifest, at: fixture.directory)
        let catalog = CatalogModel(id: fixture.manifest.modelID, s3Name: "x", displayName: "x", sizeGb: 1,
            version: fixture.manifest.version, r2Prefix: fixture.manifest.r2Prefix,
            aggregateSHA256: fixture.manifest.aggregateSHA256)
        let plan = try GLM5NextCoordinatorServing.resolvePlan(
            modelID: catalog.id, directory: fixture.directory, catalog: catalog).plan
        #expect(throws: GLM5NextManagedLoadError.lifecycle) {
            try GLM5NextArtifactOwnership.borrowingCallerLease(plan: plan, heldForModelID: nil)
        }
        #expect(throws: GLM5NextManagedLoadError.lifecycle) {
            try GLM5NextArtifactOwnership.borrowingCallerLease(plan: plan, heldForModelID: "other")
        }
        #expect(throws: GLM5NextManagedLoadError.identityMismatch) {
            try ProviderLoop.requireGLM5NextLoadedArtifact(hash: String(repeating: "0", count: 64), plan: plan)
        }
        try ProviderLoop.requireGLM5NextLoadedArtifact(hash: fixture.manifest.aggregateSHA256, plan: plan)
        let borrowed = try GLM5NextArtifactOwnership.borrowingCallerLease(
            plan: plan, heldForModelID: catalog.id)
        try borrowed.claim(plan: plan)
        #expect(throws: GLM5NextManagedLoadError.lifecycle) { try borrowed.claim(plan: plan) }
        borrowed.release()
    }
}
