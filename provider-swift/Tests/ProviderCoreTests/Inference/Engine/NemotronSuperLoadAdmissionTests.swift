import Foundation
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

    /// A Super LOAD claim keeps its own OS reserve (none with the default
    /// `memory_reserve_gb`) beside its charge, at admission and at every
    /// recheck; any other load keeps the provider's load reserve. 90 GiB fits
    /// 100 GiB available only without that reserve.
    @Test func superClaimKeepsItsOwnSystemReserve() async throws {
        let configReserve = NemotronSuperLoadFit.defaultConfigReserveBytes
        let budget = GlobalKVCacheBudget(capFraction: 0.9, activationReserveBytes: 0,
            configReserveBytes: configReserve,
            memorySnapshot: { .init(total: 128 << 30, active: 0, cache: 0, systemAvailable: 100 << 30) })
        #expect(budget.loadReserveBytes > 10 << 30)
        let reserve = NemotronSuperLoadFit.systemReserveBytes(configReserveBytes: budget.configReserveBytes)
        #expect(reserve == 0)
        let weight: UInt64 = 89 << 30
        let refused = await budget.claimPendingLoad(requestID: "provider-reserve", weightBytes: weight)
        #expect(refused == nil)
        let lease = try #require(await budget.claimPendingLoad(requestID: "super-reserve", weightBytes: weight,
            systemReserveBytes: reserve))
        #expect(await budget.recheckPendingLoad(lease))
        #expect(await budget.finishPendingLoad(lease))
        #expect(await budget.outstandingReservedBytes() == 0)
    }

    /// An operator who raised `memory_reserve_gb` above its 4 GiB default
    /// keeps all of it free beside a Super claim, as at every recheck; the
    /// default, which every generated config carries, and anything below it
    /// keep none. With 16 GiB reserved, 90 GiB no longer fits 100 GiB.
    @Test func raisedOperatorReserveStaysBesideTheSuperClaim() async throws {
        #expect(ProviderSettings(name: "x").memoryReserveGB << 30 == NemotronSuperLoadFit.defaultConfigReserveBytes)
        let decoded = try JSONDecoder().decode(ProviderSettings.self, from: Data(#"{"name":"x"}"#.utf8))
        #expect(decoded.memoryReserveGB << 30 == NemotronSuperLoadFit.defaultConfigReserveBytes)
        for (configured, kept) in [(0, 0), (2 << 30, 0), (4 << 30, 0), (5 << 30, 5 << 30), (16 << 30, 16 << 30)]
            as [(UInt64, UInt64)] {
            #expect(NemotronSuperLoadFit.systemReserveBytes(configReserveBytes: configured) == kept, "\(configured)")
        }
        let budget = GlobalKVCacheBudget(capFraction: 0.9, activationReserveBytes: 0, configReserveBytes: 16 << 30,
            memorySnapshot: { .init(total: 128 << 30, active: 0, cache: 0, systemAvailable: 100 << 30) })
        let reserve = NemotronSuperLoadFit.systemReserveBytes(configReserveBytes: budget.configReserveBytes)
        #expect(reserve == 16 << 30)
        #expect(budget.memoryHeadroomSnapshot().loadClaimRemainingBytes(systemReserveBytes: reserve) == 84 << 30)
        #expect(await budget.claimPendingLoad(requestID: "super-raised", weightBytes: 89 << 30,
            systemReserveBytes: reserve) == nil)
        let lease = try #require(await budget.claimPendingLoad(requestID: "super-fits", weightBytes: 83 << 30,
            systemReserveBytes: reserve))
        #expect(await budget.recheckPendingLoad(lease))
        #expect(await budget.finishPendingLoad(lease))
        #expect(await budget.outstandingReservedBytes() == 0)
    }
}
