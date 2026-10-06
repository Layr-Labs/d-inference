import Foundation
import Testing
@testable import ProviderCore

private final class AutopilotStartupLoadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func record(_ id: String) { lock.withLock { values.append(id) } }
    var loads: [String] { lock.withLock { values } }
}

@Suite("Autopilot startup preferences")
struct AutopilotStartupPreferencesTests {
    private func stateDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func fixture(root: URL, backend: BackendSettings, shadow: Bool = false) async throws
        -> (ProviderLoop, AutopilotStartupLoadRecorder) {
        let inventory = ["extra", "selected", "pin"]
        var backend = backend
        backend.modelAutopilot = .init(enabled: true, consentRecorded: true,
            selectedModels: inventory, revision: "test")
        let selected = backend.enabledModels.isEmpty ? inventory : Array(Set(backend.enabledModels + [backend.model].compactMap { $0 })).sorted()
        let infos = inventory.map { ModelInfo(id: $0, modelType: "gemma4", sizeBytes: 1024, estimatedMemoryGb: 2) }
        let loop = try ProviderLoop(config: ProviderLoopConfig(
            coordinatorURL: "ws://127.0.0.1:0/unused",
            hardware: HardwareInfo(machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4, chipTier: .max,
                memoryGb: 128, memoryAvailableGb: 124, cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
                gpuCores: 40, memoryBandwidthGbs: 546),
            models: infos.filter { selected.contains($0.id) },
            config: ProviderConfig(provider: ProviderSettings(name: "startup-preference-test"), backend: backend),
            autopilotInventory: infos),
            attestationSigner: nil)
        await loop.setLoadedModelsFileForTesting(root.appendingPathComponent("loaded.json"))
        await loop.setDaemonStateFileForTesting(root.appendingPathComponent("daemon.json"))
        await loop.setStartupPreloadFreeMemoryOverrideForTesting { 100 }
        await loop.setStartupSelfTestOverrideForTesting { _ in .milliseconds(1) }
        let recorder = AutopilotStartupLoadRecorder()
        await loop.setStartupPreloadLoadOverrideForTesting { recorder.record($0) }
        if shadow { await loop.installStartupShadowControlForTesting() }
        return (loop, recorder)
    }

    @Test(arguments: [false, true])
    func implicitPreloadRetainsPriorSelectionNotNewInventory(shadow: Bool) async throws {
        let root = try stateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        LoadedModelsStore.write(["extra"], to: root.appendingPathComponent("loaded.json"))
        let backend = BackendSettings(enabledModels: ["selected"], idleTimeoutMins: 45)
        let (loop, recorder) = try await fixture(root: root, backend: backend, shadow: shadow)
        #expect(await loop.startupPreloadPlanForTesting().map(\.modelId) == ["selected"])
        #expect(await loop.runStartupPreloadGateForTesting() == .warm)
        #expect(recorder.loads == ["selected"])
        #expect(await loop.advertisedModels.keys.sorted() == ["selected"])
        #expect(await loop.autopilotAllowsModel("extra") == false)
        #expect(await loop.autopilotManagesResidency == false)
        #expect(await loop.loopConfig.config.backend.enabledModels == backend.enabledModels)
        #expect(await loop.loopConfig.config.backend.idleTimeoutMins == backend.idleTimeoutMins)

        // Inventory must remain observational in both waiting and shadow mode.
        let replies = AutopilotRecorder()
        await loop.handleLoadModelRequest(modelId: "extra", send: SendHandle(replies.append))
        let preload = await loop.preloadTasks["extra"]
        await preload?.value
        #expect(replies.legacyStatuses == [.failed])
    }

    @Test func implicitPreloadPrioritizesPinnedModelWithoutWarmingExtraInventory() async throws {
        let root = try stateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        LoadedModelsStore.write(["selected", "extra"], to: root.appendingPathComponent("loaded.json"))
        let (loop, recorder) = try await fixture(root: root,
            backend: BackendSettings(model: "pin", enabledModels: ["selected"]))
        #expect(await loop.startupPreloadPlanForTesting().map(\.modelId) == ["pin", "selected"])
        #expect(await loop.runStartupPreloadGateForTesting() == .warm)
        #expect(recorder.loads == ["pin", "selected"])
    }

    @Test func explicitPreloadListCannotWidenServingSelection() async throws {
        let root = try stateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = BackendSettings(model: "pin", enabledModels: ["selected"],
            preloadModels: ["extra", "selected", "extra"])
        let (loop, recorder) = try await fixture(root: root, backend: backend)
        #expect(await loop.startupPreloadPlanForTesting().map(\.modelId) == ["selected"])
        #expect(await loop.runStartupPreloadGateForTesting() == .warm)
        #expect(recorder.loads == ["selected"])
        #expect(await loop.loopConfig.config.backend.preloadModels == backend.preloadModels)
    }

    @Test func disabledStartupPreloadDoesNotWarmEnrolledInventory() async throws {
        let root = try stateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (loop, recorder) = try await fixture(root: root,
            backend: BackendSettings(enabledModels: ["selected"], startupPreload: false,
                preloadModels: ["extra"]))
        #expect(await loop.runStartupPreloadGateForTesting() == .disabled)
        #expect(recorder.loads.isEmpty)
        #expect(await loop.advertisedModels.count == 1)
    }

    @Test func emptySavedSelectionRetainsOrdinaryAllAdvertisedPreloadBehavior() async throws {
        let root = try stateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (loop, recorder) = try await fixture(root: root, backend: BackendSettings())
        #expect(await loop.startupPreloadPlanForTesting().map(\.modelId) == ["extra", "selected", "pin"])
        #expect(await loop.runStartupPreloadGateForTesting() == .warm)
        #expect(recorder.loads == ["extra", "selected", "pin"])
    }
}

private extension ProviderLoop {
    func installStartupShadowControlForTesting() {
        autopilotControl = .init(sessionId: "session", revision: "test", enabled: true,
            expiresAtMs: Int64(Date().timeIntervalSince1970 * 1_000) + 120_000, observeOnly: true)
        publishModelAutopilotSnapshot()
    }
}
