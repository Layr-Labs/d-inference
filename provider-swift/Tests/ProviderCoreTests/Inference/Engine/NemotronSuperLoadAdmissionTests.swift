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

    /// The room the Super gate reads is the ledger's own LOAD admission: with
    /// the same system reserve, a claim of exactly that room is admitted and
    /// one byte more is refused; without one it is the runtime room. Here
    /// min(115.2 GiB cap - 22 GiB used, 90 GiB available - reserve) less the
    /// 3 GiB activation reserve and 5 GiB not yet materialized.
    @Test(arguments: [0, 12 << 30] as [UInt64])
    func claimRoomIsTheLedgersOwnAdmission(systemReserve: UInt64) async throws {
        let budget = GlobalKVCacheBudget(capFraction: 0.9, activationReserveBytes: 3 << 30,
            memorySnapshot: { .init(total: 128 << 30, active: 20 << 30, cache: 2 << 30, systemAvailable: 90 << 30) })
        #expect(await budget.reserveBytes(requestID: "outstanding", bytes: 5 << 30))
        let sample = budget.memoryHeadroomSnapshot()
        let room = sample.loadClaimRemainingBytes(systemReserveBytes: systemReserve)
        #expect(room == (systemReserve == 0 ? 82 << 30 : 70 << 30))
        if systemReserve == 0 { #expect(room == sample.runtimeRemainingBytes) }
        let kv: UInt64 = 1 << 30
        #expect(await budget.claimPendingLoad(requestID: "over", weightBytes: room + 1 - kv, minimumKVBytes: kv,
            systemReserveBytes: systemReserve) == nil)
        let lease = try #require(await budget.claimPendingLoad(requestID: "exact", weightBytes: room - kv,
            minimumKVBytes: kv, systemReserveBytes: systemReserve))
        #expect(budget.memoryHeadroomSnapshot().loadClaimRemainingBytes(systemReserveBytes: systemReserve) == 0)
        #expect(await budget.finishPendingLoad(lease))
        await budget.release(requestID: "outstanding")
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
