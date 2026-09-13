import Foundation
import Testing
@testable import ProviderCore

@Suite("Complete checkpoint maintenance epoch", .serialized)
struct SSDCheckpointMaintenanceEpochTests {
    @Test("owned deletion reconciles once and a surviving checkpoint remains reusable")
    func ownedDeletionReconcilesWithoutSecondEpoch() async throws {
        let f = try SSDHybridCheckpointTestFixture()
        defer { f.remove() }
        let budget = SSDDiskBudget()
        let store = try f.makeStore(diskBudget: budget)
        defer { store.close() }
        #expect(try await f.donate(store, position: 256) == [256])
        #expect(try await f.donate(store, position: 512) == [512])
        let original = try #require(store.config.epochStore?.current)
        let survivor = try Data(contentsOf: f.file(store, position: 256))
        let victim = f.file(store, position: 512)
        var removed = false
        let changed = budget.performActiveDestructiveChange(root: f.modelRoot) {
            removed = SSDBlockStore.removeItemIfSafe(at: victim, under: f.root)
        }
        #expect(changed == true)
        #expect(removed)
        let rotated = try #require(store.config.epochStore?.current)
        #expect(rotated != original)
        #expect(store.index.count == 1)
        budget.reconcileAll()
        #expect(store.config.epochStore?.current == rotated)
        #expect(try Data(contentsOf: f.file(store, position: 256)) == survivor)
        let result = await store.stage(requestID: .init(777), request: f.request(),
            reserveReadScratch: f.reserveReadScratch, makeImportPlan: f.plan)
        #expect(result.staged)
        await store.abandonStaging(requestID: .init(777))
        await store.closeAndWait()
    }
}
