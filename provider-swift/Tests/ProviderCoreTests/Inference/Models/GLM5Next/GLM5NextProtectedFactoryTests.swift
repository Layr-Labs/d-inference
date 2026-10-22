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
        try await GLM5NextProtectedFactoryFixture.with(body)
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
