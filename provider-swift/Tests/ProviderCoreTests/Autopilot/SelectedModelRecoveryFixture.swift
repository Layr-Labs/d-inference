import Foundation
import Testing
@testable import ProviderCore

/// Super waiting in the selected-model recovery on the scripted 256 GB
/// machine of `UnreclaimableLoadMemoryFixture`, shared by the recovery suites.
extension UnreclaimableLoadMemoryFixture {
    /// GLM adopted outside the selection (optionally held), resident and idle
    /// for two hours, and Super waiting; Super's load installs a stub slot
    /// holding its scripted bytes.
    static func superWaitingBehindAdoptedGLM(holdSeconds: Int? = nil) async throws -> Self {
        let fixture = try await make(glm: .autopilotInventory)
        let loop = fixture.loop
        await loop.settleAutopilotOperationForTesting(target: glmID, holdSeconds: holdSeconds)
        await loop.setSelectedModelRecoveryLoadOverrideForTesting { id in await fixture.install(id) }
        await loop.enqueueSelectedModelRecovery([superID])
        #expect(await loop.selectedModelRecovery.entries.keys.sorted() == [superID])
        return fixture
    }
}

/// One recovery check at `now`, then the attempt it started, if any.
func checkSelectedModelRecovery(_ loop: ProviderLoop, at now: ContinuousClock.Instant) async {
    await loop.checkSelectedModelRecoveryIfDue(now: now)
    await loop.awaitSelectedModelRecoveryAttemptForTesting()
}

/// Super's recovery entry; fails the test when Super no longer waits.
func superRecoveryEntry(_ loop: ProviderLoop) async throws -> SelectedModelRecovery.Entry {
    try #require(await loop.selectedModelRecovery.entries[UnreclaimableLoadMemoryFixture.superID])
}
