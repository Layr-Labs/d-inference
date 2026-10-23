import Foundation
import Testing
@testable import ProviderCore

@Suite("Autopilot busy reasons", .serialized)
struct AutopilotBusyReasonTests {
    private typealias Fixture = AutopilotPlacementFixture

    /// Native retention needs a retained MiMo fault, which only the native
    /// lane can produce; the exhaustive switch still maps it.
    static let settableReasons = ModelAutopilotBusyReason.allCases.filter {
        $0 != .autopilotOperation && $0 != .nativeMemoryRetained
    }

    @Test func wireVocabulariesAreStable() {
        #expect(ModelAutopilotBusyReason.allCases.map(\.rawValue) == [
            "autopilot_operation", "shutting_down", "draining", "reconnect_after_retirement",
            "model_switch", "revision_activation", "revision_update", "startup_preload", "preload",
            "engine_recovery", "mtp_upgrade", "mtp_staging", "model_advertisement",
            "pending_advertisement", "load_gate", "model_loading", "reslice", "model_unloading",
            "model_retiring", "native_memory_retained", "inflight_work",
        ])
        #expect(ModelAutopilotTransition.allCases.map(\.rawValue) == [
            "autopilot_operation", "startup_preload", "preload", "model_loading", "model_advertisement",
            "model_switch", "reslice", "reconnect_after_retirement",
        ])
        #expect(ModelAutopilotCapability.allCases.map(\.rawValue)
            == ["inventory_adoption", "placement_holds", "busy_reasons"])
    }

    @Test(arguments: settableReasons)
    func everyBusyFlagMapsToItsReason(reason: ModelAutopilotBusyReason) async throws {
        let fixture = try await Fixture.make(resident: [])
        defer { Task { await fixture.remove() } }
        let loop = fixture.loop
        #expect(await loop.autopilotBusyReasons().isEmpty)
        await loop.raiseBusyFlagForTesting(reason)
        #expect(await loop.autopilotBusyReasons() == [reason])
        await loop.lowerBusyFlagForTesting(reason)
        #expect(await loop.autopilotBusyReasons().isEmpty)
    }

    @Test func theOutermostOwnerIsReportedFirst() async throws {
        let fixture = try await Fixture.make(resident: [])
        defer { Task { await fixture.remove() } }
        let loop = fixture.loop
        for reason in [ModelAutopilotBusyReason.inflightWork, .modelLoading, .loadGate, .preload, .startupPreload] {
            await loop.raiseBusyFlagForTesting(reason)
        }
        #expect(await loop.autopilotBusyReasons() == [.startupPreload, .preload, .loadGate, .modelLoading, .inflightWork])
        await loop.installAutopilotCommandForBusyTesting()
        // The operation policy never treats its own command as busy.
        #expect(await loop.autopilotBusyReasons().first == .startupPreload)
        #expect(await loop.reportedAutopilotBusyReasons().first == .autopilotOperation)
        await loop.publishModelAutopilotSnapshot()
        #expect(await loop.state.modelAutopilot?.busyReason == "autopilot_operation")
        for reason in ModelAutopilotBusyReason.allCases { await loop.lowerBusyFlagForTesting(reason) }
    }

    @Test func providerBusyFailureNamesItsFirstReason() async throws {
        let fixture = try await Fixture.make()
        defer { Task { await fixture.remove() } }
        let loop = fixture.loop
        await loop.activateAutopilotForTesting()
        await loop.raiseBusyFlagForTesting(.loadGate)
        await loop.raiseBusyFlagForTesting(.startupPreload)
        let command = Fixture.command("busy", unload: [Fixture.spare])
        let failure = try #require(await loop.runAutopilotCommandForTesting(command))
        #expect(failure.status == .failed)
        #expect(failure.error == "provider_busy")
        #expect(failure.detail == "startup_preload")
        #expect(failure.modelAutopilot.busyReason == "startup_preload")
        #expect(failure.modelAutopilot.busyReasons == ["startup_preload", "load_gate"])
        // A replayed command returns its recorded outcome, detail included.
        #expect(await loop.runAutopilotCommandForTesting(command)?.detail == "startup_preload")
        #expect(fixture.engines.values.allSatisfy { $0.shutdownCalls == 0 })
        // Other refusals carry no detail.
        await loop.lowerBusyFlagForTesting(.loadGate)
        await loop.lowerBusyFlagForTesting(.startupPreload)
        var stale = command
        stale.commandId = "stale"
        stale.expectedResidentModels = [Fixture.ordinary]
        let staleFailure = await loop.runAutopilotCommandForTesting(stale)
        #expect(staleFailure?.error == "residency_changed")
        #expect(staleFailure?.detail == nil)
    }

    @Test func aConcurrentCommandIsBusyWithTheAcceptedOperation() async throws {
        let fixture = try await Fixture.make()
        defer { Task { await fixture.remove() } }
        let loop = fixture.loop
        await loop.activateAutopilotForTesting()
        await loop.installAutopilotCommandForBusyTesting()
        let busy = await loop.runAutopilotCommandForTesting(Fixture.command("second", unload: [Fixture.spare]))
        #expect(busy?.error == "provider_busy")
        #expect(busy?.detail == "autopilot_operation")
        // The accepted operation outlives revoked consent; the refusal then
        // answers exactly as a provider without consented detail would.
        await loop.updateAutopilotSettingsForTesting { $0.consentRecorded = false }
        let revoked = await loop.runAutopilotCommandForTesting(Fixture.command("third", unload: [Fixture.spare]))
        #expect(revoked?.error == "provider_busy")
        #expect(revoked?.detail == nil)
        await loop.lowerBusyFlagForTesting(.autopilotOperation)
    }

    @Test func busySinceIsTheFirstContinuousObservationOfTheReportedReason() async throws {
        let fixture = try await Fixture.make(resident: [])
        defer { Task { await fixture.remove() } }
        let loop = fixture.loop
        await loop.publishModelAutopilotSnapshot()
        var snapshot = try #require(await loop.state.modelAutopilot)
        #expect(snapshot.busyReason == nil && snapshot.busyReasons == nil && snapshot.busySinceMs == nil)

        await loop.raiseBusyFlagForTesting(.preload)
        await loop.publishModelAutopilotSnapshot()
        snapshot = try #require(await loop.state.modelAutopilot)
        let preloadSince = try #require(snapshot.busySinceMs)
        #expect(snapshot.busyReason == "preload")
        try await Task.sleep(for: .milliseconds(20))
        await loop.raiseBusyFlagForTesting(.loadGate)
        await loop.publishModelAutopilotSnapshot()
        snapshot = try #require(await loop.state.modelAutopilot)
        #expect(snapshot.busyReasons == ["preload", "load_gate"])
        #expect(snapshot.busySinceMs == preloadSince)

        await loop.lowerBusyFlagForTesting(.preload)
        await loop.publishModelAutopilotSnapshot()
        snapshot = try #require(await loop.state.modelAutopilot)
        #expect(snapshot.busyReason == "load_gate")
        #expect(try #require(snapshot.busySinceMs) > preloadSince)

        await loop.lowerBusyFlagForTesting(.loadGate)
        await loop.publishModelAutopilotSnapshot()
        snapshot = try #require(await loop.state.modelAutopilot)
        #expect(snapshot.busyReason == nil && snapshot.busySinceMs == nil)
    }

    // MARK: - Failure paths release every busy flag

    @Test func failedStartupPreloadLoadReleasesItsFlags() async throws {
        let fixture = try await Fixture.make(resident: []) {
            $0.preloadModels = [Fixture.ordinary]
            $0.startupSelftest = false
        }
        defer { Task { await fixture.remove() } }
        let loop = fixture.loop
        await loop.setStartupPreloadFreeMemoryOverrideForTesting { 1_000 }
        await loop.setStartupPreloadLoadOverrideForTesting { _ in
            throw InferenceError.modelLoadFailed("injected load failure")
        }
        #expect(await loop.runStartupPreloadGateForTesting() == .warm)
        #expect(await modelLoadingWaitUntil { await !loop.startupPreloadTaskRunningForTesting() })
        #expect(await loop.autopilotBusyReasons().isEmpty)
    }

    @Test func failClosedSelfTestRetirementReleasesItsFlags() async throws {
        let fixture = try await Fixture.make(resident: []) {
            $0.preloadModels = [Fixture.ordinary]
            $0.startupSelftestFailClosed = true
        }
        defer { Task { await fixture.remove() } }
        let loop = fixture.loop
        await loop.setStartupPreloadFreeMemoryOverrideForTesting { 1_000 }
        await loop.setStartupPreloadLoadOverrideForTesting { _ in }
        await loop.setStartupSelfTestOverrideForTesting { _ in
            throw InferenceError.generationFailed("injected self-test failure")
        }
        #expect(await loop.runStartupPreloadGateForTesting() == .warm)
        #expect(await modelLoadingWaitUntil { await !loop.startupPreloadTaskRunningForTesting() })
        #expect(await loop.isModelAdvertised(Fixture.ordinary) == false)
        #expect(await loop.autopilotBusyReasons().isEmpty)
    }

    @Test func failedCoordinatorPreloadReleasesItsFlags() async throws {
        let fixture = try await Fixture.make(resident: [])
        defer { Task { await fixture.remove() } }
        let loop = fixture.loop
        let recorder = AutopilotRecorder()
        // No snapshot of the ordinary model exists in the model cache.
        await loop.handleLoadModelRequest(modelId: Fixture.ordinary, send: SendHandle(recorder.append))
        #expect(await modelLoadingWaitUntil { await loop.autopilotBusyReasons().isEmpty })
        #expect(recorder.legacyStatuses == [.started, .failed])
    }

    @Test(arguments: ["insufficient_memory", "unreadable_weights"])
    func failedLoadReleasesItsFlags(failure: String) async throws {
        let fixture = try await Fixture.make(resident: [])
        defer { Task { await fixture.remove() } }
        let loop = fixture.loop
        let sandbox = try ModelLoadingSandbox()
        defer { sandbox.remove() }
        await ModelLoadingFixtures.setAvailableMemory(loop, gb: failure == "insufficient_memory" ? 0 : 1_000)
        do {
            try await loop.ensureModelLoaded(modelId: Fixture.ordinary,
                revisionDirectory: try sandbox.makeSnapshot(Fixture.ordinary))
            Issue.record("the injected \(failure) load succeeded")
        } catch {}
        #expect(await loop.autopilotBusyReasons().isEmpty)
        #expect(await loop.modelLoadingResidentIDs().isEmpty)
        #expect(await loop.outstandingKVReservationBytesForTesting() == 0)
    }

    @Test func failedAdvertisementReleasesItsFlags() async throws {
        let fixture = try await Fixture.make(resident: [])
        defer { Task { await fixture.remove() } }
        let loop = fixture.loop
        // The verified build cannot be scanned from the model cache.
        #expect(await loop.publishVerifiedPrefetch(modelId: Fixture.ordinary) == false)
        #expect(await loop.autopilotBusyReasons().isEmpty)
    }
}

extension ProviderLoop {
    func raiseBusyFlagForTesting(_ reason: ModelAutopilotBusyReason) {
        switch reason {
        case .autopilotOperation: installAutopilotCommandForBusyTesting()
        case .shuttingDown: isShuttingDown = true
        case .draining: servingDrain.begin(.update)
        case .reconnectAfterRetirement: isReconnectingAfterRetirement = true
        case .modelSwitch: modelSwitchTask = Task { ProviderModelSwitchStatus() }
        case .revisionActivation: modelRevisionActivationID = "busy-model"
        case .revisionUpdate: revisionUpdatesInProgress.insert("busy-model")
        case .startupPreload: startupPreloadTask = Task {}
        case .preload: preloadTasks["busy-model"] = Task {}
        case .engineRecovery: engineV2RecoveryInProgress.insert("busy-model")
        case .mtpUpgrade: mtpUpgradeTransitions.insert("busy-model")
        case .mtpStaging: _ = mtpStagingReservations.retainPreparingTarget(ObjectIdentifier(self), bytes: 0)
        case .modelAdvertisement: modelAdvertisementsInFlight += 1
        case .pendingAdvertisement: pendingAdvertise.insert("busy-model")
        case .loadGate: isLoadingAny = true
        case .modelLoading: modelsLoading.insert("busy-model")
        case .reslice: isReslicing = true
        case .modelUnloading: modelsUnloading.insert("busy-model")
        case .modelRetiring: retiringModels.insert("busy-model")
        case .nativeMemoryRetained: break
        case .inflightWork: requestToModel["busy-request"] = "busy-model"
        }
    }

    func lowerBusyFlagForTesting(_ reason: ModelAutopilotBusyReason) {
        switch reason {
        case .autopilotOperation: autopilotCommand = nil
        case .shuttingDown: isShuttingDown = false
        case .draining: servingDrain.resumeUpdate()
        case .reconnectAfterRetirement: isReconnectingAfterRetirement = false
        case .modelSwitch: modelSwitchTask = nil
        case .revisionActivation: modelRevisionActivationID = nil
        case .revisionUpdate: revisionUpdatesInProgress.remove("busy-model")
        case .startupPreload: startupPreloadTask = nil
        case .preload: preloadTasks.removeValue(forKey: "busy-model")
        case .engineRecovery: engineV2RecoveryInProgress.remove("busy-model")
        case .mtpUpgrade: mtpUpgradeTransitions.remove("busy-model")
        case .mtpStaging: mtpStagingReservations = MTPStagingReservations()
        case .modelAdvertisement: modelAdvertisementsInFlight = 0
        case .pendingAdvertisement: pendingAdvertise.remove("busy-model")
        case .loadGate: isLoadingAny = false
        case .modelLoading: modelsLoading.remove("busy-model")
        case .reslice: isReslicing = false
        case .modelUnloading: modelsUnloading.remove("busy-model")
        case .modelRetiring: retiringModels.remove("busy-model")
        case .nativeMemoryRetained: break
        case .inflightWork: requestToModel.removeValue(forKey: "busy-request")
        }
    }

    func installAutopilotCommandForBusyTesting() {
        autopilotCommand = AutopilotPlacementFixture.command("accepted", unload: [AutopilotPlacementFixture.spare])
    }
}
