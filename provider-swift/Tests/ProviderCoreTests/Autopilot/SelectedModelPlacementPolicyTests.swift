import Foundation
import Testing
@testable import ProviderCore

/// The operator's selection outranks an Autopilot placement outside it once
/// the placement's hold is over (policy for owner review): a selected model an
/// operation unloaded to place GLM waits to come back, and an adopted GLM that
/// keeps it out with steady traffic after the hold is released (it stops
/// taking new requests), finishes its requests, and is evicted. A hold is
/// always honoured. Scripted 256 GB machine; Super's load is a stub slot.
@Suite("Selected models outrank expired placements", .serialized)
struct SelectedModelPlacementPolicyTests {
    private typealias Fixture = UnreclaimableLoadMemoryFixture

    private func check(_ loop: ProviderLoop, at now: ContinuousClock.Instant) async {
        await loop.checkSelectedModelRecoveryIfDue(now: now)
        await loop.awaitSelectedModelRecoveryAttemptForTesting()
    }

    /// The reported operation, with Super resident and its explicit victim.
    @Test(.timeLimit(.minutes(1)))
    func anOperationThatUnloadsSuperForGLMQueuesSuper() async throws {
        let fixture = try await Fixture.make(glm: .autopilotInventory)
        defer { Task { await fixture.remove() } }
        let loop = fixture.loop
        await fixture.install(Fixture.superID, idleFor: .seconds(3_600))
        await loop.ageAutopilotResidentsForTesting()
        await loop.activateAutopilotForTesting()
        let command = ModelAutopilotCommand(commandId: "op_fedcba9876543210fedcba9876543210",
            loadModelId: Fixture.glmID, unloadModelIds: [Fixture.superID],
            expectedResidentModels: [Fixture.gemmaID, Fixture.glmID, Fixture.superID],
            expiresAtMs: ProviderLoop.autopilotNowMs + 60_000, leaseSeconds: 0,
            sessionId: "session", revision: "test", holdSeconds: 600)
        let status = try #require(await fixture.withModelCache { await loop.runAutopilotCommandForTesting(command) })
        #expect(status.status == .succeeded, "\(status.error ?? "")")
        await loop.clearAutopilotControl()
        #expect(fixture.shutdownCalls(Fixture.superID) == 1)
        #expect(await loop.selectedModelRecovery.entries.keys.sorted() == [Fixture.superID])

        // The hold keeps GLM for its ten minutes.
        await loop.setSelectedModelRecoveryLoadOverrideForTesting { id in await fixture.install(id) }
        await check(loop, at: .now)
        let held = try #require(await loop.selectedModelRecovery.entries[Fixture.superID])
        #expect(held.blocker?.contains("Autopilot hold until ") == true, "\(held.blocker ?? "")")
        #expect(fixture.shutdownCalls(Fixture.glmID) == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func aBusyAdoptionIsReleasedTenMinutesAfterItsHoldThenEvicted() async throws {
        let fixture = try await Fixture.make(glm: .autopilotInventory)
        defer { Task { await fixture.remove() } }
        let loop = fixture.loop
        await loop.settleAutopilotOperationForTesting(target: Fixture.glmID, holdSeconds: 600)
        await loop.setAutopilotHoldForTesting(Fixture.glmID, until: .now.advanced(by: .seconds(-660)))
        await loop.setSelectedModelRecoveryLoadOverrideForTesting { id in await fixture.install(id) }
        await loop.enqueueSelectedModelRecovery([Fixture.superID])
        let start = ContinuousClock.now
        await fixture.beginGLMRequest()

        // Traffic alone does not release it at once.
        await check(loop, at: start)
        #expect(await loop.autopilotServesModel(Fixture.glmID))

        await check(loop, at: start.advanced(by: .seconds(601)))
        #expect(await loop.autopilotServesModel(Fixture.glmID) == false)
        #expect(await loop.isModelAdvertised(Fixture.glmID) == false)
        #expect(await loop.modelLoadingResidentIDs() == [Fixture.gemmaID, Fixture.glmID])
        let released = try #require(await loop.selectedModelRecovery.entries[Fixture.superID])
        #expect(released.blocker == "released the Autopilot adoption of glm-5.3-flash; waiting for its "
            + "1 request in flight", "\(released.blocker ?? "")")
        #expect(fixture.shutdownCalls(Fixture.glmID) == 0)

        // Its request finishes; GLM takes no new work, so it goes at once.
        await fixture.endGLMRequest()
        await check(loop, at: released.nextCheckAt)
        #expect(fixture.shutdownCalls(Fixture.glmID) == 1)
        #expect(fixture.shutdownCalls(Fixture.gemmaID) == 0)
        #expect(await loop.modelLoadingResidentIDs() == [Fixture.gemmaID, Fixture.superID])
        #expect(await loop.selectedModelRecovery.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func aHeldAdoptionIsNeverReleased() async throws {
        let fixture = try await Fixture.make(glm: .autopilotInventory)
        defer { Task { await fixture.remove() } }
        let loop = fixture.loop
        await loop.settleAutopilotOperationForTesting(target: Fixture.glmID, holdSeconds: 3_600)
        await loop.setSelectedModelRecoveryLoadOverrideForTesting { id in await fixture.install(id) }
        await loop.enqueueSelectedModelRecovery([Fixture.superID])
        await fixture.beginGLMRequest()
        await check(loop, at: .now.advanced(by: .seconds(1_800)))
        #expect(await loop.autopilotServesModel(Fixture.glmID))
        #expect(fixture.shutdownCalls(Fixture.glmID) == 0)
    }

    /// A model in the running daemon's selection is the operator's, however
    /// busy: never released or evicted.
    @Test(.timeLimit(.minutes(1)))
    func aSelectedModelIsNeverReleased() async throws {
        let fixture = try await Fixture.make(glm: .ordinary)
        defer { Task { await fixture.remove() } }
        let loop = fixture.loop
        await loop.setSelectedModelRecoveryLoadOverrideForTesting { id in await fixture.install(id) }
        await loop.enqueueSelectedModelRecovery([Fixture.superID])
        await fixture.beginGLMRequest()
        await check(loop, at: .now.advanced(by: .seconds(1_800)))
        #expect(await loop.autopilotServesModel(Fixture.glmID))
        #expect(await loop.isModelAdvertised(Fixture.glmID))
        #expect(fixture.shutdownCalls(Fixture.glmID) == 0)
    }
}
