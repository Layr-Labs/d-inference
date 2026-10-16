import CryptoKit
import Foundation
import MLX
import MLXLLM
import MLXVLM
import ProviderCoreFoundation
import Testing

@testable import MLXLMCommon
@testable import ProviderCore

/// Opt-in, real provider construction over tiny synthetic weights. This is not
/// full-model qualification or persistent-Keychain/cross-process evidence.
@Suite(
    .serialized,
    .enabled(
        if: ProcessInfo.processInfo.environment["DARKBLOOM_TEST_GLM5_PROTECTED_FACTORY"] == "1"))
struct GLM5NextProtectedFactoryTests {
    private func withFixture(_ body: (GLM5NextProtectedFactoryFixture) async throws -> Void)
        async throws
    {
        try #require(CBv2MTPConfig.envEnabled, "DARKBLOOM_CBV2_MTP must be enabled")
        let fixture = try GLM5NextProtectedFactoryFixture()
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

    @Test func managedSlotBindsExactEncryptedStoreAndRestoresPrefix() async throws {
        try await withFixture { fixture in
            let container = try await fixture.load()
            let tokenizer = await container.tokenizer
            // Checkpoints are captured at interior chunk ends, and the 1,536-token
            // fixture context fits any prompt in one 2,048-token chunk.
            let bundle = try await EngineV2Factory.$glm5NextStepTokensForTesting.withValue(512) {
                try await EngineV2SlotFactory.makeProductionBundle(
                    modelId: fixture.plan.weights.catalog.id, modelType: "glm5_next", isVLM: false,
                    modelDirectory: fixture.directory, container: container,
                    tokenizer: TokenizerHandle(tokenizer),
                    sizing: fixture.sizing, kvBytesCapacity: fixture.kvBytesCapacity,
                    maxConcurrentRequests: 1, kvBudget: fixture.budget, kvBackendConfig: "paged",
                    weightHash: fixture.plan.weights.manifest.aggregateSHA256,
                    specDecPreparation: fixture.mtpPreparation,
                    assemblyOverrides: .init(completeCheckpointIdentity: fixture.identity),
                    environment: fixture.environment, startServingTelemetry: false)
            }
            fixture.bridges.append(bundle.bridge)
            let store = try #require(bundle.bridge.ssdHybridCheckpointStore)
            let engine = try #require(await bundle.bridge.ownedEngine as? EngineV2)
            #expect(engine.schedulerConfig.prefillChunkSize == 512)
            #expect(bundle.mtpStatus.active)
            #expect(store.identity == fixture.identity && store.kvBudget === fixture.budget)
            #expect(
                store.config.backendLayout == CBv2CompleteCheckpointManifest.glm5NextPagedLayout)
            #expect(store.usesEphemeralKey)
            #expect(store.config.dedicatedRoot == fixture.cacheRoot)
            #expect(
                store.config.root
                    == fixture.cacheRoot.appendingPathComponent(
                        SSDHybridCheckpointStoreFactory.namespace(
                            modelId: fixture.plan.weights.catalog.id,
                            identity: fixture.identity,
                            backendLayout: CBv2CompleteCheckpointManifest.glm5NextPagedLayout),
                        isDirectory: true))
            #expect(engine.completePrefixCache === store)
            #expect(engine.completeCheckpointCodec?.isNativePagedGLM5Next == true)
            #expect(engine.completeCheckpointCodec?.assistant != nil)
            #expect(await bundle.bridge.canSubmitWithNativeOwner())

            let prompt = Array(repeating: 3, count: 1057)
            let cold = try await fixture.run(bundle.bridge, tokens: prompt, id: "cold")
            #expect(cold.prefixCacheHitTokens == 0)
            #expect(cold.prefixCachePrefillTokensSaved == 0)
            await store.waitForWritesForTesting()
            #expect(store.stats().filesWritten > 0)
            let enumerator = try #require(
                FileManager.default.enumerator(
                    at: store.config.root,
                    includingPropertiesForKeys: nil))
            let files = (enumerator.allObjects as? [URL] ?? []).filter {
                $0.pathExtension == SSDBlockStore.fileExtension
            }
            let file = try #require(files.first)
            #expect(Array(try Data(contentsOf: file).prefix(4)) == SSDBlockStore.magic)
            let restored = try await fixture.run(bundle.bridge, tokens: prompt, id: "restored")
            let saved = try #require(restored.prefixCachePrefillTokensSaved)
            let lookup = try #require(restored.lookupResult)
            #expect(saved > 0)
            #expect(lookup.outcome == .hit && lookup.tier == .ssd)
            #expect(lookup.cachedTokens > 0 && lookup.prefillTokensSaved == saved)
            #expect(restored.prefixCacheHitTokens == lookup.cachedTokens)
            #expect(store.stats().filesRead > 0)
            #expect(store.stats().stageConsumptions == 1)
            #expect(await bundle.bridge.canSubmitWithNativeOwner())
        }
    }

    /// Default configuration for the pinned identity: automatic KV backend, no
    /// cache flag and more than one request. Serving resolves the native paged
    /// backend and the provider-resolved MTP configuration reaches the GLM
    /// complete-prefix branch, so the encrypted full-state store is bound.
    @Test func defaultServingSelectsPagedKVAndCompletePrefix() async throws {
        try await withFixture { fixture in
            let container = try await fixture.load()
            let tokenizer = await container.tokenizer
            var environment = fixture.environment
            environment.removeValue(forKey: PrefixCachePolicy.environmentFlag)
            let bundle = try await EngineV2SlotFactory.makeProductionBundle(
                modelId: GLM5NextLocalQualification.modelID, modelType: "glm5_next", isVLM: true,
                modelDirectory: fixture.directory, container: container,
                tokenizer: TokenizerHandle(tokenizer),
                sizing: fixture.sizing, kvBytesCapacity: fixture.kvBytesCapacity, maxConcurrentRequests: 2,
                kvBudget: fixture.budget,
                weightHash: fixture.plan.weights.manifest.aggregateSHA256,
                specDecPreparation: fixture.mtpPreparation,
                assemblyOverrides: .init(completeCheckpointIdentity: fixture.identity),
                environment: environment, startServingTelemetry: false)
            fixture.bridges.append(bundle.bridge)
            #expect(await bundle.bridge.kvBackendKind == .paged)
            #expect(await bundle.bridge.maxConcurrentRequests == 2)
            #expect(bundle.mtpStatus.active)
            let store = try #require(bundle.bridge.ssdHybridCheckpointStore)
            let engine = try #require(await bundle.bridge.ownedEngine as? EngineV2)
            #expect(store.identity == fixture.identity)
            #expect(store.config.backendLayout == CBv2CompleteCheckpointManifest.glm5NextPagedLayout)
            #expect(engine.completePrefixCache === store)
            #expect(engine.completeCheckpointCodec?.isNativePagedGLM5Next == true)
            #expect(engine.schedulerConfig.enablePrefixCache)
            #expect(engine.schedulerConfig.maxConcurrentRequests == 2)
            let context = fixture.sizing.maxContextLength
            #expect(engine.schedulerConfig.maxBatchedTokensPerStep
                == min(context, EngineV2Factory.glm5NextMaximumStepTokens))
            #expect(engine.schedulerConfig.prefillChunkSize
                == min(context, EngineV2Factory.glm5NextMaximumPrefillChunkTokens))
            #expect(await bundle.bridge.canSubmitWithNativeOwner())
            try await fixture.run(bundle.bridge, tokens: [3, 3], id: "default-serving")
        }
    }

    /// The global flag opts the pinned identity out, and GLM never degrades
    /// to contiguous KV: the kill switch or an explicit contiguous selection
    /// refuses the load instead.
    @Test func prefixOptOutAndPagedVetoesNeverFallBackToContiguous() async throws {
        try await withFixture { fixture in
            let container = try await fixture.load()
            let prepared = try await EngineV2SlotFactory.prepareProductionModel(
                modelId: GLM5NextLocalQualification.modelID, isVLM: false, container: container,
                specDecPreparation: fixture.mtpPreparation,
                maximumContextLength: fixture.sizing.maxContextLength)
            let model = try #require(prepared.servingModel as? GLM5NextProtectedModel)
            func prepare(_ selection: EngineV2KVBackendSelection, _ extra: [String: String] = [:]) throws
                -> EngineV2Factory.ProductionBackendPreparation
            {
                try EngineV2Factory.prepareProductionBackend(
                    model: model, modelID: GLM5NextLocalQualification.modelID, kvBudget: fixture.budget,
                    kvBytesCapacity: fixture.kvBytesCapacity, maxConcurrentRequests: 1, kvBackend: selection,
                    maxContextLength: model.maximumContextLength,
                    environment: fixture.environment.merging(extra) { _, value in value })
            }
            for refused in [
                (EngineV2KVBackendSelection.contiguous, [String: String]()),
                (.auto, [EngineV2KVBackendPolicy.killSwitchEnvKey: "0"]),
                (.paged, [EngineV2KVBackendPolicy.killSwitchEnvKey: "0"]),
            ] {
                #expect(throws: EngineV2ProductionError.self) { try prepare(refused.0, refused.1) }
            }
            let backend = try prepare(.auto)
            #expect(backend.kind == .paged && backend.fallbackReason == nil)
            #expect(backend.pagedPoolDType == "float32")
            let disabled = await EngineV2SlotFactory.prepareCompletePrefixCache(
                modelId: GLM5NextLocalQualification.modelID, model: model, preparedBackend: backend,
                weightHash: fixture.plan.weights.manifest.aggregateSHA256,
                promptContractID: fixture.identity.promptContractID,
                mtpDrafter: model.assistant, mtpConfig: fixture.mtpConfig, kvBudget: fixture.budget,
                environment: fixture.environment.merging([PrefixCachePolicy.environmentFlag: "0"]) { _, value in value },
                identityOverride: fixture.identity)
            #expect(disabled?.cache == nil && disabled?.status.reason == .configDisabled)
        }
    }

    @Test func preparedFactoryRejectsForeignStoreAndTuple() async throws {
        try await withFixture { fixture in
            let container = try await fixture.load()
            let tokenizer = await container.tokenizer
            let prepared = try await EngineV2SlotFactory.prepareProductionModel(
                modelId: fixture.plan.weights.catalog.id, isVLM: false, container: container,
                specDecPreparation: fixture.mtpPreparation,
                maximumContextLength: fixture.sizing.maxContextLength)
            let model = try #require(prepared.servingModel as? GLM5NextProtectedModel)
            #expect(throws: EngineV2ProductionError.self) {
                try EngineV2Factory.prepareProductionBackend(
                    model: model, kvBudget: fixture.budget,
                    kvBytesCapacity: fixture.kvBytesCapacity, maxConcurrentRequests: 1, kvBackend: .paged,
                    environment: fixture.environment,
                    residentPrefixCache: .init(
                        blockSize: PrefixCachePolicy.residentBlockSize,
                        promptContractID: fixture.identity.promptContractID,
                        scopeID: fixture.plan.weights.catalog.id))
            }
            #expect(throws: EngineV2ProductionError.self) {
                try EngineV2Factory.prepareProductionBackend(
                    model: model, kvBudget: fixture.budget,
                    kvBytesCapacity: fixture.kvBytesCapacity, maxConcurrentRequests: 1, kvBackend: .paged,
                    environment: fixture.environment,
                    hybridPrefixCache: .init(
                        maximumBytes: 1 << 20, modelID: fixture.plan.weights.catalog.id,
                        promptContractID: fixture.identity.promptContractID,
                        buildID: fixture.identity.buildID))
            }
            let backend = try EngineV2Factory.prepareProductionBackend(
                model: model,
                modelID: fixture.plan.weights.catalog.id, kvBudget: fixture.budget,
                kvBytesCapacity: fixture.kvBytesCapacity, maxConcurrentRequests: 1, kvBackend: .paged,
                maxContextLength: model.maximumContextLength, environment: fixture.environment)
            #expect(backend.glm5NextNative == nil, "SSD creation must precede SDK tuple issuance")
            let storage = try #require(
                CompleteCheckpointStorageIdentity(
                    kind: backend.kind,
                    layerDTypes: backend.nativeLayerDTypes, pagedConfig: backend.pagedPoolConfig,
                    target: .glm5Next(backend.layerKinds)))
            #expect(storage.backendLayout == CBv2CompleteCheckpointManifest.glm5NextPagedLayout)
            #expect(storage.fingerprintFields["storage.maximumContext"] == "1536")
            #expect(
                storage.fingerprintFields["storage.executionPolicy"]
                    == String(describing: GLM5NextExecutionPolicy.serving))
            #expect(model.root.textTower.executionPolicy == .serving)
            #expect(model.root.mtp?.executionPolicy == .serving)
            #expect(
                backend.schedulerConfig.prefillChunkSize
                    == min(model.maximumContextLength, EngineV2Factory.glm5NextMaximumPrefillChunkTokens))
            #expect(
                backend.schedulerConfig.maxBatchedTokensPerStep
                    == min(model.maximumContextLength, EngineV2Factory.glm5NextMaximumStepTokens))
            #expect(backend.schedulerConfig.soloPrefillStripeTokens == nil)
            #expect(
                storage.fingerprintFields["storage.nativeProfile"]
                    == "glm5_next_native_paged_full_state_serial_mtp_v1")
            // The default issued profile is rectangular adaptive up to depth 3.
            #expect(model.execution.verification == .rectangular(depth: 3))
            let resolved = try model.resolvedMTPConfiguration(
                .init(
                    enabled: true,
                    maxDraftTokens: 3, maxSpeculativeBatch: 4, fixedDraftTokens: 2,
                    verificationMode: .rectangular), drafter: model.assistant)
            #expect(
                resolved.maxDraftTokens == 3 && resolved.fixedDraftTokens == 2
                    && resolved.maxSpeculativeBatch == 1 && resolved.verificationMode == .rectangular)
            let baseline = try model.resolvedMTPConfiguration(
                .init(enabled: true, verificationMode: .serialTarget), drafter: model.assistant)
            #expect(
                baseline.maxDraftTokens == 3 && baseline.fixedDraftTokens == nil
                    && baseline.verificationMode == .rectangular)
            // The rollback issues the serial single-proposal profile.
            let serial = try GLM5NextProtectedModel(
                root: model.root, maximumContextLength: model.maximumContextLength,
                environment: [GLM5NextProtectedModel.rectangularVerifyEnvironmentKey: " Off "])
            #expect(serial.execution.verification == .serialTarget)
            let serialResolved = try serial.resolvedMTPConfiguration(
                .init(
                    enabled: true, maxDraftTokens: 3, maxSpeculativeBatch: 4, fixedDraftTokens: 2,
                    verificationMode: .rectangular), drafter: serial.assistant)
            #expect(
                serialResolved.maxDraftTokens == 1 && serialResolved.fixedDraftTokens == 1
                    && serialResolved.maxSpeculativeBatch == 1
                    && serialResolved.verificationMode == .serialTarget)
            let cache = try #require(
                await EngineV2SlotFactory.prepareCompletePrefixCache(
                    modelId: fixture.plan.weights.catalog.id, model: model,
                    preparedBackend: backend,
                    weightHash: fixture.plan.weights.manifest.aggregateSHA256,
                    promptContractID: fixture.identity.promptContractID,
                    mtpDrafter: model.assistant, mtpConfig: fixture.mtpConfig,
                    kvBudget: fixture.budget,
                    environment: fixture.environment, identityOverride: fixture.identity)?.cache)
            fixture.stores.append(cache)
            #expect(backend.glm5NextNative == nil)
            let foreignModel = try GLM5NextProtectedModel(
                root: model.root,
                maximumContextLength: model.maximumContextLength)
            let foreignBudget = GLM5NextProtectedFactoryFixture.makeBudget()
            func assemble(
                store: SSDHybridCheckpointStore?, budget: GlobalKVCacheBudget,
                assistant: any CBv2MTPDrafter
            ) throws -> EngineV2Factory.ProductionBuild {
                try EngineV2Factory.assembleProductionBuild(
                    model: model, tokenizer: tokenizer,
                    prefixCache: nil, completePrefixCache: store, maxConcurrentRequests: 1,
                    mtpDrafter: assistant, mtpConfig: fixture.mtpConfig,
                    preparedBackend: backend, kvBudget: budget)
            }
            try fixture.expectFactoryRefusal {
                try assemble(store: cache, budget: foreignBudget, assistant: model.assistant)
            }
            try fixture.expectFactoryRefusal {
                try assemble(
                    store: cache, budget: fixture.budget, assistant: foreignModel.assistant)
            }
            #expect(backend.glm5NextNative == nil)
            let bridge = try EngineV2Factory.makeBridge(
                modelId: fixture.plan.weights.catalog.id,
                tokenizer: TokenizerHandle(tokenizer), eosTokenIds: [], defaultMaxTokens: 4,
                maxConcurrentRequests: 1, kvBytesPerToken: 1, kvBudget: fixture.budget,
                ssdHybridCheckpointStore: cache
            ) {
                try assemble(store: cache, budget: fixture.budget, assistant: model.assistant)
            }
            fixture.bridges.append(bridge)
            let native = try #require(backend.glm5NextNative)
            #expect(native.resources.completePrefixCache === cache)
            #expect(native.resources.processMemoryOwner === native.processOwner)
            #expect(
                native.resources.contract.profile
                    == "glm5_next_native_paged_full_state_rectangular_mtp_v1")
            #expect(native.resources.contract.supportsNativeCompletePrefix)
            #expect(await bridge.canSubmitWithNativeOwner())
            let foreignStore = try #require(
                await SSDHybridCheckpointStoreFactory.make(
                    modelId: fixture.plan.weights.catalog.id, identity: cache.identity,
                    backendLayout: cache.config.backendLayout, kvBudget: fixture.budget,
                    environment: fixture.environment.merging([
                        "DARKBLOOM_PREFIX_CACHE_TEST_ROOT": fixture.root.appendingPathComponent(
                            "foreign-cache"
                        ).path
                    ]) { _, value in value }))
            fixture.stores.append(foreignStore)
            #expect(foreignStore !== cache && foreignStore.identity == cache.identity)
            try fixture.expectFactoryRefusal {
                try assemble(
                    store: foreignStore, budget: fixture.budget, assistant: model.assistant)
            }
            try fixture.expectFactoryRefusal {
                try assemble(store: nil, budget: fixture.budget, assistant: model.assistant)
            }
            #expect(native.resources.backend.pool.bytesMaterialized == 0)
            #expect(native.resources.backend.bytesReserved == 0)
            #expect(
                await bridge.canSubmitWithNativeOwner(),
                "foreign tuple refusals must not mutate the valid owner")
            try await fixture.run(bridge, tokens: [3, 3], id: "valid-after-refusals")
            let engine = try #require(await bridge.ownedEngine as? EngineV2)
            let metrics = try #require(engine.mtpMetricsSnapshot())
            #expect(metrics.rounds > 0 && metrics.rectangularVerificationRounds > 0)
        }
    }

    @Test func rectangularVerifyRollbackReachesTheProviderJob() {
        #expect(
            LaunchAgent.inferencePassthroughEnvKeys.contains("DARKBLOOM_GLM_RECTANGULAR_VERIFY"))
        #expect(GLM5NextProtectedModel.rectangularVerifyEnvironmentKey == "DARKBLOOM_GLM_RECTANGULAR_VERIFY")
    }

    @Test func disabledSSDStillUsesOriginalProtectedProfile() async throws {
        try await withFixture { fixture in
            let container = try await fixture.load()
            let tokenizer = await container.tokenizer
            let prepared = try await EngineV2SlotFactory.prepareProductionModel(
                modelId: fixture.plan.weights.catalog.id, isVLM: false, container: container,
                specDecPreparation: fixture.mtpPreparation,
                maximumContextLength: fixture.sizing.maxContextLength)
            let backend = try EngineV2Factory.prepareProductionBackend(
                model: prepared.servingModel,
                kvBudget: fixture.budget, kvBytesCapacity: fixture.kvBytesCapacity, maxConcurrentRequests: 1,
                kvBackend: .paged, environment: fixture.environment)
            let cache = await EngineV2SlotFactory.prepareCompletePrefixCache(
                modelId: fixture.plan.weights.catalog.id, model: prepared.servingModel,
                preparedBackend: backend,
                weightHash: fixture.plan.weights.manifest.aggregateSHA256,
                promptContractID: fixture.identity.promptContractID,
                mtpDrafter: prepared.assistant?.drafter, mtpConfig: fixture.mtpConfig,
                kvBudget: fixture.budget,
                environment: ["DARKBLOOM_PREFIX_CACHE": "0"], identityOverride: fixture.identity)
            #expect(cache?.cache == nil && cache?.status.reason == .configDisabled)
            #expect(
                !PrefixCachePolicy.isEnabled(
                    modelId: fixture.plan.weights.catalog.id, environment: [:]))
            let bridge = try EngineV2Factory.makeBridge(
                modelId: fixture.plan.weights.catalog.id,
                tokenizer: TokenizerHandle(tokenizer), eosTokenIds: [], defaultMaxTokens: 4,
                maxConcurrentRequests: 1, kvBytesPerToken: 1, kvBudget: fixture.budget
            ) {
                try EngineV2Factory.assembleProductionBuild(
                    model: prepared.servingModel, tokenizer: tokenizer,
                    prefixCache: nil, maxConcurrentRequests: 1,
                    mtpDrafter: prepared.assistant?.drafter,
                    mtpConfig: fixture.mtpConfig, preparedBackend: backend, kvBudget: fixture.budget
                )
            }
            fixture.bridges.append(bridge)
            let native = try #require(backend.glm5NextNative)
            #expect(native.resources.completePrefixCache == nil)
            #expect(
                native.resources.contract.profile == "glm5_next_native_paged_rectangular_mtp_v1")
            #expect(!native.resources.contract.supportsNativeCompletePrefix)
            #expect(await bridge.canSubmitWithNativeOwner())
        }
    }
}

private final class GLM5NextProtectedFactoryFixture: @unchecked Sendable {
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

    init() throws {
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
        let template = "{% for message in messages %}{{ message['content'] }}{% endfor %}x"
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
        let id = "synthetic/glm-provider-\(UUID())"
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
