import Foundation
import Testing
@testable import ProviderCore

@Suite("Autopilot inventory adoption", .serialized)
struct AutopilotAdoptionTests {
    private typealias Fixture = AutopilotPlacementFixture

    /// A live lease publishes inventory, an operation adopts its target, then
    /// the operation-scoped lease ends.
    private func adoptedAfterLease(holdSeconds: Int? = nil) async throws -> Fixture {
        let fixture = try await Fixture.make()
        let loop = fixture.loop
        await loop.activateAutopilotForTesting()
        await loop.restoreAutopilotResidentModels()
        #expect(await loop.advertisedIDsForTesting() == Fixture.all.sorted())
        await loop.settleAutopilotOperationForTesting(target: Fixture.inventory, holdSeconds: holdSeconds)
        await loop.clearAutopilotControl()
        return fixture
    }

    @Test func adoptedInventoryKeepsServingWithoutALease() async throws {
        let fixture = try await adoptedAfterLease()
        defer { Task { await fixture.remove() } }
        let loop = fixture.loop

        // The lease ended: unadopted inventory is withdrawn, adopted inventory
        // keeps serving, and selection permission itself is unchanged.
        #expect(await loop.modelAutopilotEnabled == false)
        #expect(await loop.advertisedIDsForTesting() == [Fixture.inventory, Fixture.ordinary].sorted())
        #expect(await loop.autopilotServesModel(Fixture.inventory))
        #expect(await loop.autopilotAllowsModel(Fixture.inventory) == false)
        #expect(await loop.autopilotServesModel(Fixture.spare) == false)
        #expect(await loop.autopilotServesModel(Fixture.ordinary))

        // Every serving entry point admits the adopted model.
        try await loop.throwIfRefusingNewLocalWork(modelId: Fixture.inventory)
        try await loop.ensureModelLoaded(modelId: Fixture.inventory)
        #expect(await loop.fastAdmissionReject(modelId: Fixture.inventory) == false)
        let replies = AutopilotRecorder()
        await loop.handleLoadModelRequest(modelId: Fixture.inventory, send: SendHandle(replies.append))
        #expect(replies.legacyStatuses == [.succeeded])
        do {
            try await loop.throwIfRefusingNewLocalWork(modelId: Fixture.spare)
            Issue.record("unadopted inventory served without a lease")
        } catch { #expect(error.localizedDescription.contains("model_not_selected")) }

        let snapshot = try #require(await loop.state.modelAutopilot)
        #expect(snapshot.adoptedModels == [Fixture.inventory])
        #expect(snapshot.capabilities == ["inventory_adoption", "placement_holds", "busy_reasons"])
        #expect(fixture.engines.values.allSatisfy { $0.shutdownCalls == 0 })
    }

    @Test func withdrawalSkipsOnlyValidAdoptions() async throws {
        let fixture = try await adoptedAfterLease()
        defer { Task { await fixture.remove() } }
        let loop = fixture.loop
        // Inventory published by a later lease and then left without one.
        await loop.activateAutopilotForTesting()
        await loop.restoreAutopilotResidentModels()
        await loop.clearAutopilotControlStateForTesting()
        #expect(await loop.isModelAdvertised(Fixture.spare))
        await loop.withdrawInactiveAutopilotModels()
        #expect(await loop.isModelAdvertised(Fixture.spare) == false)
        #expect(await loop.isModelAdvertised(Fixture.inventory))
        #expect(await loop.isModelAdvertised(Fixture.ordinary))
    }

    @Test func onlyAResidentInventoryTargetIsAdopted() async throws {
        let fixture = try await Fixture.make(resident: [Fixture.ordinary, Fixture.spare])
        defer { Task { await fixture.remove() } }
        let loop = fixture.loop
        await loop.activateAutopilotForTesting()
        // An ordinary target already serves without a lease; a target whose
        // load did not settle has no slot to adopt.
        await loop.settleAutopilotOperationForTesting(target: Fixture.ordinary)
        await loop.settleAutopilotOperationForTesting(target: Fixture.inventory)
        #expect(await loop.autopilotPlacementsForTesting.adopted.isEmpty)
        await loop.settleAutopilotOperationForTesting(target: Fixture.spare)
        #expect(await loop.autopilotPlacementsForTesting.adopted == [Fixture.spare])
    }

    @Test func rejectedAndUnloadOnlyCommandsAdoptNothing() async throws {
        let fixture = try await Fixture.make()
        defer { Task { await fixture.remove() } }
        let loop = fixture.loop
        await loop.activateAutopilotForTesting()
        // Rejected before any mutation: the inventory build is not on disk.
        let rejected = await loop.runAutopilotCommandForTesting(
            Fixture.command("rejected", load: Fixture.inventory, unload: [Fixture.spare], hold: 600))
        #expect(rejected?.error == "model_not_cached")
        // An unload-only operation succeeds without placing anything.
        let unloadOnly = await loop.runAutopilotCommandForTesting(
            Fixture.command("unload-only", unload: [Fixture.spare]))
        #expect(unloadOnly?.status == .succeeded)
        #expect(fixture.engines[Fixture.spare]?.shutdownCalls == 1)
        let placements = await loop.autopilotPlacementsForTesting
        #expect(placements.adopted.isEmpty)
        #expect(placements.held.isEmpty)
    }

    /// Each way a placement's basis can end.
    enum BasisEnd: CaseIterable, Sendable {
        case unload, consentRevoked, disabled, deselected, selfTestFailed, retiring, hashUnavailable, shutdown
    }

    @Test(arguments: BasisEnd.allCases)
    func everyEndOfThePlacementBasisUnadoptsAndWithdraws(end: BasisEnd) async throws {
        let fixture = try await adoptedAfterLease(holdSeconds: 600)
        defer { Task { await fixture.remove() } }
        let loop = fixture.loop
        #expect(await loop.autopilotPlacementsForTesting.adopted == [Fixture.inventory])
        #expect(await loop.autopilotPlacementsForTesting.held == [Fixture.inventory])

        switch end {
        case .unload: #expect(await loop.unloadModel(Fixture.inventory))
        case .consentRevoked: await loop.updateAutopilotSettingsForTesting { $0.consentRecorded = false }
        case .disabled: await loop.updateAutopilotSettingsForTesting { $0.enabled = false }
        case .deselected:
            await loop.updateAutopilotSettingsForTesting { $0.selectedModels.removeAll { $0 == Fixture.inventory } }
        case .selfTestFailed: await loop.markSelfTestFailedForTesting(Fixture.inventory)
        case .retiring: await loop.markRetiringForTesting(Fixture.inventory)
        case .hashUnavailable: await loop.markWeightHashUnavailable(modelId: Fixture.inventory)
        case .shutdown: await loop.beginShutdownForTesting()
        }
        await loop.publishModelAutopilotSnapshot()

        let placements = await loop.autopilotPlacementsForTesting
        #expect(placements.adopted.isEmpty)
        #expect(placements.held.isEmpty)
        #expect(await loop.isModelAdvertised(Fixture.inventory) == false)
        #expect(await loop.autopilotServesModel(Fixture.inventory) == false)
        #expect(await loop.state.modelAutopilot?.adoptedModels == nil)
        #expect(await loop.state.modelAutopilot?.heldModels == nil)
        // Withdrawal removes only loadability; residency ends normally.
        #expect(fixture.engines[Fixture.inventory]?.shutdownCalls == (end == .unload ? 1 : 0))
    }

    @Test func idleUnloadAfterHoldExpiryWithdrawsAdoptedInventory() async throws {
        let fixture = try await adoptedAfterLease(holdSeconds: 600)
        defer { Task { await fixture.remove() } }
        let loop = fixture.loop
        await loop.setAutopilotHoldForTesting(Fixture.inventory, until: .now.advanced(by: .seconds(-3_700)))
        await loop.tickIdleMonitor(timeout: .seconds(3_600))
        #expect(fixture.engines[Fixture.inventory]?.shutdownCalls == 1)
        #expect(await loop.isModelAdvertised(Fixture.inventory) == false)
        #expect(await loop.autopilotPlacementsForTesting.adopted.isEmpty)
        do {
            try await loop.ensureModelLoaded(modelId: Fixture.inventory)
            Issue.record("unloaded adopted inventory reloaded without a lease")
        } catch InferenceError.modelLoadFailed(let reason) {
            #expect(reason == "model_not_selected")
        }
    }

    @Test func withoutConsentTheSnapshotAndServingAreUnchanged() async throws {
        let fixture = try await Fixture.make(consent: false)
        defer { Task { await fixture.remove() } }
        let loop = fixture.loop
        await loop.publishModelAutopilotSnapshot()
        let snapshot = try #require(await loop.state.modelAutopilot)
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        for key in ["capabilities", "adopted_models", "held_models", "busy_reasons", "busy_reason",
                    "busy_since_ms", "transition_stalls"] {
            #expect(json[key] == nil, "\(key) must stay absent without consent")
        }
        #expect(await loop.autopilotServesModel(Fixture.inventory) == false)
        #expect(await loop.evictableModelSlots().keys.sorted() == Fixture.all.sorted())
    }
}

private extension ProviderLoop {
    /// The lease ends without the withdrawal that normally accompanies it.
    func clearAutopilotControlStateForTesting() { autopilotControl = nil }
    func markSelfTestFailedForTesting(_ id: String) { failedSelfTestHashes[id] = "" }
}
