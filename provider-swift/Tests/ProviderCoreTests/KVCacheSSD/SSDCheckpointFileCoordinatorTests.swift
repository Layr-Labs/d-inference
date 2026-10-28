import Foundation
import Testing
@testable import ProviderCore

@Suite("Checkpoint per-file asynchronous coordination", .serialized)
struct SSDCheckpointFileCoordinatorTests {
    private let file = URL(fileURLWithPath: "/checkpoint-tests/first.dbk3")
    private let otherFile = URL(fileURLWithPath: "/checkpoint-tests/second.dbk3")

    /// The order in which queued accesses were granted.
    private final class Grants: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String] = []
        var order: [String] { lock.withLock { names } }
        func record(_ name: String) { lock.withLock { names.append(name) } }
    }

    private func acquire(_ access: SSDCheckpointFileCoordinator.Access, as name: String,
                         into grants: Grants) -> Task<Void, any Error> {
        Task {
            try await access.acquire()
            grants.record(name)
        }
    }

    @Test("maintenance skips an active commit or read and never jumps queued readers")
    func nonblockingMaintenance() async throws {
        let coordinator = SSDCheckpointFileCoordinator()
        let writer = try #require(coordinator.tryAcquire(to: file))
        defer { writer.release() }
        #expect(coordinator.tryAcquire(to: file) == nil)
        let independent = try #require(coordinator.tryAcquire(to: otherFile))
        independent.release()
        let reader = coordinator.makeAccess(to: file, mode: .shared)
        let task = Task { try await reader.acquire() }
        defer { task.cancel(); reader.cancel(); reader.release() }
        try await SSDCheckpointCoordinationTestSupport.waitUntil { coordinator.pendingCount(for: file) == 1 }
        #expect(coordinator.tryAcquire(to: file) == nil)
        writer.release()
        try await task.value
        #expect(coordinator.tryAcquire(to: file) == nil)
        reader.release()
        let retirement = try #require(coordinator.tryAcquire(to: file))
        retirement.release()
        #expect(coordinator.trackedFileCount == 0)
    }

    @Test("same-file waiters are FIFO and unrelated files proceed independently")
    func fifoAndIndependentFiles() async throws {
        let coordinator = SSDCheckpointFileCoordinator()
        let owner = coordinator.makeAccess(to: file)
        try await owner.acquire()
        defer { owner.release() }
        let first = coordinator.makeAccess(to: file)
        let firstTask = Task { try await first.acquire() }
        defer { firstTask.cancel(); first.cancel(); first.release() }
        try await SSDCheckpointCoordinationTestSupport.waitUntil { coordinator.pendingCount(for: file) == 1 }
        let second = coordinator.makeAccess(to: file)
        let secondTask = Task { try await second.acquire() }
        defer { secondTask.cancel(); second.cancel(); second.release() }
        try await SSDCheckpointCoordinationTestSupport.waitUntil { coordinator.pendingCount(for: file) == 2 }
        let independent = coordinator.makeAccess(to: otherFile)
        try await independent.acquire()
        #expect(coordinator.trackedFileCount == 2)
        independent.release()
        owner.release()
        try await firstTask.value
        #expect(coordinator.pendingCount(for: file) == 1)
        first.release()
        try await secondTask.value
        second.release()
        #expect(coordinator.trackedFileCount == 0)
    }

    @Test("shared readers hold a file together; a writer waits for every one of them")
    func sharedReadersOverlap() async throws {
        let coordinator = SSDCheckpointFileCoordinator()
        let grants = Grants()
        let first = coordinator.makeAccess(to: file, mode: .shared)
        try await first.acquire()
        defer { first.release() }
        let second = coordinator.makeAccess(to: file, mode: .shared)
        let secondTask = acquire(second, as: "second", into: grants)
        defer { secondTask.cancel(); second.cancel(); second.release() }
        try await SSDCheckpointCoordinationTestSupport.waitUntil { grants.order == ["second"] }
        try await secondTask.value
        #expect(coordinator.pendingCount(for: file) == 0)
        #expect(coordinator.trackedFileCount == 1)
        #expect(coordinator.tryAcquire(to: file) == nil)
        let writer = coordinator.makeAccess(to: file)
        let writerTask = acquire(writer, as: "writer", into: grants)
        defer { writerTask.cancel(); writer.cancel(); writer.release() }
        try await SSDCheckpointCoordinationTestSupport.waitUntil { coordinator.pendingCount(for: file) == 1 }
        first.release()
        #expect(coordinator.pendingCount(for: file) == 1, "one reader still holds the file")
        #expect(grants.order == ["second"])
        second.release()
        try await SSDCheckpointCoordinationTestSupport.waitUntil { grants.order.count == 2 }
        try await writerTask.value
        #expect(grants.order == ["second", "writer"])
        #expect(coordinator.tryAcquire(to: file) == nil)
        writer.release()
        #expect(coordinator.trackedFileCount == 0)
    }

    @Test("a queued writer holds back later readers, which then enter together")
    func queuedWriterOrdersLaterReaders() async throws {
        let coordinator = SSDCheckpointFileCoordinator()
        let grants = Grants()
        let reader = coordinator.makeAccess(to: file, mode: .shared)
        try await reader.acquire()
        defer { reader.release() }
        let writer = coordinator.makeAccess(to: file)
        let writerTask = acquire(writer, as: "writer", into: grants)
        defer { writerTask.cancel(); writer.cancel(); writer.release() }
        try await SSDCheckpointCoordinationTestSupport.waitUntil { coordinator.pendingCount(for: file) == 1 }
        let late = (0..<2).map { _ in coordinator.makeAccess(to: file, mode: .shared) }
        let lateTasks = late.enumerated().map { acquire($0.element, as: "late\($0.offset)", into: grants) }
        defer { for (task, access) in zip(lateTasks, late) { task.cancel(); access.cancel(); access.release() } }
        try await SSDCheckpointCoordinationTestSupport.waitUntil { coordinator.pendingCount(for: file) == 3 }
        #expect(grants.order.isEmpty, "later readers must not join the active reader past a queued writer")
        reader.release()
        try await SSDCheckpointCoordinationTestSupport.waitUntil { !grants.order.isEmpty }
        try await writerTask.value
        #expect(grants.order == ["writer"])
        #expect(coordinator.pendingCount(for: file) == 2)
        writer.release()
        try await SSDCheckpointCoordinationTestSupport.waitUntil { grants.order.count == 3 }
        for task in lateTasks { try await task.value }
        #expect(grants.order.first == "writer" && Set(grants.order.dropFirst()) == ["late0", "late1"])
        #expect(coordinator.pendingCount(for: file) == 0)
        for access in late { access.release() }
        #expect(coordinator.trackedFileCount == 0)
    }

    @Test("upgrade needs the only holder and no queued request; downgrade admits waiting readers")
    func upgradeAndDowngrade() async throws {
        let coordinator = SSDCheckpointFileCoordinator()
        let grants = Grants()
        let owner = coordinator.makeAccess(to: file, mode: .shared)
        #expect(!owner.tryUpgrade(), "an access that holds nothing cannot upgrade")
        try await owner.acquire()
        defer { owner.release() }
        #expect(owner.tryUpgrade())
        #expect(!owner.tryUpgrade(), "already exclusive")
        let reader = coordinator.makeAccess(to: file, mode: .shared)
        let readerTask = acquire(reader, as: "reader", into: grants)
        defer { readerTask.cancel(); reader.cancel(); reader.release() }
        try await SSDCheckpointCoordinationTestSupport.waitUntil { coordinator.pendingCount(for: file) == 1 }
        #expect(coordinator.tryAcquire(to: file) == nil)
        owner.downgrade()
        try await SSDCheckpointCoordinationTestSupport.waitUntil { grants.order == ["reader"] }
        try await readerTask.value
        #expect(!owner.tryUpgrade() && !reader.tryUpgrade(), "neither of two readers may upgrade")
        reader.release()
        let writer = coordinator.makeAccess(to: file)
        let writerTask = acquire(writer, as: "writer", into: grants)
        defer { writerTask.cancel(); writer.cancel(); writer.release() }
        try await SSDCheckpointCoordinationTestSupport.waitUntil { coordinator.pendingCount(for: file) == 1 }
        #expect(!owner.tryUpgrade(), "a sole reader cannot overtake a queued writer")
        owner.release()
        try await SSDCheckpointCoordinationTestSupport.waitUntil { grants.order == ["reader", "writer"] }
        try await writerTask.value
        #expect(!writer.tryUpgrade() && !owner.tryUpgrade())
        owner.downgrade()
        #expect(coordinator.tryAcquire(to: file) == nil, "downgrading a released access changes nothing")
        writer.release()
        #expect(coordinator.trackedFileCount == 0)
    }

    @Test("a writer that queued during an upgrade keeps its place when the holder downgrades")
    func downgradeKeepsQueuedWriterFirst() async throws {
        let coordinator = SSDCheckpointFileCoordinator()
        let grants = Grants()
        let owner = coordinator.makeAccess(to: file, mode: .shared)
        try await owner.acquire()
        defer { owner.release() }
        #expect(owner.tryUpgrade())
        let writer = coordinator.makeAccess(to: file)
        let writerTask = acquire(writer, as: "writer", into: grants)
        defer { writerTask.cancel(); writer.cancel(); writer.release() }
        try await SSDCheckpointCoordinationTestSupport.waitUntil { coordinator.pendingCount(for: file) == 1 }
        let reader = coordinator.makeAccess(to: file, mode: .shared)
        let readerTask = acquire(reader, as: "reader", into: grants)
        defer { readerTask.cancel(); reader.cancel(); reader.release() }
        try await SSDCheckpointCoordinationTestSupport.waitUntil { coordinator.pendingCount(for: file) == 2 }
        owner.downgrade()
        #expect(coordinator.pendingCount(for: file) == 2, "the reader must not pass the queued writer")
        #expect(grants.order.isEmpty)
        owner.release()
        try await writerTask.value
        #expect(grants.order == ["writer"] && coordinator.pendingCount(for: file) == 1)
        writer.release()
        try await readerTask.value
        #expect(grants.order == ["writer", "reader"])
        reader.release()
        #expect(coordinator.trackedFileCount == 0)
    }

    @Test("a withdrawn queued writer readmits readers behind it; a withdrawn reader holds nothing")
    func cancelledSharedWaiters() async throws {
        let coordinator = SSDCheckpointFileCoordinator()
        let grants = Grants()
        let reader = coordinator.makeAccess(to: file, mode: .shared)
        try await reader.acquire()
        defer { reader.release() }
        let writer = coordinator.makeAccess(to: file)
        let writerTask = acquire(writer, as: "writer", into: grants)
        defer { writerTask.cancel(); writer.cancel(); writer.release() }
        try await SSDCheckpointCoordinationTestSupport.waitUntil { coordinator.pendingCount(for: file) == 1 }
        let queued = coordinator.makeAccess(to: file, mode: .shared)
        let queuedTask = acquire(queued, as: "queued", into: grants)
        defer { queuedTask.cancel(); queued.cancel(); queued.release() }
        try await SSDCheckpointCoordinationTestSupport.waitUntil { coordinator.pendingCount(for: file) == 2 }
        writerTask.cancel()
        await #expect(throws: CancellationError.self) { try await writerTask.value }
        try await SSDCheckpointCoordinationTestSupport.waitUntil { grants.order == ["queued"] }
        try await queuedTask.value
        #expect(coordinator.pendingCount(for: file) == 0)
        reader.release()
        queued.release()
        #expect(coordinator.trackedFileCount == 0)

        let commit = try #require(coordinator.tryAcquire(to: file))
        let blocked = coordinator.makeAccess(to: file, mode: .shared)
        let blockedTask = Task { try await blocked.acquire() }
        defer { blockedTask.cancel(); blocked.cancel(); blocked.release() }
        try await SSDCheckpointCoordinationTestSupport.waitUntil { coordinator.pendingCount(for: file) == 1 }
        blockedTask.cancel()
        await #expect(throws: CancellationError.self) { try await blockedTask.value }
        #expect(coordinator.pendingCount(for: file) == 0)
        #expect(coordinator.trackedFileCount == 1)
        commit.release()
        #expect(coordinator.trackedFileCount == 0)
        let retirement = try #require(coordinator.tryAcquire(to: file))
        retirement.release()
    }

    @Test("queued cancellation refunds a waiter without unlocking its active reader")
    func cancelledWaiter() async throws {
        let coordinator = SSDCheckpointFileCoordinator()
        let owner = coordinator.makeAccess(to: file)
        try await owner.acquire()
        defer { owner.release() }
        let queued = coordinator.makeAccess(to: file)
        let task = Task { try await queued.acquire() }
        defer { task.cancel(); queued.cancel(); queued.release() }
        try await SSDCheckpointCoordinationTestSupport.waitUntil { coordinator.pendingCount(for: file) == 1 }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(coordinator.pendingCount(for: file) == 0)
        #expect(coordinator.trackedFileCount == 1)
        owner.cancel()
        #expect(coordinator.trackedFileCount == 1)
        owner.release()
        owner.release()
        #expect(coordinator.trackedFileCount == 0)
    }

    @Test("explicit cancellation before or during enqueue leaves no tombstones")
    func explicitCancellation() async throws {
        let coordinator = SSDCheckpointFileCoordinator()
        let before = coordinator.makeAccess(to: file)
        before.cancel()
        await #expect(throws: CancellationError.self) { try await before.acquire() }
        let owner = coordinator.makeAccess(to: file)
        try await owner.acquire()
        defer { owner.release() }
        let queued = coordinator.makeAccess(to: file)
        let task = Task { try await queued.acquire() }
        defer { task.cancel(); queued.cancel(); queued.release() }
        try await SSDCheckpointCoordinationTestSupport.waitUntil { coordinator.pendingCount(for: file) == 1 }
        queued.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        owner.release()
        #expect(coordinator.trackedFileCount == 0)
    }

    @Test("handoff racing cancellation resumes exactly once and prunes every file",
          arguments: [SSDCheckpointFileCoordinator.Mode.exclusive, .shared])
    func cancellationHandoff(waiterMode: SSDCheckpointFileCoordinator.Mode) async throws {
        let coordinator = SSDCheckpointFileCoordinator()
        for offset in 0..<128 {
            let url = file.appendingPathComponent(String(offset))
            let owner = coordinator.makeAccess(to: url)
            try await owner.acquire()
            let queued = coordinator.makeAccess(to: url, mode: waiterMode)
            let task = Task {
                defer { queued.release() }
                try await queued.acquire()
            }
            defer { owner.release(); task.cancel(); queued.cancel(); queued.release() }
            try await SSDCheckpointCoordinationTestSupport.waitUntil { coordinator.pendingCount(for: url) == 1 }
            let cancellation = Task.detached { task.cancel() }
            owner.release()
            await cancellation.value
            do { try await task.value } catch is CancellationError { }
            #expect(coordinator.trackedFileCount == 0)
        }
    }

    /// Modes inside each file between a grant and its release, recorded
    /// independently of the coordinator.
    private final class Occupancy: @unchecked Sendable {
        private let lock = NSLock()
        private var held: [String: (shared: Int, exclusive: Int)] = [:]
        private var conflicts: [String] = []
        var violations: [String] { lock.withLock { conflicts } }

        func enter(_ path: String, _ mode: SSDCheckpointFileCoordinator.Mode) {
            lock.withLock {
                var inside = held[path, default: (0, 0)]
                if inside.exclusive > 0 || (mode == .exclusive && inside.shared > 0) {
                    conflicts.append("\(mode) entered \(path) beside \(inside)")
                }
                if mode == .shared { inside.shared += 1 } else { inside.exclusive += 1 }
                held[path] = inside
            }
        }

        func leave(_ path: String, _ mode: SSDCheckpointFileCoordinator.Mode) {
            lock.withLock {
                if mode == .shared { held[path]?.shared -= 1 } else { held[path]?.exclusive -= 1 }
            }
        }
    }

    private struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var mixed = state
            mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
            mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
            return mixed ^ (mixed >> 31)
        }
    }

    @Test("random grants, cancellations, upgrades and releases never share a file with an exclusive holder and drain",
          arguments: [UInt64(1), 2, 3, 4])
    func randomizedSchedules(seed: UInt64) async throws {
        let coordinator = SSDCheckpointFileCoordinator()
        let occupancy = Occupancy()
        let urls = (0..<3).map { file.appendingPathComponent(String($0)) }
        let workers = Task {
            await withTaskGroup(of: Void.self) { group in
                for worker in 0..<32 {
                    group.addTask {
                        var random = SplitMix64(state: seed << 8 | UInt64(worker))
                        for _ in 0..<100 {
                            let url = urls[Int.random(in: 0..<urls.count, using: &random)]
                            let roll = Int.random(in: 0..<10, using: &random)
                            if roll == 0 {
                                guard let maintenance = coordinator.tryAcquire(to: url) else { continue }
                                occupancy.enter(url.path, .exclusive)
                                await Task.yield()
                                occupancy.leave(url.path, .exclusive)
                                maintenance.release()
                                continue
                            }
                            let mode: SSDCheckpointFileCoordinator.Mode = roll < 7 ? .shared : .exclusive
                            let access = coordinator.makeAccess(to: url, mode: mode)
                            let attempt = Task { try await access.acquire() }
                            if Int.random(in: 0..<5, using: &random) == 0 { attempt.cancel() }
                            do {
                                try await withTaskCancellationHandler {
                                    try await attempt.value
                                } onCancel: {
                                    attempt.cancel()
                                }
                            } catch {
                                #expect(!access.tryUpgrade(), "a withdrawn request holds nothing")
                                continue
                            }
                            occupancy.enter(url.path, mode)
                            if mode == .shared, Bool.random(using: &random), access.tryUpgrade() {
                                occupancy.leave(url.path, .shared)
                                occupancy.enter(url.path, .exclusive)
                                await Task.yield()
                                occupancy.leave(url.path, .exclusive)
                                occupancy.enter(url.path, .shared)
                                access.downgrade()
                            }
                            await Task.yield()
                            // Lifecycle cancellation of an active holder keeps its lease.
                            if Int.random(in: 0..<4, using: &random) == 0 { access.cancel() }
                            await Task.yield()
                            occupancy.leave(url.path, mode)
                            access.release()
                        }
                    }
                }
            }
        }
        let watchdog = Task { () -> Bool in
            do { try await Task.sleep(for: .seconds(10)) } catch { return false }
            workers.cancel()
            return true
        }
        await workers.value
        watchdog.cancel()
        #expect(await !watchdog.value, "a queued request was never granted")
        #expect(occupancy.violations.isEmpty, "\(occupancy.violations.prefix(3))")
        #expect(coordinator.trackedFileCount == 0)
    }
}
