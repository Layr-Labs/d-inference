// Copyright © 2026 Eigen Labs.

import Foundation
import Testing
@testable import ProviderCore

extension NemotronSuperManagedSlotTests {
    /// A hold retires the managed Super slot through its own owner path. That
    /// temporary unload must keep the preload plan, as the generic unload does.
    @Test(.timeLimit(.minutes(3)))
    func anAddonHoldRetiresTheSuperSlotButKeepsItsPreloadPlan() async throws {
        let fixture = try await Self.fixture(mode: .off)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let runtime = try AddonRuntimeFixture()
        defer { runtime.remove() }
        let loop = fixture.loop, peer = AddonHoldLoopTests.peer
        let plan = fixture.directory.appendingPathComponent("loaded-models.json")
        await loop.setLoadedModelsFileForTesting(plan)
        try await loop.ensureModelLoaded(modelId: Self.modelID, allowEviction: false,
                                         revisionDirectory: fixture.directory)
        #expect(LoadedModelsStore.read(from: plan) == [Self.modelID])

        await loop.useAddonHoldForTesting(paths: runtime.paths, clock: AddonTestClock())
        guard case .hold(let id, _, _, _) = await loop.handleAddonIPC(
            .hold(addon: peer.identifier, vmBytes: 0, leaseSeconds: 60), peer: peer)
        else {
            Issue.record("the hold was refused")
            return
        }
        let held = try await addonEventually(timeout: .seconds(60)) {
            guard case .status(.held, _, _) = await loop.handleAddonIPC(.status(holdID: id), peer: peer)
            else { return false }
            return true
        }
        try #require(held)
        #expect(await loop.modelLoadingResidentIDs().isEmpty)
        #expect(LoadedModelsStore.read(from: plan) == [Self.modelID])
        #expect(await loop.handleAddonIPC(.release(holdID: id), peer: peer) == .released)
    }
}
