import Foundation
import Testing
@testable import ProviderCore

@Suite("KV budget ownership survives rejection audits")
struct GlobalKVCacheBudgetAuditTests {
    private let gib: UInt64 = 1 << 30

    private func fixture() -> (GlobalKVCacheBudget, AuditClock, AuditEventLog) {
        let clock = AuditClock()
        let log = AuditEventLog()
        let budget = GlobalKVCacheBudget(
            capFraction: 1, activationReserveBytes: 0,
            memorySnapshot: {
                .init(total: 8 << 30, active: 0, cache: 0, systemAvailable: .max)
            },
            clockNow: { clock.now() },
            emitAuditEvent: { severity, message, fields in
                log.append(severity, message, fields)
            })
        return (budget, clock, log)
    }

    @Test("long decode and load charges survive repeated continuous-rejection audits",
          arguments: ["decode", "pending-load:model"])
    func liveOwnershipNeverExpires(owner: String) async throws {
        let (budget, clock, log) = fixture()
        var pendingLoad: PendingModelLoadLease?
        if owner == "decode" {
            #expect(await budget.reserveBytes(requestID: owner, bytes: 6 * gib))
        } else {
            pendingLoad = await budget.claimPendingLoad(
                requestID: owner, weightBytes: 6 * gib, minimumKVBytes: 0)
            _ = try #require(pendingLoad)
        }
        // The former age-based refund activated after 600 seconds and a
        // continuous 120-second rejection streak. Exercise both boundaries.
        clock.advance(.seconds(601))
        for index in 0...24 {
            #expect(!(await budget.reserveBytes(requestID: "arrival-\(index)", bytes: 1)))
            #expect(await budget.outstandingReservedBytes() == 6 * gib)
            clock.advance(.seconds(10))
        }
        #expect(log.operations() == Array(repeating: "kv_budget_sustained_rejection", count: 3))
        #expect(await budget.reservationIDsForTesting() == [owner])
        #expect(log.lastFields()["reservation_count"]?.description == "1")
        #expect(log.lastFields()["reserved_bytes"]?.description == String(6 * gib))

        if let pendingLoad {
            #expect(await budget.finishPendingLoad(pendingLoad))
        } else {
            await budget.release(requestID: owner)
        }
        #expect(await budget.outstandingReservedBytes() == 0)
        #expect(await budget.reserveBytes(requestID: "replacement", bytes: 6 * gib))
        await budget.release(requestID: "replacement")
        #expect(await budget.reservationIDsForTesting().isEmpty)
    }

    @Test("audit logging stays rate-limited without refunding owners")
    func auditRateLimit() async {
        let (budget, clock, log) = fixture()
        #expect(await budget.reserveBytes(requestID: "live", bytes: 6 * gib))
        for index in 0...18 {
            #expect(!(await budget.reserveBytes(requestID: "arrival-\(index)", bytes: 1)))
            clock.advance(.seconds(10))
            if index == 12 { #expect(log.operations().count == 1) }
            if index == 17 { #expect(log.operations().count == 1) }
        }
        #expect(log.operations().count == 2)
        #expect(await budget.outstandingReservedBytes() == 6 * gib)
        await budget.release(requestID: "live")
    }

    @Test("idle rejection gaps restart the diagnostic streak")
    func idleGapsDoNotAudit() async {
        let (budget, clock, log) = fixture()
        #expect(await budget.reserveBytes(requestID: "live", bytes: 6 * gib))
        clock.advance(.seconds(601))
        for index in 0..<5 {
            #expect(!(await budget.reserveBytes(requestID: "sparse-\(index)", bytes: 1)))
            clock.advance(.seconds(121))
        }
        #expect(log.operations().isEmpty)
        #expect(await budget.outstandingReservedBytes() == 6 * gib)
        await budget.release(requestID: "live")
    }

    @Test("actual releases clear a rejection streak while unknown releases preserve it")
    func releaseProgress() async {
        let (budget, clock, log) = fixture()
        #expect(await budget.reserveBytes(requestID: "live", bytes: 6 * gib))
        for index in 0...12 {
            #expect(!(await budget.reserveBytes(requestID: "arrival-\(index)", bytes: 1)))
            await budget.release(requestID: "unknown")
            clock.advance(.seconds(10))
        }
        #expect(log.operations() == ["kv_budget_sustained_rejection"])
        #expect(await budget.rejectionStreakArmedForTesting())
        await budget.release(requestID: "live")
        #expect(!(await budget.rejectionStreakArmedForTesting()))
        #expect(await budget.outstandingReservedBytes() == 0)
    }

    @Test("successful reservations clear rejection diagnostics")
    func successfulCommitResetsStreak() async {
        let (budget, clock, log) = fixture()
        for index in 0..<20 {
            #expect(!(await budget.reserveBytes(requestID: "large-\(index)", bytes: 7 * gib)))
            #expect(await budget.rejectionStreakArmedForTesting())
            #expect(await budget.reserveBytes(requestID: "small-\(index)", bytes: 1))
            #expect(!(await budget.rejectionStreakArmedForTesting()))
            clock.advance(.seconds(10))
        }
        #expect(log.operations().isEmpty)
        for index in 0..<20 { await budget.release(requestID: "small-\(index)") }
        #expect(await budget.reservationIDsForTesting().isEmpty)
    }
}

private final class AuditClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now

    func now() -> ContinuousClock.Instant { lock.withLock { instant } }
    func advance(_ duration: Duration) { lock.withLock { instant = instant.advanced(by: duration) } }
}

private final class AuditEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [[String: AnyCodableValue]] = []

    func append(_ severity: TelemetrySeverity, _ message: String, _ fields: [String: AnyCodableValue]) {
        lock.withLock { events.append(fields) }
    }

    func operations() -> [String] {
        lock.withLock { events.compactMap { $0["operation"]?.description } }
    }

    func lastFields() -> [String: AnyCodableValue] { lock.withLock { events.last ?? [:] } }
}
