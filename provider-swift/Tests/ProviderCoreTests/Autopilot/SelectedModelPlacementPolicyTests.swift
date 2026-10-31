import Foundation
import Testing
@testable import ProviderCore

/// The operator's selection outranks an Autopilot placement outside it once
/// the placement's hold is over (policy for owner review): an adopted GLM that
/// keeps a waiting selected model out with steady traffic after the hold, its
/// minimum dwell and any per-model lease is released (it stops taking new
/// requests), finishes its requests, and is evicted. A hold is always
/// honoured. Scripted 256 GB machine; Super's load is a stub slot.
@Suite("Selected models outrank expired placements", .serialized)
struct SelectedModelPlacementPolicyTests {
    private typealias Fixture = UnreclaimableLoadMemoryFixture

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
        await checkSelectedModelRecovery(loop, at: start)
        #expect(await loop.autopilotServesModel(Fixture.glmID))

        await checkSelectedModelRecovery(loop, at: start.advanced(by: .seconds(601)))
        #expect(await loop.autopilotServesModel(Fixture.glmID) == false)
        #expect(await loop.isModelAdvertised(Fixture.glmID) == false)
        #expect(await loop.modelLoadingResidentIDs() == [Fixture.gemmaID, Fixture.glmID])
        let released = try await superRecoveryEntry(loop)
        #expect(released.blocker == "released the Autopilot adoption of glm-5.3-flash; waiting for its "
            + "1 request in flight", "\(released.blocker ?? "")")
        #expect(fixture.shutdownCalls(Fixture.glmID) == 0)

        // Its request finishes; GLM takes no new work, so it goes at once.
        await fixture.endGLMRequest()
        await checkSelectedModelRecovery(loop, at: released.nextCheckAt)
        #expect(fixture.shutdownCalls(Fixture.glmID) == 1)
        #expect(fixture.shutdownCalls(Fixture.gemmaID) == 0)
        #expect(await loop.modelLoadingResidentIDs() == [Fixture.gemmaID, Fixture.superID])
        #expect(await loop.selectedModelRecovery.isEmpty)
    }

    /// The release waits for the minimum dwell an operation's victim rules
    /// apply: GLM, resident fifteen minutes, goes at thirty.
    @Test(.timeLimit(.minutes(1)))
    func aBusyAdoptionIsNotReleasedBeforeItsMinimumDwell() async throws {
        let fixture = try await Fixture.make(glm: .autopilotInventory)
        defer { Task { await fixture.remove() } }
        let loop = fixture.loop
        await loop.settleAutopilotOperationForTesting(target: Fixture.glmID, holdSeconds: 600)
        await loop.setSelectedModelRecoveryLoadOverrideForTesting { id in await fixture.install(id) }
        await loop.enqueueSelectedModelRecovery([Fixture.superID])
        let start = ContinuousClock.now
        await loop.setAutopilotHoldForTesting(Fixture.glmID, until: start.advanced(by: .seconds(-660)))
        await loop.setAutopilotResidentSinceForTesting(Fixture.glmID, start.advanced(by: .seconds(-900)))
        await fixture.beginGLMRequest()

        await checkSelectedModelRecovery(loop, at: start)
        await checkSelectedModelRecovery(loop, at: start.advanced(by: .seconds(601)))
        #expect(await loop.autopilotServesModel(Fixture.glmID))
        await checkSelectedModelRecovery(loop, at: start.advanced(by: .seconds(901)))
        #expect(await loop.autopilotServesModel(Fixture.glmID) == false)
        #expect(fixture.shutdownCalls(Fixture.glmID) == 0)
        await fixture.endGLMRequest()
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
        await checkSelectedModelRecovery(loop, at: .now.advanced(by: .seconds(1_800)))
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
        await checkSelectedModelRecovery(loop, at: .now.advanced(by: .seconds(1_800)))
        #expect(await loop.autopilotServesModel(Fixture.glmID))
        #expect(await loop.isModelAdvertised(Fixture.glmID))
        #expect(fixture.shutdownCalls(Fixture.glmID) == 0)
    }
}
