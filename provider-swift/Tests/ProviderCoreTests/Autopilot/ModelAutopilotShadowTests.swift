import Foundation
import Testing
@testable import ProviderCore

@Suite("Autopilot shadow control", .serialized)
struct ModelAutopilotShadowTests {
    private func control(observeOnly: Bool) -> ModelAutopilotControl {
        .init(sessionId: "session", revision: "test", enabled: true,
            expiresAtMs: Int64(Date().timeIntervalSince1970 * 1_000) + 120_000,
            observeOnly: observeOnly)
    }

    private func stateDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test(arguments: [false, true])
    func controlAndAcknowledgementHaveRequiredObserveOnlyWireField(observeOnly: Bool) throws {
        let message = CoordinatorMessage.modelAutopilotControl(control(observeOnly: observeOnly))
        let data = try JSONEncoder().encode(message)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["type"] as? String == "model_autopilot_control")
        #expect(object["observe_only"] as? Bool == observeOnly)
        #expect(try JSONDecoder().decode(CoordinatorMessage.self, from: data) == message)
        var missingField = object
        missingField.removeValue(forKey: "observe_only")
        let incomplete = try JSONSerialization.data(withJSONObject: missingField)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(CoordinatorMessage.self, from: incomplete)
        }

        var snapshot = ModelAutopilotSnapshot(enabled: true)
        snapshot.observeOnly = observeOnly
        snapshot.active = !observeOnly
        let ack = ProviderMessage.modelAutopilotStatus(.init(commandId: "ack", status: .failed,
            modelAutopilot: snapshot))
        let ackData = try JSONEncoder().encode(ack)
        let ackObject = try #require(JSONSerialization.jsonObject(with: ackData) as? [String: Any])
        let state = try #require(ackObject["model_autopilot"] as? [String: Any])
        #expect(state["observe_only"] as? Bool == observeOnly)
        #expect(state["active"] as? Bool == !observeOnly)
        #expect(try JSONDecoder().decode(ProviderMessage.self, from: ackData) == ack)
    }

    @Test(arguments: ["ordinary", "waiting", "shadow"])
    func ordinaryIdleAndLoadDrivenBehaviorIsPreserved(mode: String) async throws {
        let root = try stateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let loop = try await autopilotTestLoop(enabled: mode != "ordinary",
            models: [ModelInfo(id: "uncached", modelType: "gpt_oss", sizeBytes: 1, estimatedMemoryGb: 1)],
            activeControl: false)
        await loop.setDaemonStateFileForTesting(root.appendingPathComponent("daemon.json"))
        await loop.startIdleMonitor()
        if mode == "shadow" { await loop.handleAutopilotControl(control(observeOnly: true)) }
        #expect(await loop.idleMonitorTask != nil)
        #expect(await loop.modelAutopilotEnabled == false)
        #expect(await loop.autopilotManagesResidency == false)
        #expect(await loop.autopilotProtectsPins == false)
        #expect(await loop.autopilotPhase == (mode == "ordinary" ? "off" : mode))

        let recorder = AutopilotRecorder()
        await loop.handleLoadModelRequest(modelId: "uncached", send: SendHandle(recorder.append))
        let preload = await loop.preloadTasks["uncached"]
        await preload?.value
        #expect(recorder.legacyStatuses.first == .started)
        #expect(await loop.autopilotCommand == nil)
        await loop.idleMonitorTask?.cancel()
    }

    @Test func shadowControlSurvivesCapacityTicksAndExpiresToWaiting() async throws {
        let root = try stateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let loop = try await autopilotTestLoop(enabled: true, activeControl: false)
        await loop.setDaemonStateFileForTesting(root.appendingPathComponent("daemon.json"))
        await loop.handleAutopilotControl(control(observeOnly: true))
        await loop.capacityRefreshTick()
        #expect(await loop.autopilotPhase == "shadow")
        #expect(await loop.autopilotControl?.observeOnly == true)
        #expect(await loop.state.modelAutopilot?.observeOnly == true)
        #expect(await loop.state.modelAutopilot?.active == false)
        await loop.expireShadowControlForTesting()
        await loop.capacityRefreshTick()
        #expect(await loop.autopilotControl == nil)
        #expect(await loop.autopilotPhase == "waiting")
        #expect(await loop.state.modelAutopilot?.observeOnly == false)
        #expect(await loop.idleMonitorTask != nil)
        await loop.idleMonitorTask?.cancel()
    }

    @Test func shadowLiveTransitionsTransferOnlyResidencyAuthority() async throws {
        let root = try stateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let loop = try await autopilotTestLoop(enabled: true, activeControl: false)
        await loop.setDaemonStateFileForTesting(root.appendingPathComponent("daemon.json"))
        await loop.handleAutopilotControl(control(observeOnly: true))
        #expect(await loop.idleMonitorTask != nil)
        await loop.handleAutopilotControl(control(observeOnly: false))
        #expect(await loop.modelAutopilotEnabled)
        #expect(await loop.autopilotPhase == "active")
        #expect(await loop.state.modelAutopilot?.observeOnly == false)
        #expect(await loop.idleMonitorTask == nil)
        await loop.handleAutopilotControl(control(observeOnly: true))
        #expect(await loop.modelAutopilotEnabled == false)
        #expect(await loop.autopilotPhase == "shadow")
        #expect(await loop.state.modelAutopilot?.observeOnly == true)
        #expect(await loop.idleMonitorTask != nil)
        await loop.idleMonitorTask?.cancel()
    }

    @Test func explicitPauseRetainsExistingResidencyAndPinOwnershipInShadow() async throws {
        let root = try stateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let loop = try await autopilotTestLoop(enabled: true, activeControl: false)
        await loop.setDaemonStateFileForTesting(root.appendingPathComponent("daemon.json"))
        await loop.handleAutopilotControl(control(observeOnly: true))
        await loop.pauseShadowControlForTesting()
        await loop.clearAutopilotControl()
        #expect(await loop.autopilotPhase == "paused")
        #expect(await loop.modelAutopilotEnabled == false)
        #expect(await loop.autopilotManagesResidency)
        #expect(await loop.autopilotProtectsPins)
        #expect(await loop.idleMonitorTask == nil)
    }
}

private extension ProviderLoop {
    func expireShadowControlForTesting() { autopilotControl?.expiresAtMs = 1 }
    func pauseShadowControlForTesting() {
        var settings = autopilotSettings
        settings.paused = true
        autopilotSettingsOverride = settings
    }
}
