import Foundation
import Testing
@testable import ProviderCore

/// Pauses a real sweep at the existing active-store mutation barrier, without
/// adding a production hook or requiring a large/slow filesystem fixture, and
/// takes a heartbeat snapshot there. The paused sweep holds
/// `SSDDiskBudget.shared`'s lock, which parallel suites take on cooperative-pool
/// threads, so the snapshot runs on its own thread and the pause is bounded:
/// nothing that ends it needs a pool thread.
private final class SnapshotDuringSweepStore: SSDEvictableStore, @unchecked Sendable {
    let evictionRoot: URL
    private let maintainer: SSDWholeRootMaintainer
    private let lock = NSLock()
    private var pauses = 0
    private var snapshotWasAvailable = false
    private var snapshot: SSDWholeRootMaintainer.Stats?
    init(root: URL, maintainer: SSDWholeRootMaintainer) {
        evictionRoot = root
        self.maintainer = maintainer
    }
    var ownsEvictionRoot: Bool { true }
    var diskBytesOnDisk: Int { 0 }
    func oldestEntryAccess() -> Int64? { nil }
    func evictOldestEntry() -> Int { 0 }
    func reconcileExternalRemovals() {}
    func retireOwnedEntries(_ urls: [URL]) -> Set<String> {
        var removed = Set<String>()
        _ = performExternalDestructiveChange {
            for url in urls where SSDBlockStore.removeItemIfSafe(at: url, under: evictionRoot) {
                removed.insert(url.standardizedFileURL.path)
            }
        }
        return removed
    }
    func performExternalDestructiveChange(_ body: () -> Void) -> Bool {
        let returned = DispatchSemaphore(value: 0)
        // Its own thread, not a GCD worker: while the pool is full of threads
        // blocked on the budget lock, GCD did not start default-QoS work for 5 s.
        Thread { [self] in
            let stats = maintainer.statsSnapshot()
            lock.withLock { snapshot = stats }
            returned.signal()
        }.start()
        // A snapshot that waits for the sweep fails the test here instead of
        // holding the shared budget lock until the run's watchdog.
        let available = returned.wait(timeout: .now() + 5) == .success
        lock.withLock {
            pauses += 1
            snapshotWasAvailable = available
        }
        body()
        return true
    }
    var observed: (pauses: Int, snapshotWasAvailable: Bool, snapshot: SSDWholeRootMaintainer.Stats?) {
        lock.withLock { (pauses, snapshotWasAvailable, snapshot) }
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

        let maintainer = SSDWholeRootMaintainer()
        let paused = SnapshotDuringSweepStore(root: fixture.modelRoot, maintainer: maintainer)
        SSDDiskBudget.shared.register(paused)
        defer { SSDDiskBudget.shared.deregister(paused) }
        let swept = try await onGCD {
            maintainer.maintain(root: fixture.root, ttlSeconds: 1,
                nowSeconds: Int64(Date().timeIntervalSince1970) + 7200,
                budgetBytes: Int.max)
        }
        #expect(swept.ttlExpired == 1)
        let observed = paused.observed
        try #require(observed.pauses == 1)
        #expect(observed.snapshotWasAvailable, "capacity heartbeat must not wait for the sweep")
        if observed.snapshotWasAvailable { #expect(observed.snapshot?.ttlExpired == 0) }
        #expect(maintainer.statsSnapshot().ttlExpired == 1)
    }
}
