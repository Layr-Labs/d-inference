import Foundation
import MLXLMCommon
import MLXNN
import Testing
@testable import ProviderCore

private final class AutopilotEmptyModel: Module, LanguageModel {
    func prepare(_ input: LMInput, cache: [KVCache], windowSize: Int?) throws -> PrepareResult { .tokens(input.text) }
    func newCache(parameters: GenerateParameters?) -> [KVCache] { [] }
}
private struct AutopilotEmptyProcessor: UserInputProcessor {
    struct Unused: Error {}
    func prepare(input: UserInput) async throws -> LMInput { throw Unused() }
}
private func autopilotEmptyContainer() -> ModelContainer {
    .init(context: ModelContext(configuration: ModelConfiguration(id: "test/autopilot"),
        model: AutopilotEmptyModel(), processor: AutopilotEmptyProcessor(), tokenizer: StubBridgeTokenizer()))
}
private extension ProviderLoop {
    func markAutopilotResidentOld(_ model: String, local: Bool = false, superseded: Bool = false) {
        autopilotResidentSince[model] = .now.advanced(by: .seconds(-3_600))
        modelSlots[model]?.lastInferenceAt = .now.advanced(by: .seconds(-3_600))
        if local { localReservations.reserve(model) }
        if superseded { autopilotSupersededModels.insert(model); advertisedModels.removeValue(forKey: model) }
        publishModelAutopilotSnapshot()
    }
    func configurePinOwnershipForTest(_ state: String) {
        if state == "waiting" || state == "accepted" { clearAutopilotControl() }
        if state == "expired" { autopilotControl?.expiresAtMs = 1 }
        if state == "shadow" { autopilotControl?.observeOnly = true }
        if state == "paused" || state == "disabled" {
            var settings = autopilotSettings
            settings.paused = state == "paused"
            settings.enabled = state != "disabled"
            autopilotSettingsOverride = settings
        }
        if state == "accepted" {
            autopilotCommand = .init(commandId: "accepted", loadModelId: "keep", expiresAtMs: 1)
        }
        idleMonitorTask?.cancel()
        idleMonitorTask = nil
    }
    func autopilotLoadedIDs() -> [String] { modelSlots.keys.sorted() }
    func unadvertiseWithoutReleaseForTest(_ model: String) { advertisedModels.removeValue(forKey: model) }
    func preparePausedDesiredModelRetirementForTest(activeKind: String) {
        let hash = String(repeating: "a", count: 64)
        advertisedModels["replacement"] = ModelInfo(id: "replacement", modelType: "gemma4",
            sizeBytes: 1024, estimatedMemoryGb: 0.001, weightHash: hash)
        modelHashes["replacement"] = hash
        var settings = autopilotSettings
        settings.selectedModels.append("replacement")
        settings.paused = true
        autopilotSettingsOverride = settings
        startIdleMonitor()
        if activeKind == "network" { requestToModel["retirement-active-request"] = "local" }
        else { localReservations.reserve("local") }
    }
    func finishDesiredRetirementWorkForTest(activeKind: String) {
        if activeKind == "network" { requestToModel.removeValue(forKey: "retirement-active-request") }
        else { localReservations.release("local") }
    }
}
private final class AutopilotUnloadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [ModelAutopilotStatus] = []
    func send(_ message: OutboundMessage) {
        if case .modelAutopilotStatus(let status) = message { lock.withLock { states.append(status) } }
    }
    var last: ModelAutopilotStatus? { lock.withLock { states.last } }
}

@Suite("ModelAutopilot actual unload lifecycle", .serialized)
struct ModelAutopilotUnloadTests {
    private func fixture(pins: [String] = [], selectedModels: [String]? = nil,
                         oldShutdown: @escaping @Sendable () async -> Void = {}) async throws -> (ProviderLoop, [String: InertStubEngine]) {
        let ids = ["old", "keep", "local"]
        let loop = try ProviderLoop(config: ProviderLoopConfig(
            coordinatorURL: "ws://127.0.0.1:0/unused",
            hardware: HardwareInfo(machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4, chipTier: .max,
                memoryGb: 128, memoryAvailableGb: 124, cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
                gpuCores: 40, memoryBandwidthGbs: 546),
            models: ids.map { ModelInfo(id: $0, modelType: "gemma4", sizeBytes: 1024, estimatedMemoryGb: 0.001) },
            config: ProviderConfig(provider: ProviderSettings(name: "autopilot-unload-test"),
                backend: BackendSettings(modelAutopilot: .init(enabled:true, pinnedModels:pins, consentRecorded:true, selectedModels:selectedModels ?? ids, revision:"test")))),
            attestationSigner: nil)
        await loop.activateAutopilotForTesting()
        await loop.setLoadedModelsPersistenceEnabledForTesting(false)
        let runtime = EngineV2Runtime()
        await loop.setEngineV2RuntimeForTesting(runtime)
        var engines: [String: InertStubEngine] = [:]
        for model in ids {
            let engine = InertStubEngine(onShutdown: { @Sendable in
                if model == "old" { await oldShutdown() }
            })
            let bridge = EngineV2Bridge(engine: engine, modelId: model,
                tokenizer: TokenizerHandle(StubBridgeTokenizer()), eosTokenIds: [])
            engines[model] = engine
            await runtime.register(modelId: model, bridge: bridge)
            await loop.installModelSlotForTesting(modelId: model, container: autopilotEmptyContainer(),
                tokenizer: TokenizerHandle(StubBridgeTokenizer()), engineV2: bridge)
            await loop.markAutopilotResidentOld(model)
        }
        return (loop, engines)
    }

    @Test(arguments: ["active", "paused", "waiting", "shadow", "expired", "disabled", "accepted"])
    func pinsFollowResidencyOwnership(state: String) async throws {
        let (loop, engines) = try await fixture(pins: ["old"])
        await loop.configurePinOwnershipForTest(state)
        let ordinaryPolicy = ["waiting", "shadow", "expired", "disabled"].contains(state)
        #expect(await loop.evictableModelSlots().keys.contains("old") == ordinaryPolicy)
        #expect(await loop.unloadModel("old", forEviction: true) == ordinaryPolicy)
        #expect(engines["old"]?.shutdownCalls == (ordinaryPolicy ? 1 : 0))
    }

    @Test func explicitUnloadTouchesOnlyDeclaredVictim() async throws {
        let (loop, engines) = try await fixture()
        let recorder = AutopilotUnloadRecorder()
        await loop.handleModelAutopilot(.init(commandId: "unload", unloadModelIds: ["old"],
            expectedResidentModels: ["old", "keep", "local"],
            expiresAtMs: Int64(Date().timeIntervalSince1970 * 1_000) + 60_000, sessionId:"session", revision:"test"), send: SendHandle(recorder.send))
        let task = await loop.autopilotTask
        await task?.value
        #expect(recorder.last?.status == .succeeded)
        #expect(engines["old"]?.shutdownCalls == 1)
        #expect(engines["keep"]?.shutdownCalls == 0)
        #expect(engines["local"]?.shutdownCalls == 0)
        #expect(await loop.autopilotLoadedIDs() == ["keep", "local"])
    }

    @Test(arguments: [false, true])
    func coordinatorCannotUnloadUnselectedResidentOrPartiallyApplyMixedVictims(mixedVictims: Bool) async throws {
        let (loop, engines) = try await fixture(selectedModels: ["keep", "local"])
        let recorder = AutopilotRecorder()
        let expiry = Int64(Date().timeIntervalSince1970 * 1_000) + 60_000
        await loop.handleModelAutopilot(.init(commandId: "unselected-victim",
            unloadModelIds: mixedVictims ? ["keep", "old"] : ["old"],
            expectedResidentModels: ["old", "keep", "local"], expiresAtMs: expiry,
            sessionId: "session", revision: "test"), send: SendHandle(recorder.append))
        #expect(recorder.statuses.count == 1)
        #expect(recorder.statuses.last?.status == .failed)
        #expect(recorder.statuses.last?.error == "model_not_selected")
        #expect(await loop.autopilotCommand == nil)
        #expect(await loop.autopilotTask == nil)
        #expect(await loop.state.refusingNewWork == false)
        #expect(engines.values.allSatisfy { $0.shutdownCalls == 0 })
        #expect(await loop.autopilotLoadedIDs() == ["keep", "local", "old"])

        await loop.handleModelAutopilot(.init(commandId: "selected-victim", unloadModelIds: ["keep"],
            expectedResidentModels: ["old", "keep", "local"], expiresAtMs: expiry,
            sessionId: "session", revision: "test"), send: SendHandle(recorder.append))
        let task = await loop.autopilotTask
        await task?.value
        #expect(recorder.statuses.last?.status == .succeeded)
        #expect(engines["keep"]?.shutdownCalls == 1)
        #expect(engines["old"]?.shutdownCalls == 0)
        #expect(await loop.autopilotLoadedIDs() == ["local", "old"])
    }

    @Test func shadowRejectsMutationAndExplicitLiveSwitchStillUnloads() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (loop, engines) = try await fixture()
        await loop.setDaemonStateFileForTesting(root.appendingPathComponent("daemon.json"))
        let expiry = Int64(Date().timeIntervalSince1970 * 1_000) + 120_000
        await loop.handleAutopilotControl(.init(sessionId: "session", revision: "test",
            enabled: true, expiresAtMs: expiry, observeOnly: true))
        let recorder = AutopilotUnloadRecorder()
        var command = ModelAutopilotCommand(commandId: "shadow-unload", unloadModelIds: ["old"],
            expectedResidentModels: ["old", "keep", "local"], expiresAtMs: expiry,
            sessionId: "session", revision: "test")
        await loop.handleModelAutopilot(command, send: SendHandle(recorder.send))
        #expect(recorder.last?.error == "inactive_session")
        #expect(await loop.autopilotTask == nil)
        #expect(engines["old"]?.shutdownCalls == 0)
        #expect(await loop.autopilotLoadedIDs() == ["keep", "local", "old"])

        await loop.handleAutopilotControl(.init(sessionId: "session", revision: "test",
            enabled: true, expiresAtMs: expiry, observeOnly: false))
        command.commandId = "live-unload"
        await loop.handleModelAutopilot(command, send: SendHandle(recorder.send))
        let task = await loop.autopilotTask
        await task?.value
        #expect(recorder.last?.status == .succeeded)
        #expect(engines["old"]?.shutdownCalls == 1)

        await loop.handleAutopilotControl(.init(sessionId: "session", revision: "test",
            enabled: true, expiresAtMs: expiry, observeOnly: true))
        command.commandId = "shadow-again"
        command.unloadModelIds = ["keep"]
        command.expectedResidentModels = ["keep", "local"]
        await loop.handleModelAutopilot(command, send: SendHandle(recorder.send))
        #expect(recorder.last?.error == "inactive_session")
        #expect(engines["keep"]?.shutdownCalls == 0)
        #expect(await loop.autopilotPhase == "shadow")
        await loop.idleMonitorTask?.cancel()
    }

    @Test func releaseCleanupPreservesArbitraryUnadvertisedAndSupportedResidents() async throws {
        let (loop, engines) = try await fixture()
        await loop.markAutopilotResidentOld("old", superseded: true)
        await loop.unadvertiseWithoutReleaseForTest("keep")
        await loop.cleanupAutopilotSupersededModels()
        #expect(engines["old"]?.shutdownCalls == 1)
        #expect(engines["keep"]?.shutdownCalls == 0)
        #expect(engines["local"]?.shutdownCalls == 0)
        #expect(await loop.autopilotLoadedIDs() == ["keep", "local"])
    }

    @Test func liveToShadowRetainsAcceptedMutationUntilActualUnloadCompletes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (release, continuation) = AsyncStream<Void>.makeStream()
        defer { continuation.finish() }
        let (loop, engines) = try await fixture(oldShutdown: {
            for await _ in release { break }
        })
        await loop.setDaemonStateFileForTesting(root.appendingPathComponent("daemon.json"))
        let expiry = Int64(Date().timeIntervalSince1970 * 1_000) + 120_000
        let recorder = AutopilotUnloadRecorder()
        await loop.handleModelAutopilot(.init(commandId: "accepted-live", unloadModelIds: ["old"],
            expectedResidentModels: ["old", "keep", "local"], expiresAtMs: expiry,
            sessionId: "session", revision: "test"), send: SendHandle(recorder.send))
        let task = await loop.autopilotTask
        var polls = 0
        while engines["old"]?.shutdownCalls == 0, polls < 500 {
            try await Task.sleep(for: .milliseconds(10))
            polls += 1
        }
        #expect(engines["old"]?.shutdownCalls == 1)
        await loop.handleAutopilotControl(.init(sessionId: "session", revision: "test",
            enabled: true, expiresAtMs: expiry, observeOnly: true))
        #expect(await loop.modelAutopilotEnabled == false)
        #expect(await loop.autopilotPhase == "recovering")
        #expect(await loop.autopilotCommand?.commandId == "accepted-live")
        #expect(await loop.state.refusingNewWork)
        try await loop.checkAutopilotLoadOwnership("accepted-live")
        #expect(await loop.unloadModel("keep", forEviction: true) == false)
        #expect(engines["keep"]?.shutdownCalls == 0)
        continuation.yield(())
        await task?.value
        #expect(recorder.last?.status == .succeeded)
        #expect(await loop.autopilotCommand == nil)
        #expect(await loop.autopilotPhase == "shadow")
        #expect(await loop.state.refusingNewWork == false)
        #expect(await loop.autopilotLoadedIDs() == ["keep", "local"])
        await loop.idleMonitorTask?.cancel()
    }

    @Test(arguments: [false, true])
    func releaseCleanupOnlyRetiresExplicitInactiveUnpinnedBuilds(paused: Bool) async throws {
        let (loop, engines) = try await fixture(pins: ["keep"])
        if paused { await loop.configurePinOwnershipForTest("paused") }
        await loop.markAutopilotResidentOld("old", superseded: true)
        await loop.markAutopilotResidentOld("keep", superseded: true)
        await loop.markAutopilotResidentOld("local", local: true, superseded: true)
        await loop.cleanupAutopilotSupersededModels()
        #expect(engines["old"]?.shutdownCalls == 1)
        #expect(engines["keep"]?.shutdownCalls == 0)
        #expect(engines["local"]?.shutdownCalls == 0)
        #expect(await loop.autopilotLoadedIDs() == ["keep", "local"])
        await loop.releaseLocalReservation("local")
        await loop.cleanupAutopilotSupersededModels()
        #expect(engines["local"]?.shutdownCalls == 1)
        #expect(engines["keep"]?.shutdownCalls == 0)
    }

    @Test(arguments: ["network", "local"])
    func pausedDesiredModelDropTracksRetirementAndPreservesPinsAndActiveWork(activeKind: String) async throws {
        let (loop, engines) = try await fixture(pins: ["keep"])
        await loop.preparePausedDesiredModelRetirementForTest(activeKind: activeKind)
        #expect(await loop.autopilotPhase == "paused")
        #expect(await loop.modelAutopilotEnabled == false)
        #expect(await loop.autopilotManagesResidency)
        #expect(await loop.idleMonitorTask == nil)
        #expect(await loop.autopilotSupersededModels.isEmpty)

        // The replacement is already verified, as after prefetch publication.
        // Reconcile the real alias lineage rather than inserting cleanup state.
        await loop.reconcileDesiredModels(["old", "keep", "local"].map { (model: String) in
            .init(modelName: "alias-\(model)", desiredBuild: "replacement", previousBuild: model)
        }, send: SendHandle { _ in })
        #expect(await loop.autopilotSupersededModels == Set(["old", "keep", "local"]))
        #expect(await loop.advertisedModels.keys.sorted() == ["replacement"])
        #expect(engines.values.allSatisfy { $0.shutdownCalls == 0 })

        await loop.cleanupAutopilotSupersededModels()
        #expect(engines["old"]?.shutdownCalls == 1)
        #expect(engines["keep"]?.shutdownCalls == 0)
        #expect(engines["local"]?.shutdownCalls == 0)
        #expect(await loop.autopilotSupersededModels == Set(["keep", "local"]))

        await loop.finishDesiredRetirementWorkForTest(activeKind: activeKind)
        await loop.cleanupAutopilotSupersededModels()
        #expect(engines["local"]?.shutdownCalls == 1)
        #expect(engines["keep"]?.shutdownCalls == 0)
        #expect(await loop.autopilotLoadedIDs() == ["keep"])
        #expect(await loop.autopilotSupersededModels == Set(["keep"]))
    }
}
