import Foundation
import Testing
@testable import ProviderCore

@Suite("ModelAutopilot")
struct ModelAutopilotTests {
    private let now: Int64 = 1_000_000
    private func snapshot() -> ModelAutopilotSnapshot {
        var state = ModelAutopilotSnapshot(enabled: true, minDwellSeconds: 1_800, maxModelSlots: 2,
              residentModels: [
                .init(modelId: "donor", residentSeconds: 3_600, idleSeconds: 2_000, weightsGb: 12, residentGb: 10),
                .init(modelId: "keep", residentSeconds: 3_600, idleSeconds: 2_000, weightsGb: 10)])
        state.active = true; state.sessionId = "session"; state.revision = "test"
        state.selectedModels = ["donor", "keep", "new"]; state.minIdleSeconds = 60
        return state
    }
    private func command() -> ModelAutopilotCommand {
        .init(commandId: "one", loadModelId: "new", unloadModelIds: ["donor"],
              expectedResidentModels: ["keep", "donor"], expiresAtMs: now + 60_000, sessionId:"session", revision:"test")
    }
    private func reject(_ command: ModelAutopilotCommand, _ snapshot: ModelAutopilotSnapshot,
                        busy: Bool = false) -> String? {
        ModelAutopilotPolicy.rejection(command: command, snapshot: snapshot, busy: busy, nowMs: now)
    }

    @Test func defaultOffAndPartialConfigRemainDefaultOff() throws {
        #expect(BackendSettings().modelAutopilot.enabled == false)
        let settings = try JSONDecoder().decode(ModelAutopilotSettings.self, from: Data("{}".utf8))
        #expect(settings == ModelAutopilotSettings())
        let legacy = try JSONDecoder().decode(ModelAutopilotSettings.self, from: Data("{\"enabled\":true}".utf8))
        #expect(!legacy.enabled)
        #expect(!legacy.hasConsent)
        let backend = try JSONDecoder().decode(BackendSettings.self, from: Data("{}".utf8))
        #expect(backend.modelAutopilot == settings)
        #expect(ModelAutopilotSettings(minDwellSeconds: .max).effectiveMinDwellSeconds == 86_400)
    }

    @Test func consentBusyExpiryAndSnapshotAreMandatory() {
        let c = command()
        let s = snapshot()
        #expect(reject(c, s) == nil)
        var oversized = c; oversized.commandId = String(repeating: "x", count: 65)
        #expect(reject(oversized, s) == "invalid_command")
        var disabled = s; disabled.enabled = false
        #expect(reject(c, disabled) == "not_opted_in")
        #expect(reject(c, s, busy: true) == "provider_busy")
        var stale = c; stale.expiresAtMs = now
        #expect(reject(stale, s) == "expired_command")
        stale.expiresAtMs = now + 300_001
        #expect(reject(stale, s) == "expired_command")
        stale = c; stale.expectedResidentModels = ["donor"]
        #expect(reject(stale, s) == "residency_changed")
    }

    @Test func allVictimsMustBeIdleOldAndUnpinnedAndFitSlots() {
        let c = command()
        var s = snapshot(); s.pinnedModels = ["donor"]
        #expect(reject(c, s) == "pinned_model")
        s = snapshot(); s.residentModels[0].idleSeconds = 59
        #expect(reject(c, s) == "minimum_dwell")
        s = snapshot(); s.residentModels[0].residentSeconds = 1_799
        #expect(reject(c, s) == "minimum_dwell")
        var noVictim = c; noVictim.unloadModelIds = []
        #expect(reject(noVictim, snapshot()) == "slot_capacity")
        var duplicate = c; duplicate.unloadModelIds = ["donor", "donor"]
        #expect(reject(duplicate, snapshot()) == "invalid_command")
        var twoVictims = c; twoVictims.unloadModelIds = ["donor", "keep"]
        s = snapshot(); s.residentModels[1].idleSeconds = 0
        #expect(reject(twoVictims, s) == "minimum_dwell")
    }

    @Test func unloadAndLeaseRenewalAreExplicit() {
        var c = command(); c.loadModelId = nil
        #expect(reject(c, snapshot()) == nil)
        c.unloadModelIds = []
        #expect(reject(c, snapshot()) == "invalid_command")
        c.loadModelId = "keep"
        #expect(reject(c, snapshot()) == nil)
        c.unloadModelIds = ["keep"]
        #expect(reject(c, snapshot()) == "invalid_command")
    }

    @Test(arguments: [false, true], [false, true])
    func everyUnloadVictimRequiresSelectionConsent(loadTarget: Bool, mixedVictims: Bool) {
        var c = command()
        if !loadTarget { c.loadModelId = nil }
        if mixedVictims { c.unloadModelIds = ["keep", "donor"] }
        #expect(reject(c, snapshot()) == nil)
        var s = snapshot()
        s.selectedModels.removeAll { $0 == "donor" }
        #expect(reject(c, s) == "model_not_selected")

        // Reporting an unselected resident does not give permission to release
        // it; selected victims can still move while that resident is retained.
        c.unloadModelIds = ["keep"]
        #expect(reject(c, s) == nil)
    }

    @Test func commandAndStatusHaveSymmetricFlatWireFields() throws {
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        let commandMessage = CoordinatorMessage.modelAutopilot(command())
        let wire = try encoder.encode(commandMessage)
        let object = try #require(JSONSerialization.jsonObject(with: wire) as? [String: Any])
        #expect(object["type"] as? String == "model_autopilot")
        #expect(object["command_id"] as? String == "one")
        #expect(object["unload_model_ids"] as? [String] == ["donor"])
        #expect(try decoder.decode(CoordinatorMessage.self, from: wire) == commandMessage)
        let status = ModelAutopilotStatus(commandId: "one", status: .failed,
                                         error: "minimum_dwell", modelAutopilot: snapshot())
        let reply = ProviderMessage.modelAutopilotStatus(status)
        let replyData = try encoder.encode(reply)
        #expect(try decoder.decode(ProviderMessage.self, from: replyData) == reply)
        let encoded = try #require(JSONSerialization.jsonObject(with: replyData) as? [String: Any])
        let snapshotObject = try #require(encoded["model_autopilot"] as? [String: Any])
        #expect(snapshotObject["protocol"] as? Int == 3)
        #expect(snapshotObject["cached_only"] as? Bool == true)
        let residents = try #require(snapshotObject["resident_models"] as? [[String: Any]])
        #expect(residents.first?["weights_gb"] as? Double == 12)
        #expect(residents.first?["resident_gb"] as? Double == 10)
    }

    @Test func terminalHeartbeatCannotCombineWithEarlierCapacity() {
        let state = ProviderState()
        var running = snapshot(); running.activeCommandId = "one"
        state.modelAutopilot = running
        let old = BackendCapacity(slots: [], gpuMemoryActiveGb: 0, gpuMemoryPeakGb: 0, gpuMemoryCacheGb: 0, totalMemoryGb: 128)
        state.setModelAutopilotCapacity(old, snapshot: running)
        var terminal = snapshot(); terminal.lastCommandId = "one"; terminal.lastCommandStatus = .succeeded
        state.modelAutopilot = terminal
        let beforeRebuild = state.modelAutopilotHeartbeat()
        #expect(beforeRebuild.1?.activeCommandId == "one")
        #expect(beforeRebuild.1?.lastCommandId == nil)
        state.setModelAutopilotCapacity(BackendCapacity(slots: [], gpuMemoryActiveGb: 0, gpuMemoryPeakGb: 0, gpuMemoryCacheGb: 0, totalMemoryGb: 128), snapshot: terminal)
        let afterRebuild = state.modelAutopilotHeartbeat()
        #expect(afterRebuild.1?.activeCommandId == nil)
        #expect(afterRebuild.1?.lastCommandId == "one")
        #expect(afterRebuild.0?.capacitySeq == 2)
    }
}


@Suite("ModelAutopilot runtime")
struct ModelAutopilotRuntimeTests {
    @Test func unconsentedCommandsNeverStartAndDuplicateIsIdempotent() async throws {
        let loop = try await autopilotTestLoop(enabled: false), recorder = AutopilotRecorder()
        let command = ModelAutopilotCommand(commandId: "denied", loadModelId: "uncached",
            expiresAtMs: Int64(Date().timeIntervalSince1970 * 1_000) + 60_000, sessionId:"session", revision:"test")
        await loop.handleModelAutopilot(command, send: SendHandle(recorder.append))
        await loop.handleModelAutopilot(command, send: SendHandle(recorder.append))
        #expect(recorder.statuses.count == 2)
        #expect(recorder.statuses.allSatisfy { $0.status == .failed && $0.error == "not_opted_in" })
        #expect(await loop.autopilotCommand == nil)
        #expect(await loop.autopilotHistory.count == 1)
    }

    @Test func enrolledProviderHasOneIdleResidencyAuthority() async throws {
        let managed = try await autopilotTestLoop(enabled: true)
        await managed.startIdleMonitor()
        #expect(await managed.idleMonitorTask == nil)
        let legacy = try await autopilotTestLoop(enabled: false)
        await legacy.startIdleMonitor()
        let timer = await legacy.idleMonitorTask
        #expect(timer != nil)
        timer?.cancel()
    }

    @Test func managedProviderRefusesLegacyLoadsAndUncachedCommands() async throws {
        let loop = try await autopilotTestLoop(enabled: true), recorder = AutopilotRecorder()
        let send = SendHandle(recorder.append)
        await loop.handleLoadModelRequest(modelId: "uncached", send: send)
        #expect(recorder.legacyFailures == 1)
        let command = ModelAutopilotCommand(commandId: "cold", loadModelId: "uncached",
            expiresAtMs: Int64(Date().timeIntervalSince1970 * 1_000) + 60_000, sessionId:"session", revision:"test")
        await loop.handleModelAutopilot(command, send: send)
        #expect(recorder.statuses.last?.error == "model_not_cached")
        #expect(await loop.autopilotTask == nil)
        #expect(await loop.preloadTasks.isEmpty)
    }
}

private extension ProviderLoop {
    func startAutopilotMutationForTest() { autopilotMutationStarted = true }
    func installAutopilotTransitionForTest(_ command: ModelAutopilotCommand?) {
        autopilotCommand = command
        autopilotMutationStarted = false
        publishModelAutopilotSnapshot()
    }
}

extension ModelAutopilotRuntimeTests {
    @Test func acceptanceExpiryDoesNotAbandonStartedMutation() async throws {
        let loop = try await autopilotTestLoop(enabled: true)
        let expired = ModelAutopilotCommand(commandId: "in-progress", loadModelId: "target", expiresAtMs: 1)
        await loop.installAutopilotTransitionForTest(expired)
        do {
            try await loop.checkAutopilotLoadOwnership(expired.commandId)
            Issue.record("expired command entered first mutation")
        } catch let InferenceError.modelLoadFailed(message) { #expect(message == "expired_command") }
        await loop.startAutopilotMutationForTest()
        try await loop.checkAutopilotLoadOwnership(expired.commandId)
        await loop.installAutopilotTransitionForTest(nil)
    }

    @Test func transitionExcludesLocalAndCompetingLoadsAndParticipatesInDrain() async throws {
        let loop = try await autopilotTestLoop(enabled: true)
        let command = ModelAutopilotCommand(commandId: "owned", loadModelId: "target",
            expiresAtMs: Int64(Date().timeIntervalSince1970 * 1_000) + 60_000, sessionId:"session", revision:"test")
        await loop.installAutopilotTransitionForTest(command)
        do {
            try await loop.throwIfRefusingNewLocalWork()
            Issue.record("local reservation entered an active residency transition")
        } catch {
            #expect(error.localizedDescription.contains("placement in progress"))
        }
        do {
            try await loop.ensureModelLoaded(modelId: "other")
            Issue.record("competing load entered an active residency transition")
        } catch let InferenceError.modelLoadFailed(message) {
            #expect(message.contains("placement in progress"))
        } catch { Issue.record("Unexpected competing-load error: \(error)") }
        let drained = await loop.waitForInflightDrain(timeout: .milliseconds(1), reason: "test")
        #expect(!drained)
        let recorder = AutopilotRecorder()
        var competing = command; competing.commandId = "different"
        await loop.handleModelAutopilot(competing, send: SendHandle(recorder.append))
        #expect(recorder.statuses.last?.error == "provider_busy")
        #expect(await loop.autopilotCommand?.commandId == "owned")
        #expect(await loop.autopilotHistory.isEmpty)
        await loop.installAutopilotTransitionForTest(nil)
        #expect(await loop.waitForInflightDrain(timeout: .milliseconds(1)))
    }
}

extension ModelAutopilotTests {
    @Test func changedSelectionOrOldSessionCannotExecute() {
        let s = snapshot()
        var c = command(); c.revision = "old"
        #expect(reject(c,s) == "inactive_session")
        c = command(); c.sessionId = "old-connection"
        #expect(reject(c,s) == "inactive_session")
        c = command(); c.loadModelId = "not-selected"
        #expect(reject(c,s) == "model_not_selected")
        var waiting = s; waiting.active = false
        #expect(reject(command(),waiting) == "inactive_session")
        var shadow = s; shadow.observeOnly = true
        #expect(reject(command(),shadow) == "inactive_session")
    }
    @Test func localLoadHistorySurvivesRestartAndUnload() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:path) }
        var history = ModelAutopilotHistory()
        history.record(.init(modelId:"cached",loadMs:2400,measuredAtMs:1,weightHash:"verified"))
        try history.write(to:path)
        let recovered = ModelAutopilotHistory.read(from:path)
        #expect(recovered.loads.count == 1)
        #expect(recovered.loads[0].loadMs == 2400)
        #expect(recovered.loads[0].weightHash == "verified")
    }
}

private extension ProviderLoop {
    func seedOldAutopilotTimingForTesting() {
        autopilotLastElapsedMs = 9000; autopilotLastReleaseMs = 2000; autopilotLastLoadMs = 7000
    }
}
extension ModelAutopilotRuntimeTests {
    @Test func rejectedCommandDoesNotInheritPreviousOperationTimings() async throws {
        let loop = try await autopilotTestLoop(enabled:true), recorder = AutopilotRecorder()
        await loop.seedOldAutopilotTimingForTesting()
        await loop.handleModelAutopilot(.init(commandId:"expired-timing",loadModelId:"uncached",expiresAtMs:1,
            sessionId:"session",revision:"test"),send:SendHandle(recorder.append))
        #expect(recorder.statuses.last?.error == "expired_command")
        #expect(recorder.statuses.last?.modelAutopilot.lastElapsedMs == 0)
        #expect(recorder.statuses.last?.modelAutopilot.lastReleaseMs == 0)
        #expect(recorder.statuses.last?.modelAutopilot.lastLoadMs == 0)
    }
}

private extension ProviderLoop {
    func holdManualModelSwitchForAutopilotTesting() {
        modelSwitchTask = Task { ProviderModelSwitchStatus() }
    }
    func releaseManualModelSwitchForAutopilotTesting() { modelSwitchTask = nil }
}
extension ModelAutopilotRuntimeTests {
    @Test func manualSwitchValidationOwnsResidencyBeforeDrainStarts() async throws {
        let loop = try await autopilotTestLoop(enabled:true), recorder = AutopilotRecorder()
        await loop.holdManualModelSwitchForAutopilotTesting()
        await loop.handleModelAutopilot(.init(commandId:"switch-overlap",loadModelId:"uncached",
            expiresAtMs:Int64(Date().timeIntervalSince1970*1000)+60000,sessionId:"session",revision:"test"),
            send:SendHandle(recorder.append))
        #expect(recorder.statuses.last?.error == "provider_busy")
        #expect(await loop.autopilotCommand == nil)
        await loop.releaseManualModelSwitchForAutopilotTesting()
    }
}

private extension ProviderLoop {
    func expireAutopilotControlForTesting() { autopilotControl?.expiresAtMs = 1 }
    func pauseAutopilotForTesting() {
        var settings = autopilotSettings
        settings.paused = true
        autopilotSettingsOverride = settings
    }
}

extension ModelAutopilotRuntimeTests {
    @Test(arguments: [false, true])
    func lostControlRestoresIdleTimerWithoutAbandoningAcceptedCommand(expired: Bool) async throws {
        let loop = try await autopilotTestLoop(enabled: true)
        await loop.startIdleMonitor()
        #expect(await loop.idleMonitorTask == nil)
        let command = ModelAutopilotCommand(commandId: "accepted", loadModelId: "target", expiresAtMs: 1)
        await loop.installAutopilotTransitionForTest(command)
        if expired { await loop.expireAutopilotControlForTesting() }
        await loop.clearAutopilotControl()
        let timer = await loop.idleMonitorTask
        #expect(timer != nil)
        #expect(await loop.autopilotControl == nil)
        #expect(await loop.autopilotCommand?.commandId == "accepted")
        #expect(await loop.autopilotPhase == "recovering")
        timer?.cancel()
        await loop.installAutopilotTransitionForTest(nil)
    }

    @Test func disabledRenewalAfterExpiryRestoresIdleTimer() async throws {
        let loop = try await autopilotTestLoop(enabled: true)
        await loop.startIdleMonitor()
        await loop.expireAutopilotControlForTesting()
        await loop.handleAutopilotControl(.init(sessionId: "session", revision: "test", enabled: false, expiresAtMs: 1))
        let timer = await loop.idleMonitorTask
        #expect(timer != nil)
        #expect(await loop.autopilotPhase == "waiting")
        timer?.cancel()
    }

    @Test func lostControlPreservesExplicitPause() async throws {
        let loop = try await autopilotTestLoop(enabled: true)
        await loop.pauseAutopilotForTesting()
        await loop.clearAutopilotControl()
        #expect(await loop.idleMonitorTask == nil)
        #expect(await loop.autopilotPhase == "paused")
    }
}
