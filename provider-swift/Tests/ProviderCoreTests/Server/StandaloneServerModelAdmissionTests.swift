import Foundation
import Hummingbird
import HummingbirdTesting
import Logging
import MLXLMCommon
import MLXNN
import NIOCore
import NIOEmbedded
import Testing
@testable import ProviderCore

// Model admission, slot bookkeeping and eviction policy of the standalone
// (local mode) server. Slots use an empty model container and an inert
// engine: no weights load, no inference runs, no model directory is read
// or written.

// MARK: - Fixtures

private final class AdmissionEmptyModel: Module, LanguageModel {
    func prepare(_ input: LMInput, cache: [KVCache], windowSize: Int?) throws -> PrepareResult {
        .tokens(input.text)
    }
    func newCache(parameters: GenerateParameters?) -> [KVCache] { [] }
}

private struct AdmissionUnusedProcessor: UserInputProcessor {
    private struct NotUsed: Error {}
    func prepare(input: UserInput) async throws -> LMInput { throw NotUsed() }
}

private func makeAdmissionContainer() -> ModelContainer {
    ModelContainer(context: ModelContext(
        configuration: ModelConfiguration(id: "test/admission-empty-model"),
        model: AdmissionEmptyModel(),
        processor: AdmissionUnusedProcessor(),
        tokenizer: StubBridgeTokenizer()))
}

private let admissionGiB: UInt64 = 1024 * 1024 * 1024
private let admissionPhysicalBytes: UInt64 = 64 * admissionGiB

private let admissionSizing = SlotSizingSnapshot(
    weightsBytes: Int(admissionGiB),
    fp16KVBytesPerToken: 1024,
    maxContextLength: 128,
    defaultMaxTokens: 8)

private struct InstalledSlot {
    let bridge: EngineV2Bridge
    let engine: InertStubEngine
}

private func installSlot(
    _ server: StandaloneServer,
    modelId: String,
    modelType: String? = "gpt_oss",
    tokenizer: TokenizerHandle = TokenizerHandle(StubBridgeTokenizer())
) async -> InstalledSlot {
    let (bridge, engine) = makeInertStubBridge(modelId: modelId, kvBytesCapacity: 1 << 20)
    await server.installSlotForTesting(
        modelId: modelId,
        bridge: bridge,
        container: makeAdmissionContainer(),
        tokenizer: tokenizer,
        sizing: admissionSizing,
        modelType: modelType)
    return InstalledSlot(bridge: bridge, engine: engine)
}

/// Hooks that keep eviction off the real MLX allocator and pin machine memory.
private func admissionHooks() -> StandaloneServer.V2TestHooks {
    StandaloneServer.V2TestHooks(
        physicalMemoryBytes: admissionPhysicalBytes,
        clearMemoryCache: {},
        makeEngine: { _, grant in InertStubEngine(kvBytesCapacity: grant) })
}

private final class WeightHashCallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(path: URL, modelId: String)] = []
    func record(path: URL, modelId: String) { lock.withLock { calls.append((path, modelId)) } }
    var snapshot: [(path: URL, modelId: String)] { lock.withLock { calls } }
}

/// Render an acquisition failure through the production local HTTP error
/// boundary (`CORSResponder`), the layer every local route shares.
private struct AdmissionAcquireResponder: HTTPResponder {
    typealias Context = BasicRequestContext
    let acquire: @Sendable () async throws -> Void

    func respond(to request: Request, context: Context) async throws -> Response {
        try await acquire()
        return Response(status: .ok)
    }
}

private func renderAcquire(
    _ acquire: @escaping @Sendable () async throws -> Void
) async throws -> Response {
    let responder = CORSResponder(inner: AdmissionAcquireResponder(acquire: acquire))
    let request = Request(
        head: .init(method: .post, scheme: "http", authority: "localhost", path: "/v1/chat/completions"),
        body: .init(buffer: ByteBuffer()))
    let context = BasicRequestContext(
        source: ApplicationRequestContextSource(
            channel: EmbeddedChannel(), logger: Logger(label: "standalone-admission")))
    return try await responder.respond(to: request, context: context)
}

private func absentModelID() -> String {
    "darkbloom-tests/absent-\(UUID().uuidString)"
}

private func chatBody(model: String) -> ByteBuffer {
    ByteBuffer(string: #"{"model":""# + model
        + #"","messages":[{"role":"user","content":"hi"}],"stream":false}"#)
}

// MARK: - Tests

@Suite("Standalone server model admission")
struct StandaloneServerModelAdmissionTests {

    // MARK: Catalog

    @Test func catalogDropsModelsThatNeedMissingRuntimeCapabilities() async throws {
        let gated = ModelInfo(
            id: ModelRuntimeRequirements.qwen38ConcreteModelID, modelType: "qwen3_5",
            quantization: "4bit", sizeBytes: 1, estimatedMemoryGb: 1)
        let open = ModelInfo(
            id: "gpt-oss-20b", modelType: "gpt_oss", quantization: "4bit",
            sizeBytes: 1, estimatedMemoryGb: 1)

        let plain = StandaloneServer(models: [gated, open])
        #expect(await plain.advertisedModelIds() == ["gpt-oss-20b"])

        let capable = StandaloneServer(
            config: StandaloneServerConfig(runtimeCapabilities: [.appleM5, .mlxNAX]),
            models: [gated, open])
        #expect(await capable.advertisedModelIds()
            == [ModelRuntimeRequirements.qwen38ConcreteModelID, "gpt-oss-20b"].sorted())
    }

    @Test func configClampsCacheSizeAndRecordsExplicitConcurrency() {
        let defaults = StandaloneServerConfig(maxCachedModels: 0)
        #expect(defaults.maxCachedModels == 1)
        #expect(defaults.host == "127.0.0.1")
        #expect(!defaults.engineV2MaxConcurrentIsExplicit)
        #expect(defaults.engineV2MaxConcurrent == BackendSettings.defaultEngineV2MaxConcurrent)

        let explicit = StandaloneServerConfig(engineV2MaxConcurrent: 3)
        #expect(explicit.engineV2MaxConcurrentIsExplicit)
        #expect(explicit.engineV2MaxConcurrent == 3)
    }

    @Test func engineConcurrencyUsesPerModelOverrideAndClamps() async {
        let server = StandaloneServer(config: StandaloneServerConfig(
            engineV2MaxConcurrent: 100,
            engineV2MaxConcurrentByModel: ["zero-model": 0, "two-model": 2]))

        #expect(await server.engineV2MaxConcurrent(forModel: "other-model")
            == ServingPerformanceProfiles.maximumQualifiedConcurrency)
        #expect(await server.engineV2MaxConcurrent(forModel: "zero-model") == 1)
        #expect(await server.engineV2MaxConcurrent(forModel: "two-model") == 2)
    }

    // MARK: Acquisition errors

    @Test func ineligibleModelIsRefusedBeforeCatalogLookup() async throws {
        let modelID = ModelRuntimeRequirements.qwen38ConcreteModelID
        let server = StandaloneServer()

        do {
            try await server.ensureModelLoaded(modelID)
            Issue.record("an ineligible model must not start loading")
        } catch let error as ModelRuntimeIneligibleError {
            #expect(error.eligibility.modelID == modelID)
            #expect(error.eligibility.missing == [.appleM5, .mlxNAX])
        }
        // acquireModel maps the refusal to "model not loaded" (404).
        await #expect(throws: MultiModelBatchSchedulerEngineError.modelNotLoaded(modelID)) {
            _ = try await server.acquireModel(modelID)
        }
        #expect(await server.debugSlotReservationCount(modelId: modelID) == 0)
    }

    @Test func advertisedModelWithoutLocalFilesIsNotFound() async throws {
        let modelID = absentModelID()
        try #require(ModelScanner.resolveLocalPath(modelID: modelID) == nil)
        let server = StandaloneServer(
            models: [ModelInfo(
                id: modelID, modelType: "gemma4", quantization: "4bit",
                sizeBytes: 1, estimatedMemoryGb: 1)],
            kvBudgetForTesting: ScriptedProviderMemory.budget(modelIDs: [modelID]))
        #expect(await server.advertisedModelIds() == [modelID])

        do {
            try await server.ensureModelLoaded(modelID)
            Issue.record("a model with no local snapshot must not load")
        } catch StandaloneServerError.modelNotFound(let missing) {
            #expect(missing == modelID)
        }
        await #expect(throws: MultiModelBatchSchedulerEngineError.modelNotLoaded(modelID)) {
            _ = try await server.acquireModel(modelID)
        }
        // The refusal leaves no load marker, reservation or resident slot.
        #expect(await server.loadedModelIds().isEmpty)
        #expect(!(await server.isLoadingAny))
        #expect(await server.modelsLoading.isEmpty)
        #expect(await server.debugOutstandingKVReservationBytes() == 0)
        #expect(await server.debugSlotReservationCount(modelId: modelID) == 0)
    }

    @Test func chatForUnavailableModelsMapsToNotFoundEnvelope() async throws {
        let absent = absentModelID()
        try #require(ModelScanner.resolveLocalPath(modelID: absent) == nil)
        let ineligible = ModelRuntimeRequirements.qwen38ConcreteModelID
        let server = StandaloneServer(models: [ModelInfo(
            id: absent, modelType: "gemma4", quantization: "4bit",
            sizeBytes: 1, estimatedMemoryGb: 1)])
        let app = server.makeApplication()

        try await app.test(.router) { client in
            for model in [absent, ineligible] {
                try await client.execute(
                    uri: "/v1/chat/completions",
                    method: .post,
                    headers: [.contentType: "application/json"],
                    body: chatBody(model: model)
                ) { response in
                    #expect(response.status == .notFound)
                    #expect(response.headers[.accessControlAllowOrigin] == "*")
                    let body = String(buffer: response.body)
                    #expect(body.contains(InferenceFailureCode.modelUnavailable.message))
                    #expect(!body.contains(model))
                }
            }
        }
        _ = server
    }

    @Test func acquisitionWhileDrainingMapsToTooManyRequests() async throws {
        let server = StandaloneServer(config: .init(port: 0))
        _ = await installSlot(server, modelId: "gpt-oss-20b")
        let identity = try #require(ProcessIdentity.current())
        let status = await server.drainForLifecycle(
            ProviderDrainRequest(target: identity, timeoutSeconds: 0))
        #expect(status.outcome == .drained)

        // Even a resident model refuses new work once the drain began.
        await #expect(throws: MultiModelBatchSchedulerEngineError.queueFull("provider draining")) {
            _ = try await server.acquireModel("gpt-oss-20b")
        }
        #expect(await server.debugSlotReservationCount(modelId: "gpt-oss-20b") == 0)

        let response = try await renderAcquire {
            _ = try await server.acquireModel("gpt-oss-20b")
        }
        #expect(response.status == .tooManyRequests)
        #expect(response.headers[.accessControlAllowOrigin] == "*")
        #expect(response.headers[.contentType] == "application/json")
    }

    // MARK: Tokenizer resolution

    @Test func tokenizerResolutionPrefersTheNamedResidentModel() async throws {
        let server = StandaloneServer()
        await #expect(throws: MultiModelBatchSchedulerEngineError.noModelLoadedForTokenization) {
            _ = try await server.resolveTokenizer(nil)
        }
        await #expect(throws: MultiModelBatchSchedulerEngineError.modelNotLoaded("model-a")) {
            _ = try await server.resolveTokenizer("model-a")
        }

        let tokenizerA = TokenizerHandle(StubBridgeTokenizer())
        let tokenizerB = TokenizerHandle(StubBridgeTokenizer())
        _ = await installSlot(server, modelId: "model-b", modelType: "gpt_oss", tokenizer: tokenizerB)
        _ = await installSlot(server, modelId: "model-a", modelType: "gemma4", tokenizer: tokenizerA)

        let named = try await server.resolveTokenizer("model-b")
        #expect(named.tokenizer === tokenizerB)
        #expect(named.modelType == "gpt_oss")

        // No model named: the first resident model in sorted order answers.
        let fallback = try await server.resolveTokenizer(nil)
        #expect(fallback.tokenizer === tokenizerA)
        #expect(fallback.modelType == "gemma4")

        await #expect(throws: MultiModelBatchSchedulerEngineError.modelNotLoaded("missing")) {
            _ = try await server.resolveTokenizer("missing")
        }
    }

    @Test func tokenizeRouteUsesTheResidentTokenizer() async throws {
        let server = StandaloneServer()
        _ = await installSlot(server, modelId: "model-a")
        let app = server.makeApplication()

        try await app.test(.router) { client in
            try await client.execute(
                uri: "/tokenize",
                method: .post,
                headers: [.contentType: "application/json"],
                body: ByteBuffer(string: #"{"model":"model-a","prompt":"hello"}"#)
            ) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body).contains(#""tokens""#))
            }
        }
        _ = server
    }

    @Test func audioAdmissionModelTypePrefersTheResidentSlot() async {
        let server = StandaloneServer(models: [ModelInfo(
            id: "gpt-oss-20b", modelType: "gpt_oss", quantization: "4bit",
            sizeBytes: 1, estimatedMemoryGb: 1)])

        #expect(await server.localModelTypeForAudioAdmission("gpt-oss-20b") == "gpt_oss")
        #expect(await server.localModelTypeForAudioAdmission("unknown-model") == nil)

        _ = await installSlot(server, modelId: "gpt-oss-20b", modelType: "resident_type")
        #expect(await server.localModelTypeForAudioAdmission("gpt-oss-20b") == "resident_type")
    }

    // MARK: Metrics samples

    @Test func metricsSamplesSkipSlotsWhoseEngineHasShutDown() async throws {
        let server = StandaloneServer()
        let slotB = await installSlot(server, modelId: "model-b")
        _ = await installSlot(server, modelId: "model-a")

        let both = await server.mtpSlotMetricsSamples()
        #expect(both.map(\.model) == ["model-a", "model-b"])
        #expect(both.allSatisfy { $0.posture != nil })

        await slotB.bridge.shutdown()
        #expect(slotB.engine.shutdownCalls == 1)
        let live = await server.mtpSlotMetricsSamples()
        #expect(live.map(\.model) == ["model-a"])

        let app = server.makeApplication()
        try await app.test(.router) { client in
            try await client.execute(uri: "/metrics", method: .get) { response in
                #expect(response.status == .ok)
                let body = String(buffer: response.body)
                #expect(body.contains(#"kv_active_requests{model="model-a"} 0"#))
                #expect(body.contains(#"mtp_enabled{model="model-a"}"#))
                #expect(!body.contains(#"model="model-b""#))
            }
        }
        _ = server
    }

    // MARK: Slot bookkeeping and LRU eviction

    @Test func reservationsCountUpAndDownAndUnknownReleaseIsIgnored() async {
        let server = StandaloneServer()
        _ = await installSlot(server, modelId: "model-a")

        await server.reserveSlot("model-a")
        await server.reserveSlot("model-a")
        #expect(await server.debugSlotReservationCount(modelId: "model-a") == 2)
        await server.releaseSlot("model-a")
        #expect(await server.debugSlotReservationCount(modelId: "model-a") == 1)
        await server.releaseSlot("model-a")
        #expect(await server.debugSlotReservationCount(modelId: "model-a") == 0)
        await server.releaseSlot("model-a")
        await server.releaseSlot("never-reserved")
        #expect(await server.debugSlotReservationCount(modelId: "model-a") == 0)
        #expect(await server.debugSlotReservationCount(modelId: "never-reserved") == 0)

        #expect(await server.debugActiveRequestCount(modelId: "model-a") == 0)
        #expect(await server.debugActiveRequestCount(modelId: "missing") == nil)
        #expect(await server.debugEngineKVGrant(modelId: "model-a") == 1 << 20)
    }

    @Test func evictionPicksTheLeastRecentlyUsedIdleSlot() async throws {
        let server = StandaloneServer()
        await server.setV2TestHooksForTesting(admissionHooks())
        let slotA = await installSlot(server, modelId: "model-a")
        let slotB = await installSlot(server, modelId: "model-b")

        // A request for a resident model returns at once and marks it used,
        // so model-b becomes the least recently used slot.
        try await server.ensureModelLoaded("model-a")

        #expect(await server.evictLRUIdleSlotForTesting())
        #expect(await server.loadedModelIds() == ["model-a"])
        #expect(slotB.engine.shutdownCalls == 1)
        #expect(slotA.engine.shutdownCalls == 0)

        #expect(await server.evictLRUIdleSlotForTesting())
        #expect(await server.loadedModelIds().isEmpty)
        #expect(slotA.engine.shutdownCalls == 1)

        // Nothing is left to evict.
        #expect(!(await server.evictLRUIdleSlotForTesting()))
    }

    @Test func reservedSlotIsNeverEvicted() async {
        let server = StandaloneServer()
        await server.setV2TestHooksForTesting(admissionHooks())
        let slotA = await installSlot(server, modelId: "model-a")
        let slotB = await installSlot(server, modelId: "model-b")
        await server.reserveSlot("model-a")
        await server.reserveSlot("model-b")

        #expect(!(await server.evictLRUIdleSlotForTesting()))
        #expect(await server.loadedModelIds() == ["model-a", "model-b"])

        await server.releaseSlot("model-b")
        #expect(await server.evictLRUIdleSlotForTesting())
        #expect(await server.loadedModelIds() == ["model-a"])
        #expect(slotB.engine.shutdownCalls == 1)
        #expect(slotA.engine.shutdownCalls == 0)
        await server.releaseSlot("model-a")
    }

    @Test func fullCacheEvictsOnlyAnIdleSlotWhenAllowed() async throws {
        let server = StandaloneServer(config: StandaloneServerConfig(maxCachedModels: 1))
        await server.setV2TestHooksForTesting(admissionHooks())
        let slot = await installSlot(server, modelId: "model-a")
        let expectedMessage =
            "All 1 cached model slot(s) are active; try again when a request finishes"

        do {
            try await server.evictIfNeededForLoad(allowEviction: false)
            Issue.record("a full cache must refuse a load that may not evict")
        } catch StandaloneServerError.capacityUnavailable(let message) {
            #expect(message == expectedMessage)
        }
        #expect(await server.loadedModelIds() == ["model-a"])

        await server.reserveSlot("model-a")
        do {
            try await server.evictIfNeededForLoad()
            Issue.record("a full cache with only busy slots must refuse the load")
        } catch StandaloneServerError.capacityUnavailable(let message) {
            #expect(message == expectedMessage)
        }
        #expect(await server.loadedModelIds() == ["model-a"])
        #expect(slot.engine.shutdownCalls == 0)

        await server.releaseSlot("model-a")
        try await server.evictIfNeededForLoad()
        #expect(await server.loadedModelIds().isEmpty)
        #expect(slot.engine.shutdownCalls == 1)
    }

    @Test func cacheWithFreeSpaceSkipsEviction() async throws {
        let server = StandaloneServer(config: StandaloneServerConfig(maxCachedModels: 2))
        await server.setV2TestHooksForTesting(admissionHooks())
        let slot = await installSlot(server, modelId: "model-a")

        try await server.evictIfNeededForLoad()

        #expect(await server.loadedModelIds() == ["model-a"])
        #expect(slot.engine.shutdownCalls == 0)
    }

    // MARK: Memory headroom gate

    @Test func headroomGateIgnoresNonPositiveOrNonFiniteNeeds() async throws {
        let server = StandaloneServer(
            kvBudgetForTesting: ScriptedProviderMemory.budget())
        for need in [0, -1, Double.infinity, Double.nan] {
            try await server.ensureMemoryHeadroomForLoad(requiredGb: need)
        }
    }

    @Test func headroomGateAdmitsASmallLoadOnTheScriptedMachine() async throws {
        let budget = ScriptedProviderMemory.budget()
        let server = StandaloneServer(kvBudgetForTesting: budget)
        let available = await server.availableMemoryGb()
        #expect(available == budget.availableForLoadGb())
        try #require(available > 1)

        try await server.ensureMemoryHeadroomForLoad(requiredGb: 1)
    }

    @Test func headroomGateRefusesAnImpossibleLoad() async throws {
        let server = StandaloneServer(
            kvBudgetForTesting: ScriptedProviderMemory.budget())
        do {
            try await server.ensureMemoryHeadroomForLoad(requiredGb: 100_000)
            Issue.record("no scripted machine has 100000 GB free")
        } catch StandaloneServerError.capacityUnavailable(let message) {
            #expect(message
                == "Insufficient memory headroom to load model (needs 100000.0 GB available)")
        }
    }

    @Test func headroomGateEvictsIdleSlotsOnlyWhenAllowed() async throws {
        let server = StandaloneServer(
            kvBudgetForTesting: ScriptedProviderMemory.budget())
        await server.setV2TestHooksForTesting(admissionHooks())
        let slot = await installSlot(server, modelId: "model-a")

        do {
            try await server.ensureMemoryHeadroomForLoad(
                requiredGb: 100_000, allowEviction: false)
            Issue.record("the gate must refuse without eviction")
        } catch StandaloneServerError.capacityUnavailable {}
        #expect(await server.loadedModelIds() == ["model-a"])
        #expect(slot.engine.shutdownCalls == 0)

        // With eviction allowed the idle slot goes first; the need is still
        // too large, so the gate then refuses.
        do {
            try await server.ensureMemoryHeadroomForLoad(requiredGb: 100_000)
            Issue.record("the gate must refuse after evicting every idle slot")
        } catch StandaloneServerError.capacityUnavailable {}
        #expect(await server.loadedModelIds().isEmpty)
        #expect(slot.engine.shutdownCalls == 1)
    }

    @Test func qwen4EvictionOpensARetirementWindowBeforeRefusal() async throws {
        let server = StandaloneServer(
            kvBudgetForTesting: ScriptedProviderMemory.budget())
        await server.setV2TestHooksForTesting(admissionHooks())
        let slot = await installSlot(server, modelId: "qwen4-model", modelType: "qwen4_exp")

        #expect(await server.evictLRUIdleSlotForTesting())
        #expect(slot.engine.shutdownCalls == 1)

        // The gate re-checks memory during the retirement window, then
        // refuses because nothing is left to evict.
        do {
            try await server.ensureMemoryHeadroomForLoad(
                requiredGb: 100_000, waitForQwen4Retirement: true)
            Issue.record("the gate must refuse once the retirement window ends")
        } catch StandaloneServerError.capacityUnavailable(let message) {
            #expect(message.hasPrefix("Insufficient memory headroom to load model"))
        }
        #expect(await server.loadedModelIds().isEmpty)
    }

    // MARK: Budget helpers

    @Test func fleetBudgetCountsResidentAndNewWeights() async {
        let server = StandaloneServer()
        await server.setV2TestHooksForTesting(admissionHooks())
        #expect(await server.reserveKeepsSurvivorsServiceable(reserveBytes: .max))
        _ = await installSlot(server, modelId: "model-a")
        let reserve: UInt64 = 4 * admissionGiB
        let resident = UInt64(admissionSizing.weightsBytes)

        let withNewcomer = await server.fleetKVBudgetBytes(
            extraWeightBytes: Int(2 * admissionGiB), activationReserveBytes: reserve)
        #expect(withNewcomer == UnifiedMemoryCap.kvBudgetBytes(
            physicalBytes: admissionPhysicalBytes,
            residentWeightBytes: resident + 2 * admissionGiB,
            activationReserveBytes: reserve,
            configReserveBytes: 0))

        // A negative newcomer size counts as zero.
        let negative = await server.fleetKVBudgetBytes(
            extraWeightBytes: -5, activationReserveBytes: reserve)
        #expect(negative == UnifiedMemoryCap.kvBudgetBytes(
            physicalBytes: admissionPhysicalBytes,
            residentWeightBytes: resident,
            activationReserveBytes: reserve,
            configReserveBytes: 0))
    }

    @Test func pendingLoadSeamNeedsThePendingLoadPrefix() async {
        let server = StandaloneServer(
            kvBudgetForTesting: ScriptedProviderMemory.budget())

        #expect(!(await server.reservePendingLoadForTesting(requestID: "model-a", bytes: 1 << 20)))
        #expect(await server.debugOutstandingKVReservationBytes() == 0)

        #expect(await server.reservePendingLoadForTesting(
            requestID: "pending-load:model-a", bytes: 1 << 20))
        #expect(await server.debugOutstandingKVReservationBytes() == 1 << 20)
        // The same request ID cannot hold two reservations.
        #expect(!(await server.reservePendingLoadForTesting(
            requestID: "pending-load:model-a", bytes: 1 << 20)))
    }

    // MARK: Weight hash

    @Test func weightHashIsSkippedWhenNotRequired() async {
        let server = StandaloneServer()
        let recorder = WeightHashCallRecorder()
        await server.setV2TestHooksForTesting(StandaloneServer.V2TestHooks(
            computeWeightHash: { path, modelId in
                recorder.record(path: path, modelId: modelId)
                return "unused"
            },
            makeEngine: { _, grant in InertStubEngine(kvBytesCapacity: grant) }))
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("weight-hash-\(UUID().uuidString)", isDirectory: true)

        let hash = await server.computeStandaloneWeightHash(
            modelPath: path, modelId: "model-a", required: false)

        #expect(hash == nil)
        #expect(recorder.snapshot.isEmpty)
    }

    @Test func weightHashTrimsTheComputedValueAndRejectsBlankValues() async {
        let server = StandaloneServer()
        let recorder = WeightHashCallRecorder()
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("weight-hash-\(UUID().uuidString)", isDirectory: true)
        await server.setV2TestHooksForTesting(StandaloneServer.V2TestHooks(
            computeWeightHash: { path, modelId in
                recorder.record(path: path, modelId: modelId)
                return modelId == "blank-model" ? "   " : "  abc123  "
            },
            makeEngine: { _, grant in InertStubEngine(kvBytesCapacity: grant) }))

        let trimmed = await server.computeStandaloneWeightHash(
            modelPath: path, modelId: "model-a", required: true)
        let blank = await server.computeStandaloneWeightHash(
            modelPath: path, modelId: "blank-model", required: true)

        #expect(trimmed == "abc123")
        #expect(blank == nil)
        let calls = recorder.snapshot
        #expect(calls.map { $0.modelId } == ["model-a", "blank-model"])
        #expect(calls.allSatisfy { $0.path == path })
    }
}
