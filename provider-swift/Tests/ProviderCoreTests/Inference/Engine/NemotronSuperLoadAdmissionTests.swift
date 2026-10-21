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

    /// A Super LOAD claim keeps its own OS reserve (none) beside its charge,
    /// at admission and at every recheck; any other load keeps the provider's
    /// load reserve. 90 GiB fits 100 GiB available only without that reserve.
    @Test func superClaimKeepsItsOwnSystemReserve() async throws {
        let budget = GlobalKVCacheBudget(capFraction: 0.9, activationReserveBytes: 0,
            memorySnapshot: { .init(total: 128 << 30, active: 0, cache: 0, systemAvailable: 100 << 30) })
        #expect(budget.loadReserveBytes > 10 << 30)
        #expect(NemotronSuperLoadFit.systemReserveBytes == 0)
        let weight: UInt64 = 89 << 30
        let refused = await budget.claimPendingLoad(requestID: "provider-reserve", weightBytes: weight)
        #expect(refused == nil)
        let lease = try #require(await budget.claimPendingLoad(requestID: "super-reserve", weightBytes: weight,
            systemReserveBytes: NemotronSuperLoadFit.systemReserveBytes))
        #expect(await budget.recheckPendingLoad(lease))
        #expect(await budget.finishPendingLoad(lease))
        #expect(await budget.outstandingReservedBytes() == 0)
    }
}
