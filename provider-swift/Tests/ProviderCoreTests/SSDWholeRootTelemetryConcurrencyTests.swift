import Foundation
import Testing
@testable import ProviderCore

/// Pauses a real sweep at the existing active-store mutation barrier, without
/// adding a production hook or requiring a large/slow filesystem fixture.
private final class PausedMaintenanceStore: SSDEvictableStore, @unchecked Sendable {
    let evictionRoot: URL
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    init(root: URL) { evictionRoot = root }
    var diskBytesOnDisk: Int { 0 }
    func oldestEntryAccess() -> Int64? { nil }
    func evictOldestEntry() -> Int { 0 }
    func reconcileExternalRemovals() {}
    func performExternalDestructiveChange(_ body: () -> Void) -> Bool {
        entered.signal()
        release.wait()
        body()
        return true
    }
}

@Suite("Whole-root telemetry concurrency")
struct SSDWholeRootTelemetryConcurrencyTests {
    @Test("heartbeat snapshot remains available during a paused filesystem sweep")
    func snapshotDoesNotWaitForSweep() async throws {
        let fixture = try SSDHybridCheckpointTestFixture()
        defer { fixture.remove() }
        let donor = try fixture.makeStore()
        #expect(try await fixture.donate(donor) == [256])
        await donor.closeAndWait()

        let paused = PausedMaintenanceStore(root: fixture.modelRoot)
        SSDDiskBudget.shared.register(paused)
        defer { paused.release.signal(); SSDDiskBudget.shared.deregister(paused) }
        let maintainer = SSDWholeRootMaintainer()
        let sweep = Task.detached {
            maintainer.maintain(root: fixture.root, ttlSeconds: 1,
                nowSeconds: Int64(Date().timeIntervalSince1970) + 7200,
                budgetBytes: Int.max)
        }
        // Poll rather than blocking a cooperative executor thread.
        func signalled(_ semaphore: DispatchSemaphore) -> Bool {
            semaphore.wait(timeout: .now()) == .success
        }
        func waitForSignal(_ semaphore: DispatchSemaphore) async -> Bool {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while ContinuousClock.now < deadline {
                if signalled(semaphore) { return true }
                try? await Task.sleep(for: .milliseconds(1))
            }
            return false
        }
        let sweepPaused = await waitForSignal(paused.entered)
        #expect(sweepPaused)
        let snapshotFinished = DispatchSemaphore(value: 0)
        let snapshot = Task.detached {
            let result = maintainer.statsSnapshot()
            snapshotFinished.signal()
            return result
        }
        let snapshotWasAvailable = await waitForSignal(snapshotFinished)
        #expect(snapshotWasAvailable, "capacity heartbeat must not wait for the sweep")
        paused.release.signal()
        #expect(await sweep.value.ttlExpired == 1)
        let duringSweep = await snapshot.value
        if snapshotWasAvailable { #expect(duringSweep.ttlExpired == 0) }
        #expect(maintainer.statsSnapshot().ttlExpired == 1)
    }
}
