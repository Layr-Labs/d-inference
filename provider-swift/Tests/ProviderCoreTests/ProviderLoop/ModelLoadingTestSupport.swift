import Foundation
import MLXLMCommon
import Testing

@testable import ProviderCore

/// Shared fixtures for the model load, unload and admission suites. They use
/// a scripted memory budget, temp folders, stub slots and no model weights.

enum ModelLoadingFixtureError: Error {
    case unexpectedEngineBuild
}

/// One temp folder per test. Model snapshots and state files live here, so a
/// test never writes under the real home folder.
struct ModelLoadingSandbox {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-loading-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    var daemonStateFile: URL {
        root.appendingPathComponent("state", isDirectory: true)
            .appendingPathComponent("daemon-state.json")
    }

    var loadedModelsFile: URL {
        root.appendingPathComponent("state", isDirectory: true)
            .appendingPathComponent("loaded-models.json")
    }

    /// A small model folder: a config file and a few bytes of fake weights.
    func makeSnapshot(
        _ name: String, config: String = #"{"model_type":"gpt_oss"}"#
    ) throws -> URL {
        let directory = root.appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(config.utf8).write(to: directory.appendingPathComponent("config.json"))
        try Data(repeating: 0x5a, count: 512)
            .write(to: directory.appendingPathComponent("model.safetensors"))
        return directory
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

enum ModelLoadingFixtures {
    static func model(
        _ id: String, memoryGb: Double = 0.01, modelType: String = "gpt_oss",
        weightHash: String? = nil
    ) -> ModelInfo {
        ModelInfo(
            id: id, modelType: modelType, sizeBytes: 1 << 20,
            estimatedMemoryGb: memoryGb, weightHash: weightHash)
    }

    /// A loop on a scripted machine (no host memory reads for the budget),
    /// with MTP off, an isolated engine runtime and a temp daemon state file.
    static func makeLoop(
        sandbox: ModelLoadingSandbox,
        models: [ModelInfo] = [],
        maxModelSlots: UInt64 = 3,
        physicalBytes: UInt64 = 64 << 30,
        modelHashes: [String: String] = [:],
        modelHashFingerprints: [String: String] = [:],
        beforeModelLoad: (@Sendable (String) async -> Void)? = nil
    ) async throws -> ProviderLoop {
        let config = ProviderLoopConfig(
            coordinatorURL: "ws://127.0.0.1:0/ignored",
            hardware: HardwareInfo(
                machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4,
                chipTier: .max,
                memoryGb: 64, memoryAvailableGb: 60,
                cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
                gpuCores: 40, memoryBandwidthGbs: 546
            ),
            models: models,
            config: ProviderConfig(
                provider: ProviderSettings(name: "model-loading-test", memoryReserveGB: 0),
                backend: BackendSettings(
                    idleTimeoutMins: 0, maxModelSlots: maxModelSlots, mtpMode: .off),
                coordinator: CoordinatorSettings(heartbeatIntervalSecs: 60)
            ),
            modelHashes: modelHashes,
            modelHashFingerprints: modelHashFingerprints
        )
        let loop = try ProviderLoop(
            config: config,
            attestationSigner: nil,
            beforeModelLoad: beforeModelLoad,
            kvBudgetForTesting: ScriptedProviderMemory.budget(
                physicalBytes: physicalBytes, modelIDs: models.map(\.id)))
        await loop.setDaemonStateFileForTesting(sandbox.daemonStateFile)
        await loop.setEngineV2RuntimeForTesting(EngineV2Runtime())
        return loop
    }

    /// Pin the load-admission memory sample to a fixed value.
    static func setAvailableMemory(_ loop: ProviderLoop, gb: Double) async {
        await loop.setEngineV2SlotHooksForTesting(.init(
            availableMemoryGb: gb,
            makeEngine: { _, _ in throw ModelLoadingFixtureError.unexpectedEngineBuild }))
    }
}

/// Records the model id the before-load hook sees, then starts shutdown.
actor ModelLoadHookRecorder {
    private(set) var seen: [String] = []
    private var loop: ProviderLoop?

    func attach(_ loop: ProviderLoop) {
        self.loop = loop
    }

    func recordAndShutDown(_ modelId: String) async {
        seen.append(modelId)
        await loop?.beginShutdownForTesting()
    }
}

struct ModelLoadingWarmState: Sendable, Equatable {
    let warmModels: [String]
    let currentModel: String?
    let currentModelHash: String?
}

/// Poll a condition for up to about 10 seconds.
func modelLoadingWaitUntil(_ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<2000 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

extension ProviderLoop {
    func modelLoadingInstallSlot(
        _ modelId: String,
        bridge: EngineV2Bridge,
        weightsBytes: Int = 0,
        modelType: String? = "gpt_oss",
        lastInferenceAt: ContinuousClock.Instant = .now
    ) {
        modelSlots[modelId] = ModelSlot(
            engineV2: bridge,
            container: mtpFloorContainer(),
            tokenizer: TokenizerHandle(StubBridgeTokenizer()),
            sizing: SlotSizingSnapshot(
                weightsBytes: weightsBytes, fp16KVBytesPerToken: 20_480,
                maxContextLength: 8192, defaultMaxTokens: 4096),
            isVLM: false,
            modelType: modelType,
            lastInferenceAt: lastInferenceAt)
    }

    func modelLoadingResidentIDs() -> [String] { modelSlots.keys.sorted() }

    func modelLoadingSetLoadingAny(_ value: Bool) { isLoadingAny = value }

    func modelLoadingIsLoadingAny() -> Bool { isLoadingAny }

    func modelLoadingLoadGateWaiterCount() -> Int { loadGateWaiters.count }

    func modelLoadingMarkLoading(_ modelId: String) { modelsLoading.insert(modelId) }

    func modelLoadingClearLoading(_ modelId: String) { modelsLoading.remove(modelId) }

    func modelLoadingInFlightIDs() -> Set<String> { modelsLoading }

    func modelLoadingLoadingWaiterCount(_ modelId: String) -> Int {
        loadingWaiters[modelId]?.count ?? 0
    }

    /// Resume parked same-model waiters. A non-nil message resumes them with
    /// `InferenceError.modelLoadFailed(message)`, as a failed first load does.
    func modelLoadingResumeLoadingWaiters(_ modelId: String, failure message: String? = nil) {
        for waiter in loadingWaiters.removeValue(forKey: modelId) ?? [] {
            if let message {
                waiter.resume(throwing: InferenceError.modelLoadFailed(message))
            } else {
                waiter.resume()
            }
        }
    }

    func modelLoadingMarkUnloading(_ modelId: String) { modelsUnloading.insert(modelId) }

    func modelLoadingUnloadWaiterCount(_ modelId: String) -> Int {
        unloadingWaiters[modelId]?.count ?? 0
    }

    func modelLoadingFinishUnloading(_ modelId: String) {
        modelsUnloading.remove(modelId)
        for waiter in unloadingWaiters.removeValue(forKey: modelId) ?? [] {
            waiter.resume()
        }
    }

    func modelLoadingSetRequest(_ requestID: String, model: String?) {
        requestToModel[requestID] = model
    }

    func modelLoadingLastLoadError() -> DaemonState.ModelLoadError? { lastModelLoadError }

    func modelLoadingSetLiveHash(_ modelId: String, _ hash: String?) {
        liveModelHashes[modelId] = hash
    }

    func modelLoadingFingerprint(_ modelId: String) -> String? { modelHashFingerprints[modelId] }

    func modelLoadingAdvertise(_ info: ModelInfo) { advertisedModels[info.id] = info }

    func modelLoadingMarkFailedSelfTest(_ modelId: String, hash: String) {
        failedSelfTestHashes[modelId] = hash
    }

    func modelLoadingHasQwen4RetirementWindow() -> Bool { qwen4MemoryRetirement != nil }

    func modelLoadingReserveEpoch() -> UInt64 { activationReserveEpoch }

    func modelLoadingWarmState() -> ModelLoadingWarmState {
        ModelLoadingWarmState(
            warmModels: state.warmModels,
            currentModel: state.currentModel,
            currentModelHash: state.currentModelHash)
    }
}
