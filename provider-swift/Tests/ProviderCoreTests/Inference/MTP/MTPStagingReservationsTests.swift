import Foundation
import Testing
@testable import ProviderCore

@Suite("MTP staging target ownership")
struct MTPStagingReservationsTests {
    @Test("overlapping preparations and staged leases pin one target without double counting")
    func retentionTransfersWithoutAnEvictionGap() {
        let target = NSObject()
        let id = ObjectIdentifier(target)
        let ledger = ProcessMemoryLedger(policy: .init(epoch: 1, capBytes: 1_000, reserveBytes: 0),
            readUsage: { .init(activeBytes: 0, cacheBytes: 0, systemAvailableBytes: 1_000) })
        let lease = PendingModelLoadLease(owner: ledger.createOwner().owner)
        var reservations = MTPStagingReservations()
        let first = reservations.retainPreparingTarget(id, bytes: 100)
        let second = reservations.retainPreparingTarget(id, bytes: 100)
        #expect(reservations.retains(id))
        #expect(reservations.extraBytes(residentTargets: [id]) == 0)
        #expect(reservations.extraBytes(residentTargets: []) == 100)
        reservations.reserve(lease, target: id, targetBytes: 100, assistantBytes: 20, kvBytes: 30)
        reservations.releasePreparingTarget(first)
        reservations.releasePreparingTarget(second)
        #expect(reservations.retains(id), "the staged owner succeeds both preparation owners")
        #expect(reservations.extraBytes(residentTargets: [id]) == 50)
        #expect(reservations.extraBytes(residentTargets: []) == 150)
        let generation = reservations.generation
        reservations.release(lease)
        #expect(!reservations.retains(id))
        #expect(!reservations.hasRetainedTargets)
        #expect(reservations.extraBytes(residentTargets: []) == 0)
        #expect(reservations.generation > generation)
        let releasedGeneration = reservations.generation
        reservations.release(lease)
        reservations.releasePreparingTarget(first)
        #expect(reservations.generation == releasedGeneration, "late duplicate cleanup is inert")
    }

    @Test("pre-lease retained target remains charged after explicit unload until final owner leaves")
    func concurrentPreparationOwnersReleaseIndependently() {
        let target = NSObject()
        let id = ObjectIdentifier(target)
        var reservations = MTPStagingReservations()
        let first = reservations.retainPreparingTarget(id, bytes: 100)
        let second = reservations.retainPreparingTarget(id, bytes: 100)
        reservations.releasePreparingTarget(first)
        #expect(reservations.retains(id))
        #expect(reservations.extraBytes(residentTargets: []) == 100)
        reservations.releasePreparingTarget(second)
        #expect(!reservations.retains(id))
        #expect(reservations.extraBytes(residentTargets: []) == 0)
    }
}
