import Foundation
import Testing
@testable import ProviderCore

/// Resident MLX bytes of a scripted machine, by model. A stub engine's
/// shutdown frees its model's bytes.
final class ScriptedResidentMemory: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [String: UInt64] = [:]

    func set(_ id: String, _ value: UInt64) { lock.withLock { bytes[id] = value } }
    func remove(_ id: String) { lock.withLock { _ = bytes.removeValue(forKey: id) } }
    var total: UInt64 { lock.withLock { bytes.values.reduce(0, +) } }
}

/// A consented 256 GB M5 Ultra whose ordinary selection is Nemotron Super and
/// Gemma, with GLM-5.3-Flash resident beside Gemma and Super cold: the state
/// one operator's `darkbloom status` reported. GLM is either a cached
/// Autopilot inventory build (it can serve only through an operation's
/// adoption) or part of the ordinary selection the daemon started with.
/// Memory is scripted to the reported figures: idle, 42.3 GiB is usable for a
/// load (36.8 GiB of LOAD room for Super's claim) beside 16.8 GiB of Gemma
/// weights; a GLM request in flight holds 2 GiB more (its KV), leaving Super
/// 34.8 GiB. No weights load: GLM and Gemma are inert stub slots, and Super's
/// loader is never reached.
struct UnreclaimableLoadMemoryFixture: Sendable {
    static let superID = NemotronSuperServingPolicy.modelID
    static let gemmaID = "gemma-4-26b-qat-4bit"
    static let glmID = GLM5NextCoordinatorServing.catalogModelID
    static let weightHash = String(repeating: "d", count: 64)
    static let physicalBytes: UInt64 = 256 << 30
    static let gemmaBytes = UInt64(16.8 * 1_073_741_824)
    static let idleSuperRoomBytes = UInt64(36.8 * 1_073_741_824)
    static let glmRequestKVBytes: UInt64 = 2 << 30

    /// GLM's resident bytes: what leaves Super `idleSuperRoomBytes` under the
    /// cap beside Gemma and the serving set's activation reserve.
    static var glmBytes: UInt64 {
        UnifiedMemoryCap.hardCapBytes(physicalBytes: physicalBytes, capFraction: 0.9)
            - idleSuperRoomBytes - gemmaBytes
            - UnifiedMemoryCap.resolvedActivationReserveBytes(modelIDs: [superID, gemmaID, glmID])
    }

    static let hardware = HardwareInfo(machineModel: "Mac17,9", chipName: "Apple M5 Ultra",
        chipFamily: .m5, chipTier: .ultra, memoryGb: 256, memoryAvailableGb: 256,
        cpuCores: CpuCores(total: 32, performance: 24, efficiency: 8), gpuCores: 80, memoryBandwidthGbs: 1_228)

    enum GLMSelection { case autopilotInventory, ordinary }

    let loop: ProviderLoop
    let budget: GlobalKVCacheBudget
    let memory: ScriptedResidentMemory
    let root: URL
    let modelCache: URL
    let superDirectory: URL
    let configPath: URL
    private let engines: EngineRegistry

    /// `resident` models are installed as idle stub slots, the first least
    /// recently used. `persistedLoadedModels` seeds the loaded-models file the
    /// startup preload reads.
    static func make(glm: GLMSelection, resident: [String] = [gemmaID, glmID], maxModelSlots: UInt64 = 3,
                     persistedLoadedModels: [String]? = nil) async throws -> Self {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("unreclaimable-load-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let modelCache = root.appendingPathComponent("hub", isDirectory: true)
        for id in [superID, gemmaID, glmID] { try makeCachedSnapshot(id, in: modelCache) }
        let superDirectory = try #require(ModelScanner.resolveLocalPath(modelID: superID,
            environment: [:], configuredDirectory: modelCache.path))

        let memory = ScriptedResidentMemory()
        let budget = GlobalKVCacheBudget(capFraction: 0.9, activationReserveBytes: 0, configReserveBytes: 0) {
            let resident = min(memory.total, physicalBytes)
            return .init(total: physicalBytes, active: resident, cache: 0, systemAvailable: physicalBytes - resident)
        }
        let ordinaryIDs = glm == .ordinary ? [superID, gemmaID, glmID] : [superID, gemmaID]
        let settings = ModelAutopilotSettings(enabled: true, consentRecorded: true,
            selectedModels: [superID, gemmaID], revision: "test", minIdleSeconds: 1)
        let backend = BackendSettings(enabledModels: ordinaryIDs,
            idleTimeoutMins: 0, maxModelSlots: maxModelSlots, startupSelftest: false, mtpMode: .auto,
            modelAutopilot: settings)
        let config = ProviderConfig(provider: ProviderSettings(name: "unreclaimable-load", memoryReserveGB: 0),
            backend: backend, coordinator: CoordinatorSettings(heartbeatIntervalSecs: 60))
        let configPath = root.appendingPathComponent("provider.toml")
        try ConfigManager.save(config, to: configPath)
        let loop = try ProviderLoop(config: ProviderLoopConfig(
                coordinatorURL: "ws://127.0.0.1:0/unused", hardware: hardware,
                models: ordinaryIDs.map(model), config: config,
                runtimeCapabilities: ModelRuntimeRequirements.glm5NextRequiredCapabilities,
                // As at daemon start: every candidate's startup hash is live.
                modelHashes: Dictionary(uniqueKeysWithValues: [superID, gemmaID, glmID].map { ($0, weightHash) }),
                configPath: configPath,
                autopilotInventory: [model(glmID)]),
            attestationSigner: nil, kvBudgetForTesting: budget)
        await loop.setDaemonStateFileForTesting(root.appendingPathComponent("daemon-state.json"))
        let loadedModels = root.appendingPathComponent("loaded-models.json")
        if let persistedLoadedModels { LoadedModelsStore.write(persistedLoadedModels, to: loadedModels) }
        await loop.setLoadedModelsFileForTesting(loadedModels)
        await loop.setEngineV2RuntimeForTesting(EngineV2Runtime())
        // KV re-slice arithmetic (an operation's reserve preflight, the
        // capacity summary) reads machine memory from these hooks, else from
        // the Mac running the tests: pin it to the scripted machine.
        await loop.setEngineV2SlotHooksForTesting(ProviderLoop.EngineV2SlotHooks(
            physicalMemoryBytes: physicalBytes, makeEngine: { _, _ in throw CancellationError() }))
        await loop.setNemotronSuperSlotLoaderForTesting(NemotronSuperSlotLoader(
            pinned: true, physicalBytes: physicalBytes, kvBytesPerToken: { _ in 64 },
            load: { _ in throw InferenceError.modelLoadFailed("the scripted machine never loads Super") }),
            environment: [:])
        let fixture = Self(loop: loop, budget: budget, memory: memory, root: root, modelCache: modelCache,
                           superDirectory: superDirectory, configPath: configPath, engines: EngineRegistry())
        for (index, id) in resident.enumerated() {
            await fixture.install(id, idleFor: .seconds(7_200 - index))
        }
        await loop.refreshActivationReserve()
        await loop.ageAutopilotResidentsForTesting()
        return fixture
    }

    static func model(_ id: String) -> ModelInfo {
        switch id {
        case superID:
            let footprint = NemotronSuperServingPolicy.discoveryFootprint(sizeBytes: 75_010_188_240)
            return ModelInfo(id: id, modelType: NemotronSuperServingPolicy.modelType, sizeBytes: 75_010_188_240,
                estimatedMemoryGb: footprint.estimatedMemoryGb, weightHash: weightHash,
                nativeLoadTransientBytes: footprint.nativeLoadTransientBytes)
        case glmID:
            return ModelInfo(id: id, modelType: "gpt_oss", sizeBytes: glmBytes,
                estimatedMemoryGb: Double(glmBytes) / 1_073_741_824, weightHash: weightHash)
        default:
            return ModelInfo(id: id, modelType: "gpt_oss", sizeBytes: gemmaBytes,
                estimatedMemoryGb: Double(gemmaBytes) / 1_073_741_824, weightHash: weightHash)
        }
    }

    static func residentBytes(_ id: String) -> UInt64 { id == glmID ? glmBytes : gemmaBytes }

    /// Installs `id` as a resident stub slot holding its scripted bytes.
    func install(_ id: String, idleFor idle: Duration = .zero) async {
        let memory = self.memory
        let stub = makeInertStubBridge(modelId: id, onShutdown: { memory.remove(id) })
        engines.add(id, stub.engine)
        memory.set(id, Self.residentBytes(id))
        await loop.modelLoadingInstallSlot(id, bridge: stub.bridge, weightsBytes: Int(Self.residentBytes(id)),
            lastInferenceAt: .now.advanced(by: .zero - idle))
    }

    func shutdownCalls(_ id: String) -> Int { engines.engine(id)?.shutdownCalls ?? 0 }

    /// A GLM request is accepted and decoding: GLM has work in flight and its
    /// KV holds `glmRequestKVBytes`.
    func beginGLMRequest() async {
        memory.set("glm-request-kv", Self.glmRequestKVBytes)
        await loop.modelLoadingSetRequest("glm-request", model: Self.glmID)
    }

    func endGLMRequest() async {
        await loop.modelLoadingSetRequest("glm-request", model: nil)
        memory.remove("glm-request-kv")
    }

    /// Runs `body` with the provider's model cache set to this machine's.
    func withModelCache<T>(_ body: () async throws -> T) async rethrows -> T {
        let previous = ModelScanner.configuredCacheDirectory
        ModelScanner.configureCacheDirectory(modelCache.path)
        defer { ModelScanner.configureCacheDirectory(previous) }
        return try await body()
    }

    /// The operation an admin submits through the coordinator: load GLM with
    /// a placement hold, under the session's acknowledged lease. The
    /// coordinator omits the reason and requests no lease.
    static func adminOperation(holdSeconds: Int, residents: [String] = [gemmaID, glmID]) -> ModelAutopilotCommand {
        ModelAutopilotCommand(commandId: "op_0123456789abcdef0123456789abcdef", loadModelId: glmID,
            expectedResidentModels: residents,
            expiresAtMs: ProviderLoop.autopilotNowMs + 60_000, leaseSeconds: 0,
            sessionId: "session", revision: "test", holdSeconds: holdSeconds)
    }

    /// Super's refusal when evicting Gemma alone cannot make room.
    static func superRefusal(room: String) -> String {
        "Insufficient memory (\(room) GB of LOAD room, need 83.6 GB) even after "
            + "evicting every idle model (16.8 GB reclaimable) — refusing without evicting"
    }

    /// The refusal the operator's status reported, verbatim: GLM decoding.
    static let reportedSuperRefusal = superRefusal(room: "34.8")

    func remove() async {
        await loop.idleMonitorTask?.cancel()
        try? FileManager.default.removeItem(at: root)
    }

    private static func makeCachedSnapshot(_ id: String, in cache: URL) throws {
        let snapshot = cache.appendingPathComponent(ModelScanner.cacheDirectoryName(for: id), isDirectory: true)
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent("0000000000000000000000000000000000000000", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try Data(#"{"model_type":"gpt_oss"}"#.utf8).write(to: snapshot.appendingPathComponent("config.json"))
        try Data(repeating: 0x5a, count: 512).write(to: snapshot.appendingPathComponent("model.safetensors"))
    }

    private final class EngineRegistry: @unchecked Sendable {
        private let lock = NSLock()
        private var engines: [String: InertStubEngine] = [:]
        func add(_ id: String, _ engine: InertStubEngine) { lock.withLock { engines[id] = engine } }
        func engine(_ id: String) -> InertStubEngine? { lock.withLock { engines[id] } }
    }
}

extension ProviderLoop {
    /// Whether the ordinary selection the daemon serves without Autopilot
    /// contains `id`.
    func ordinarySelectionContainsForTesting(_ id: String) -> Bool { ordinaryServingModelIDs.contains(id) }

    func markInferenceForTesting(_ id: String, at instant: ContinuousClock.Instant = .now) {
        modelSlots[id]?.lastInferenceAt = instant
        syncWarmModelState()
    }
}
