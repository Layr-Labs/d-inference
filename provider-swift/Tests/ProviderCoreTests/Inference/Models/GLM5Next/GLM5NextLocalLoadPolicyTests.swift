import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
import ProviderCoreFoundation
import Testing

@testable import ProviderCore

struct GLM5NextLocalQualificationTests {
    private var model: ModelInfo {
        .init(id: GLM5NextLocalQualification.modelID, modelType: "glm5_next",
            sizeBytes: 1, estimatedMemoryGb: 1)
    }

    @Test func disabledByDefaultAndNeverCoordinatorSupported() {
        #expect(!GLM5NextLocalQualification.isSupportedLocally(model: model, environment: [:]))
        #expect(!EngineV2SupportedModels.isSupported(model: model))
        #expect(!EngineV2SupportedModels.isSupported(modelType: "glm5_next"))
        #expect(EngineV2SupportedModels.partition([model]).supported.isEmpty)
    }

    /// MTP is on for GLM without any knob: automatic intent needs no config
    /// declaration, while `off` still disables it and other families keep theirs.
    @Test func automaticModeEnablesGLMEmbeddedMTP() {
        for declared in [false, true] {
            #expect(MTPMode.auto.enablesMTP(forModelType: "glm5_next", embeddedArtifactDeclared: declared))
            #expect(MTPMode.auto.enablesMTP(forModelType: " GLM5_NEXT ", embeddedArtifactDeclared: declared))
            #expect(!MTPMode.off.enablesMTP(forModelType: "glm5_next", embeddedArtifactDeclared: declared))
        }
        #expect(BackendSettings().mtpMode == .auto)
        // Defaults alone (no config, no environment) serve both GLM identities,
        // local and coordinator, with MTP and rectangular verification.
        for id in [GLM5NextLocalQualification.modelID, "glm-5.3-flash"] {
            #expect(GLM5NextLocalServing.nativeMTPAvailable(
                mode: BackendSettings().mtpMode, modelID: id, processMTPEnabled: true))
        }
        #expect(SpecDecArtifactFunnel.killSwitchEnabled(environment: [:]))
        #expect(MiMoV26DecodeDefaults.isEnabled(
            GLM5NextProtectedModel.rectangularVerifyEnvironmentKey, environment: [:]))
        #expect(!MTPMode.auto.enablesMTP(forModelType: "glm5", embeddedArtifactDeclared: false))
        #expect(!MTPMode.auto.enablesMTP(forModelType: "qwen3", embeddedArtifactDeclared: false))
    }

    /// The local list hides GLM exactly when every load would fail with
    /// `nativeMTPRequired`; other families are never filtered.
    @Test func localListHidesGLMWithoutNativeMTP() {
        let other = ModelInfo(id: "other", modelType: "qwen3", sizeBytes: 1, estimatedMemoryGb: 1)
        let cases: [(MTPMode, Bool, Bool)] = [
            (.on, true, true), (.auto, true, true), (.off, true, false), (.on, false, false),
            (.auto, false, false),
        ]
        for (mode, process, loadable) in cases {
            let split = GLM5NextLocalServing.partition(
                [model, other], mode: mode, processMTPEnabled: process)
            #expect(split.loadable.map(\.id) == (loadable ? [model.id, other.id] : [other.id]))
            #expect(split.nativeMTPUnavailable.map(\.id) == (loadable ? [] : [model.id]))
            #expect(GLM5NextLocalServing.nativeMTPAvailable(
                mode: mode, modelID: model.id, processMTPEnabled: process) == loadable)
        }
    }

    @Test func explicitPinnedSelectionAndMismatches() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let aggregate = String(repeating: "a", count: 64)
        let manifest = ModelManifest(schemaVersion: 1, modelID: model.id, version: "local-test",
            r2Prefix: "local/test", aggregateSHA256: aggregate, totalSizeBytes: 1,
            fileCount: 1, files: [.init(path: "config.json", sizeBytes: 1,
                sha256: String(repeating: "a", count: 64), role: "config")], createdAt: Date())
        let catalog = CatalogModel(id: model.id, s3Name: "local", displayName: "local",
            sizeGb: 1, version: manifest.version, r2Prefix: manifest.r2Prefix,
            huggingFaceArtifact: .init(repoID: model.id, revision: String(repeating: "1", count: 40)),
            aggregateSHA256: aggregate, totalSizeBytes: 1, fileCount: 1)
        try GLM5NextLocalSelectionFile.write(catalog: catalog, manifest: manifest, to: file)
        let environment = [GLM5NextLocalQualification.environmentKey: file.path]
        #expect(GLM5NextLocalQualification.isSupportedLocally(model: model, environment: environment))
        #expect(!EngineV2SupportedModels.isSupported(model: model))
        var mismatch = model
        mismatch.id += "-other"
        #expect(!GLM5NextLocalQualification.isSupportedLocally(model: mismatch, environment: environment))
        mismatch = model
        mismatch.weightHash = String(repeating: "b", count: 64)
        #expect(!GLM5NextLocalQualification.isSupportedLocally(model: mismatch, environment: environment))
        #expect(throws: GLM5NextManagedLoadError.identityMismatch) {
            try GLM5NextLocalQualification.validate(modelID: model.id,
                aggregate: mismatch.weightHash!, expectedAggregate: aggregate)
        }
        #expect(!GLM5NextLocalQualification.isSupportedLocally(model: model,
            environment: [GLM5NextLocalQualification.environmentKey: "1"]))

        // Operators see why a GLM model is skipped; other families get no GLM reason.
        #expect(GLM5NextLocalQualification.localSelectionRefusal(
            model: model, environment: environment) == nil)
        let unset = try #require(GLM5NextLocalQualification.localSelectionRefusal(
            model: model, environment: [:]))
        #expect(unset.contains(GLM5NextLocalQualification.environmentKey))
        #expect(GLM5NextLocalQualification.localSelectionRefusal(
            model: mismatch, environment: environment)?.contains("aggregate") == true)
        #expect(GLM5NextLocalQualification.localSelectionRefusal(
            model: .init(id: "other", modelType: "qwen3", sizeBytes: 1, estimatedMemoryGb: 1),
            environment: [:]) == nil)
    }

    @Test func localPlanRecognizesOnlyTheShippedTemplate() throws {
        let selection = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: selection) }
        for shipped in [false, true] {
            let fixture = try GLM5NextManagedFixture(modelID: GLM5NextLocalQualification.modelID,
                chatTemplate: shipped ? GLM5NextManagedFixture.shippedTemplate() : nil)
            try GLM5NextLocalSelectionFile.write(catalog: fixture.catalog, manifest: fixture.manifest,
                to: selection)
            let environment = [GLM5NextLocalQualification.environmentKey: selection.path]
            if shipped {
                let local = try GLM5NextLocalQualification.resolveLocalPlan(
                    modelID: GLM5NextLocalQualification.modelID, directory: fixture.directory,
                    environment: environment)
                #expect(local.plan.usesShippedPromptTemplate)
            } else {
                #expect(throws: GLM5NextManagedLoadError.self) {
                    try GLM5NextLocalQualification.resolveLocalPlan(
                        modelID: GLM5NextLocalQualification.modelID, directory: fixture.directory,
                        environment: environment)
                }
            }
        }
    }

    @Test func separateTokenizerSelectionIsRefused() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let fixture = try GLM5NextManagedFixture(modelID: GLM5NextLocalQualification.modelID)
        try GLM5NextLocalSelectionFile.write(catalog: fixture.catalog, manifest: fixture.manifest,
            to: file)
        var object = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        object["tokenizer"] = ["directory": "/tmp/tokenizer"]
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        let environment = [GLM5NextLocalQualification.environmentKey: file.path]
        #expect(throws: GLM5NextManagedLoadError.self) {
            try GLM5NextLocalQualification.selection(environment: environment)
        }
        #expect(!GLM5NextLocalQualification.isSupportedLocally(model: model, environment: environment))
        let reason = try #require(GLM5NextLocalQualification.localSelectionRefusal(
            model: model, environment: environment))
        #expect(reason.contains("separate tokenizer selection is unsupported"))
    }

    /// A request that omits max_tokens leaves room for a prompt inside the bound.
    @Test func defaultOutputBudgetStaysBelowTheEnforcedContext() throws {
        let sizing = SlotSizingSnapshot(weightsBytes: 1 << 30, fp16KVBytesPerToken: 33_836,
            maxContextLength: 1_048_576, defaultMaxTokens: 4096)
        let fixture = try GLM5NextManagedFixture()
        let plan = try fixture.plan()
        for (context, expected) in [(4096, 2048), (32, 16), (1, 1), (65_536, 4096)] {
            let bounded = try GLM5NextServingPlan(
                plan: plan, maximumContextLength: context).boundedSizing(sizing)
            #expect(bounded.maxContextLength == context)
            #expect(bounded.defaultMaxTokens == expected)
            #expect(context == 1 || bounded.defaultMaxTokens < context)
        }
    }

    @Test func servingSchedulerBoundsEveryGLMStep() {
        let base = CBv2SchedulerConfig(maxConcurrentRequests: 2, maxBatchedTokensPerStep: 4096,
            prefillChunkSize: 4096, soloPrefillStripeTokens: 8192, soloPrefillStripeMediaCeiling: 2048)
        // The native step price of a 2,048-token step fits the post-load
        // envelope with four requests at 8K and 32K (GLM5NextStepPriceTests).
        #expect(EngineV2Factory.glm5NextMaximumPrefillChunkTokens == 2048)
        #expect(EngineV2Factory.glm5NextMaximumStepTokens == 2048)
        var scheduler = EngineV2Factory.glm5NextServingScheduler(base, context: 4096)
        #expect(scheduler.prefillChunkSize == 2048 && scheduler.maxBatchedTokensPerStep == 2048)
        #expect(scheduler.soloPrefillStripeTokens == nil && scheduler.soloPrefillStripeMediaCeiling == nil)
        #expect(scheduler.maxConcurrentRequests == 2)
        scheduler = EngineV2Factory.glm5NextServingScheduler(base, context: 32)
        #expect(scheduler.prefillChunkSize == 32 && scheduler.maxBatchedTokensPerStep == 32)
        // The generic production default chunk (512) does not narrow GLM's.
        scheduler = EngineV2Factory.glm5NextServingScheduler(
            EngineV2Factory.productionSchedulerConfig(maxConcurrentRequests: 4, environment: [:]),
            context: 32_768)
        #expect(scheduler.prefillChunkSize == 2048 && scheduler.maxBatchedTokensPerStep == 2048)
    }

    /// Request concurrency follows the operator cap and its reviewed-profile
    /// ceiling; GLM adds no width-1 pin of its own. Native step pricing and
    /// per-request admission bound what actually runs together.
    @Test func servingConcurrencyIsNotPinnedToOneRow() {
        for requested in [1, 2, 4, 8] {
            let config = EngineV2Factory.productionSchedulerConfig(
                maxConcurrentRequests: requested, environment: [:])
            let scheduler = EngineV2Factory.glm5NextServingScheduler(config, context: 4096)
            #expect(scheduler.maxConcurrentRequests == requested)
        }
    }

    /// A refused protected engine reports the native cause, including the
    /// step-scratch needed/available bytes, and the geometry it was priced at.
    @Test func activationRefusalNamesNativeReasonsAndStepGeometry() throws {
        let scheduler = EngineV2Factory.glm5NextServingScheduler(
            EngineV2Factory.productionSchedulerConfig(maxConcurrentRequests: 4, environment: [:]),
            context: 8192)
        #expect(EngineV2Factory.glm5NextActivationRefusal(
            mtpInactiveReason: nil, pagedAttentionWorkInactiveReason: nil,
            nativeCompletionFault: nil, scheduler: scheduler) == nil)
        let scratch = "GLM worst-case step scratch exceeds the engine envelope "
            + "(capacityExhausted(needed: 99268888418, available: 56801301254))"
        let refusal = try #require(EngineV2Factory.glm5NextActivationRefusal(
            mtpInactiveReason: nil, pagedAttentionWorkInactiveReason: scratch,
            nativeCompletionFault: nil, scheduler: scheduler))
        #expect(refusal.hasPrefix("GLM protected engine did not activate its issued tuple: "))
        #expect(refusal.contains("paged attention work: \(scratch)"))
        #expect(refusal.contains("max_concurrent_requests=4 step_tokens=2048 prefill_chunk_tokens=2048"))
        #expect(!refusal.contains("mtp:") && !refusal.contains("native completion fault"))
        let description = String(describing: EngineV2ProductionError.pagedUnavailable(refusal))
        #expect(description.contains("needed: 99268888418, available: 56801301254"))
        let combined = try #require(EngineV2Factory.glm5NextActivationRefusal(
            mtpInactiveReason: "no drafter supplied", pagedAttentionWorkInactiveReason: nil,
            nativeCompletionFault: "stepWatchdog", scheduler: scheduler))
        #expect(combined.contains("mtp: no drafter supplied; native completion fault: stepWatchdog"))
    }

    /// The exact local download and catalog build default the encrypted SSD
    /// store on; the global flag still opts out, and near-miss identities stay off.
    @Test func pinnedIdentityDefaultsCompletePrefixOn() {
        for modelID in [GLM5NextLocalQualification.modelID, GLM5NextCoordinatorServing.catalogModelID] {
            for value in [nil, "", "  ", "1", "on"] as [String?] {
                let environment = value.map { [PrefixCachePolicy.environmentFlag: $0] } ?? [:]
                #expect(PrefixCachePolicy.isEnabled(modelId: modelID, environment: environment))
            }
            for value in ["0", "false", "off", "junk"] {
                #expect(!PrefixCachePolicy.isEnabled(
                    modelId: modelID, environment: [PrefixCachePolicy.environmentFlag: value]))
            }
        }
        for other in ["EigenLabs/GLM-5.3-Flash-MLX-4bit", "eigenlabs/glm-5.3-flash-mlx-4bit-mtp",
            "GLM-5.3-Flash", " glm-5.3-flash", " \(GLM5NextLocalQualification.modelID)", "synthetic/glm5"] {
            #expect(!PrefixCachePolicy.isEnabled(modelId: other, environment: [:]))
        }
        // Not a family grant: only the exact catalog build is advertised.
        #expect(!EngineV2SupportedModels.isSupported(modelType: "glm5_next"))
    }

    @Test func providerLoadsUseTheQualifiedServingPolicy() {
        #expect(GLM5NextManagedLoad.executionPolicy == .serving)
        #expect(GLM5NextManagedLoad.executionPolicy != .reference)
    }

    /// Layer geometry comes from the pinned GLM-5.3-Flash architecture
    /// evidence, and the re-slice weight must equal the rate the engine admits
    /// for the same FP32 native rows on both storage backends.
    @Test func actualAsymmetricFP32KVRateMatchesEngineAdmission() throws {
        struct Architecture: Decodable {
            struct Text: Decodable {
                struct Sparse: Decodable {
                    let num_attention_heads, kv_lora_rank, index_head_dim: Int
                }
                let sparse_attention_layers: [Int]
                let sparse_attention: Sparse
            }
            let text: Text
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try JSONDecoder().decode(Architecture.self, from: Data(contentsOf:
            root.appendingPathComponent("fixtures/models/glm53-flash/architecture.json"))).text
        let layers = text.sparse_attention_layers.map { index in
            CBv2LayerKind(attention: .full, headDim: text.sparse_attention.kv_lora_rank,
                valueHeadDim: 2 * text.sparse_attention.index_head_dim + 1, kvHeads: 1,
                queryHeads: text.sparse_attention.num_attention_heads, modelLayerIndex: index)
        }
        #expect(layers.count == 11)
        let rate = GLM5NextLoadFunnel.kvBytesPerToken(layerKinds: layers)
        #expect(rate == 33_836)
        let dtypes = Array(repeating: DType.float32, count: layers.count)
        for kind in [EngineV2KVBackendKind.paged, .contiguous] {
            #expect(rate == EngineV2SlotFactory.slotKVBytesPerToken(
                resolvedKind: kind, pagedPoolDType: "float32", nativeLayerDTypes: dtypes,
                layerKinds: layers, nominalFP16BytesPerToken: 0, servingModelIsGPTOSS: false))
        }
        #expect(SlotSizingSnapshot.fp16KVBytesPerToken(layerKinds: layers) == 22_528)
    }

    @Test func retainedFaultIsObservableAndOnlyRefusesGLM() throws {
        let store = GLM5NextRetainedOwnerStore()
        let owner = NSObject()
        weak var retained = owner
        store.retain([owner, owner])
        #expect(store.retainedOwnerObjectCount == 1 && retained != nil)
        #expect(throws: GLM5NextManagedLoadError.retirementUnproven) {
            try store.requireHealthy(modelType: "glm5_next")
        }
        try store.requireHealthy(modelType: "mimo_v2")
        try store.requireHealthy(modelType: "gemma4")
        #expect(store.diagnosticMetrics.contains("darkbloom_glm5_next_retained_fault 1\n"))
        #expect(store.diagnosticMetrics.contains("darkbloom_glm5_next_retained_owner_objects 1\n"))
        #expect(store.diagnosticMetrics.contains("darkbloom_glm5_next_retained_resident_bytes 0\n"))
        #expect(!GLM5NextLoadFunnel.isUnproven(GLM5NextManagedLoadError.identityMismatch))
    }

    /// Nested failure paths charge the same newcomer: the larger figure wins
    /// (no double count), distinct owners add, and the sum saturates.
    @Test func retainedResidentChargesDeduplicateAndSaturate() {
        let store = GLM5NextRetainedOwnerStore()
        let newcomer = NSObject()
        store.retain([], charging: newcomer, residentBytes: 12 << 30)
        store.retain([NSObject()], charging: newcomer, residentBytes: 8 << 30)
        #expect(store.retainedResidentBytes == 12 << 30)
        store.retain([], charging: newcomer, residentBytes: 14 << 30)
        #expect(store.retainedResidentBytes == 14 << 30)
        let bundle = NSObject()
        store.retain([], charging: bundle, residentBytes: 1 << 30)
        #expect(store.retainedResidentBytes == 15 << 30)
        store.retain([], charging: NSObject(), residentBytes: .max)
        #expect(store.retainedResidentBytes == .max)
        #expect(store.retainedOwnerObjectCount == 4)
        #expect(GLM5NextLoadFaultState.residentBytes(-1, 5) == 5)
        #expect(GLM5NextLoadFaultState.residentBytes(Int.max, Int.max) == UInt64(Int.max) * 2)
    }

    /// Target-only GLM has no checked completion receipt: every disabled,
    /// fallen-back or external preparation is refused before weights load.
    @Test func targetOnlyPreparationsAreRefused() throws {
        let refused: [SpecDecPreparation] = [
            .init(artifact: nil, status: .disabled(.configDisabled, configured: false)),
            .init(artifact: nil, status: .disabled(.metadataMissing, configured: true)),
            .init(artifact: nil, status: .init(configured: true, active: false, reason: .killSwitchDisabled,
                source: .inline, revision: nil, sourceRevision: nil, artifactBytes: 0, assistantBytes: 0)),
        ]
        for preparation in refused {
            #expect(throws: GLM5NextManagedLoadError.nativeMTPRequired) {
                try GLM5NextLoadFunnel.requireNativeMTP(preparation)
            }
        }
        let inline = SpecDecPreparation(artifact: nil, status: .init(configured: true, active: false,
            reason: nil, source: .inline, revision: nil, sourceRevision: nil,
            artifactBytes: 1, assistantBytes: 0))
        if CBv2MTPConfig.envEnabled {
            try GLM5NextLoadFunnel.requireNativeMTP(inline)
        } else {
            #expect(throws: GLM5NextManagedLoadError.nativeMTPRequired) {
                try GLM5NextLoadFunnel.requireNativeMTP(inline)
            }
        }
    }
}

/// Selection-file shape read by `DARKBLOOM_EXPERIMENTAL_GLM5_NEXT`.
enum GLM5NextLocalSelectionFile {
    private struct Envelope: Encodable {
        let catalog: CatalogModel
        let manifest: ModelManifest
        let expectedAggregateSHA256: String
        let maximumContextLength: Int?
    }

    static func write(
        catalog: CatalogModel, manifest: ModelManifest, maximumContextLength: Int? = nil, to url: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(Envelope(catalog: catalog, manifest: manifest,
            expectedAggregateSHA256: manifest.aggregateSHA256,
            maximumContextLength: maximumContextLength)).write(to: url)
    }
}

/// A synthetic artifact under the locally qualified identity in a private
/// HF-style cache, selected through the real opt-in file. Process-global
/// environment/cache configuration: run only in an isolated filtered process.
private struct GLM5NextStandaloneHost {
    let root: URL
    let fixture: GLM5NextManagedFixture
    let model: ModelInfo
    private let previousPrefixCacheFlag = ProcessInfo.processInfo.environment[PrefixCachePolicy.environmentFlag]

    init() throws {
        // The pinned identity defaults the encrypted SSD store on, and the
        // server reads the process environment. These lifecycle tests never
        // touch the live cache root or Keychain key; the protected factory
        // suite covers the default-on store in an isolated test root.
        setenv(PrefixCachePolicy.environmentFlag, "0", 1)
        root = FileManager.default.temporaryDirectory.appendingPathComponent("glm5-standalone-\(UUID())")
        let snapshot = root.appendingPathComponent(
            ModelScanner.cacheDirectoryName(for: GLM5NextLocalQualification.modelID))
            .appendingPathComponent("snapshots/\(String(repeating: "a", count: 40))")
        fixture = try GLM5NextManagedFixture(
            modelID: GLM5NextLocalQualification.modelID, directory: snapshot,
            chatTemplate: GLM5NextManagedFixture.shippedTemplate())
        let selection = root.appendingPathComponent("selection.json")
        try GLM5NextLocalSelectionFile.write(catalog: fixture.catalog, manifest: fixture.manifest,
            maximumContextLength: 32, to: selection)
        setenv(GLM5NextLocalQualification.environmentKey, selection.path, 1)
        ModelScanner.configureCacheDirectory(root.path)
        model = try #require(ModelScanner.parseModelInfo(
            snapshotDir: snapshot, modelName: GLM5NextLocalQualification.modelID))
        try #require(GLM5NextLocalQualification.isSupportedLocally(model: model))
    }

    func restoreProcessEnvironment() {
        unsetenv(GLM5NextLocalQualification.environmentKey)
        if let previousPrefixCacheFlag {
            setenv(PrefixCachePolicy.environmentFlag, previousPrefixCacheFlag, 1)
        } else {
            unsetenv(PrefixCachePolicy.environmentFlag)
        }
    }

    func server(mtpMode: MTPMode) -> StandaloneServer {
        StandaloneServer(config: .init(
            runtimeCapabilities: ModelRuntimeRequirements.glm5NextRequiredCapabilities,
            engineV2KVBackend: "paged", mtpMode: mtpMode), models: [model],
            kvBudgetForTesting: nil)
    }
}

@Suite(.serialized) struct GLM5NextStandaloneLoadPolicyTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_TEST_GLM5_MANAGED_SYNTHETIC"] == "1"))
    func localOptInRefusesTargetOnlyBeforeAnyLoadState() async throws {
        let oldCache = ModelScanner.configuredCacheDirectory
        defer { ModelScanner.configureCacheDirectory(oldCache) }
        let host = try GLM5NextStandaloneHost()
        defer {
            host.restoreProcessEnvironment()
            try? FileManager.default.removeItem(at: host.root)
        }
        // The server never lists GLM without native MTP, so a load is refused
        // as an unknown model before any load state exists.
        let server = host.server(mtpMode: .off)
        #expect(await server.models.isEmpty)
        await #expect(throws: StandaloneServerError.self) {
            try await server.ensureModelLoaded(host.model.id)
        }
        #expect(await host.server(mtpMode: .on).models.map(\.id) == [host.model.id])
        let state = await server.glm5NextLoadRetentionForTesting(host.model.id)
        #expect(!state.pendingLease && !state.loading && !state.loadGateHeld)
        #expect(await server.debugOutstandingKVReservationBytes() == 0)
        #expect(!GLM5NextLoadFaultState.isRetained)
    }

    #if DEBUG
    /// Run alone: an unproven retirement is deliberately process-retained.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_TEST_GLM5_RETAINED_FAULT"] == "1"))
    func unprovenPostBuildUnwindKeepsLeaseOwnershipAndCharge() async throws {
        let oldCache = ModelScanner.configuredCacheDirectory
        defer { ModelScanner.configureCacheDirectory(oldCache) }
        let host = try GLM5NextStandaloneHost()
        let server = host.server(mtpMode: .on)
        let reserveBefore = await server.resolvedActivationReserveBytes
        let budgetBefore = await server.fleetKVBudgetBytes(extraWeightBytes: 0)
        let built = GLM5NextBridgeBox()
        await server.setGLM5NextPostBuildProbeForTesting { bridge in
            built.bridge = bridge
            try await bridge.installGLM5NextRetirementRefusalForTesting {
                built.closeAttempts += 1
                throw GLM5NextManagedLoadError.lifecycle
            }
            return false  // Post-bridge headroom failure.
        }
        await #expect(throws: GLM5NextManagedLoadError.retirementUnproven) {
            try await server.ensureModelLoaded(host.model.id)
        }
        let bridge = try #require(built.bridge)
        #expect(await bridge.hasGLM5NextNativeOwner)
        #expect(await bridge.ownedEngine != nil)
        // A retained close is never re-driven by a later unload or eviction.
        #expect(built.closeAttempts == 1)
        await #expect(throws: GLM5NextManagedLoadError.retirementUnproven) {
            try await bridge.shutdownGLM5NextReportingCompletion()
        }
        #expect(built.closeAttempts == 1)
        #expect(await bridge.ownedEngine != nil)

        // The unproven load keeps its lease and activity: no refund, no lapse.
        let state = await server.glm5NextLoadRetentionForTesting(host.model.id)
        #expect(state.pendingLease && state.loading && !state.loadGateHeld)
        #expect(await server.debugOutstandingKVReservationBytes() > 0)
        #expect(!(await server.serviceBudgetIsIdleForTesting()))
        #expect(throws: (any Error).self) { try GLM5NextArtifactOwnership.acquire(plan: host.fixture.plan()) }
        #expect(GLM5NextLoadFaultState.isRetained)

        // Fleet KV budgets exclude the retained weights and grant.
        let charged = GLM5NextLoadFaultState.retainedResidentBytes
        #expect(charged >= UInt64(host.fixture.manifest.totalSizeBytes))
        let reserve = await server.resolvedActivationReserveBytes
        #expect(reserve >= reserveBefore)
        #expect(await server.fleetKVBudgetBytes(extraWeightBytes: 0) == UnifiedMemoryCap.kvBudgetBytes(
            physicalBytes: ProcessInfo.processInfo.physicalMemory, residentWeightBytes: charged,
            activationReserveBytes: reserve, configReserveBytes: 0))
        #expect(await server.fleetKVBudgetBytes(extraWeightBytes: 0) < budgetBefore)

        // The retained grant is frozen in both directions; new GLM work is refused.
        let grant = await bridge.engineKVBytesCapacity()
        await bridge.updateKVBytesCapacity(grant + (1 << 30))
        #expect(await bridge.engineKVBytesCapacity() == grant)
        await bridge.updateKVBytesCapacity(grant - 1)
        #expect(await bridge.engineKVBytesCapacity() == grant)
        #expect(!(await bridge.canSubmitWithNativeOwner()))
        await #expect(throws: GLM5NextManagedLoadError.retirementUnproven) {
            try await server.ensureModelLoaded(host.model.id)
        }
        await #expect(throws: GLM5NextManagedLoadError.retirementUnproven) {
            _ = try await server.acquireModel(host.model.id)
        }
        try GLM5NextLoadFaultState.requireHealthy(modelType: "gemma4")
        await server.setV2TestHooksForTesting(.init(
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            makeEngine: { _, grant in InertStubEngine(kvBytesCapacity: grant) }))
        // A lone GLM newcomer was granted the whole fleet KV budget, and the
        // retained charge keeps all of it: an unrelated family is refused
        // fail-closed instead of being granted memory the engine may hold.
        // Other families still load when capacity remains (co-resident slots).
        #expect(await server.fleetKVBudgetBytes(extraWeightBytes: 0) == 0)
        do {
            _ = try await server.buildSlotForTesting(
                modelId: "other-family", modelType: "gemma4",
                container: otherFamilyContainer(),
                tokenizer: TokenizerHandle(StubBridgeTokenizer()),
                sizing: otherFamilySizing)
            Issue.record("other family was granted KV the retained GLM grant still holds")
        } catch StandaloneServerError.capacityUnavailable {
        } catch {
            Issue.record("unexpected refusal: \(error)")
        }
        // Keep the host artifact: retained owners may still map its files.
        GLM5NextLoadFaultState.retain([server, built])
    }

    /// Run alone: a failed in-slot retirement is deliberately process-retained.
    /// A published GLM slot whose eviction cannot prove native retirement is
    /// charged its KV claim, keeps a frozen grant, is never selected again for
    /// eviction, and is not re-closed by shutdown.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_TEST_GLM5_RETAINED_SHUTDOWN"] == "1"))
    func failedInSlotRetirementChargesClaimAndLeavesEvictionToOthers() async throws {
        try #require(!GLM5NextLoadFaultState.isRetained, "run alone in a fresh process")
        let oldCache = ModelScanner.configuredCacheDirectory
        defer { ModelScanner.configureCacheDirectory(oldCache) }
        let host = try GLM5NextStandaloneHost()
        let server = host.server(mtpMode: .on)
        let built = GLM5NextBridgeBox()
        await server.setGLM5NextPostBuildProbeForTesting { bridge in
            built.bridge = bridge
            return true
        }
        try await server.ensureModelLoaded(host.model.id)
        let bridge = try #require(built.bridge)
        #expect(await bridge.hasGLM5NextNativeOwner)
        try await bridge.installGLM5NextRetirementRefusalForTesting {
            built.closeAttempts += 1
            throw GLM5NextManagedLoadError.lifecycle
        }
        await server.setV2TestHooksForTesting(.init(
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory, clearMemoryCache: {},
            makeEngine: { _, grant in InertStubEngine(kvBytesCapacity: grant) }))
        let other = try await server.buildSlotForTesting(
            modelId: "other-family", modelType: "gemma4", container: otherFamilyContainer(),
            tokenizer: TokenizerHandle(StubBridgeTokenizer()), sizing: otherFamilySizing)
        #expect(await other.canSubmitWithNativeOwner())

        // The least recently used GLM slot fails retirement and stays
        // published; only its KV claim is charged (its weights stay counted).
        let assistant = try #require(await server.slots[host.model.id]).bundle.assistantBytes
        let claim = UInt64(await bridge.slotKVBytesClaim()) + UInt64(assistant)
        #expect(claim > 0)
        #expect(!(await server.evictLRUIdleSlotForTesting()))
        #expect(built.closeAttempts == 1)
        #expect(GLM5NextLoadFaultState.isRetained)
        #expect(GLM5NextLoadFaultState.retainedResidentBytes == claim)
        #expect(await server.slots[host.model.id]?.bridge === bridge)
        #expect(await bridge.ownedEngine != nil)

        // Survivor regrowth after the next eviction cannot move its grant.
        let grant = await bridge.engineKVBytesCapacity()
        await bridge.updateKVBytesCapacity(grant - 1)
        #expect(await bridge.engineKVBytesCapacity() == grant)

        // The retained slot is skipped, so the other family is evicted.
        #expect(await server.evictLRUIdleSlotForTesting())
        #expect(await server.slots["other-family"] == nil)
        #expect(await server.slots[host.model.id]?.bridge === bridge)
        #expect(!(await server.evictLRUIdleSlotForTesting()))
        #expect(built.closeAttempts == 1)
        #expect(await bridge.engineKVBytesCapacity() == grant)

        // Shutdown keeps draining instead of re-driving the retained close.
        await server.finishShutdown(serviceTask: nil)
        #expect(await server.lifecycleDraining)
        #expect(built.closeAttempts == 1)
        #expect(GLM5NextLoadFaultState.retainedResidentBytes == claim)
        // Keep the host artifact: retained owners may still map its files.
        GLM5NextLoadFaultState.retain([server, built])
    }
    #endif
}

private func otherFamilyContainer() -> ModelContainer {
    ModelContainer(context: .init(configuration: .init(id: "other-family"),
        model: OtherFamilyStubModel(), processor: OtherFamilyStubProcessor(),
        tokenizer: StubBridgeTokenizer()))
}

/// A short context keeps the co-resident GLM slot's proportional share above
/// its serviceability floor.
private let otherFamilySizing = SlotSizingSnapshot(weightsBytes: 1 << 30,
    fp16KVBytesPerToken: 20_480, maxContextLength: 64, defaultMaxTokens: 32)

private final class GLM5NextBridgeBox: @unchecked Sendable {
    var bridge: EngineV2Bridge?
    var closeAttempts = 0
}

private final class OtherFamilyStubModel: Module, LanguageModel {
    func prepare(_ input: LMInput, cache: [KVCache], windowSize: Int?) throws -> PrepareResult {
        .tokens(input.text)
    }
    func newCache(parameters: GenerateParameters?) -> [KVCache] { [] }
}

private struct OtherFamilyStubProcessor: UserInputProcessor {
    struct Unsupported: Error {}
    func prepare(input: UserInput) async throws -> LMInput { throw Unsupported() }
}
