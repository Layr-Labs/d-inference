import Foundation
@testable import ProviderCore

/// A provider with saved Autopilot consent and no control lease: one ordinary
/// model and two cached inventory builds, resident behind inert engines on a
/// scripted machine, idle for two hours and old enough to be victims.
struct AutopilotPlacementFixture {
    static let ordinary = "placement-ordinary"
    static let inventory = "placement-inventory"
    static let spare = "placement-spare"
    static let all = [ordinary, inventory, spare]
    static let weightHash = String(repeating: "a", count: 64)

    let loop: ProviderLoop
    let engines: [String: InertStubEngine]
    private let root: URL

    static func make(consent: Bool = true, resident: [String] = all, maxModelSlots: UInt64 = 4,
                     weightsBytes: Int = 1 << 30, kvBudget: GlobalKVCacheBudget? = nil,
                     configure: (inout BackendSettings) -> Void = { _ in }) async throws -> AutopilotPlacementFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("autopilot-placement-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let settings = ModelAutopilotSettings(enabled: consent, consentRecorded: consent,
            selectedModels: all, revision: "test", minIdleSeconds: 1)
        var backend = BackendSettings(idleTimeoutMins: 60, maxModelSlots: maxModelSlots,
            mtpMode: .off, modelAutopilot: settings)
        configure(&backend)
        let loop = try ProviderLoop(
            config: ProviderLoopConfig(
                coordinatorURL: "ws://127.0.0.1:0/unused", hardware: ModelLoadingFixtures.defaultHardware,
                models: [model(ordinary)],
                config: ProviderConfig(
                    provider: ProviderSettings(name: "autopilot-placement-test", memoryReserveGB: 0),
                    backend: backend,
                    coordinator: CoordinatorSettings(heartbeatIntervalSecs: 60)),
                autopilotInventory: [model(inventory), model(spare)]),
            attestationSigner: nil,
            kvBudgetForTesting: kvBudget ?? ScriptedProviderMemory.budget(modelIDs: all))
        await loop.setDaemonStateFileForTesting(root.appendingPathComponent("daemon-state.json"))
        await loop.setLoadedModelsPersistenceEnabledForTesting(false)
        let runtime = EngineV2Runtime()
        await loop.setEngineV2RuntimeForTesting(runtime)
        var engines: [String: InertStubEngine] = [:]
        for id in resident {
            let engine = InertStubEngine()
            let bridge = EngineV2Bridge(engine: engine, modelId: id,
                tokenizer: TokenizerHandle(StubBridgeTokenizer()), eosTokenIds: [])
            await runtime.register(modelId: id, bridge: bridge)
            await loop.modelLoadingInstallSlot(id, bridge: bridge, weightsBytes: weightsBytes,
                lastInferenceAt: .now.advanced(by: .seconds(-7_200)))
            engines[id] = engine
        }
        await loop.ageAutopilotResidentsForTesting()
        return AutopilotPlacementFixture(loop: loop, engines: engines, root: root)
    }

    static func model(_ id: String) -> ModelInfo {
        ModelInfo(id: id, modelType: "gpt_oss", sizeBytes: 1 << 20, estimatedMemoryGb: 0.01,
            weightHash: weightHash)
    }

    /// An unexpired command for the `activateAutopilotForTesting()` session
    /// that expects every fixture model resident.
    static func command(_ id: String, load: String? = nil, unload: [String] = [],
                        hold: Int? = nil) -> ModelAutopilotCommand {
        ModelAutopilotCommand(commandId: id, loadModelId: load, unloadModelIds: unload, expectedResidentModels: all,
            expiresAtMs: ProviderLoop.autopilotNowMs + 60_000, sessionId: "session", revision: "test",
            holdSeconds: hold)
    }

    func remove() async {
        await loop.idleMonitorTask?.cancel()
        try? FileManager.default.removeItem(at: root)
    }
}

extension ProviderLoop {
    func ageAutopilotResidentsForTesting() {
        for id in modelSlots.keys { autopilotResidentSince[id] = .now.advanced(by: .seconds(-7_200)) }
        publishModelAutopilotSnapshot()
    }

    /// Submits the command, waits for the operation it started, if any, and
    /// returns the last status sent for it.
    func runAutopilotCommandForTesting(_ command: ModelAutopilotCommand) async -> ModelAutopilotStatus? {
        let recorder = AutopilotRecorder()
        handleModelAutopilot(command, send: SendHandle(recorder.append))
        if autopilotCommand?.commandId == command.commandId { await autopilotTask?.value }
        return recorder.statuses.last
    }

    /// What a succeeded operation leaves behind: its target published and its
    /// placement recorded. The command path itself runs in the tiny-model suite.
    func settleAutopilotOperationForTesting(target: String, holdSeconds: Int? = nil) {
        if advertisedModels[target] == nil, let model = autopilotInventoryModels[target] {
            advertisedModels[target] = model
        }
        recordAutopilotPlacement(ModelAutopilotCommand(commandId: "settled-\(target)", loadModelId: target,
            expiresAtMs: 0, holdSeconds: holdSeconds))
        publishModelAutopilotSnapshot()
    }

    func updateAutopilotSettingsForTesting(_ change: (inout ModelAutopilotSettings) -> Void) {
        var settings = autopilotSettings
        change(&settings)
        autopilotSettingsOverride = settings
        withdrawInactiveAutopilotModels()
        publishModelAutopilotSnapshot()
    }

    func setAutopilotHoldForTesting(_ id: String, until: ContinuousClock.Instant) {
        let offsetSeconds = (until - ContinuousClock.now).components.seconds
        autopilotHolds[id] = AutopilotHold(until: until, untilMs: Self.autopilotNowMs + offsetSeconds * 1_000)
    }

    func setIdleForTesting(_ id: String, since: ContinuousClock.Instant) {
        modelSlots[id]?.lastInferenceAt = since
    }

    var autopilotPlacementsForTesting: (adopted: Set<String>, held: Set<String>) {
        (autopilotAdoptedModelIDs, Set(autopilotHolds.keys))
    }

    func advertisedIDsForTesting() -> [String] { advertisedModels.keys.sorted() }
}
