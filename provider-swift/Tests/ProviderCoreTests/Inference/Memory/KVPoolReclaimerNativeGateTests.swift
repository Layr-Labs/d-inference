import Foundation
import XCTest
@testable import ProviderCore

/// Pure host callback-control tests. These counters do not stand in for native
/// completion, model memory or actual allocator reclamation evidence.
final class KVPoolReclaimerNativeGateTests: XCTestCase {
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var allowed: Bool
        private var cache: UInt64 = 16
        private var reads = 0
        private var flushes = 0
        private var denyOnRead: Int?

        init(allowed: Bool, denyOnRead: Int? = nil) {
            self.allowed = allowed
            self.denyOnRead = denyOnRead
        }
        func mayReclaim() -> Bool { lock.withLock { allowed } }
        func allow() { lock.withLock { allowed = true; denyOnRead = nil } }
        func readCache() -> UInt64 {
            lock.withLock {
                reads += 1
                if reads == denyOnRead { allowed = false }
                return cache
            }
        }
        func flush() { lock.withLock { flushes += 1; cache = 0 } }
        var counts: (reads: Int, flushes: Int) { lock.withLock { (reads, flushes) } }
    }

    func testRefusedQueuedWorkDoesNotReadAllocatorOrRecordReclamation() async {
        let state = State(allowed: false)
        let reclaimer = KVPoolReclaimer(clearCache: { state.flush() },
            reclaimableBytes: { state.readCache() }, minInterval: .seconds(60),
            proactiveThresholdBytes: 1, isReclaimAllowed: { state.mayReclaim() })
        let sweep = await reclaimer.sweep()
        let pressure = await reclaimer.reclaimIfNeeded(shortfall: 1)
        XCTAssertFalse(sweep)
        XCTAssertFalse(pressure)
        XCTAssertEqual(state.counts.reads, 0)
        XCTAssertEqual(state.counts.flushes, 0)
        XCTAssertEqual(reclaimer.telemetrySnapshot().sweepSignals, 1)
        XCTAssertEqual(reclaimer.telemetrySnapshot().reclaims, 0)
        state.allow()
        let resumed = await reclaimer.sweep()
        XCTAssertTrue(resumed, "a refusal must not consume the rate-limit window")
        XCTAssertEqual(state.counts.flushes, 1)
        XCTAssertEqual(reclaimer.telemetrySnapshot().reclaims, 1)
        XCTAssertEqual(reclaimer.telemetrySnapshot().reclaimedBytes, 16)
    }

    func testOwnershipRefusalDuringObservationIsRecheckedBeforeCallback() async {
        // First observation passes the shortfall check; the observation inside
        // flushIfDue closes the gate. No sleeps or scheduling timing assumption.
        let state = State(allowed: true, denyOnRead: 2)
        let reclaimer = KVPoolReclaimer(clearCache: { state.flush() },
            reclaimableBytes: { state.readCache() }, minInterval: .seconds(60),
            proactiveThresholdBytes: 1, isReclaimAllowed: { state.mayReclaim() })
        let refused = await reclaimer.reclaimIfNeeded(shortfall: 1)
        XCTAssertFalse(refused)
        XCTAssertEqual(state.counts.reads, 2)
        XCTAssertEqual(state.counts.flushes, 0)
        XCTAssertEqual(reclaimer.telemetrySnapshot().reclaims, 0)
        XCTAssertEqual(reclaimer.telemetrySnapshot().reclaimedBytes, 0)
        state.allow()
        let resumed = await reclaimer.reclaimIfNeeded(shortfall: 1)
        XCTAssertTrue(resumed)
        XCTAssertEqual(state.counts.flushes, 1)
        XCTAssertEqual(reclaimer.telemetrySnapshot().reclaims, 1)
    }

    func testExistingInjectedReclaimerKeepsItsDefaultBehavior() async {
        let state = State(allowed: false)
        let reclaimer = KVPoolReclaimer(clearCache: { state.flush() },
            reclaimableBytes: { state.readCache() }, minInterval: .seconds(60),
            proactiveThresholdBytes: 1)
        let reclaimed = await reclaimer.sweep()
        XCTAssertTrue(reclaimed)
        XCTAssertEqual(state.counts.flushes, 1)
        let repeated = await reclaimer.sweep()
        XCTAssertFalse(repeated)
        XCTAssertEqual(reclaimer.telemetrySnapshot().reclaims, 1)
    }
}
