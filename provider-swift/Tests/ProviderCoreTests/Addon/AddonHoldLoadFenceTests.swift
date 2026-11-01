import Foundation
import Testing

@testable import ProviderCore

extension TinyModelLoadTests {
    /// A cold load already past the load gate when a hold begins, such as a
    /// local request's, which no drain bound cancels. It runs through the
    /// real loader; nested here because the tiny model's cache is process-wide.
    @Suite("Add-on hold load fence")
    struct AddonHoldLoadFence {
        @Test func aLoadRunningWhenTheHoldBeginsNeverPublishesAndTheHoldWaitsForIt() async throws {
            _ = LiveInferenceFixtures.ensureMetallibColocated()
            let checkpoint = try TinyModelCheckpoint()
            defer { checkpoint.remove() }
            let sandbox = try ModelLoadingSandbox()
            defer { sandbox.remove() }
            let runtime = try AddonRuntimeFixture()
            defer { runtime.remove() }
            let peer = AddonHoldLoopTests.peer

            try await checkpoint.withModelCache {
                let modelID = checkpoint.modelID
                let weightsLoad = UpgradeBarrier()
                let loop = try await ModelLoadingFixtures.makeLoop(
                    sandbox: sandbox, models: [try checkpoint.scannedModelInfo()],
                    beforeModelLoad: { _ in await weightsLoad.wait() })
                await loop.useAddonHoldForTesting(paths: runtime.paths, clock: AddonTestClock())
                await loop.setAddonHoldSettleTimeoutForTesting(.milliseconds(200))
                let load = Task { try await loop.ensureModelLoaded(modelId: modelID) }
                await weightsLoad.observeEntry()

                guard case .hold(let id, .draining, _, _) = await loop.handleAddonIPC(
                    .hold(addon: peer.identifier, vmBytes: 0, leaseSeconds: 60), peer: peer)
                else {
                    Issue.record("the hold was refused")
                    await weightsLoad.release()
                    return
                }
                func state() async -> AddonIPC.HoldState? {
                    guard case .status(let state, _, _) = await loop.handleAddonIPC(.status(holdID: id), peer: peer)
                    else { return nil }
                    return state
                }
                // Long past the settle bound the load still owns memory, so
                // the Mac is not reported held.
                try await Task.sleep(for: .seconds(1))
                #expect(await state() == .draining)

                await weightsLoad.release()
                do {
                    try await load.value
                    Issue.record("the load published its slot while an add-on held the Mac")
                } catch {
                    #expect(ProviderLoop.loadErrorStatusCode(for: error) == 503, "\(error)")
                }
                #expect(try await addonEventually { await state() == .held })
                #expect(await loop.modelLoadingResidentIDs().isEmpty)

                // While held no load starts; the release lifts the fence.
                await #expect(throws: InferenceError.self) { try await loop.ensureModelLoaded(modelId: modelID) }
                #expect(await loop.modelLoadingResidentIDs().isEmpty)
                #expect(await loop.handleAddonIPC(.release(holdID: id), peer: peer) == .released)
                try await loop.ensureModelLoaded(modelId: modelID)
                #expect(await loop.modelLoadingResidentIDs() == [modelID])
                #expect(await loop.unloadModel(modelID))
            }
        }
    }
}
