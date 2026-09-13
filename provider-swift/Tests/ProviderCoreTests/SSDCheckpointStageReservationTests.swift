import Foundation
import Testing
@testable import ProviderCore

private final class SSDReservationBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    func didEnter() -> Bool { entered.wait(timeout: .now()) == .success }
    func arm() { lock.withLock { armed = true } }
    func sample() -> GlobalKVCacheBudget.MemorySnapshot {
        let block = lock.withLock { () -> Bool in
            defer { armed = false }
            return armed
        }
        if block { entered.signal(); release.wait() }
        return .init(total: 64 << 30, active: 0, cache: 0, systemAvailable: 64 << 30)
    }
}

@Suite("Complete checkpoint staging reservation")
struct SSDCheckpointStageReservationTests {
    @Test("native cancellation cannot refund host Data before the IO scope drains")
    func releaseWaitsForIO() async throws {
        let budget = GlobalKVCacheBudget(capFraction: 1, activationReserveBytes: 0, memorySnapshot: {
            .init(total: 8 << 30, active: 0, cache: 0, systemAvailable: .max)
        })
        #expect(await budget.reserveBytes(requestID: "io-held", bytes: 1024))
        let stats = SSDHybridCheckpointStatsBox()
        let activity = SSDCheckpointActivity()
        let lease = SSDCheckpointStageReservation(
            key: "io-held", bytes: 1024, budget: budget,
            activity: activity, stats: stats, holdsIO: true)
        lease.release()
        #expect(await budget.outstandingReservedBytes() == 1024)
        #expect(stats.snapshot().stagedBytesInUse == 1024)
        #expect(!(await lease.resize(to: 2048)))
        lease.finishIO()
        await lease.waitForRefund()
        #expect(await budget.outstandingReservedBytes() == 0)
        #expect(stats.snapshot().stagedBytesInUse == 0)
        lease.finishIO()
        lease.release()
    }

    @Test("release while a budget resize awaits cannot resurrect accounting", arguments: [false, true])
    func releaseDuringResize(holdsIO: Bool) async throws {
        let barrier = SSDReservationBarrier()
        let budget = GlobalKVCacheBudget(capFraction: 0.9, activationReserveBytes: 0, memorySnapshot: barrier.sample)
        #expect(await budget.reserveBytes(requestID: "lease", bytes: 1024))
        let stats = SSDHybridCheckpointStatsBox()
        let activity = SSDCheckpointActivity()
        let lease = SSDCheckpointStageReservation(
            key: "lease", bytes: 1024, budget: budget, activity: activity, stats: stats, holdsIO: holdsIO)
        barrier.arm()
        let resize = Task { await lease.resize(to: 2048) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var entered = false
        while ContinuousClock.now < deadline {
            if barrier.didEnter() { entered = true; break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(entered)
        lease.release()
        barrier.release.signal()
        #expect(await resize.value == false)
        if holdsIO {
            #expect(await budget.outstandingReservedBytes() == 2048)
            #expect(stats.snapshot().stagedBytesInUse == 2048)
            lease.finishIO()
        }
        await lease.waitForRefund()
        await activity.waitUntilDrained()
        #expect(stats.snapshot().stagedBytesInUse == 0)
        #expect(await budget.outstandingReservedBytes() == 0)
        #expect(await lease.resize(to: 4096) == false)
        lease.release()
        #expect(stats.snapshot().stagedBytesInUse == 0)
    }
}
