import Foundation
import Testing
@testable import ProviderCore

/// A selected model the startup preload skipped for memory is retried on the
/// capacity tick, through the ordinary daemon paths only: the startup gate,
/// the tick and Super's real load gate on the scripted 256 GB machine of
/// `UnreclaimableLoadMemoryFixture`. GLM-5.3-Flash, adopted by an earlier
/// Autopilot operation outside the selection and idle, is what keeps Super
/// out; the selected Gemma stays.
@Suite("Selected models recover after a skipped startup preload", .serialized)
struct SelectedModelRecoveryTests {
    private typealias Fixture = UnreclaimableLoadMemoryFixture

    /// GLM adopted outside the selection with no hold; the startup preload
    /// then skips Super for memory and finds Gemma resident.
    private func startWithSuperSkipped(_ fixture: Fixture) async throws {
        let loop = fixture.loop
        await loop.settleAutopilotOperationForTesting(target: Fixture.glmID)
        #expect(await loop.autopilotAdoptionIsValid(Fixture.glmID))
        await loop.setStartupPreloadLoadOverrideForTesting { id in
            if await !loop.modelLoadingResidentIDs().contains(id) { await fixture.install(id) }
        }
        _ = await loop.runStartupPreloadGateForTesting()
        #expect(await modelLoadingWaitUntil { await loop.startupPreloadTaskRunningForTesting() == false })
        #expect(await loop.modelLoadingResidentIDs() == [Fixture.gemmaID, Fixture.glmID])
    }

    @Test(.timeLimit(.minutes(1)))
    func theCapacityTickEvictsTheIdleModelOutsideTheSelectionAndLoadsSuper() async throws {
        let fixture = try await Fixture.make(glm: .autopilotInventory)
        defer { Task { await fixture.remove() } }
        let loop = fixture.loop
        try await startWithSuperSkipped(fixture)
        #expect(fixture.superLoads.value == 0)

        await fixture.withModelCache {
            await loop.capacityRefreshTick()
            _ = await modelLoadingWaitUntil { fixture.superLoads.value > 0 }
        }
        // GLM made the room; the selected Gemma stayed; Super's own gate ran
        // and reached its loader, which this scripted machine refuses.
        #expect(fixture.superLoads.value == 1)
        #expect(fixture.shutdownCalls(Fixture.glmID) == 1)
        #expect(fixture.shutdownCalls(Fixture.gemmaID) == 0)
        #expect(await loop.isModelAdvertised(Fixture.glmID) == false)
    }

    @Test(.timeLimit(.minutes(1)))
    func aRequestInFlightKeepsTheModelOutsideTheSelection() async throws {
        let fixture = try await Fixture.make(glm: .autopilotInventory)
        defer { Task { await fixture.remove() } }
        let loop = fixture.loop
        try await startWithSuperSkipped(fixture)
        await fixture.beginGLMRequest()
        await fixture.withModelCache { await loop.capacityRefreshTick() }
        try await Task.sleep(for: .milliseconds(200))
        #expect(fixture.superLoads.value == 0)
        #expect(fixture.shutdownCalls(Fixture.glmID) == 0)
        #expect(fixture.shutdownCalls(Fixture.gemmaID) == 0)
    }
}
