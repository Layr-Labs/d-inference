import Testing
@testable import ProviderCore

/// CPU-only accounting regressions. Pending execution while the build lane is held.
struct NemotronSuperLoadAdmissionTests {
    @Test func liveButUndersizedLeaseCannotAuthorizeSetup() async throws {
        let budget = GlobalKVCacheBudget(capFraction: 1, activationReserveBytes: 0,
            memorySnapshot: { .init(total: 8 << 30, active: 0, cache: 0, systemAvailable: .max) })
        let pending = await budget.claimPendingLoad(requestID: "super-charge-fixture",
            weightBytes: 4096, minimumKVBytes: 1 << 30)
        let lease = try #require(pending)
        #expect(await budget.recheckPendingLoad(lease, minimumWeightBytes: 4096,
            minimumKVBytes: 1 << 30))
        #expect(!(await budget.recheckPendingLoad(lease, minimumWeightBytes: 8192,
            minimumKVBytes: 1 << 30)))
        #expect(!(await budget.recheckPendingLoad(lease, minimumWeightBytes: 1,
            minimumKVBytes: 2 << 30)))
        #expect(!(await budget.recheckPendingLoad(lease, minimumWeightBytes: .max,
            minimumKVBytes: 1 << 30)))
        #expect(await budget.finishPendingLoad(lease))
        #expect(!(await budget.recheckPendingLoad(lease, minimumWeightBytes: 1,
            minimumKVBytes: 1)))
        #expect(await budget.outstandingReservedBytes() == 0)
    }
}
