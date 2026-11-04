import Foundation
import Testing
@testable import ProviderCore

/// How a consented provider whose ordinary selection is Super and Gemma ends
/// up serving GLM while Super cannot load, through each path that can put GLM
/// there: an admin Autopilot operation (adoption and a placement hold), or an
/// ordinary selection that still contains GLM from the daemon's start.
@Suite("Load memory a resident model keeps", .serialized)
struct UnreclaimableLoadMemoryTests {
    private typealias Fixture = UnreclaimableLoadMemoryFixture

    // MARK: - An admin operation

    /// Runs the admin operation through the real command path under a live
    /// lease, then ends the lease as the coordinator does. GLM was resident
    /// from an earlier lease, so the operation's load step returns at once;
    /// the cold load itself runs in the tiny-model suite.
    private func adoptAndHoldGLM(_ fixture: Fixture, holdSeconds: Int) async throws {
        let loop = fixture.loop
        #expect(await loop.autopilotServesModel(Fixture.glmID) == false, "inventory alone serves nothing")
        await loop.activateAutopilotForTesting()
        let status = try #require(await fixture.withModelCache {
            await loop.runAutopilotCommandForTesting(Fixture.adminOperation(holdSeconds: holdSeconds))
        })
        #expect(status.status == .succeeded, "\(status.error ?? "")")
        await loop.clearAutopilotControl()
        await loop.markInferenceForTesting(Fixture.glmID)
    }

    @Test(.timeLimit(.minutes(1)))
    func anAdminOperationLeavesGLMAdoptedAndHeldAndSuperRefused() async throws {
        let fixture = try await Fixture.make(glm: .autopilotInventory)
        defer { Task { await fixture.remove() } }
        let loop = fixture.loop
        try await adoptAndHoldGLM(fixture, holdSeconds: 3_600)

        // The reported state: waiting, GLM warm and most recently used
        // outside the selection, Super advertised but cold.
        #expect(await loop.autopilotPhase == "waiting")
        #expect(await loop.ordinarySelectionContainsForTesting(Fixture.glmID) == false)
        #expect(await loop.autopilotServesModel(Fixture.glmID))
        let snapshot = try #require(await loop.state.modelAutopilot)
        #expect(snapshot.adoptedModels == [Fixture.glmID])
        #expect(snapshot.heldModels?.map(\.modelId) == [Fixture.glmID])
        #expect(snapshot.lastCommandStatus == .succeeded)
        let state = await loop.currentDaemonState()
        #expect(state.warmModels == [Fixture.gemmaID, Fixture.glmID])
        #expect(state.currentModel == Fixture.glmID)
        #expect(state.advertisedModels == [Fixture.gemmaID, Fixture.glmID, Fixture.superID])
        #expect(state.autopilotPhase == "waiting")
        #expect(state.modelSwitch == ProviderModelSwitchStatus())
        #expect(state.autopilotOperation?.target == Fixture.glmID)
        #expect(state.autopilotOperation?.reason == "coordinator placement")

        // The hold alone keeps GLM out of Super's eviction candidates.
        #expect(await loop.nemotronSuperClaimRoomBytes() == Fixture.idleSuperRoomBytes)
        #expect(await loop.evictableModelSlots().keys.sorted() == [Fixture.gemmaID])
        // Pre-accept refuses a routed Super request without a load attempt,
        // so only a coordinator preload (or a local request) records it.
        #expect(await loop.fastAdmissionReject(modelId: Fixture.superID))
        let idleError = try await coordinatorPreloadError(fixture)
        #expect(idleError.hasPrefix(Fixture.superRefusal(room: "36.8")), "\(idleError)")
        // With a GLM request decoding, the reported line, verbatim.
        await fixture.beginGLMRequest()
        let busyError = try await coordinatorPreloadError(fixture)
        #expect(busyError.hasPrefix(Fixture.reportedSuperRefusal), "\(busyError)")
        #expect(fixture.shutdownCalls(Fixture.gemmaID) == 0 && fixture.shutdownCalls(Fixture.glmID) == 0)
    }

    /// After the hold expires GLM is evictable whenever it has no request in
    /// flight. A Super load that coincides with GLM traffic is still refused,
    /// with the same message; one in an idle gap evicts Gemma and then GLM,
    /// which ends the adoption: GLM stops serving until another operation.
    @Test(.timeLimit(.minutes(1)))
    func afterTheHoldOnlyGLMTrafficKeepsSuperOut() async throws {
        let fixture = try await Fixture.make(glm: .autopilotInventory)
        defer { Task { await fixture.remove() } }
        let loop = fixture.loop
        try await adoptAndHoldGLM(fixture, holdSeconds: 600)
        await loop.setAutopilotHoldForTesting(Fixture.glmID, until: .now.advanced(by: .seconds(-1)))
        #expect(await loop.autopilotHoldsModel(Fixture.glmID) == false)

        await fixture.beginGLMRequest()
        #expect(await loop.fastAdmissionReject(modelId: Fixture.superID))
        let busyError = try await coordinatorPreloadError(fixture)
        #expect(busyError.hasPrefix(Fixture.reportedSuperRefusal), "\(busyError)")

        await fixture.endGLMRequest()
        #expect(await loop.fastAdmissionReject(modelId: Fixture.superID) == false)
        try await loop.evictUntilNemotronSuperFits(Fixture.model(Fixture.superID), allowEviction: true)
        #expect(fixture.shutdownCalls(Fixture.gemmaID) == 1)
        #expect(fixture.shutdownCalls(Fixture.glmID) == 1)
        #expect(await loop.autopilotServesModel(Fixture.glmID) == false)
        #expect(await loop.isModelAdvertised(Fixture.glmID) == false)
        await #expect(throws: InferenceError.self) { try await loop.ensureModelLoaded(modelId: Fixture.glmID) }
        // Nothing retries the startup preload: Super loads only on a request.
        #expect(await loop.startupPreloadTaskRunningForTesting() == false)
        #expect(await loop.modelLoadingInFlightIDs().isEmpty)
    }

    /// `darkbloom status` labels an advertised cold model "Preload skipped (no
    /// eviction)" only when the published eviction-aware figure
    /// (`free_for_load_gb`) covers it, otherwise "Cold load blocked (memory)".
    /// A held model gives no reclaim credit there, so while GLM is held Super's
    /// line reads "Cold load blocked"; it reads "Preload skipped" only once
    /// GLM is unheld and idle. The idle figures are the reported ones.
    @Test(.timeLimit(.minutes(1)))
    func statusSaysSuperMayLoadAfterEvictionOnlyWhenGLMIsUnheld() async throws {
        let fixture = try await Fixture.make(glm: .autopilotInventory)
        defer { Task { await fixture.remove() } }
        let loop = fixture.loop
        try await adoptAndHoldGLM(fixture, holdSeconds: 3_600)
        let superGb = Fixture.model(Fixture.superID).estimatedMemoryGb

        await loop.updateAggregateCapacity()
        let held = try #require(await loop.currentDaemonState().capacity)
        #expect(String(format: "%.1f", try #require(held.loadUsableGb)) == "42.3")
        #expect(String(format: "%.1f", try #require(held.loadHeadroomGb)) == "6.5")
        #expect(try #require(held.freeForLoadGb) < superGb)
        await loop.setAutopilotHoldForTesting(Fixture.glmID, until: .now.advanced(by: .seconds(-1)))
        await loop.updateAggregateCapacity()
        let unheld = try #require(await loop.currentDaemonState().capacity)
        #expect(try #require(unheld.freeForLoadGb) >= superGb)
        // A request in flight withdraws every reclaim credit.
        await fixture.beginGLMRequest()
        await loop.updateAggregateCapacity()
        let busy = try #require(await loop.currentDaemonState().capacity)
        #expect(try #require(busy.freeForLoadGb) < superGb)
    }

    // MARK: - A stale ordinary selection

    /// GLM is in the ordinary selection the daemon started with; the config's
    /// `enabled_models` was edited to Super and Gemma afterwards. The running
    /// daemon reads only Autopilot policy from the config, so GLM keeps
    /// serving with no Autopilot operation, adoption or hold. A Super load
    /// while a GLM request decodes is refused with the reported line.
    @Test(.timeLimit(.minutes(1)))
    func aStaleOrdinarySelectionServesGLMWithoutAutopilot() async throws {
        let fixture = try await Fixture.make(glm: .ordinary)
        defer { Task { await fixture.remove() } }
        let loop = fixture.loop
        var config = try ConfigManager.load(from: fixture.configPath)
        config.backend.enabledModels = [Fixture.superID, Fixture.gemmaID]
        try ConfigManager.save(config, to: fixture.configPath)
        await loop.refreshAutopilotSettings()
        await loop.markInferenceForTesting(Fixture.glmID)

        #expect(await loop.autopilotPhase == "waiting")
        #expect(await loop.ordinarySelectionContainsForTesting(Fixture.glmID))
        #expect(await loop.autopilotServesModel(Fixture.glmID))
        await loop.publishModelAutopilotSnapshot()
        let snapshot = try #require(await loop.state.modelAutopilot)
        #expect(snapshot.adoptedModels == nil)
        #expect(snapshot.heldModels == nil)
        #expect(snapshot.lastCommandId == nil)
        let state = await loop.currentDaemonState()
        #expect(state.warmModels == [Fixture.gemmaID, Fixture.glmID])
        #expect(state.currentModel == Fixture.glmID)
        #expect(state.advertisedModels == [Fixture.gemmaID, Fixture.glmID, Fixture.superID])
        #expect(state.autopilotOperation == nil)

        await fixture.beginGLMRequest()
        #expect(await loop.evictableModelSlots().keys.sorted() == [Fixture.gemmaID])
        let busyError = try await coordinatorPreloadError(fixture)
        #expect(busyError.hasPrefix(Fixture.reportedSuperRefusal), "\(busyError)")

        // Idle, GLM is evicted for Super and stays selected: its next request
        // loads it again.
        await fixture.endGLMRequest()
        try await loop.evictUntilNemotronSuperFits(Fixture.model(Fixture.superID), allowEviction: true)
        #expect(fixture.shutdownCalls(Fixture.glmID) == 1)
        #expect(await loop.autopilotServesModel(Fixture.glmID))
        #expect(await loop.isModelAdvertised(Fixture.glmID))
    }

    /// The daemon started with GLM selected and GLM in the persisted loaded
    /// set: the startup preload loads it first (biggest first), skips Super
    /// for memory and fills the last slot with Gemma.
    @Test(.timeLimit(.minutes(1)))
    func startingWithGLMSelectedPreloadsItFirstAndSkipsSuper() async throws {
        let fixture = try await Fixture.make(glm: .ordinary, resident: [],
            persistedLoadedModels: [Fixture.gemmaID, Fixture.glmID])
        defer { Task { await fixture.remove() } }
        let loop = fixture.loop
        #expect(await loop.startupPreloadPlanForTesting().map(\.modelId)
            == [Fixture.glmID, Fixture.gemmaID, Fixture.superID])
        await loop.setStartupPreloadLoadOverrideForTesting { id in await fixture.install(id) }
        _ = await loop.runStartupPreloadGateForTesting()
        #expect(await modelLoadingWaitUntil { await loop.startupPreloadTaskRunningForTesting() == false })
        #expect(await loop.modelLoadingResidentIDs() == [Fixture.gemmaID, Fixture.glmID])
    }

    /// With consent and the current filter at start, the persisted GLM is
    /// filtered out of the preload: only an operation could load it.
    @Test(.timeLimit(.minutes(1)))
    func aConsentedStartWithTheCurrentFilterNeverPreloadsGLM() async throws {
        let fixture = try await Fixture.make(glm: .autopilotInventory, resident: [],
            persistedLoadedModels: [Fixture.gemmaID, Fixture.glmID, Fixture.superID])
        defer { Task { await fixture.remove() } }
        #expect(await fixture.loop.startupPreloadPlanForTesting().map(\.modelId)
            == [Fixture.superID, Fixture.gemmaID])
    }

    /// A coordinator `load_model` for Super, a path that records the refusal:
    /// the recorded `Last model-load error` message.
    private func coordinatorPreloadError(_ fixture: Fixture) async throws -> String {
        let replies = AutopilotRecorder()
        await fixture.withModelCache {
            await fixture.loop.handleLoadModelRequest(modelId: Fixture.superID, send: SendHandle(replies.append))
            #expect(await modelLoadingWaitUntil { replies.legacyStatuses.count == 2 })
        }
        #expect(replies.legacyStatuses == [.started, .failed])
        let recorded = try #require(await fixture.loop.modelLoadingLastLoadError())
        #expect(recorded.model == Fixture.superID)
        return recorded.message
    }
}
